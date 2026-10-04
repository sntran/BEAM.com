// A snapshot of the booted VM for the Workers of beam.com --target wasm32
// (docs/WORKERS.md, "Snapshots"). It boots the release of DIR
// in Node.js (26, for JSPI) as worker.js does, optionally sends requests to
// warm it up, asks all the threads of ERTS to return (erts_wasm_hibernate),
// and writes DIR/release/snapshot.bin. worker.js restores it in place of a
// boot, and global.js (wrangler.global.jsonc) in the global scope of the
// Worker.
//
//   node snapshot.mjs DIR [--warm PORT:PATH]... [--after MS]
//   node snapshot.mjs DIR --boot-point   a snapshot at the boot point: before
//                                        runtime.exs and the program (Ecto SQLite)
//   node snapshot.mjs DIR --check PORT:PATH     restore it here, 3 requests
//
// The environment of the boot (SECRET_KEY_BASE, PHX_HOST, ...) is in the
// snapshot: give it here (--env NAME=VALUE), as the Worker would.
import fs from 'node:fs';
import path from 'node:path';

const argv = process.argv.slice(2);
const dir = argv.shift();
const opts = { warm: [], env: {}, after: 1500, check: null, bootPoint: false };
while (argv.length) {
  const a = argv.shift();
  if (a === '--warm') opts.warm.push(argv.shift());
  else if (a === '--after') opts.after = Number(argv.shift());
  else if (a === '--check') opts.check = argv.shift();
  else if (a === '--boot-point') opts.bootPoint = true;
  else if (a === '--env') { const [k, ...v] = argv.shift().split('='); opts.env[k] = v.join('='); }
  else throw new Error(`unknown option ${a}`);
}
if (!dir) throw new Error('usage: node snapshot.mjs DIR [--warm PORT:PATH]... [--after MS] [--env NAME=VALUE]... | --check PORT:PATH');

const { default: createBeam } = await import(path.resolve(dir, 'beam.mjs'));
const wasmBytes = fs.readFileSync(path.join(dir, 'beam.wasm'));
const release = fs.readFileSync(path.join(dir, 'release', 'release.bin'));
const out = path.join(dir, 'release', 'snapshot.bin');
const t0 = performance.now();
const log = (s) => console.error(`[${(performance.now() - t0).toFixed(1)} ms] ${s}`);
const PAGE = 65536;

// As worker.js: the files of release.bin in /app (views, not copies).
function unpack(FS, b) {
  const view = new DataView(b.buffer, b.byteOffset, b.byteLength), text = new TextDecoder();
  let meta = null;
  const dirs = new Set();
  for (let i = 8; i < b.length;) {
    const plen = view.getUint32(i); i += 4; const p = text.decode(b.subarray(i, i + plen)); i += plen;
    const dlen = view.getUint32(i); i += 4; const data = b.subarray(i, i + dlen); i += dlen;
    if (p === '.release.json') { meta = JSON.parse(text.decode(data)); continue; }
    const full = '/app/' + p, d = full.slice(0, full.lastIndexOf('/'));
    if (!dirs.has(d)) { FS.mkdirTree(d); dirs.add(d); }
    FS.writeFile(full, data, { canOwn: true });
  }
  return meta;
}

// The files that the boot wrote (not in release.bin), and the open files.
function fsState(FS, since) {
  const files = {};
  const walk = (d) => {
    for (const n of FS.readdir(d)) {
      if (n === '.' || n === '..') continue;
      const p = d === '/' ? '/' + n : d + '/' + n;
      if (p === '/dev' || p === '/proc') continue;
      const st = FS.stat(p);
      if (FS.isDir(st.mode)) walk(p);
      else if (FS.isFile(st.mode) && st.mtime.getTime() >= since) files[p] = Buffer.from(FS.readFile(p)).toString('base64');
    }
  };
  walk('/');
  const pipes = new Map();
  const streams = FS.streams.map((s, fd) => {
    if (!s) return null;
    if (s.node?.pipe) {
      if (!pipes.has(s.node.pipe)) pipes.set(s.node.pipe, pipes.size);
      const buffered = s.node.pipe.buckets.reduce((n, b) => n + b.offset - b.roffset, 0);
      if (buffered) throw new Error(`fd ${fd}: ${buffered} bytes in the pipe`);
      return { fd, pipe: pipes.get(s.node.pipe), flags: s.flags };
    }
    return { fd, path: s.path, flags: s.flags, position: s.position };
  }).filter(Boolean);
  return { files, streams };
}

let exports, m;
const listeners = {};
let answer = null;

// The host side of wasm_host: listeners, and one HTTP request at a time.
function onsend(bytes) {
  const nl = bytes.indexOf(10);
  const msg = JSON.parse(new TextDecoder().decode(bytes.subarray(0, nl)));
  const body = bytes.subarray(nl + 1);
  if (msg.t === 'ready') log('ready');
  else if (msg.t === 'boot_point') { log('boot point'); atBootPoint(); }
  else if (msg.t === 'tcp_listen') {
    listeners[msg.fetch ? 'fetch' : msg.port] = msg.id;
    if (msg.fetch && msg.tls) listeners['fetch-tls'] = msg.id;
    push({ t: 'tcp_listening', id: msg.id });
  } else if (msg.t === 'tcp_send' && answer) answer(body);
}
function push(h, body = new Uint8Array()) {
  const head = new TextEncoder().encode(JSON.stringify(h) + '\n');
  const b = new Uint8Array(head.length + body.length);
  b.set(head); b.set(body, head.length);
  m.beamHost.push(b);
}
let conn = 0;
async function request(spec) {
  const [port, p] = spec.split(/:(.*)/s);
  const id = `s${++conn}`;
  const t = performance.now();
  // After a restore at the boot point, the program starts its listener.
  for (let i = 0; !listeners[port] && i < 2000; i++) await new Promise((r) => setTimeout(r, 5));
  return new Promise((resolve, reject) => {
    if (!listeners[port]) return reject(new Error(`nothing listens on ${port}`));
    let bytes = Buffer.alloc(0);
    answer = (b) => {
      bytes = Buffer.concat([bytes, b]);
      const end = bytes.indexOf('\r\n\r\n');
      if (end < 0) return;
      const head = bytes.subarray(0, end).toString('latin1');
      const len = /content-length: *(\d+)/i.exec(head)?.[1];
      const done = len !== undefined ? bytes.length >= end + 4 + Number(len)
        : /transfer-encoding: *chunked/i.test(head) ? bytes.subarray(-5).toString() === '0\r\n\r\n' : true;
      if (done) {
        answer = null;
        resolve({ status: head.split('\r\n')[0], ms: performance.now() - t });
      }
    };
    push({ t: 'tcp_accept', id: listeners[port], conn: id, host: '127.0.0.1', port: 40000 + conn });
    push({ t: 'tcp_data', id }, new TextEncoder().encode(`GET ${p} HTTP/1.1\r\nhost: localhost\r\n\r\n`));
  });
}

let atBootPoint = () => {};
let relMeta = null;  // .release.json, for --check
const bootPointReached = new Promise((r) => { atBootPoint = r; });

const env = (m, meta) => Object.assign(m.ENV, {
  ROOTDIR: '/app', BINDIR: '/app/bin', EMU: 'beam', PROGNAME: 'erl', HOME: '/',
  RELEASE_ROOT: '/app', RELEASE_NAME: meta.name, RELEASE_VSN: meta.vsn, RELEASE_MODE: 'interactive',
  RELEASE_TMP: '/app/tmp', RELEASE_SYS_CONFIG: '/app/tmp/run.runtime', RELEASE_PROG: meta.name,
  WASM_HOST: '1',
}, meta.env, opts.env, opts.bootPoint && !opts.check ? { WASM_HOST_BOOT_POINT: 'wait' } : {});

const common = {
  arguments: [],
  print: (s) => console.log(s),
  printErr: (s) => console.error(s),
  instantiateWasm: (imports, done) => {
    WebAssembly.instantiate(wasmBytes, imports).then(({ instance }) => { exports = instance.exports; done(instance); });
    return {};
  },
};

if (!opts.check) {
  let since;
  createBeam({
    ...common,
    preRun: [(mod) => {
      m = mod;
      const meta = unpack(m.FS, release);
      since = Date.now();
      // -c false: no time correction. The monotonic time then follows the
      // system time, which goes on after a restore (the OS monotonic time
      // of a new instance starts again at 0: ERTS would stop).
      m.arguments.push('-S', '1', '-SDcpu', '1', '-A', '0', '-c', 'false', '--',
        '-root', '/app', '-bindir', '/app/bin', '-progname', 'erl', '--', '-home', '/', ...meta.args, '-noshell');
      env(m, meta);
      m.beamHost.onsend = onsend;
    }],
    onExit: (code) => { log(`the VM stopped (${code})`); process.exit(1); },
  });
  if (opts.bootPoint) await bootPointReached;
  else await new Promise((r) => setTimeout(r, opts.after));
  for (const w of opts.bootPoint ? [] : opts.warm) {
    const r = await request(w);
    log(`warm-up ${w}: ${r.status} in ${r.ms.toFixed(1)} ms`);
  }
  await new Promise((r) => setTimeout(r, 300));
  exports.erts_wasm_hibernate();
  const start = performance.now();
  while (exports.jspi_live_threads() > 0) {
    if (performance.now() - start > 5000) {
      exports.jspi_report_live();
      await new Promise((r) => setTimeout(r, 50));
      throw new Error('the threads of ERTS did not return: no snapshot');
    }
    await new Promise((r) => setImmediate(r));
  }
  const heap = m.HEAPU8;
  const pages = [];
  for (let p = 0; p < heap.length / PAGE; p++) {
    if (heap.subarray(p * PAGE, (p + 1) * PAGE).some((b) => b !== 0)) pages.push(p);
  }
  // The NIF libraries in WebAssembly: their pages come after the pages of
  // the VM, as in capture() of worker.js.
  const libs = m.nifHost?.loaded() ? m.nifHost.save() : null;
  const libData = libs ? libs.libs.flatMap((l) => l.data) : [];
  const data = Buffer.alloc((pages.length + libData.length) * PAGE);
  pages.forEach((p, i) => data.set(heap.subarray(p * PAGE, (p + 1) * PAGE), i * PAGE));
  libData.forEach((d, i) => data.set(d, (pages.length + i) * PAGE));
  const nifs = libs && { count: libs.count, libs: libs.libs.map(({ data, ...l }) => l) };
  const head = Buffer.from(JSON.stringify({ size: heap.length, pages, fs: fsState(m.FS, since), listeners, boot_point: opts.bootPoint, nifs }));
  const len = Buffer.alloc(4);
  len.writeUInt32BE(head.length);
  fs.writeFileSync(out, Buffer.concat([Buffer.from('BEAMSNP1'), len, head, data]));
  log(`${out}: ${pages.length} of ${heap.length / PAGE} pages of 64 KiB${libs ? ` and ${libData.length} pages of ${libs.libs.length} NIF libraries` : ''} (${(data.length / 1048576).toFixed(1)} MB)`);
  // workerd: the Worker with the release gets the module too.
  const capnp = path.join(dir, 'worker.capnp');
  const c = fs.readFileSync(capnp, 'utf8');
  if (!c.includes('snapshot.bin')) {
    fs.writeFileSync(capnp, c.replace('(name = "release.bin", data = embed "release/release.bin"),',
      '(name = "release.bin", data = embed "release/release.bin"),\n    (name = "snapshot.bin", data = embed "release/snapshot.bin"),'));
  }
  process.exit(0);
} else {
  // The restore of worker.js (restore()), here.
  const b = fs.readFileSync(out);
  const len = b.readUInt32BE(8);
  const snap = JSON.parse(b.subarray(12, 12 + len));
  const pagesData = b.subarray(12 + len);
  createBeam({
    ...common,
    noInitialRun: true,
    preRun: [(mod) => {
      m = mod;
      const meta = relMeta = unpack(m.FS, release);
      for (const [p, b64] of Object.entries(snap.fs.files)) {
        m.FS.mkdirTree(p.slice(0, p.lastIndexOf('/')));
        m.FS.writeFile(p, Buffer.from(b64, 'base64'));
      }
      env(m, meta);
      m.beamHost.onsend = onsend;
    }],
    onRuntimeInitialized() {
      const first = m.HEAPU8.length / PAGE, have = new Set(snap.pages);
      for (let p = 0; p < first; p++) if (!have.has(p)) m.HEAPU8.fill(0, p * PAGE, (p + 1) * PAGE);
      if (!exports.jspi_snapshot_grow(snap.size)) throw new Error('no memory');
      snap.pages.forEach((p, i) => m.HEAPU8.set(pagesData.subarray(i * PAGE, (i + 1) * PAGE), p * PAGE));
      if (snap.nifs) {
        let at = snap.pages.length * PAGE;
        const libs = snap.nifs.libs.map((l) => ({
          ...l, data: l.pages.map(() => { const d = pagesData.subarray(at, at + PAGE); at += PAGE; return d; }),
        }));
        m.nifHost.restore({ count: snap.nifs.count, libs }, (f) => m.FS.readFile(f));
      }
      const made = new Set();
      for (const s of snap.fs.streams) {
        if (s.fd <= 2) continue;
        if (s.pipe !== undefined) {
          if (!made.has(s.pipe)) { made.add(s.pipe); exports.jspi_snapshot_pipe(); }
          const got = m.FS.getStream(s.fd);
          if (!got?.node?.pipe) throw new Error(`fd ${s.fd} is not a pipe`);
          got.flags = s.flags;
        } else {
          const st = m.FS.open(s.path, s.flags);
          if (st.fd !== s.fd) throw new Error(`fd ${s.fd} is ${st.fd}`);
          st.position = s.position;
        }
      }
      Object.assign(listeners, snap.listeners);
      exports.wasm_host_restore();
      log(`restored: ${exports.erts_wasm_resume()} threads`);
      push({ t: 'restored' }, crypto.getRandomValues(new Uint8Array(48)));
      // A snapshot of the boot point: the boot goes on, with this environment.
      if (snap.boot_point) push({ t: 'go' }, new TextEncoder().encode(JSON.stringify({ ...relMeta.env, ...opts.env })));
      (async () => {
        for (let i = 0; i < 3; i++) {
          const r = await request(opts.check);
          log(`${opts.check}: ${r.status} in ${r.ms.toFixed(1)} ms`);
        }
        process.exit(0);
      })();
    },
  });
}
