// The BEAM on Cloudflare Workers: a Worker with the WebAssembly emulator
// (threads on JSPI, the runtime of wasm/erts, with no files) and no
// application. At the first request of an isolate, it gets a release
// (release.bin of beam_com_wasm), writes it into its file system at /app and boots
// it; the next requests to the isolate use the same VM. The release comes
// from:
// - a service binding APP (another Worker, as app.js): GET /release.bin;
// - else a text binding RELEASE_URL (R2, any URL): a fetch of that URL;
// - else a module release.bin in this Worker.
// A Durable Object can hold the VM in place of the isolate: see Vm.
//
// The HTTP server of the app (Bandit, with gen_tcp of wasm_tcp) listens on
// PORT (4000), and each request is a TCP connection to it (bridge): the
// request as HTTP/1.1 bytes, the response read back, and WebSocket frames
// turned into messages.
//
// Workers get no TCP connections: a WebSocket to /.tcp/PORT is a connection
// to the listener of PORT (gen_tcp:listen of wasm_tcp), and its binary
// messages are the bytes (a client proxy, as tcp-proxy.mjs or websocat -b,
// makes a local TCP port of it).
//
// The events between the host and Erlang (wasm_host) are those of
// wasm_host_server.erl; outgoing wasm_tcp sockets use node:net. Node.js
// and Deno have it, and Workers have it with nodejs_compat (on
// cloudflare:sockets), the default from the compatibility date 2026-08-04.
// TLS runs in Erlang (ssl), over this socket.
//
// "beam.com INPUT -o DIR --target wasm32" writes this file into DIR, with
// the runtime (beam.mjs, beam.wasm) and the release (release.bin).
import net from 'node:net';
import createBeam from './beam.mjs';
import wasm from './beam.wasm';

// The NIF libraries in WebAssembly of the release (docs/NIFS.md), compiled
// by Wrangler: a Worker cannot compile WebAssembly at run time. nifs.js of
// "beam.com --target wasm32" maps the path of each file in /app to its
// module; the other hosts compile the files at run time (null).
async function nifModules() {
  return (await import('./nifs.js')).default;
}

// The module of the NIF library FILE: the key of nifs.js is its path in
// the release (lib/APP-VSN/priv/...). FILE can also be in a copy of priv
// (the priv files of a NIF app that beam.com copies to a directory), so
// the end of FILE must be APP-VSN/priv/...
function nifModule(nifs, file) {
  for (const [path, module] of Object.entries(nifs ?? {})) {
    if (file.endsWith('/' + path.slice(path.indexOf('/') + 1))) return module;
  }
  return null;
}

async function loadRelease(env) {
  if (env.APP) return (await env.APP.fetch('http://app/release.bin')).arrayBuffer();
  if (env.RELEASE_URL) return (await fetch(env.RELEASE_URL)).arrayBuffer();
  return (await import('./release.bin')).default;
}

// release.bin: "BEAMFS1\n", then (length, path, length, data) for each file.
// Or the files of appFiles (app-com.js): {meta, files}, with no copy.
function unpack(FS, bytes) {
  if (bytes.files) {
    const dirs = new Set();
    for (const [path, data] of bytes.files) {
      const full = '/app/' + path;
      const dir = full.slice(0, full.lastIndexOf('/'));
      if (!dirs.has(dir)) { FS.mkdirTree(dir); dirs.add(dir); }
      FS.writeFile(full, data, { canOwn: true });
    }
    return releaseMeta(bytes);
  }
  const b = new Uint8Array(bytes);
  const view = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const text = new TextDecoder();
  if (text.decode(b.subarray(0, 8)) !== 'BEAMFS1\n') throw new Error('release.bin: not a release');
  let meta = null;
  const dirs = new Set();
  for (let i = 8; i < b.length;) {
    const plen = view.getUint32(i); i += 4;
    const path = text.decode(b.subarray(i, i + plen)); i += plen;
    const dlen = view.getUint32(i); i += 4;
    const data = b.subarray(i, i + dlen); i += dlen;
    if (path === '.release.json') { meta = JSON.parse(text.decode(data)); continue; }
    const full = '/app/' + path;
    const dir = full.slice(0, full.lastIndexOf('/'));
    if (!dirs.has(dir)) { FS.mkdirTree(dir); dirs.add(dir); }
    // canOwn: the file is a view of release.bin, not a copy.
    FS.writeFile(full, data, { canOwn: true });
  }
  return meta;
}

// .release.json, the first file of release.bin.
export function releaseMeta(bytes) {
  if (bytes.meta) return JSON.parse(new TextDecoder().decode(bytes.meta));
  const b = new Uint8Array(bytes);
  const view = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const plen = view.getUint32(8);
  const dlen = view.getUint32(12 + plen);
  return JSON.parse(new TextDecoder().decode(b.subarray(16 + plen, 16 + plen + dlen)));
}

// The snapshots that the Worker makes itself (see Vm.makeSnapshot): in the
// R2 bucket of the binding SNAPSHOTS, else in the Cache API (of each data
// center). The key: the runtime, worker.js and the release (snapshot_key of
// .release.json, from the build), the text bindings, which the boot
// reads (a new secret gives a new snapshot), the host (a Worker or a
// Durable Object) and the version of the deploy (the binding BEAM_VERSION,
// version_metadata). The Workers of an account share the Cache API, and
// the boot of a snapshot ran its migrations on the database of its own
// Worker: so each deploy boots once, on its own database.
const snapshots = {
  url: (key) => `https://beam-snapshot.invalid/${key}`,
  async get(env, key) {
    try {
      if (env.SNAPSHOTS) return (await env.SNAPSHOTS.get(key))?.arrayBuffer() ?? null;
      return (await caches.default.match(snapshots.url(key)))?.arrayBuffer() ?? null;
    } catch (e) {
      // No store here (workerd with no cache): no snapshot to make either.
      console.log(`beam: no snapshot store (${e.message})`);
      snapshots.unavailable = true;
      return null;
    }
  },
  async put(env, key, bytes) {
    if (env.SNAPSHOTS) return env.SNAPSHOTS.put(key, bytes);
    return caches.default.put(snapshots.url(key), new Response(bytes, {
      headers: { 'content-type': 'application/octet-stream', 'cache-control': 'public, max-age=2592000' },
    }));
  },
};

async function snapshotKey(env, meta, host) {
  const vars = Object.entries(env).filter(([, v]) => typeof v === 'string').sort(([a], [b]) => (a < b ? -1 : 1));
  const id = JSON.stringify([meta.snapshot_key, vars, host, env.BEAM_VERSION?.id ?? null]);
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(id));
  return [...new Uint8Array(d)].map((x) => x.toString(16).padStart(2, '0')).join('');
}

// A buffer of the files of the release: release.bin, or a buffer of
// appFiles (app-com.js).
const ofRelease = (release, buffer) => (release.buffers ? release.buffers.has(buffer) : buffer === release);

// The memory and the open files of a VM whose threads all returned
// (erts_wasm_hibernate), as snapshot.bin. The files that the boot wrote
// are the ones that are not views of release.bin (unpack: canOwn).
function capture(m, release, listeners, bootPoint = false, skip = () => false, flags = '') {
  const PAGE = 65536;
  const heap = m.HEAPU8;
  const words = new BigUint64Array(heap.buffer, 0, heap.length / 8);
  const pages = [];
  for (let p = 0, w = PAGE / 8; p < heap.length / PAGE; p++) {
    for (let i = p * w; i < (p + 1) * w; i++) if (words[i]) { pages.push(p); break; }
  }
  const files = {};
  const walk = (d) => {
    for (const n of m.FS.readdir(d)) {
      if (n === '.' || n === '..') continue;
      const p = d === '/' ? '/' + n : d + '/' + n;
      if (p === '/dev' || p === '/proc' || skip(p)) continue;
      const node = m.FS.lookupPath(p).node;
      if (m.FS.isDir(node.mode)) walk(p);
      else if (m.FS.isFile(node.mode) && !ofRelease(release, node.contents?.buffer)) {
        let bin = '';
        for (const c of m.FS.readFile(p)) bin += String.fromCharCode(c);
        files[p] = btoa(bin);
      }
    }
  };
  walk('/');
  const pipes = new Map();
  const streams = m.FS.streams.map((st, fd) => {
    if (!st) return null;
    if (st.node?.pipe) {
      if (!pipes.has(st.node.pipe)) pipes.set(st.node.pipe, pipes.size);
      return { fd, pipe: pipes.get(st.node.pipe), flags: st.flags };
    }
    return { fd, path: st.path, flags: st.flags, position: st.position };
  }).filter(Boolean);
  // The NIF libraries in WebAssembly (nif_wasm_host.js): their pages come
  // after the pages of the VM.
  const libs = m.nifHost?.loaded() ? m.nifHost.save() : null;
  const libPages = libs ? libs.libs.reduce((n, l) => n + l.pages.length, 0) : 0;
  const head = new TextEncoder().encode(JSON.stringify({
    size: heap.length, pages, fs: { files, streams }, listeners: Object.fromEntries(listeners),
    boot_point: bootPoint,
    // The release of this memory (snapshot_key of .release.json): a VM of
    // another release does not restore it.
    release: releaseMeta(release).snapshot_key ?? null,
    // The flags of the emulator of this memory (BEAM_ERL_FLAGS): a VM with
    // other flags does not restore it (-Mea min changes the allocators).
    flags,
    nifs: libs && { count: libs.count, libs: libs.libs.map(({ data, ...l }) => l) },
  }));
  const out = new Uint8Array(12 + head.length + (pages.length + libPages) * PAGE);
  out.set(new TextEncoder().encode('BEAMSNP1'));
  new DataView(out.buffer).setUint32(8, head.length);
  out.set(head, 12);
  pages.forEach((p, i) => out.set(heap.subarray(p * PAGE, (p + 1) * PAGE), 12 + head.length + i * PAGE));
  let at = 12 + head.length + pages.length * PAGE;
  for (const l of libs?.libs ?? []) for (const d of l.data) { out.set(d, at); at += PAGE; }
  return out;
}

// snapshot.bin (optional, beside release.bin): the memory of a booted VM
// whose threads all returned to the host (erts_wasm_hibernate), and the
// files and pipes of that moment. "BEAMSNP1", a 32-bit length and a JSON
// header, then the 64 KiB pages of the header (the others are zero): the
// pages of the VM, then the pages of each NIF library in WebAssembly
// (nifs of the header).
async function loadSnapshot(env) {
  try {
    if (env.APP) {
      const r = await env.APP.fetch('http://app/snapshot.bin');
      return r.ok ? r.arrayBuffer() : null;
    }
    return (await import('./snapshot.bin')).default;
  } catch {
    return null;
  }
}

// The header of a snapshot, without its pages: boot_point, release, ...
export function snapshotHeader(bytes) {
  const { pagesData, packed, ...head } = parseSnapshot(bytes);
  return head;
}

// A snapshot is "BEAMSNP1" (the pages as they are) or "BEAMSNZ1" (the
// pages in gzip, packSnapshot): the same header, which the host reads
// with no inflate. The pages of BEAMSNZ1 are in packed, and inflate()
// gives pagesData.
export function parseSnapshot(bytes) {
  const b = new Uint8Array(bytes);
  const magic = new TextDecoder().decode(b.subarray(0, 8));
  if (magic !== 'BEAMSNP1' && magic !== 'BEAMSNZ1') throw new Error('snapshot.bin: not a snapshot');
  const len = new DataView(b.buffer, b.byteOffset).getUint32(8);
  const head = JSON.parse(new TextDecoder().decode(b.subarray(12, 12 + len)));
  return magic === 'BEAMSNP1' ? { ...head, pagesData: b.subarray(12 + len) }
    : { ...head, pagesData: null, packed: b.subarray(12 + len) };
}

// The bytes of the pages of a snapshot (the pages of the VM, then the
// pages of the NIF libraries).
const pagesSize = (head) => 65536 * (head.pages.length + (head.nifs?.libs ?? []).reduce((n, l) => n + l.pages.length, 0));

// A snapshot of BEAMSNP1 as BEAMSNZ1: the pages in gzip. A snapshot of
// the build is a module of the Worker, and the module stays in the memory
// of the isolate: the pages of a Phoenix app are about 21 MB, and 5 MB in
// gzip.
export async function packSnapshot(bytes) {
  const b = new Uint8Array(bytes);
  if (new TextDecoder().decode(b.subarray(0, 8)) !== 'BEAMSNP1') return b;
  const len = new DataView(b.buffer, b.byteOffset).getUint32(8);
  const gz = new Uint8Array(await new Response(new Blob([b.subarray(12 + len)]).stream()
    .pipeThrough(new CompressionStream('gzip'))).arrayBuffer());
  const out = new Uint8Array(12 + len + gz.length);
  out.set(new TextEncoder().encode('BEAMSNZ1'));
  out.set(b.subarray(8, 12 + len), 8);
  out.set(gz, 12 + len);
  return out;
}

// The pages of a parsed snapshot (pagesData), with no copy of the whole
// gzip output: the header gives their size.
export async function inflateSnapshot(snap) {
  if (!snap.packed) return snap;
  const size = pagesSize(snap);
  const out = new Uint8Array(size);
  const reader = new Blob([snap.packed]).stream().pipeThrough(new DecompressionStream('gzip')).getReader();
  let at = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    if (at + value.length > size) throw new Error('snapshot: more pages than its header gives');
    out.set(value, at);
    at += value.length;
  }
  if (at !== size) throw new Error('snapshot: fewer pages than its header gives');
  snap.pagesData = out;
  snap.packed = null;
  return snap;
}

// BEAM_ERL_FLAGS as one text, with one space between the flags.
export const erlFlags = (env) => (env.BEAM_ERL_FLAGS ?? '').split(/\s+/).filter(Boolean).join(' ');

// The flags of the allocators of the VM, before BEAM_ERL_FLAGS (a later
// flag wins). A binary or a heap of 512 KB or more got its own carrier,
// and in WebAssembly these carriers made the memory of the VM grow far
// above the memory that Erlang used (14 MB): 16 clients that sent bodies
// of 2.7 MiB grew it to 1 GB and more. With a threshold of 8 MB, the peak
// was about 200 MB. With -Mea min, the allocators of ERTS are off, and
// these flags do not apply.
export function allocFlags(flags) {
  return flags.includes('-Mea') ? [] : ['-MBsbct', '8192', '-MHsbct', '8192'];
}

// No busy wait of the schedulers of the VM, before BEAM_ERL_FLAGS (a
// later flag wins). A scheduler with no work spins for a time before it
// sleeps. In WebAssembly, each yield of the spin is a JSPI suspend and a
// message of the host: in a body of 16 MiB through fetch() in workerd,
// the spins used about half of the CPU time. With none, a scheduler with
// no work sleeps at once.
export const WAIT_FLAGS = ['-sbwt', 'none', '-sbwtdcpu', 'none', '-sbwtdio', 'none'];

// Ports to the bindings of env (docs/WORKERS.md, "Ports to bindings"): the
// port {spawn_executable, "/env/NAME"} of the VM runs the binding NAME. A
// binding is a port when it has a method port(stdin, {argv}), as a
// service binding to a WorkerEntrypoint or a JS object, or when it is a
// Durable Object namespace: then the port is one object, of the name of
// the first argument (idFromName), or a new object with no argument. port()
// gets the bytes of the VM as a ReadableStream, and gives a ReadableStream
// of the bytes for the VM. The end of that stream gives the exit status 0,
// and an error gives 1.
export const PORT_DIR = '/env';
const isNamespace = (b) => typeof b?.idFromName === 'function' && typeof b?.get === 'function';
const isPort = (b) => b !== null && typeof b === 'object' && (isNamespace(b) || typeof b.port === 'function');
export const portNames = (env) => Object.keys(env ?? {}).filter((k) => /^[A-Za-z0-9_-]+$/.test(k) && isPort(env[k]));
// The bytes of a port that wait in the host, on each side, at most.
const PORT_WINDOW = 256 * 1024;
// The size of a read of the result of a port.
const PORT_READ = 64 * 1024;
// The time that the result of a port that ended waits for a claim.
export const PORT_CLAIM_MS = 10000;

// A port to the binding NAME of PORT_DIR/NAME, for the spawn of the host
// (Module.beamHost.spawn of jspi_lib.js). The bytes that the port writes go
// to the stdin of port(), and the bytes of its result go to the port. A
// path that is not a binding that is a port gives ENOENT (44 in
// Emscripten). opts: log(text), dead() (the VM stopped), ports (a Set of
// the open ports), keep(promise) (the request that must stay open while
// the port runs), and claimMs. It gives {pid, write, end, stop, claim,
// done}.
// Flow control: stdin holds at most PORT_WINDOW bytes, and write() then
// gives false; the pull of stdin asks for more (events.pull). A false of
// events.data() stops the read of the result until events.room().
// BEAM_PORT_OUTPUT=response in the environment of the port: the result
// waits for claim(writer) (a response of the app that names the port, see
// claimPort), and goes to that writer, not to the VM. The close of the
// port is the end of its stdin, so the app can close the port before its
// response: the result then waits claimMs for a claim, and then the port
// drops it.
export function openPort(env, { path, argv, env: vars = [], pid = null }, events,
                         { log = () => {}, dead = () => false, ports = null, keep = () => {},
                           claimMs = PORT_CLAIM_MS, run = (f) => f() } = {}) {
  const name = path.startsWith(`${PORT_DIR}/`) ? path.slice(PORT_DIR.length + 1) : '';
  const binding = portNames(env).includes(name) ? env[name] : null;
  if (!binding || dead()) throw Object.assign(new Error(`no port ${path}`), { errno: 44 });
  const args = argv.slice(1);
  let input = null;
  let reader = null;
  let open = true;
  let claim = null;
  let sink = null;  // the writer of claim()
  let length = null;  // the length of the body of claim(), or null
  let timer = null;
  const claimed = vars.includes('BEAM_PORT_OUTPUT=response') ? new Promise((r) => { claim = r; }) : null;
  const stdin = new ReadableStream({ type: 'bytes', start(c) { input = c; }, pull: () => events.pull?.() },
                                   { highWaterMark: PORT_WINDOW });
  // No claim now: the port drops its result.
  const unclaim = () => {
    clearTimeout(timer);
    claim?.(null);
    claim = null;
  };
  // The end of stdin. A BYOB read that waits ends only with respond(0)
  // after the close.
  const end = () => {
    if (claim && timer === null) timer = setTimeout(unclaim, claimMs);
    if (!open) return;
    open = false;
    try {
      input.close();
      input.byobRequest?.respond(0);
    } catch {}
  };
  const port = {
    pid,
    write: (bytes) => {
      if (!open) return false;
      input.enqueue(bytes);
      return input.desiredSize > 0;
    },
    end,
    stop: () => { unclaim(); end(); reader?.cancel().catch(() => {}); },
    // The writer of the body of a response, and its length (or null): true
    // when the port waited for one.
    claim: (writer, size = null) => {
      if (!claim) return false;
      clearTimeout(timer);
      sink = writer;
      length = size;
      claim(writer);
      claim = null;
      return true;
    },
  };
  ports?.add(port);
  port.done = run(async () => {
    let status = 0;
    try {
      const target = isNamespace(binding)
        ? binding.get(args.length ? binding.idFromName(args[0]) : binding.newUniqueId())
        : binding;
      const out = await target.port(stdin, { argv: args });
      // A BYOB read of PORT_READ bytes in workerd (it has readAtLeast):
      // its default reader gives parts of 4 KB (the stream of an RPC call),
      // and each part is a read of the VM. Not on the other hosts: there,
      // the result can be a byte stream of JavaScript, and its close() does
      // not end a BYOB read that waits (the Streams standard asks for
      // byobRequest.respond(0)), so the port waits for ever (Chrome).
      let byob = null;
      try { byob = out.getReader({ mode: 'byob' }); } catch {}
      if (byob && !byob.readAtLeast) { byob.releaseLock(); byob = null; }
      reader = byob ?? out.getReader();
      if (claimed && !await claimed) await reader.cancel();
      let sent = 0;
      while (!claimed || sink) {
        const { done, value } = byob ? await byob.read(new Uint8Array(PORT_READ)) : await reader.read();
        if (done || dead()) break;
        if (!value?.byteLength) continue;
        let bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
        if (sink) {
          if (length !== null && sent + bytes.length > length) bytes = bytes.subarray(0, length - sent);
          await sink.write(bytes);
          sent += bytes.length;
          // The whole length: the body ends now, not at the end of the
          // result. Else a client that has all the bytes can close first,
          // and the runtime then cancels the request and the port.
          if (length !== null && sent >= length) {
            const done = sink;
            sink = null;
            await done.close();
            await reader.cancel().catch(() => {});
          }
        } else if (events.data(bytes) === false) {
          await events.room?.();
          // The VM closed the port: the result stops, as a write to a
          // closed pipe.
          if (events.closed?.()) {
            await reader.cancel().catch(() => {});
            break;
          }
        }
      }
      if (sink) await (dead() ? sink.abort(new Error('the app stopped')) : sink.close());
    } catch (e) {
      status = 1;
      sink?.abort(e).catch(() => {});
      if (!dead()) log(`beam: the port ${path}: ${e?.message ?? e}`);
    } finally {
      ports?.delete(port);
      unclaim();
      end();
    }
    events.exit(status);
  });
  keep(port.done);
  return port;
}

// A runner of jobs in the async context of the request that makes it: a
// job runs in a reaction of a promise of that request. In a plain Worker,
// the code of the VM runs in the async context of the request that booted
// the VM, and workerd ties the trace span of that context to that request.
// So the I/O of a port starts in a job of the runner of a later request.
function requestRunner() {
  const jobs = [];
  let wake = null;
  const next = () => new Promise((r) => { wake = r; }).then(() => {
    for (const job of jobs.splice(0)) job();
    return next();
  });
  next();
  return (job) => { jobs.push(job); wake?.(); };
}

// BEAM_CONNECT: the hosts that the VM can connect to, separated by commas:
// "host", "host:port", "*.domain" (the subdomains of domain), or "*" (all
// hosts, as "*:443"). The host resolves a name, so the VM cannot reach
// another address through it. With no BEAM_CONNECT, the VM can connect to
// all hosts. BEAM_FETCH has the same rules. named: only a rule that names
// the port counts (BEAM_FETCH for a port other than 80 and 443).
export function connectAllowed(list, host, port, named = false) {
  if (list === undefined) return true;
  const name = String(host).toLowerCase().replace(/\.$/, '');
  return list.split(',').map((r) => r.trim().toLowerCase()).filter(Boolean).some((rule) => {
    const i = rule.lastIndexOf(':');
    const [pattern, p] = i > 0 && !rule.includes(']') ? [rule.slice(0, i), rule.slice(i + 1)] : [rule, undefined];
    if (p === undefined ? named : Number(p) !== port) return false;
    if (pattern === '*') return true;
    return pattern.startsWith('*.') ? name.endsWith(pattern.slice(1)) : name === pattern;
  });
}

// The IP ranges of Cloudflare (https://www.cloudflare.com/ips-v4 and
// ips-v6, October 2026), and the ranges of its resolver 1.1.1.1. On
// Cloudflare, connect() of a Worker cannot reach them: the fallback of the
// fetch path (wasm_host_fetch.erl) sends the HTTP of such a host through
// fetch().
export const CLOUDFLARE_RANGES = [
  '173.245.48.0/20', '103.21.244.0/22', '103.22.200.0/22', '103.31.4.0/22', '141.101.64.0/18',
  '108.162.192.0/18', '190.93.240.0/20', '188.114.96.0/20', '197.234.240.0/22', '198.41.128.0/17',
  '162.158.0.0/15', '104.16.0.0/13', '104.24.0.0/14', '172.64.0.0/13', '131.0.72.0/22',
  '1.1.1.0/24', '1.0.0.0/24',
  '2400:cb00::/32', '2606:4700::/32', '2803:f800::/32', '2405:b500::/32', '2405:8100::/32',
  '2a06:98c0::/29', '2c0f:f248::/32',
];

// An IP address as {bits, size} (a BigInt of 32 or 128 bits), or null.
export function ipBits(text) {
  const ip = String(text).replace(/^\[|\]$/g, '');
  const v4 = (t) => {
    const parts = t.split('.');
    if (parts.length !== 4 || !parts.every((x) => /^\d{1,3}$/.test(x) && Number(x) < 256)) return null;
    return parts.reduce((n, x) => (n << 8n) | BigInt(x), 0n);
  };
  if (!ip.includes(':')) {
    const n = v4(ip);
    return n === null ? null : { bits: n, size: 32 };
  }
  let [head, tail] = ip.split('::');
  if (ip.split('::').length > 2) return null;
  const words = (t) => (t ? t.split(':') : []);
  let h = words(head), t = tail === undefined ? [] : words(tail);
  // An IPv4 address at the end (::ffff:1.2.3.4) is two words.
  const last = (tail === undefined ? h : t);
  if (last.length && last.at(-1).includes('.')) {
    const n = v4(last.pop());
    if (n === null) return null;
    last.push((n >> 16n).toString(16), (n & 0xffffn).toString(16));
  }
  const fill = tail === undefined ? 0 : 8 - h.length - t.length;
  if (fill < 0 || (tail === undefined && h.length !== 8)) return null;
  const all = [...h, ...Array(fill).fill('0'), ...t];
  if (!all.every((w) => /^[0-9a-f]{1,4}$/i.test(w))) return null;
  return { bits: all.reduce((n, w) => (n << 16n) | BigInt(parseInt(w, 16)), 0n), size: 128 };
}

// The address is in one of the ranges ("address/prefix").
export function inRanges(address, ranges = CLOUDFLARE_RANGES) {
  let a = ipBits(address);
  if (!a) return false;
  // An IPv4 address in IPv6 (::ffff:a.b.c.d) is that IPv4 address.
  if (a.size === 128 && a.bits >> 32n === 0xffffn) a = { bits: a.bits & 0xffffffffn, size: 32 };
  return ranges.some((r) => {
    const [base, prefix] = r.split('/');
    const b = ipBits(base);
    if (!b || b.size !== a.size) return false;
    const shift = BigInt(a.size - Number(prefix));
    return (a.bits >> shift) === (b.bits >> shift);
  });
}

// The URL of a request of the fetch path: the host and the port of the
// connect of the program (never a name of the request), and the path of
// the request. null for a path that would change the origin.
export function fetchUrl(host, port, tls, path) {
  const scheme = tls ? 'https' : 'http';
  const name = String(host).includes(':') ? `[${host}]` : String(host);
  const origin = `${scheme}://${name}${port === (tls ? 443 : 80) ? '' : `:${port}`}`;
  if (typeof path !== 'string' || !path.startsWith('/') || path.startsWith('//')) return null;
  const url = new URL(path, origin);
  return url.origin === new URL(origin).origin ? url.href : null;
}

// The memory and the open files of the snapshot, in a new instance (before
// main(), which does not run): then the threads start again.
function restore(m, exports, snap) {
  const PAGE = 65536;
  // The pages of the new instance that are not in the snapshot: zero (the
  // memory that grows is zero already).
  const first = m.HEAPU8.length / PAGE, have = new Set(snap.pages);
  for (let p = 0; p < first; p++) if (!have.has(p)) m.HEAPU8.fill(0, p * PAGE, (p + 1) * PAGE);
  if (!exports.jspi_snapshot_grow(snap.size)) throw new Error('snapshot: no memory');
  const heap = m.HEAPU8;
  snap.pages.forEach((p, i) => heap.set(snap.pagesData.subarray(i * PAGE, (i + 1) * PAGE), p * PAGE));
  // The NIF libraries in WebAssembly, from their files (capture).
  if (snap.nifs) {
    let at = snap.pages.length * PAGE;
    const libs = snap.nifs.libs.map((l) => ({
      ...l, data: l.pages.map(() => { const d = snap.pagesData.subarray(at, at + PAGE); at += PAGE; return d; }),
    }));
    m.nifHost.restore({ count: snap.nifs.count, libs }, (f) => m.FS.readFile(f));
  }
  const made = new Set();
  for (const s of snap.fs.streams) {
    if (s.fd <= 2) continue;
    if (s.pipe !== undefined) {
      if (!made.has(s.pipe)) { made.add(s.pipe); exports.jspi_snapshot_pipe(); }
      const got = m.FS.getStream(s.fd);
      if (!got?.node?.pipe) throw new Error(`snapshot: fd ${s.fd} is not a pipe`);
      got.flags = s.flags;
    } else {
      const st = m.FS.open(s.path, s.flags);
      if (st.fd !== s.fd) throw new Error(`snapshot: fd ${s.fd} is ${st.fd}`);
      st.position = s.position;
    }
  }
  exports.wasm_host_restore();
}

// The threads of a restored VM start again (erts_wasm_resume), and OpenSSL
// gets new random bytes. The global scope of a Worker has no random
// values: there, warm() starts the threads, and the first request sends
// the bytes (seed()).
function resume(m, exports) {
  const n = exports.erts_wasm_resume();
  seed(m);
  return n;
}

function seed(m) {
  // New random bytes for OpenSSL, before any request (wasm_host_server).
  const h = new TextEncoder().encode('{"t":"restored"}\n');
  const b = new Uint8Array(h.length + 48);
  b.set(h);
  crypto.getRandomValues(b.subarray(h.length));
  m.beamHost.push(b);
}

// The directories of BEAM_PERSIST (a Durable Object): their files are in
// the SQLite storage of the object, so they stay when the object leaves
// memory. The host writes them into the file system of the VM before it
// starts, and saves a file when the VM closes it after a write (or 1 s
// after a write, for a file that stays open), and a delete, a rename or a
// new directory at once. A file is in chunks of 1 MB (a row has 2 MB at
// most).
const CHUNK = 1 << 20;

export class Persist {
  constructor(sql, dirs) {
    this.sql = sql;
    this.dirs = dirs.map((d) => d.replace(/\/+$/, '')).filter((d) => d.startsWith('/') && d.length > 1);
    this.dirty = new Set();
    sql.exec('CREATE TABLE IF NOT EXISTS beam_fs (path TEXT PRIMARY KEY, dir INTEGER, mode INTEGER, size INTEGER)');
    sql.exec('CREATE TABLE IF NOT EXISTS beam_fs_chunk (path TEXT, n INTEGER, data BLOB, PRIMARY KEY (path, n))');
  }

  under(path) {
    return typeof path === 'string' && this.dirs.some((d) => path === d || path.startsWith(d + '/'));
  }

  // The files of the storage, into FS (before the VM starts).
  load(FS) {
    for (const d of this.dirs) FS.mkdirTree(d);
    let files = 0, bytes = 0;
    for (const { path, dir, size } of this.sql.exec('SELECT path, dir, size FROM beam_fs ORDER BY path')) {
      if (!this.under(path)) continue;
      if (dir) { FS.mkdirTree(path); continue; }
      const data = new Uint8Array(size);
      for (const { n, data: part } of this.sql.exec('SELECT n, data FROM beam_fs_chunk WHERE path = ? ORDER BY n', path)) {
        data.set(new Uint8Array(part), n * CHUNK);
      }
      FS.mkdirTree(path.slice(0, path.lastIndexOf('/')) || '/');
      FS.writeFile(path, data, { canOwn: true });
      files++;
      bytes += size;
    }
    console.log(`beam: persist ${this.dirs.join(', ')}: ${files} files, ${bytes >> 10} KB`);
  }

  save(FS, path) {
    this.dirty.delete(path);
    let node;
    try { node = FS.lookupPath(path).node; } catch { return this.remove(path); }
    if (FS.isDir(node.mode)) return this.sql.exec('INSERT OR REPLACE INTO beam_fs VALUES (?, 1, ?, 0)', path, node.mode);
    if (!FS.isFile(node.mode)) return;
    const data = FS.readFile(path);
    this.sql.exec('DELETE FROM beam_fs_chunk WHERE path = ?', path);
    this.sql.exec('INSERT OR REPLACE INTO beam_fs VALUES (?, 0, ?, ?)', path, node.mode, data.length);
    for (let n = 0; n * CHUNK < data.length; n++) {
      this.sql.exec('INSERT INTO beam_fs_chunk VALUES (?, ?, ?)', path, n, data.slice(n * CHUNK, (n + 1) * CHUNK).buffer);
    }
  }

  // Each file that the VM wrote after the last save. The timer of a write
  // calls it, and also the stop of the VM, so a stop loses no write.
  saveDirty() {
    clearTimeout(this.flush);
    this.flush = null;
    for (const p of [...this.dirty]) this.save(this.fs, p);
  }

  // A file or a directory, and all under it.
  remove(path) {
    for (const t of ['beam_fs', 'beam_fs_chunk']) {
      this.sql.exec(`DELETE FROM ${t} WHERE path = ? OR substr(path, 1, ?) = ?`, path, path.length + 1, path + '/');
    }
  }

  // A directory and all under it, or one file.
  saveTree(FS, path) {
    this.save(FS, path);
    let node;
    try { node = FS.lookupPath(path).node; } catch { return; }
    if (!FS.isDir(node.mode)) return;
    for (const n of FS.readdir(path)) if (n !== '.' && n !== '..') this.saveTree(FS, `${path}/${n}`);
  }

  // Wrap the functions of FS that change files (the system calls of the
  // VM call them).
  attach(FS) {
    this.fs = FS;
    const abs = (p) => (typeof p === 'string' && !p.startsWith('/') ? `${FS.cwd()}/${p}` : p);
    const wrap = (name, after) => {
      const f = FS[name];
      FS[name] = (...a) => {
        const r = f.apply(FS, a);
        try { after(...a); } catch (e) { console.log(`beam: persist ${name}: ${e.message}`); }
        return r;
      };
    };
    wrap('write', (stream) => {
      if (!this.under(stream.path)) return;
      this.dirty.add(stream.path);
      this.flush ??= setTimeout(() => this.saveDirty(), 1000);
    });
    wrap('close', (stream) => {
      if (this.under(stream.path) && ((stream.flags & 3) !== 0 || this.dirty.has(stream.path))) this.save(FS, stream.path);
    });
    wrap('truncate', (path) => { if (this.under(abs(path))) this.save(FS, abs(path)); });
    wrap('mkdir', (path) => { if (this.under(abs(path))) this.save(FS, abs(path)); });
    wrap('unlink', (path) => { if (this.under(abs(path))) this.remove(abs(path)); });
    wrap('rmdir', (path) => { if (this.under(abs(path))) this.remove(abs(path)); });
    wrap('rename', (from, to) => {
      if (this.under(abs(from))) this.remove(abs(from));
      if (this.under(abs(to))) this.saveTree(FS, abs(to));
    });
  }
}

// Ecto SQLite (wasm_host_sqlite): the host runs each statement, on the
// SQLite storage of a Durable Object (ctx.storage.sql: the option sql of
// Vm), else on the D1 database of the binding BEAM_D1 (default DB). A
// value on the wire: a blob as {b: base64}, a big integer as {i: "..."}.
function toWire(v) {
  // D1 gives a BLOB as an array of bytes (a SQL value is no array else).
  if (Array.isArray(v)) v = Uint8Array.from(v);
  if (v instanceof ArrayBuffer || ArrayBuffer.isView(v)) {
    let bin = '';
    for (const c of new Uint8Array(v.buffer ?? v, v.byteOffset ?? 0, v.byteLength)) bin += String.fromCharCode(c);
    return { b: btoa(bin) };
  }
  if (typeof v === 'bigint') return { i: String(v) };
  return v;
}

function fromWire(v) {
  if (v && typeof v === 'object' && 'b' in v) return Uint8Array.from(atob(v.b), (c) => c.charCodeAt(0)).buffer;
  if (v && typeof v === 'object' && 'i' in v) return BigInt(v.i);
  return v;
}

// The statements that give rows (the others give changes and a row id).
const givesRows = (sql) => /^\s*(select|with|pragma|values|explain)\b/i.test(sql) || /\breturning\b/i.test(sql);

// The changes of SQLite (rowsWritten counts the writes of the indexes and
// of sqlite_sequence too).
const reads = (sql) => /^\s*(select|with|pragma|values|explain)\b/i.test(sql);

function sqlDurable(storage, sql, params) {
  const c = storage.exec(sql, ...params);
  const rows = [...c.raw()].map((r) => r.map(toWire));
  const out = { columns: c.columnNames, rows, changes: 0 };
  if (!reads(sql)) {
    const [[changes, rowid]] = [...storage.exec('SELECT changes(), last_insert_rowid()').raw()];
    Object.assign(out, { changes, last_row_id: rowid });
  }
  return out;
}

async function sqlD1(env, sql, params) {
  const name = env.BEAM_D1 ?? 'DB';
  if (!env[name]) throw new Error(`no D1 binding ${name} (or set BEAM_D1)`);
  const st = env[name].prepare(sql).bind(...params);
  if (givesRows(sql)) {
    const [columns = [], ...rows] = await st.raw({ columnNames: true });
    return { columns, rows: rows.map((r) => r.map(toWire)), changes: reads(sql) ? 0 : rows.length };
  }
  const { meta } = await st.run();
  return { columns: [], rows: [], changes: meta.changes ?? 0, last_row_id: meta.last_row_id ?? 0 };
}

let vm;  // the VM of this isolate

export default {
  fetch(request, env, ctx) {
    if (!vm) {
      const v = vm = new Vm(env, { host: new URL(request.url).hostname });
      v.ready.catch(() => { if (vm === v) vm = undefined; });
      // A VM that stopped: the next request starts a new one.
      v.onDead = () => { if (vm === v) vm = undefined; };
    }
    return vm.fetch(request, ctx, env);
  },
};

// The files of the host for SQLite in the VM (exqlite, the NIF of the
// runtime, with c_src/erts_wasm/sqlite_vfs.c): the main database files. A store
// keeps their blocks of 4 KiB, each with the version of the database that
// wrote it:
//   meta(name) -> {version, size, stamp}: version 0 and size 0 for no file
//   block(name, n, version) -> {data, v, prev}: the newest block n at or
//     before version, or null
//   commit(name, stamp, {version, size, blocks: [{n, data, prev, drop}]}, release)
//     -> the new stamp, or null when another commit came first; with
//     release, the commit also removes the write lock
//   lock(name, stamp, owner, ms) -> a lease, or null when another owner
//     has the write lock or the stamp is not the last one
//   unlock(name, lease): removes the write lock of that lease
//   remove(name)
// A transaction reads one version of the database: the version at its
// shared lock. Its writes go to the store in one commit, which fails when
// another VM committed first (SQLITE_BUSY, and nothing changes). A block
// keeps its last two versions, for the reads of an older transaction.
const BLOCK = 4096;
const FOP = { OPEN: 1, CLOSE: 2, READ: 3, WRITE: 4, TRUNCATE: 5, SYNC: 6, SIZE: 7, LOCK: 8, UNLOCK: 9,
  DELETE: 10, ACCESS: 11, BEGIN_BATCH: 12, COMMIT_BATCH: 13, ROLLBACK_BATCH: 14 };
const SQLITE_BUSY = 5, SQLITE_IOERR = 10, SQLITE_FULL = 13;

export class HostFiles {
  // maxBlocks: the blocks of one commit (a commit of the store has limits).
  // lease: the time of the write lock of a database (ms). The lock only
  // makes a conflict less frequent; the commit checks the version. A
  // write transaction is three operations of the store: the version (at
  // the shared lock), the lock, and the commit, which also unlocks.
  constructor(store, { maxBlocks = 160, lease = 10000, debug = false } = {}) {
    this.store = store;
    this.debug = debug;
    this.maxBlocks = maxBlocks;
    this.lease = lease;
    this.owner = crypto.randomUUID();
    this.files = new Map();  // id -> {db, snap, dirty, size}
    this.dbs = new Map();    // name -> {name, version, cache}: blocks of one version
    this.next = 1;
  }

  // An operation of sqlite_vfs.c (jspi_file_wait): an integer.
  async call(op, id, offset, buf, n, mem) {
    try {
      const r = await this.op(op, id, offset, buf, n, mem);
      if (this.debug) console.log(`beam: SQLite file: op ${op} file ${id} at ${offset} n ${n}: ${r}`);
      return r;
    } catch (e) {
      console.log(`beam: SQLite file: ${e.message}`);
      return op === FOP.READ ? -1 : SQLITE_IOERR;
    }
  }

  db(name) {
    let d = this.dbs.get(name);
    if (!d) this.dbs.set(name, d = { name, version: -1, cache: new Map() });
    return d;
  }

  async op(op, id, offset, buf, n, mem) {
    switch (op) {
      case FOP.OPEN: {
        const fid = this.next++;
        this.files.set(fid, { db: this.db(mem.string(buf)), snap: null, dirty: new Map(), size: null });
        return fid;
      }
      case FOP.ACCESS: return (await this.store.meta(mem.string(buf))).size > 0 ? 1 : 0;
      case FOP.DELETE: {
        const name = mem.string(buf);
        await this.store.remove(name);
        this.dbs.delete(name);
        return 0;
      }
    }
    const f = this.files.get(id);
    if (!f) return op === FOP.READ ? -1 : SQLITE_IOERR;
    switch (op) {
      case FOP.CLOSE: await this.release(f, id); this.files.delete(id); return 0;
      case FOP.LOCK:
        if (n === 1) await this.begin(f);
        else if (n >= 2 && !f.lease) return this.reserve(f, id);
        return 0;
      case FOP.UNLOCK:
        if (n < 2) await this.release(f, id);
        if (n === 0) { f.snap = null; f.dirty.clear(); f.size = null; }
        return 0;
      case FOP.READ: return this.read(f, offset, buf, n, mem);
      case FOP.WRITE: await this.write(f, offset, buf, n, mem); return 0;
      case FOP.TRUNCATE:
        if (!f.snap) await this.begin(f);
        f.size = offset;
        for (const k of f.dirty.keys()) if (k * BLOCK >= offset) f.dirty.delete(k);
        return 0;
      case FOP.SIZE:
        if (!f.snap) await this.begin(f);
        new DataView(mem.heap().buffer).setFloat64(buf, f.size ?? f.snap.size, true);
        return 0;
      case FOP.BEGIN_BATCH: return 0;
      case FOP.SYNC: case FOP.COMMIT_BATCH: return this.commit(f);
      case FOP.ROLLBACK_BATCH: f.dirty.clear(); f.size = null; return 0;
    }
    return SQLITE_IOERR;
  }

  // A shared lock: the last version of the database. The cache of the
  // blocks keeps one version.
  async begin(f) {
    f.snap = await this.store.meta(f.db.name);
    f.dirty.clear();
    f.size = null;
    if (f.db.version !== f.snap.version) {
      f.db.cache.clear();
      f.db.version = f.snap.version;
    }
  }

  // A reserved lock starts a write. It fails with SQLITE_BUSY when another
  // file has the write lock, or when the version of the read is not the
  // last one. Then the busy handler of SQLite tries again from a new read.
  async reserve(f, id) {
    if (!f.snap) await this.begin(f);
    f.lease = await this.store.lock(f.db.name, f.snap.stamp, `${this.owner}:${id}`, this.lease);
    return f.lease ? 0 : SQLITE_BUSY;
  }

  async release(f, id) {
    const lease = f.lease;
    if (!lease) return;
    f.lease = null;
    await this.store.unlock(f.db.name, lease);
  }

  // Block k as this transaction sees it (zeros for no block).
  async block(f, k) {
    const d = f.dirty.get(k);
    if (d) return d;
    const db = f.db, same = db.version === f.snap.version;
    let b = same ? db.cache.get(k) : undefined;
    if (!b) {
      b = (await this.store.block(db.name, k, f.snap.version)) ?? { data: null, v: 0, prev: 0 };
      if (same && db.version === f.snap.version) db.cache.set(k, b);
    }
    return b.data ?? new Uint8Array(BLOCK);
  }

  async read(f, offset, buf, n, mem) {
    if (!f.snap) await this.begin(f);
    const end = Math.min(offset + n, f.size ?? f.snap.size);
    for (let pos = offset; pos < end;) {
      const k = Math.floor(pos / BLOCK), at = pos - k * BLOCK, len = Math.min(BLOCK - at, end - pos);
      const data = await this.block(f, k);
      mem.heap().set(data.subarray(at, at + len), buf + (pos - offset));
      pos += len;
    }
    return Math.max(0, end - offset);
  }

  async write(f, offset, buf, n, mem) {
    if (!f.snap) await this.begin(f);
    for (let pos = offset; pos < offset + n;) {
      const k = Math.floor(pos / BLOCK), at = pos - k * BLOCK, len = Math.min(BLOCK - at, offset + n - pos);
      const data = new Uint8Array(await this.block(f, k));
      data.set(mem.heap().subarray(buf + (pos - offset), buf + (pos - offset) + len), at);
      f.dirty.set(k, data);
      pos += len;
    }
    f.size = Math.max(f.size ?? f.snap.size, offset + n);
  }

  // The writes of the transaction, in one commit of the store.
  async commit(f) {
    if (!f.snap) return 0;
    const size = f.size ?? f.snap.size;
    if (!f.dirty.size && size === f.snap.size) return 0;
    const db = f.db, version = f.snap.version + 1;
    if (f.dirty.size > this.maxBlocks) {
      console.log(`beam: SQLite: a commit of ${f.dirty.size} blocks of 4 KiB (at most ${this.maxBlocks})`);
      f.dirty.clear();
      f.size = null;
      return SQLITE_FULL;
    }
    const same = db.version === f.snap.version;
    const blocks = [...f.dirty].map(([n, data]) => {
      const old = same ? db.cache.get(n) : undefined;
      return { n, data, prev: old?.v ?? 0, drop: old?.prev || 0 };
    });
    const stamp = await this.store.commit(db.name, f.snap.stamp, { version, size, blocks }, !!f.lease);
    f.dirty.clear();
    f.size = null;
    if (stamp === null) {
      db.cache.clear();
      db.version = -1;
      return SQLITE_BUSY;
    }
    f.lease = null;  // the commit removed it
    if (!same) db.cache.clear();
    db.version = version;
    for (const b of blocks) db.cache.set(b.n, { data: b.data, v: version, prev: b.prev });
    f.snap = { version, size, stamp };
    return 0;
  }
}

// A store of HostFiles in memory: for a page, and for the tests.
export class MemoryStore {
  constructor() { this.dbs = new Map(); }
  get(name) {
    let d = this.dbs.get(name);
    if (!d) this.dbs.set(name, d = { version: 0, size: 0, stamp: 0, blocks: new Map() });
    return d;
  }
  async meta(name) { const d = this.get(name); return { version: d.version, size: d.size, stamp: d.stamp }; }
  async block(name, n, version) {
    const vs = this.get(name).blocks.get(n) ?? [];
    for (let i = vs.length - 1; i >= 0; i--) if (vs[i].v <= version) return vs[i];
    return null;
  }
  async commit(name, stamp, { version, size, blocks }, release = false) {
    const d = this.get(name);
    if (d.stamp !== stamp) return null;
    if (release) d.lock = null;
    for (const b of blocks) {
      const vs = (d.blocks.get(b.n) ?? []).filter((x) => !b.drop || x.v !== b.drop);
      vs.push({ data: b.data, v: version, prev: b.prev });
      d.blocks.set(b.n, vs);
    }
    Object.assign(d, { version, size, stamp: d.stamp + 1 });
    return d.stamp;
  }
  async lock(name, stamp, owner, ms) {
    const d = this.get(name), now = Date.now();
    if (d.stamp !== stamp || (d.lock && d.lock.owner !== owner && d.lock.until > now)) return null;
    d.lock = { owner, until: now + ms, lease: (this.leases = (this.leases ?? 0) + 1) };
    return d.lock.lease;
  }
  async unlock(name, lease) {
    const d = this.get(name);
    if (d.lock?.lease === lease) d.lock = null;
  }
  async remove(name) { this.dbs.delete(name); }
}

// WebAssembly for the VM (wasm_host_wasm.erl, the API of the application
// wasm of beam.com): the engine of the host compiles the modules and runs
// them, with WASI preview 1 for programs. The standard output and error of
// a program go back to the caller with each reply. There is no file
// system: stdin is empty, and there are no preopens. A Cloudflare Worker
// cannot compile WebAssembly at run time, so there compile gives an error.
// A module or an instance has an id; they stay until the VM stops.
const ERRNO = { SUCCESS: 0, BADF: 8, FAULT: 21, NOSYS: 52, SPIPE: 70 };
// The limits of the WebAssembly host: the bytes of a module, the bytes of
// a read of the memory, the output of a program that the host keeps for
// each call, and the modules and instances that it keeps at one time.
const WASM_MAX_MODULE = 64 << 20, WASM_MAX_READ = 16 << 20, WASM_MAX_OUTPUT = 1 << 20, WASM_MAX_HANDLES = 1024;
const isOffset = (n) => Number.isSafeInteger(n) && n >= 0;

class WasiExit {
  constructor(code) { this.code = code; }
}

function b64(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

function unb64(text) {
  const s = atob(text), b = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i);
  return b;
}

// The types of the exported functions of a module: name -> {params,
// results}, with the value types as bytes (0x7f i32, 0x7e i64, 0x7d f32,
// 0x7c f64). The JavaScript API does not give them, and an i64 needs a
// BigInt.
export function wasmSignatures(bytes) {
  let at = 8;
  const u = () => { let r = 0, s = 0, b; do { b = bytes[at++]; r |= (b & 0x7f) << s; s += 7; } while (b & 0x80); return r >>> 0; };
  const name = () => { const n = u(); const t = new TextDecoder().decode(bytes.subarray(at, at + n)); at += n; return t; };
  const limits = () => { const f = u(); u(); if (f & 1) u(); };
  const types = [], funcs = [], out = {};
  let exports = [];
  while (at < bytes.length) {
    const id = bytes[at++], size = u(), end = at + size;
    if (id === 1) {
      for (let n = u(); n > 0; n--) {
        if (bytes[at++] !== 0x60) return out;  // not a plain function type
        const params = [], results = [];
        for (let k = u(); k > 0; k--) params.push(bytes[at++]);
        for (let k = u(); k > 0; k--) results.push(bytes[at++]);
        types.push({ params, results });
      }
    } else if (id === 2) {
      for (let n = u(); n > 0; n--) {
        name(); name();
        const kind = bytes[at++];
        if (kind === 0) funcs.push(u());
        else if (kind === 1) { at++; limits(); }
        else if (kind === 2) limits();
        else if (kind === 3) at += 2;
        else if (kind === 4) { at++; u(); }
      }
    } else if (id === 3) {
      for (let n = u(); n > 0; n--) funcs.push(u());
    } else if (id === 7) {
      for (let n = u(); n > 0; n--) exports.push({ name: name(), kind: bytes[at++], index: u() });
    }
    at = end;
  }
  for (const e of exports) if (e.kind === 0 && types[funcs[e.index]]) out[e.name] = types[funcs[e.index]];
  return out;
}

// WASI preview 1, the functions that a small program needs. The others
// give ENOSYS.
class Wasi {
  constructor(args = [], env = []) {
    this.args = args.map((a) => new TextEncoder().encode(`${a}\0`));
    this.env = env.map(([k, v]) => new TextEncoder().encode(`${k}=${v}\0`));
    this.out = []; this.err = [];
    this.kept = 0;  // the bytes of out and err
    this.memory = null;
  }

  take() {
    const join = (parts) => { const n = parts.reduce((a, p) => a + p.length, 0), b = new Uint8Array(n); let o = 0; for (const p of parts) { b.set(p, o); o += p.length; } return b; };
    const r = { stdout: b64(join(this.out)), stderr: b64(join(this.err)) };
    this.out = []; this.err = []; this.kept = 0;
    return r;
  }

  imports(module) {
    const dv = () => new DataView(this.memory.buffer), mem = () => new Uint8Array(this.memory.buffer);
    const strings = (list, ptrs, buf) => { let o = buf; list.forEach((s, i) => { dv().setUint32(ptrs + i * 4, o, true); mem().set(s, o); o += s.length; }); return ERRNO.SUCCESS; };
    const sizes = (list, count, size) => { dv().setUint32(count, list.length, true); dv().setUint32(size, list.reduce((a, s) => a + s.length, 0), true); return ERRNO.SUCCESS; };
    const f = {
      args_sizes_get: (c, s) => sizes(this.args, c, s),
      args_get: (p, b) => strings(this.args, p, b),
      environ_sizes_get: (c, s) => sizes(this.env, c, s),
      environ_get: (p, b) => strings(this.env, p, b),
      fd_write: (fd, iovs, n, written) => {
        if (fd !== 1 && fd !== 2) return ERRNO.BADF;
        let total = 0;
        for (let i = 0; i < n; i++) {
          const ptr = dv().getUint32(iovs + i * 8, true), len = dv().getUint32(iovs + i * 8 + 4, true);
          if (ptr + len > this.memory.buffer.byteLength) return ERRNO.FAULT;
          // Past WASM_MAX_OUTPUT, the output of this call is dropped.
          const keep = Math.min(len, WASM_MAX_OUTPUT - this.kept);
          if (keep > 0) {
            (fd === 1 ? this.out : this.err).push(mem().slice(ptr, ptr + keep));
            this.kept += keep;
          }
          total += len;
        }
        dv().setUint32(written, total, true);
        return ERRNO.SUCCESS;
      },
      fd_read: (fd, iovs, n, read) => { if (fd !== 0) return ERRNO.BADF; dv().setUint32(read, 0, true); return ERRNO.SUCCESS; },
      fd_close: (fd) => (fd <= 2 ? ERRNO.SUCCESS : ERRNO.BADF),
      fd_seek: () => ERRNO.SPIPE,
      fd_fdstat_get: (fd, buf) => {
        if (fd > 2) return ERRNO.BADF;
        dv().setUint8(buf, 2);  // a character device
        dv().setUint16(buf + 2, 0, true);
        dv().setBigUint64(buf + 8, 0xffffffffffffffffn, true);
        dv().setBigUint64(buf + 16, 0xffffffffffffffffn, true);
        return ERRNO.SUCCESS;
      },
      fd_fdstat_set_flags: () => ERRNO.SUCCESS,
      fd_prestat_get: () => ERRNO.BADF,
      fd_prestat_dir_name: () => ERRNO.BADF,
      proc_exit: (code) => { throw new WasiExit(code); },
      clock_res_get: (id, ptr) => { dv().setBigUint64(ptr, 1000n, true); return ERRNO.SUCCESS; },
      clock_time_get: (id, precision, ptr) => {
        const ns = id === 0 ? BigInt(Date.now()) * 1000000n : BigInt(Math.round(performance.now() * 1e6));
        dv().setBigUint64(ptr, ns, true);
        return ERRNO.SUCCESS;
      },
      random_get: (buf, len) => { for (let o = 0; o < len; o += 65536) crypto.getRandomValues(mem().subarray(buf + o, buf + Math.min(len, o + 65536))); return ERRNO.SUCCESS; },
      sched_yield: () => ERRNO.SUCCESS,
    };
    const imports = {};
    for (const i of WebAssembly.Module.imports(module)) {
      if (i.module !== 'wasi_snapshot_preview1' && i.module !== 'wasi_unstable') {
        throw new Error(`the module imports ${i.module}.${i.name}: only WASI is supported`);
      }
      (imports[i.module] ??= {})[i.name] = f[i.name] ?? (() => ERRNO.NOSYS);
    }
    return imports;
  }
}

export class WasmHost {
  constructor() {
    this.modules = new Map();
    this.instances = new Map();
    this.next = 1;
  }

  async op(op, q) {
    switch (op) {
      case 'release':
        this.modules.delete(q.id);
        this.instances.delete(q.id);
        return { ok: true };
      case 'compile': {
        if (this.modules.size + this.instances.size >= WASM_MAX_HANDLES) return { error: 'too many modules and instances' };
        const bytes = unb64(q.bytes);
        if (bytes.length > WASM_MAX_MODULE) return { error: 'the module is too large' };
        const module = await WebAssembly.compile(bytes);
        const id = `m${this.next++}`;
        this.modules.set(id, { module, sig: wasmSignatures(bytes) });
        return { ok: id };
      }
      case 'instantiate': {
        const m = this.modules.get(q.module);
        if (!m) return { error: 'unknown module' };
        if (this.modules.size + this.instances.size >= WASM_MAX_HANDLES) return { error: 'too many modules and instances' };
        const wasi = new Wasi(q.args, q.env);
        const instance = await WebAssembly.instantiate(m.module, wasi.imports(m.module));
        wasi.memory = Object.values(instance.exports).find((e) => e instanceof WebAssembly.Memory) ?? null;
        const id = `i${this.next++}`;
        this.instances.set(id, { instance, wasi, sig: m.sig });
        return { ok: id };
      }
    }
    const inst = this.instances.get(q.instance);
    if (!inst) return { error: 'unknown instance' };
    const exports = inst.instance.exports, memory = inst.wasi.memory;
    switch (op) {
      case 'exists': return { ok: typeof exports[q.name] === 'function' };
      case 'call': {
        const fn = exports[q.name];
        if (typeof fn !== 'function') return { error: 'not_found' };
        const type = inst.sig[q.name];
        const args = q.args.map((a, i) => toWasm(a, type?.params[i]));
        try {
          const r = fn(...args);
          const list = r === undefined ? [] : type && type.results.length > 1 ? [...r] : [r];
          return { ok: list.map(fromWasm), ...inst.wasi.take() };
        } catch (e) {
          if (e instanceof WasiExit) return { exit: e.code, ...inst.wasi.take() };
          if (e instanceof WebAssembly.RuntimeError) return { trap: e.message, ...inst.wasi.take() };
          return { error: String(e?.message ?? e), ...inst.wasi.take() };
        }
      }
      case 'memory_size': return memory ? { ok: memory.buffer.byteLength } : { error: 'not_found' };
      case 'memory_grow':
        if (!memory) return { error: 'not_found' };
        if (!isOffset(q.pages)) return { error: 'out_of_bounds' };
        try { return { ok: memory.grow(q.pages) }; } catch { return { error: 'out_of_bounds' }; }
      case 'read':
        if (!memory) return { error: 'not_found' };
        if (!isOffset(q.offset) || !isOffset(q.length) || q.length > WASM_MAX_READ) return { error: 'out_of_bounds' };
        if (q.offset + q.length > memory.buffer.byteLength) return { error: 'out_of_bounds' };
        return { ok: b64(new Uint8Array(memory.buffer, q.offset, q.length)) };
      case 'write': {
        if (!memory) return { error: 'not_found' };
        const data = unb64(q.data);
        if (!isOffset(q.offset) || q.offset + data.length > memory.buffer.byteLength) return { error: 'out_of_bounds' };
        new Uint8Array(memory.buffer).set(data, q.offset);
        return { ok: true };
      }
    }
    return { error: `unknown operation ${op}` };
  }
}

// A value of Erlang (JSON) for a parameter of type t, and back.
function toWasm(v, t) {
  const n = v === 'nan' ? NaN : v === 'infinity' ? Infinity : v === '-infinity' ? -Infinity : v?.i !== undefined ? v.i : v;
  return t === 0x7e ? BigInt(n) : Number(n);
}

function fromWasm(v) {
  if (typeof v === 'bigint') return v >= -9007199254740991n && v <= 9007199254740991n ? Number(v) : { i: v.toString() };
  if (Number.isNaN(v)) return 'nan';
  if (v === Infinity) return 'infinity';
  if (v === -Infinity) return '-infinity';
  return v;
}

// A VM and its release. In a Worker (plain), the VM runs only in the handlers
// of open requests (serve). A Durable Object has one context for all its
// requests, and runs the VM all the time:
//
//   import { DurableObject } from 'cloudflare:workers';
//   import { Vm } from './worker.js';
//   export class Beam extends DurableObject {
//     constructor(ctx, env) { super(ctx, env); this.vm = new Vm(env, { plain: false, sql: ctx.storage.sql }); }
//     fetch(request) { return this.vm.fetch(request); }
//   }
// The key of SECRET_KEY_BASE in the store of secrets (autoVars).
const SECRET = 'beam:SECRET_KEY_BASE';

export class Vm {
  // release and snapshot: the bytes of release.bin and snapshot.bin, for a
  // VM that the global scope of a Worker restores (global.js).
  // id: the id of the Durable Object (with sql).
  // vars: more environment of the VM for this object only (the tenant, for
  // example). They are not part of the key of the snapshot, so the object
  // makes its snapshot at the boot point, and "go" gives them.
  // files: a store of HostFiles (for example the Deno KV of deno.js):
  // SQLite in the VM keeps its databases there, when the host does not run
  // the SQL itself (sql, or a D1 binding).
  // secrets: a store of the secrets that the VM makes itself ({get(name),
  // put(name, value)}: the storage of a Durable Object, the Deno KV of
  // deno.js), and host: the host of the first request (autoVars).
  // scheme: false when the host gives x-forwarded-proto itself (the web
  // page gives https for http://localhost).
  // capture: a VM that only makes a snapshot of the build (the tool of
  // node.mjs): 'boot-point' gives the snapshot at the boot point to
  // captured, and 'full' lets the tool call snapshot() itself. Such a VM
  // makes no variables of autoVars, and uses no store of snapshots.
  constructor(env, { plain = true, sql = null, id = null, release = null, snapshot = null, vars = {}, files = null,
                     secrets = null, host = null, scheme = true, capture = null } = {}) {
    this.scheme = scheme;
    this.capture = capture;
    this.captured = new Promise((resolve) => { this.gotCapture = resolve; });
    this.vars = vars;
    this.secrets = secrets;
    this.host = host;
    this.hostFiles = files && new HostFiles(files, { debug: env.BEAM_SQLITE_DEBUG === '1' });
    this.given = release && { release, snapshot };
    this.handles = new Map();  // id -> setTimeout handle: timers after adopt()
    this.id = id;
    this.sql = sql;            // ctx.storage.sql of a Durable Object (Ecto SQLite)
    this.tcps = new Map();     // id -> {send, close, h}: a TCP socket of wasm_tcp
    this.listeners = new Map(); // port -> the id of its listener (wasm_tcp); 'fetch' (and
                                // 'fetch-tls' when the VM trusts its CA): wasm_host_fetch
    this.fetchConns = new Map(); // id -> {host, port, h}: a connection of the fetch path
    this.fetches = new Map();  // id -> the AbortController of a fetch() of the fetch path
    this.dns = new Map();      // host -> {at, addresses}: the names of the fetch path
    this.fetchPending = 0;
    this.ports = new Set();    // the open ports to bindings (spawnPort)
    this.bindings = null;      // the env of the last request of a plain Worker
    this.nextId = 1;
    this.plain = plain;
    this.handlers = [];        // the open requests (plain)
    this.jobs = [];            // the wake-ups of the threads (plain)
    this.timers = new Map();   // id -> {at, f}: the timers of the threads (plain)
    this.nextTimer = 1;
    this.env = env;
    this.waitListen = new Map();  // port -> the resolve functions of listening()
    // BEAM_YIELD_REDS (1000000, about 50 ms of work; "0": none): the
    // reductions between the timers of the turns (see turn).
    this.turns = 0;
    this.turnEvery = Math.ceil(limit(env.BEAM_YIELD_REDS, 1000000) / 20000);
    this.conns = new Set();    // the open connections of bridge() (see die)
    this.sockets = 0;          // the open WebSockets: bridge() and /.tcp/PORT
    this.peak = 0;             // the memory (MB) of the last log of the peak
    // The VM stopped (erlang:halt, or a trap such as an allocation that
    // failed): dead is the reason, and died resolves. onDead: the owner of
    // the VM drops it, so that a new VM takes the next request.
    this.dead = null;
    this.died = new Promise((resolve) => { this.markDead = resolve; });
    // The waits that the stop of the VM ends (stopWait): a race with
    // this.died itself keeps one reaction for each race until the VM stops.
    this.stopWaits = new Set();
    this.onDead = null;
    // The static files of the release (appFiles of app-com.js), when the
    // release is loaded: a request for one of them needs no VM.
    this.statics = new Promise((resolve) => { this.gotStatics = resolve; });
    this.ready = this.boot(env);
    this.ready.catch(() => this.gotStatics(null));
  }

  // The variables that a Phoenix app needs, when the host does not give
  // them, so that it runs with no setup:
  // - SECRET_KEY_BASE: a random key, made one time and kept in the store
  //   of secrets, so that all the VMs of the app share it. With no store,
  //   each VM makes its own key (the sessions of one VM only).
  // - PHX_HOST: the host name of the first request (with no port: the app
  //   gets the origin of PHX_HOST on port 443, see appOrigin).
  // They go to the VM as vars: not in the key of a snapshot.
  async autoVars(env, meta) {
    if (meta.env?.PHX_SERVER !== 'true') return;
    if (!env.SECRET_KEY_BASE && !this.vars.SECRET_KEY_BASE) {
      let key = await this.secrets?.get(SECRET);
      if (!key) {
        const made = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(48))));
        key = this.secrets ? (await this.secrets.put(SECRET, made)) ?? made : made;
        if (!this.secrets) console.log('beam: SECRET_KEY_BASE is not set, and the host has no store: a new key for this VM');
      }
      this.vars.SECRET_KEY_BASE = key;
    }
    if (!env.PHX_HOST && !this.vars.PHX_HOST && this.host) this.vars.PHX_HOST = this.host;
  }

  async boot(env) {
    const t0 = Date.now();
    const [release, bundled] = this.given
      ? [this.given.release, this.given.snapshot]
      : await Promise.all([loadRelease(env), loadSnapshot(env)]);
    this.gotStatics(release.statics ?? null);
    // The vars of the host choose a snapshot at the boot point (below);
    // the vars of autoVars do not.
    const ownVars = Object.keys(this.vars).length;
    // A snapshot of the build holds no secret that the VM made itself.
    if (!this.capture) await this.autoVars(env, releaseMeta(release));
    // A snapshot of the build, else one that a Worker made (BEAM_SNAPSHOT =
    // "off" turns them off). A snapshot that the code gives (this.given,
    // the global scope) is used as it is. Else, of the snapshot of the
    // build (serve(app, { snapshot }), or snapshot.bin):
    // - a full one is used in place of the others;
    // - one at the boot point only when the store has no snapshot, and then
    //   the VM still makes its snapshot for the store.
    // A snapshot of the build of another release: a boot in its place.
    const meta = releaseMeta(release);
    let built = bundled && parseSnapshot(bundled);
    if (built?.release && built.release !== meta.snapshot_key) {
      console.log('beam: the snapshot of the build is for another release: a boot in its place');
      built = null;
    }
    // A snapshot of the build with other flags of the emulator: a boot in
    // its place (npx beam.com --snapshot --env BEAM_ERL_FLAGS=...). A
    // snapshot with no flags in its header was made with none.
    if (built && (built.flags ?? '') !== erlFlags(env)) {
      console.log(`beam: the snapshot of the build has the flags "${built.flags ?? ''}", and BEAM_ERL_FLAGS is "${erlFlags(env)}": a boot in its place`);
      built = null;
    }
    // A Durable Object with Ecto SQLite (sql of .release.json): the
    // snapshot is made at the boot point (wasm_host_server), before the
    // program starts and runs its migrations. So all the objects (the
    // tenants) share it, and each one runs the program on its own storage.
    // Tenants (BEAM_TENANTS) share the snapshot too, so it is made at the
    // boot point, before the program has the state of one tenant.
    const atBoot = !this.plain && (this.sql || this.hostFiles)
      && ((meta.sql ?? true) || !!env.BEAM_PERSIST || !!env.BEAM_TENANTS || ownVars > 0);
    let snap = null, key = null, fallback = null;
    if (built && (this.given || (!built.boot_point && !atBoot))) snap = built;
    else if (built?.boot_point) fallback = built;
    if (this.capture === 'boot-point') this.bootKey = 'capture';
    if (!snap && !this.capture && env.BEAM_SNAPSHOT !== 'off') {
      key = await snapshotKey(env, meta, this.plain ? 'worker' : atBoot ? 'durable boot-point' : 'durable');
      const stored = await snapshots.get(env, key);
      snap = stored && parseSnapshot(stored);
      if (!snap && !snapshots.unavailable && atBoot && !fallback) this.bootKey = key;
    }
    const fromFallback = !snap && !!fallback;
    if (fromFallback) snap = fallback;
    if (snap) await inflateSnapshot(snap);
    let snapBytes = snap ? snap.pagesData : null;
    const nifs = await nifModules();
    // restored: this VM comes from a snapshot (the page shows it).
    this.restored = !!snap;
    this.bootPointSnap = !!snap?.boot_point;
    // No snapshot yet (or only the one of the build at the boot point):
    // this VM makes it, before its first request.
    this.makeKey = (!snap || (fromFallback && !atBoot)) && !snapshots.unavailable && !this.bootKey && key;
    this.release = release;
    const t1 = Date.now();
    return new Promise((resolve, reject) => {
      const snapKB = snapBytes ? snapBytes.byteLength >> 10 : 0;
      this.onready = () => { this.peak = this.megabytes(); console.log(`beam: ready in ${Date.now() - t0} ms (release ${release.byteLength >> 10} KB${snap ? `, snapshot ${snapKB} KB` : ''} in ${t1 - t0} ms), ${this.memory()}`); resolve(); };
      createBeam({
        noInitialRun: !!snap,
        onRuntimeInitialized: snap ? () => {
          try {
            this.listeners = new Map(Object.entries(snap.listeners ?? {})
              .map(([p, id]) => [/^\d+$/.test(p) ? Number(p) : p, id]));
            restore(this.beam, this.exports, snap);
            // In the global scope (the bytes given), the first request
            // starts the threads. A snapshot of the boot point then goes on
            // with the boot (go).
            const start = () => {
              resume(this.beam, this.exports);
              if (snap.boot_point) this.go();
            };
            if (this.given) this.resume = start;
            else start();
            // The copy is in the memory of the VM now: free the bytes of the
            // snapshot (an isolate has 128 MB). The closures of the VM keep
            // this scope, so snapBytes must not keep them either.
            snap.pagesData = null;
            snap.fs = null;
            snapBytes = null;
            this.onready();
          } catch (e) { reject(e); }
        } : undefined,
        // The boot arguments are set in preRun, after the release is unpacked.
        arguments: [],
        jspiTurn: (f) => this.turn(f),
        // A plain Worker runs the jobs and timers of the threads in its
        // open requests. After adopt() (a Durable Object), they run on a
        // MessageChannel and on setTimeout.
        jspiSchedule: this.plain ? {
          later: (f) => {
            if (!this.plain) return this.post(f);
            this.jobs.push(f);
            this.handlers.at(-1)?.wake?.();
          },
          // 1 ms at least: the clock of a Worker moves only by the delay of
          // a timer (see jspiTimer in jspi_lib.js).
          timer: (f, ms) => {
            const id = this.nextTimer++;
            if (!this.plain) {
              this.handles.set(id, setTimeout(() => { this.handles.delete(id); f(); }, Math.max(1, ms)));
              return id;
            }
            this.timers.set(id, { at: Date.now() + Math.max(1, ms), f });
            this.handlers.at(-1)?.wake?.();
            return id;
          },
          clear: (id) => {
            this.timers.delete(id);
            clearTimeout(this.handles.get(id));
            this.handles.delete(id);
          },
        } : undefined,
        preRun: [(m) => {
          this.beam = m;
          // .release.json: the name, the version, the boot arguments and the
          // environment of the release (beam_com_wasm).
          const { name, vsn, args, env: relEnv } = unpack(m.FS, release);
          // BEAM_PERSIST: directories in the SQLite storage of the object.
          if (this.sql && env.BEAM_PERSIST) {
            this.persist = new Persist(this.sql, env.BEAM_PERSIST.split(','));
          }
          // The files that the boot of the snapshot wrote.
          for (const [p, b64] of Object.entries(snap?.fs.files ?? {})) {
            if (this.persist?.under(p)) continue;
            m.FS.mkdirTree(p.slice(0, p.lastIndexOf('/')));
            m.FS.writeFile(p, Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)));
          }
          if (this.persist) {
            this.persist.load(m.FS);
            this.persist.attach(m.FS);
          }
          // -c false (no time correction) for a snapshot: the monotonic time
          // then follows the system time, which goes on after a restore (the
          // OS monotonic time of a new instance starts again at 0).
          // BEAM_ERL_FLAGS: more flags of the emulator, as beam takes them
          // (-Mea min: no allocators of ERTS, only malloc; the VM of
          // Livebook starts with 40 MB, not 70 MB, but :erlang.memory/0 is
          // not supported).
          const flags = (env.BEAM_ERL_FLAGS ?? '').split(/\s+/).filter(Boolean);
          m.arguments.push('-S', '1', '-SDcpu', '1', '-A', '0', ...WAIT_FLAGS, ...allocFlags(flags), ...flags, ...(this.makeKey || this.bootKey || this.capture ? ['-c', 'false'] : []), '--',
            '-root', '/app', '-bindir', '/app/bin', '-progname', 'erl', '--',
            '-home', '/', ...args, '-noshell');
          // Distributed Erlang over wasm_tcp, with no epmd (all nodes on
          // DIST_PORT): wasm_host_server starts it after the boot (DIST_NAME,
          // DIST_COOKIE, DIST_LISTEN, DIST_CONNECT), when wasm_tcp works.
          if (env.DIST_NAME) {
            m.arguments.push('-proto_dist', 'wasm_tcp', '-erl_epmd_port', env.DIST_PORT ?? '4370', '-start_epmd', 'false');
          }
          // The text bindings of the Worker are the environment of the release
          // (SECRET_KEY_BASE, PHX_HOST, DATABASE_URL, ...).
          const vars = { ...Object.fromEntries(Object.entries(env).filter(([, v]) => typeof v === 'string')), ...this.vars };
          // The environment that "go" gives to a VM of a boot point snapshot.
          this.envVars = { ...relEnv, ...vars };
          Object.assign(m.ENV, {
            ROOTDIR: '/app', BINDIR: '/app/bin', EMU: 'beam', PROGNAME: 'erl', HOME: '/',
            RELEASE_ROOT: '/app', RELEASE_NAME: name, RELEASE_VSN: vsn, RELEASE_MODE: 'interactive',
            RELEASE_TMP: '/app/tmp', RELEASE_SYS_CONFIG: '/app/tmp/run.runtime', RELEASE_PROG: name,
            // The host of the runtime, for the app: cloudflare, or the value
            // of deno.js (deno, deno-deploy) or browser.js (browser).
            WASM_HOST: '1', BEAM_HOST: 'cloudflare',
          }, relEnv, vars, { WASM_HOST_SQL: this.hostSql() }, this.bootKey ? { WASM_HOST_BOOT_POINT: 'wait' } : {});
          m.beamHost.onsend = (bytes) => this.onsend(bytes);
          if (this.hostFiles) m.beamHost.files = this.hostFiles;
          // A mark file for each binding that is a port, for open_port/2 and
          // os:find_executable/1.
          m.FS.mkdirTree(PORT_DIR);
          for (const name of portNames(env)) {
            m.FS.writeFile(`${PORT_DIR}/${name}`, '');
            m.FS.chmod(`${PORT_DIR}/${name}`, 0o755);
          }
          m.beamHost.spawn = (spec, events) => this.spawnPort(spec, events);
        }],
        print: (s) => this.log(s),
        printErr: (s) => this.log(s),
        nifModule: (file) => nifModule(nifs, file),
        // Workers compile no WebAssembly at run time: use the imported module.
        instantiateWasm: (imports, done) => {
          WebAssembly.instantiate(wasm, imports).then((instance) => { this.exports = instance.exports; done(instance); });
          return {};
        },
        // In a plain Worker, the thread that stopped can run in the context
        // of a request that ended: die runs in an open request (run).
        onExit: (code) => {
          reject(new Error(`beam exited with status ${code}`));
          this.run(() => this.die(`exit status ${code}`));
        },
      }).catch(reject);
    });
  }

  // The first request of a VM with no snapshot: all the threads return
  // (erts_wasm_hibernate), the memory is copied, the threads go on, and the
  // copy goes to the store in the background. About 1 ms of the VM, and the
  // time of the copy.
  async makeSnapshot() {
    const key = this.makeKey;
    this.makeKey = null;
    // Not before the app is up (its server listens), and not while the host
    // has I/O of the VM (a SQL call, a socket): that I/O would not be in
    // the snapshot, and a restored VM would wait for it forever.
    const port = Number(this.env.PORT ?? 4000);
    await Promise.race([this.listening(port), new Promise((r) => setTimeout(r, 10000))]);
    const bytes = await this.snapshot(false);
    // No second try: after this, the VM has served requests, and the
    // snapshot could hold their state. The next new VM tries again.
    if (bytes && bytes !== 'busy') this.store(key, bytes);
  }

  // The boot point (wasm_host_server): the snapshot of a VM that loaded the
  // modules of its boot and did not start the program; then the boot goes
  // on (go).
  async bootPoint() {
    const key = this.bootKey;
    this.bootKey = null;
    if (key) {
      const bytes = await this.snapshot(true);
      // The snapshot of the build (or 'busy', or null): the tool stops this
      // VM, so the boot does not go on.
      if (this.capture) return this.gotCapture(bytes);
      if (bytes && bytes !== 'busy') this.store(key, bytes);
      else console.log(`beam: no snapshot at the boot point (${bytes})`);
    }
    this.go();
  }

  go() {
    this.event({ t: 'go' }, new TextEncoder().encode(JSON.stringify({ ...this.envVars, WASM_HOST_SQL: this.hostSql() })));
  }

  store(key, bytes) {
    if (this.capture) return this.gotCapture(bytes);
    console.log(`beam: snapshot ${bytes.length >> 10} KB (${key.slice(0, 12)})`);
    const put = snapshots.put(this.env, key, bytes).catch((e) => console.log(`beam: snapshot not stored: ${e.message}`));
    this.waitUntil?.(put);
  }

  // The VM has I/O of the host that a snapshot cannot hold
  // (NoSnapshotInFlight of specs/FetchPath.tla): a SQL call, a socket, a
  // fetch() of the fetch path, or an operation of WasmHost in flight. A
  // module or an instance of WasmHost is in the host only, as a socket is:
  // a restored VM would have its handle, and the new host would not.
  inFlight() {
    return this.sqlPending > 0 || this.tcps.size > 0 || this.fetchPending > 0 || this.wasmPending > 0
      || (this.wasm?.modules.size ?? 0) + (this.wasm?.instances.size ?? 0) > 0;
  }

  // All the threads return (erts_wasm_hibernate), the memory is copied, and
  // the threads go on: about 1 ms of the VM, and the time of the copy.
  // 'busy': not a quiet moment (I/O of the host); null: no snapshot.
  async snapshot(bootPoint) {
    const x = this.exports;
    const tick = () => new Promise((r) => setTimeout(r, 1));
    const busy = () => this.inFlight();
    // Data in a pipe (an event of the host that Erlang did not take yet,
    // or a wake-up of ERTS) would not be in the snapshot either.
    const unread = () => this.beam.FS.streams.some((st) => st?.node?.pipe?.buckets.some((b) => b.offset > b.roffset));
    for (let attempt = 0; ; attempt++) {
      for (let i = 0; busy() && i < 2000; i++) await tick();
      if (busy()) return 'busy';
      x.erts_wasm_hibernate();
      // 1 ms steps (5 s at most): on Cloudflare, setTimeout(0) does not wait
      // and does not move the clock, so 5000 steps of 0 ms ended at once.
      for (let i = 0; x.jspi_live_threads() > 0; i++) {
        if (i > 5000) {
          x.jspi_report_live();
          x.erts_wasm_resume();
          return null;
        }
        await new Promise((r) => setTimeout(r, 1));
      }
      if (!busy() && !unread()) break;
      // Not a quiet moment: go on, and try again.
      x.erts_wasm_resume();
      if (attempt >= 20) return 'busy';
      for (let i = 0; i < 5; i++) await tick();
    }
    try {
      return capture(this.beam, this.release, this.listeners, bootPoint, (p) => !!this.persist?.under(p), erlFlags(this.env));
    } finally {
      x.erts_wasm_resume();
    }
  }

  // "1" when the host runs the SQL of Ecto SQLite (the storage of a Durable
  // Object, or D1), else "0": SQLite in the VM (wasm_host_sqlite).
  hostSql() {
    return this.sql || this.env[this.env.BEAM_D1 ?? 'DB'] ? '1' : '0';
  }

  // A VM that the global scope restored (plain: its jobs ran between
  // microtasks) becomes the VM of a Durable Object: its jobs run on a
  // MessageChannel, and its timers on setTimeout (durable-global.js).
  adopt({ sql = null, id = null, vars = {} } = {}) {
    this.sql = sql;
    this.id = id;
    this.vars = vars;
    this.envVars = { ...this.envVars, ...vars };
    this.plain = false;
    for (const f of this.jobs.splice(0)) this.post(f);
    for (const [tid, t] of this.timers) {
      this.handles.set(tid, setTimeout(() => { this.handles.delete(tid); t.f(); }, Math.max(1, t.at - Date.now())));
    }
    this.timers.clear();
    return this;
  }

  // A job after the pending I/O and timers (a macrotask), as jspiLater.
  post(f) {
    if (!this.queue) {
      const ch = new MessageChannel();
      const fns = [];
      ch.port1.onmessage = () => fns.shift()?.();
      // Both ports: a port that only its handler holds can be collected.
      this.queue = { ch, fns };
    }
    this.queue.fns.push(f);
    this.queue.ch.port2.postMessage(0);
  }

  // In the global scope of a Worker, after a restore (global.js): the
  // threads start, and a GET request of path goes to the app. So V8
  // compiles the functions of a request here, not in the first request
  // (the global scope has its own time limit). No timers here: the jobs
  // of the threads run between microtasks. The request must not use I/O
  // of the host (SQL, sockets).
  //
  // The reseed of OpenSSL costs about 30 ms of CPU at its first run in an
  // isolate. So the warm-up also reseeds, with zero bytes: the global
  // scope has no random values, and the host gives zeros to the VM while
  // it warms up. The random bytes of the first request then reseed OpenSSL
  // again, before that request (seed()). A value that the warm-up makes
  // is the same in each isolate, as a value of the snapshot is.
  async warm(path) {
    if (this.bootPointSnap) return console.log('beam: no warm-up: the program starts at the first request');
    this.resume = () => seed(this.beam);
    const random = crypto.getRandomValues;
    crypto.getRandomValues = (v) => v.fill(0);
    try {
      this.exports.erts_wasm_resume();
      this.event({ t: 'restored' }, new Uint8Array(48));
      const url = new URL(path, 'http://localhost');
      let done = false;
      this.bridge(new Request(url), url, false, undefined, () => {})
        .then((r) => r.arrayBuffer()).finally(() => { done = true; });
      const idle = { jobs: [] };
      for (let i = 0; !done && i < 100000; i++) {
        this.runJobs(idle);
        await null;
      }
      if (!done) console.log(`beam: warm ${path}: no response`);
    } finally {
      crypto.getRandomValues = random;
    }
  }

  // A turn for a scheduler that computes (jspi_host_turn of jspi_lib.js,
  // each 20000 reductions with no wait), so that the I/O of the host (new
  // requests, sockets) runs while a process computes:
  // - Deno: setImmediate, which runs after the poll of the I/O, and costs
  //   little;
  // - a Durable Object (and a web page): one turn for each BEAM_YIELD_REDS
  //   reductions waits for a timer (about 1 ms or more); the other turns
  //   are tasks;
  // - a plain Worker: only tasks. A timer there resumes the thread in the
  //   request that fired it, and that request can end before the work.
  turn(f) {
    if (this.plain) {
      this.jobs.push(f);
      return void this.handlers.at(-1)?.wake?.();
    }
    if (typeof Deno == 'object') return void setImmediate(f);
    if (this.turnEvery && ++this.turns % this.turnEvery === 0) return void setTimeout(f, 0);
    this.post(f);
  }

  // The linear memory of the VM in MB. It never shrinks, so it is also its
  // peak.
  megabytes() {
    return this.beam ? this.beam.HEAPU8.length >> 20 : 0;
  }

  memory() {
    return `memory ${this.megabytes()} MB`;
  }

  // A log line each time the memory of the VM grew by 8 MB or more since
  // the last one (a Worker has 128 MB for all of the isolate).
  notePeak() {
    const mb = this.megabytes();
    if (mb < this.peak + 8) return;
    this.peak = mb;
    this.log(`beam: memory ${mb} MB (a new peak of this VM)`);
  }

  // The VM stopped: each open request gets 503, each WebSocket closes with
  // 1011, and the owner drops the VM (onDead). The threads of the VM do not
  // run again, so without this the open requests and all later ones wait
  // for an answer that does not come.
  die(reason) {
    if (this.dead) return;
    this.dead = reason;
    try { this.persist?.saveDirty(); } catch (e) { this.log(`beam: persist: the save at the stop failed (${e.message})`); }
    const open = [...this.conns].filter((c) => !c.status).length;
    this.log(`beam: the VM stopped (${reason}), ${this.memory()}: ${open} open requests get 503`);
    for (const p of this.ports ?? []) p.stop();
    // Each connection in its own request (run): in a plain Worker, its
    // response, its socket and its timer belong to that request.
    for (const c of this.conns) {
      this.bridgeRoom(c);
      const status = c.status;
      if (!status) c.status = 503;
      if (c.ws) this.socketGone(c);
      this.run(() => {
        clearTimeout(c.timer);
        if (!status) {
          c.resolve(this.stopped());
          c.finished();
        } else if (c.ws) {
          try { c.ws.close(1011, 'the app stopped'); } catch {}
        } else if (!c.done) {
          c.done = true;
          this.bridgeFinish(c, (w) => w.abort(new Error('the app stopped')));
        }
        this.bridgeRelease(c);
      }, c.h);
    }
    this.conns.clear();
    // The other sockets: /.tcp/PORT, and the connections of the VM.
    for (const [id, t] of this.tcps) {
      if (!id.startsWith('b')) this.run(() => { try { t.close(); } catch {} }, t.h);
    }
    this.tcps.clear();
    // The fetch() calls of the VM: no one reads their bodies now.
    for (const ac of this.fetches?.values() ?? []) ac.abort();
    this.markDead();
    for (const resolve of this.stopWaits ?? []) resolve();
    this.stopWaits?.clear();
    this.onDead?.(reason);
  }

  // A log line. In a plain Worker, a thread of the VM can run in the
  // context of a request that ended, where console.log throws: then an open
  // request writes the line (run).
  log(text) {
    try { console.log(text); } catch { this.run(() => console.log(text)); }
  }

  // The answer of a VM that stopped. The owner starts a new VM for the
  // next request.
  stopped() {
    return new Response('The app stopped. Try again.\n',
      { status: 503, headers: { 'content-type': 'text/plain', 'retry-after': '1' } });
  }

  // The answer above a limit of the host (BEAM_MAX_REQUESTS,
  // BEAM_MAX_WEBSOCKETS): before the VM gets the request or its body.
  busy(what) {
    console.log(`beam: too many ${what}: 503`);
    return new Response(`The app has too many ${what}. Try again.\n`,
      { status: 503, headers: { 'content-type': 'text/plain', 'retry-after': '1' } });
  }

  // A WebSocket of the VM closed (once for each one).
  socketGone(c) {
    if (c.counted) { c.counted = false; this.sockets--; }
  }

  event(header, body) {
    if (this.dead) return;
    const h = new TextEncoder().encode(JSON.stringify(header) + '\n');
    if (!body || !body.byteLength) return this.beam.beamHost.push(h);
    const b = new Uint8Array(h.length + body.byteLength);
    b.set(h);
    b.set(new Uint8Array(body), h.length);
    this.beam.beamHost.push(b);
  }

  // ctx: the context of a request to a plain Worker (none in a Durable
  // Object). env: the bindings of that request, for the ports: workerd ties
  // a stub of the bindings of a request to that request.
  async fetch(request, ctx, env = null) {
    // Caution: only a plain Worker gets a runner (see spawnPort). In a
    // Durable Object, the runner keeps each request open: on Cloudflare,
    // the tail then gives no event of the end of any request of the object.
    if (ctx) {
      this.waitUntil = (p) => ctx.waitUntil(p);
      this.inRequest = requestRunner();
    }
    if (env) this.bindings = env;
    let finished = () => {};
    const h = this.plain ? this.serve(ctx, new Promise((r) => { finished = r; })) : undefined;
    let response;
    try {
      response = await this.request(request, h, finished);
    } catch (e) {
      finished();
      throw e;
    }
    // A response before the VM read the body (a limit of the host, a VM
    // that stopped): the body goes to no reader (see drain).
    if (request.body && !request.body.locked) {
      const reader = request.body.getReader();
      await drain(() => reader.read(), () => reader.cancel());
    }
    return response;
  }

  async request(request, h, finished) {
    const statics = await this.statics;
    const file = statics && staticResponse(statics, request);
    if (file) {
      finished();
      return file;
    }
    if (this.dead) {
      finished();
      return this.stopped();
    }
    await this.ready;
    if (this.resume) {
      const f = this.resume;
      this.resume = null;
      f();
    }
    // The first request makes the snapshot, and the other requests wait for
    // it, so that the snapshot has the state of no request.
    if (this.makeKey) this.snapping = this.makeSnapshot().finally(() => { this.snapping = null; });
    // A snapshot that takes too long does not hold the request: the VM
    // goes on, and the snapshot ends later or fails.
    if (this.snapping) await this.stopWait(this.snapping, SNAPSHOT_WAIT);
    if (this.dead) {
      finished();
      return this.stopped();
    }
    const url = new URL(request.url);
    const upgrade = request.headers.get('upgrade')?.toLowerCase() === 'websocket';
    const tcp = upgrade && url.pathname.match(/^\/\.tcp\/(\d+)$/);
    if (tcp) return this.tcpAccept(Number(tcp[1]), request, h, finished);
    return this.bridge(request, url, upgrade, h, finished);
  }

  // A plain Worker runs code only for an open request, and an I/O object (a
  // stream, a socket) or a timer belongs to the request that made it. So the
  // handler of each open request is the event loop of the VM: it runs the
  // wake-ups and timers of the threads (jspiSchedule), and the host calls
  // that make or use I/O objects (run), until the request has its response
  // and its sockets are closed. With no open request, the VM does not run.
  serve(ctx, finished) {
    const h = { jobs: [], wake: null, timeout: null, sockets: 0, done: false };
    this.handlers.push(h);
    finished.then(() => { h.done = true; h.wake?.(); });
    // A macrotask of this request, after its pending I/O (as jspiLater).
    const ch = new MessageChannel();
    const tick = () => new Promise((r) => { ch.port1.onmessage = r; ch.port2.postMessage(0); });
    ctx.waitUntil((async () => {
      try {
        for (;;) {
          this.runJobs(h);
          if (h.done && !h.sockets) break;
          if (h.jobs.length || this.jobs.length || this.nextTimerAt() <= Date.now()) {
            await tick();
            continue;
          }
          // A timer of this request at least each second: else the runtime can
          // take a request that waits only for the VM (in another request) as
          // hung, and cancel it with the work of the VM that waits in it.
          const at = Math.min(this.nextTimerAt(), Date.now() + 1000);
          await new Promise((wake) => {
            h.wake = wake;
            h.timeout = setTimeout(wake, Math.max(0, at - Date.now()));
          });
          h.wake = null;
          if (h.timeout !== null) { clearTimeout(h.timeout); h.timeout = null; }
        }
      } finally {
        this.handlers.splice(this.handlers.indexOf(h), 1);
        ch.port1.close();
        this.handlers.at(-1)?.wake?.();  // the next one takes the jobs and timers
      }
    })());
    return h;
  }

  // The jobs of h, the wake-ups, and the timers that are due, as they are now.
  runJobs(h) {
    const call = (f) => {
      try { f(); } catch (e) { console.log(`beam: host call: ${e.message}`); }
    };
    for (const f of h.jobs.splice(0)) call(f);
    for (const f of this.jobs.splice(0)) call(f);
    const now = Date.now();
    for (const [id, t] of this.timers) {
      if (t.at <= now) { this.timers.delete(id); call(t.f); }
    }
  }

  nextTimerAt() {
    let at = Infinity;
    for (const t of this.timers.values()) at = Math.min(at, t.at);
    return at;
  }

  // Runs fn in the handler h (default: the newest request), or at once in a
  // Durable Object.
  run(fn, h = this.handlers.at(-1)) {
    if (!this.plain) return fn();
    if (!h) return void this.jobs.push(fn);
    h.jobs.push(fn);
    h.wake?.();
  }

  // One statement of wasm_host_sqlite. A D1 call is I/O of the request h:
  // it keeps h open (as a socket) until the answer.
  async sqlQuery(msg, body, h) {
    if (h) h.sockets++;
    this.sqlPending = (this.sqlPending ?? 0) + 1;
    let reply;
    try {
      const q = JSON.parse(new TextDecoder().decode(body));
      const params = q.params.map(fromWire);
      reply = this.sql ? sqlDurable(this.sql, q.sql, params) : await sqlD1(this.env, q.sql, params);
    } catch (e) {
      reply = { error: String(e?.message ?? e) };
      console.log(`beam: sql: ${reply.error}`);
    } finally {
      this.sqlPending--;
      if (h) { h.sockets--; h.wake?.(); }
    }
    this.event({ t: 'sql_reply', id: msg.id }, new TextEncoder().encode(JSON.stringify(reply)));
  }

  // One operation of wasm_host_wasm (WasmHost). It keeps the request h open
  // until the answer, as a D1 call does, and a snapshot waits for it.
  async wasmRequest(msg, body, h) {
    if (h) h.sockets++;
    this.wasmPending = (this.wasmPending ?? 0) + 1;
    let reply;
    try {
      this.wasm ??= new WasmHost();
      reply = await this.wasm.op(msg.op, JSON.parse(new TextDecoder().decode(body)));
    } catch (e) {
      reply = { error: String(e?.message ?? e) };
    } finally {
      this.wasmPending--;
      if (h) { h.sockets--; h.wake?.(); }
    }
    this.event({ t: 'wasm_reply', id: msg.id }, new TextEncoder().encode(JSON.stringify(reply)));
  }

  // A listener on port, once there is one.
  listening(port) {
    if (this.listeners.has(port)) return Promise.resolve();
    return new Promise((r) => this.waitListen.set(port, [...(this.waitListen.get(port) ?? []), r]));
  }

  // The first of promise, the stop of the VM, and ms milliseconds (LATE).
  // The wait leaves nothing behind when it ends.
  async stopWait(promise, ms = 0) {
    if (this.dead) return;
    let resolve, timer;
    const stop = new Promise((r) => { resolve = r; });
    (this.stopWaits ??= new Set()).add(resolve);
    if (ms) timer = setTimeout(() => resolve(LATE), ms);
    try {
      return await Promise.race([promise, stop]);
    } finally {
      clearTimeout(timer);
      this.stopWaits.delete(resolve);
    }
  }

  // The wait of a request for the listener of port, or null when it
  // listens. cancel() removes the wait of a request that ends first.
  listenWait(port) {
    if (this.listeners.has(port)) return null;
    let resolve;
    const promise = new Promise((r) => { resolve = r; });
    this.waitListen.set(port, [...(this.waitListen.get(port) ?? []), resolve]);
    const cancel = () => {
      const rest = (this.waitListen.get(port) ?? []).filter((r) => r !== resolve);
      if (rest.length) this.waitListen.set(port, rest);
      else this.waitListen.delete(port);
    };
    return { promise, cancel };
  }

  // The Origin that the app gets. Phoenix compares the Origin of a
  // WebSocket with the host of its config (PHX_HOST), so a page of the app on
  // another name of the Worker (wrangler dev, a custom domain, a preview URL,
  // a host tenant) got 403, and LiveView did not connect. A request from a
  // page of its own origin comes from the app itself: the app gets the origin
  // of PHX_HOST. The browser sets Origin, so the Origin of another site goes
  // as it is, and the app refuses it as before (check_origin: :conn of
  // Phoenix does the same check).
  appOrigin(origin, url) {
    const host = this.env.PHX_HOST ?? this.vars.PHX_HOST;
    return origin && host && origin === url.origin ? `https://${host}` : origin;
  }

  // The request as a TCP connection to the HTTP server of the
  // app on PORT. Bandit does the HTTP; here only the bytes are framed.
  // The limits of the host (vars, 0 for no limit):
  // - BEAM_MAX_REQUESTS: the requests that wait for the app at one time
  //   (no limit by default); one more gets 503 before the VM reads it;
  // - BEAM_MAX_WEBSOCKETS: the open WebSockets (no limit by default);
  // - BEAM_REQUEST_TIMEOUT: the seconds until the head of the response
  //   (60 by default), after the end of the request body; then the request
  //   gets 504, and the app gets the end of the connection;
  // - BEAM_MAX_BODY: the bytes of a request body (no limit by default);
  //   a larger one gets 413.
  // The body goes to the app in the chunks of the client (bridgeUpload).
  async bridge(request, url, upgrade, h, finished) {
    const maxSockets = limit(this.env.BEAM_MAX_WEBSOCKETS, 0);
    if (upgrade && maxSockets && this.sockets >= maxSockets) {
      finished();
      return this.busy('WebSockets');
    }
    const maxRequests = limit(this.env.BEAM_MAX_REQUESTS, 0);
    if (!upgrade && maxRequests && [...this.conns].filter((c) => !c.ws).length >= maxRequests) {
      finished();
      return this.busy('requests');
    }
    const body = request.method === 'GET' || request.method === 'HEAD' || upgrade ? null : request.body;
    const declared = request.headers.get('content-length');
    // The bytes of the body that the app gets (null: chunked). The host
    // sends the app at most these bytes, so a declared length that is not
    // a number of bytes is a bad request.
    const length = body && declared !== null ? Number(declared) : null;
    if (length !== null && !(/^\d+$/.test(declared) && Number.isSafeInteger(length))) {
      finished();
      return this.badLength(declared);
    }
    const maxBody = limit(this.env.BEAM_MAX_BODY, 0);
    if (body && maxBody && length !== null && length > maxBody) {
      finished();
      return this.tooLarge(maxBody);
    }
    const port = Number(this.env.PORT ?? 4000);
    // The time limit counts from here: the app can also fail to listen.
    const timeout = limit(this.env.BEAM_REQUEST_TIMEOUT, 60);
    const deadline = Date.now() + timeout * 1000;
    // Only a request that comes before the app listens waits here.
    const listen = this.listenWait(port);
    let waited;
    if (listen) {
      waited = await this.stopWait(listen.promise, timeout * 1000);
      listen.cancel();
    }
    if (this.dead) {
      finished();
      return this.stopped();
    }
    if (waited === LATE) {
      finished();
      return this.late(`the app did not listen on port ${port}`, timeout);
    }
    const id = `b${this.nextId++}`;
    const headers = new Headers(request.headers);
    headers.set('host', url.host);
    // The scheme of the client: the app gets a TCP connection with no TLS,
    // and Plug.SSL (force_ssl of Phoenix) reads x-forwarded-proto, as on
    // Deno and in a web page. The value of the Worker replaces the value
    // that a client sends. The web page gives its own value (scheme: false).
    if (this.scheme) headers.set('x-forwarded-proto', url.protocol.slice(0, -1));
    const origin = this.appOrigin(headers.get('origin'), url);
    if (origin) headers.set('origin', origin);
    headers.delete('transfer-encoding');
    headers.delete('sec-websocket-extensions');  // no compression: frames as they are
    // The host has the whole request: no "100 Continue" from the app.
    headers.delete('expect');
    // The Workers runtime compresses the response for each client. The app
    // gets only gzip of Accept-Encoding: Plug.Static serves the files that
    // are gzipped already (Livebook has no other ones), and the response
    // goes as it is (encodeBody: 'manual').
    const gzip = /\bgzip\b/i.test(headers.get('accept-encoding') ?? '');
    headers.delete('accept-encoding');
    if (gzip) headers.set('accept-encoding', 'gzip');
    if (upgrade) {
      headers.set('connection', 'Upgrade');
      headers.set('sec-websocket-key', btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16)))));
      headers.set('sec-websocket-version', '13');
    } else {
      headers.set('connection', 'close');
    }
    // A body of no declared length goes to the app as chunked. A request
    // with no body gets no content-length of the client.
    if (length !== null) headers.set('content-length', String(length));
    else if (body) {
      headers.delete('content-length');
      headers.set('transfer-encoding', 'chunked');
    } else {
      headers.delete('content-length');
      if (!upgrade && !['GET', 'HEAD'].includes(request.method)) headers.set('content-length', '0');
    }
    let head = `${request.method} ${url.pathname}${url.search} HTTP/1.1\r\n`;
    for (const [k, v] of headers) head += `${k}: ${v}\r\n`;
    // The values of Headers are bytes (one character for each byte).
    const bytes = latin1Bytes(head + '\r\n');
    if (this.dead) {
      finished();
      return this.stopped();
    }
    let c;
    const response = await new Promise((resolve) => {
      c = { id, in: new Pieces(), resolve, finished, upgrade, head: request.method === 'HEAD', h, origin: request.headers.get('origin'), path: url.pathname, sent: 0, read: 0, room: null };
      if (h) h.sockets++;
      this.conns.add(c);
      c.timeout = timeout;
      // A body can take long to come: the time limit starts at its end.
      if (!body) this.bridgeClock(c, deadline - Date.now());
      // An error of one connection ends that connection, not the VM.
      // A send ends when the client read its bytes (the newest write of
      // the response, c.wrote): tcpSend then tells the VM (tcp_sent).
      this.tcps.set(id, {
        send: (b) => { this.bridgeGuard(c, () => this.bridgeData(c, b)); return c.wrote; },
        close: () => this.bridgeGuard(c, () => this.bridgeEnd(c)),
        ack: (n, msg) => this.bridgeRead(c, n, msg), h,
      });
      // ack: wasm_tcp tells the host what the app read (tcp_read): the
      // body of the request, and the messages of a WebSocket. sent: the
      // host tells wasm_tcp what the client took (tcp_sent).
      this.event({ t: 'tcp_accept', id: this.listeners.get(port), conn: id, host: request.headers.get('cf-connecting-ip') ?? '0.0.0.0', port: 0, ack: !!body || upgrade, sent: true });
      // With a body, the head goes in the event of the first part of the
      // body (bridgeUpload): a small body is one event, as before the parts.
      if (body) c.upload = this.bridgeUpload(c, body, length, maxBody, bytes);
      else this.bridgeSend(c, bytes);
    });
    // A response before the end of the body: the rest of the body goes to
    // the app while it reads, else bridgeUpload reads and drops it (see
    // drain). A response with a body stream goes at once, and the end of
    // its body waits for the upload (bridgeFinish): the client reads the
    // response while the app reads the request. A response with no stream
    // (an answer of the host, or HEAD, 204, 304 and a length of 0) ends
    // when it goes, so it waits for the upload here. The upload ends
    // within the bounds of drain after the end of the connection.
    if (c.upload && !c.stream) await c.upload;
    return response;
  }

  // Bytes to the app on the connection c.
  bridgeSend(c, bytes) {
    c.sent += bytes.length;
    if (c.need) c.need = Math.max(0, c.need - bytes.length);
    this.event({ t: 'tcp_data', id: c.id }, bytes);
  }

  // The body of a request to the app, in parts of UPLOAD_PART bytes or more
  // (or the rest of the body): one event for each part, not for each small
  // chunk of the client. A part goes when less than UPLOAD_WINDOW bytes are
  // unread in the VM (tcp_read of wasm_tcp): so a large body does not fill
  // the memory of the VM, and a slow app slows the client. While a recv of
  // the app waits for more bytes (c.need, as Bandit reads a body), a part
  // has those bytes, UPLOAD_LARGE at most: the app holds them anyway, and
  // each event costs a turn of the VM. The head of the request goes with
  // the bytes of the first read of the client, with no wait for
  // UPLOAD_PART bytes. length: the declared length of the body (null: the
  // body goes as chunked). A body with more bytes, or with fewer bytes, is
  // a bad request: the app gets at most length bytes, so the rest of a
  // stream cannot be a second request on the connection of the app.
  async bridgeUpload(c, body, length, max, head) {
    const chunked = length === null;
    // workerd has readAtLeast. The option min of the standard BYOB read is
    // not safe: when the stream closes with fewer bytes than min, the read
    // errors the stream (Node.js 26, Chromium). So the other hosts use the
    // default reader, and the parts come from the chunks here.
    let byob = null;
    try { byob = body.getReader({ mode: 'byob' }); } catch {}
    if (byob && !byob.readAtLeast) { byob.releaseLock(); byob = null; }
    const reader = byob ?? body.getReader();
    const read = byob ? (min) => byob.readAtLeast(min, new Uint8Array(UPLOAD_READ)) : () => reader.read();
    let total = 0;
    let part = [];
    let size = 0;
    // The gathered part to the app, when less than UPLOAD_WINDOW bytes are
    // unread. False when the connection ended while it waited.
    const flush = async () => {
      while (c.sent - c.read >= UPLOAD_WINDOW && !c.done && !this.dead) {
        await new Promise((resolve) => { c.room = resolve; });
      }
      if (c.done || this.dead) return false;
      const bytes = part.length === 1 ? part[0] : join(part, size);
      part = [];
      size = 0;
      out(chunked ? chunk(bytes) : bytes);
      return true;
    };
    // Bytes to the app, after the head when it did not go yet.
    const out = (bytes) => {
      clearTimeout(alone);
      this.bridgeSend(c, head ? join([head, bytes], head.length + bytes.length) : bytes);
      head = null;
    };
    // A client that sends no body yet: the head goes alone after HEAD_WAIT
    // ms, so the app sees the request (and its own time limits run).
    const alone = setTimeout(() => { if (head && !c.done && !this.dead) out(new Uint8Array(0)); }, HEAD_WAIT);
    // The end of the connection (bridgeRoom calls c.ended) ends the wait
    // for a read of a client that sends no more bytes: then drain reads
    // with its bounds, from that read (pending). Each wait has its own
    // promise, so a long upload keeps no reaction for each read.
    let pending = null;
    try {
      for (;;) {
        // A read can end the stream with its last bytes (done and a value).
        const next = read(head ? 1 : UPLOAD_PART);
        const r = c.done || this.dead ? null : await new Promise((resolve, reject) => {
          c.ended = () => resolve(null);
          next.then(resolve, reject);
        });
        c.ended = null;
        if (c.done || this.dead) {
          pending = next;
          break;
        }
        const { value, done } = r;
        if (value?.length) total += value.length;
        // No byte of a read past the declared length goes to the app.
        if (!chunked && (total > length || (done && total < length))) {
          this.bridgeRefuse(c, this.badLength(length));
          break;
        }
        if (max && total > max) {
          this.bridgeRefuse(c, this.tooLarge(max));
          break;
        }
        // A chunk of the client can be large (Deno): it goes in pieces of
        // UPLOAD_READ bytes or less, so the window stays small.
        let ok = true;
        for (let at = 0; ok && value && at < value.length; at += UPLOAD_READ) {
          const piece = value.subarray(at, at + UPLOAD_READ);
          part.push(piece);
          size += piece.length;
          if (size >= Math.min(Math.max(c.need ?? 0, UPLOAD_PART), UPLOAD_LARGE)) ok = await flush();
        }
        if (ok && (done || head) && size) ok = await flush();
        if (!ok) break;
        if (done) {
          if (chunked) out(CHUNKS_END);
          else if (head) out(new Uint8Array(0));
          this.bridgeClock(c, c.timeout * 1000);
          return;
        }
      }
    } catch {
      // The client stopped the upload.
      this.bridgeRefuse(c, new Response('bad request\n', { status: 400 }));
      return;
    } finally {
      clearTimeout(alone);
    }
    // The app ended the connection, or the body is above BEAM_MAX_BODY.
    // this.drainLimits replaces the bounds of drain (a test).
    const rest = () => {
      const p = pending ?? read(UPLOAD_PART);
      pending = null;
      return p;
    };
    await drain(rest, () => reader.cancel(), this.drainLimits);
  }

  // The time limit of the response of c: BEAM_REQUEST_TIMEOUT, in ms ms.
  bridgeClock(c, ms) {
    if (c.timeout && !c.status && !c.done) c.timer = setTimeout(() => this.bridgeTimeout(c, c.timeout), Math.max(ms, 1));
  }

  // The app read n bytes of the connection c (tcp_read). msg.want and
  // msg.got give the bytes that a recv of the app still waits for, beyond
  // the bytes on their way to it (c.need).
  bridgeRead(c, n, msg) {
    c.read += n;
    if (msg?.want !== undefined) c.need = Math.max(0, msg.got + msg.want - c.sent);
    this.bridgeRoom(c);
    c.inbound?.flush();
  }

  // The upload of c waits no more (more room, or the end of c). At the end
  // of c, it also waits no more for a read of the client (c.ended).
  bridgeRoom(c) {
    const room = c.room;
    c.room = null;
    room?.();
    if (c.done || this.dead) c.ended?.();
  }

  // The answer of the host in place of the app (when the app has not
  // answered yet), and the end of the connection for the app.
  bridgeRefuse(c, response) {
    if (!c.status) {
      clearTimeout(c.timer);
      c.status = response.status;
      c.resolve(response);
      c.finished();
    }
    this.bridgeDone(c);
  }

  // The answer above BEAM_MAX_BODY.
  tooLarge(max) {
    this.log(`beam: a request body above ${max} bytes: 413`);
    return new Response(`The body is larger than ${max} bytes.\n`, { status: 413, headers: { 'content-type': 'text/plain' } });
  }

  // The answer to a body that does not have the bytes of its
  // content-length (a Request of a host adapter, for example), or to a
  // content-length that is not a number of bytes.
  badLength(declared) {
    this.log(`beam: a request body that does not have its content-length (${String(declared).slice(0, 32)}): 400`);
    return new Response('The body does not have the length of its content-length.\n',
      { status: 400, headers: { 'content-type': 'text/plain' } });
  }

  // Bytes from the HTTP server of the app to the connection c of bridge().
  bridgeData(c, data) {
    c.in.push(data);
    while (!c.status) {
      // The head of the response: it is small, so the bytes are joined.
      const head = c.in.peek(c.in.size);
      const end = indexOf(head, [13, 10, 13, 10]);
      if (end < 0) {
        if (head.length > HEAD_MAX) throw new Error(`a head of a response above ${HEAD_MAX} bytes`);
        return;
      }
      // The bytes of a header value are characters of one byte (Headers
      // takes no character above U+00FF).
      const lines = latin1(head.subarray(0, end)).split('\r\n');
      c.in.drop(end + 4);
      const status = Number(lines[0].split(' ')[1]);
      // An informational head (100 Continue, 103 Early Hints): the head of
      // the response comes after it.
      if (status >= 100 && status < 200 && !(status === 101 && c.upgrade)) continue;
      const headers = new Headers();
      for (const l of lines.slice(1)) {
        const i = l.indexOf(':');
        headers.append(l.slice(0, i).trim(), l.slice(i + 1).trim());
      }
      clearTimeout(c.timer);
      if (status === 101) {
        c.status = 101;
        return this.bridgeUpgrade(c, headers);
      }
      if (c.upgrade && status === 403) {
        console.log(`beam: the app refused the WebSocket of ${c.path} (403) from the origin ${c.origin}. ` +
          `A Phoenix app compares the Origin with the host of its config (PHX_HOST=${this.env.PHX_HOST ?? this.vars.PHX_HOST ?? ''}): see check_origin.`);
      }
      c.length = headers.has('content-length') ? Number(headers.get('content-length')) : null;
      c.chunked = /chunked/i.test(headers.get('transfer-encoding') ?? '');
      headers.delete('transfer-encoding');
      headers.delete('connection');
      if (c.head || status === 204 || status === 304) { c.length = 0; c.chunked = false; }
      // A body from a port (x-beam-port): the bytes of the app after the
      // head go nowhere.
      const portBody = headers.has('x-beam-port') ? this.claimPort(headers, c.length === 0 && (c.head || status === 204 || status === 304)) : null;
      c.left = 0;
      // workerd sends the body of a TransformStream in chunks, also with a
      // content-length, and it ends the chunks normally when the stream
      // fails. A FixedLengthStream keeps the content-length: then a body
      // with fewer bytes is an error for the client (docs/UPSTREAM.md, CF9).
      // With content-encoding, the length is of the bytes of the app.
      const fixed = !c.chunked && Number.isSafeInteger(c.length) && c.length > 0 &&
        typeof FixedLengthStream === 'function';
      const { readable, writable } = fixed ? new FixedLengthStream(c.length) : new TransformStream();
      // The app compressed the body (Bandit: gzip, deflate): the runtime
      // must send it as it is, not compress it again.
      const encodeBody = headers.has('content-encoding') ? 'manual' : 'automatic';
      // The Response first: a status that it refuses ends the connection
      // with 502 (bridgeGuard), and the client gets an answer.
      const stream = c.length !== 0;
      const response = new Response(portBody ?? (stream ? readable : null), { status, headers, encodeBody });
      c.stream = stream;
      c.status = status;
      c.writer = portBody ? null : writable.getWriter();
      // The client went away (or the stream failed): the app gets the end
      // of the connection.
      c.writer?.closed.catch(() => this.bridgeDone(c));
      c.resolve(response);
      c.finished();
    }
    if (c.ws) return this.bridgeFrames(c);
    this.bridgeBody(c);
  }

  // The body of a response from a port (docs/WORKERS.md, "Ports to
  // bindings"): x-beam-port is the os_pid of a port of this VM, opened with
  // BEAM_PORT_OUTPUT=response, and the result of the port is the body.
  // x-beam-port-length (optional) is its length. none: a response with no
  // body (HEAD, 204, 304), which leaves the port as it is. An unknown port
  // throws (502, see bridgeGuard).
  claimPort(headers, none) {
    const value = headers.get('x-beam-port');
    const pid = Number(value);
    const size = Number(headers.get('x-beam-port-length') ?? NaN);
    headers.delete('x-beam-port');
    headers.delete('x-beam-port-length');
    if (none) return null;
    headers.delete('content-length');
    const fixed = Number.isSafeInteger(size) && size > 0 && typeof FixedLengthStream === 'function';
    const { readable, writable } = fixed ? new FixedLengthStream(size) : new TransformStream();
    const port = [...this.ports].find((p) => p.pid === pid);
    if (!port?.claim(writable.getWriter(), fixed ? size : null)) throw new Error(`no port ${value} that waits for a response`);
    if (fixed) headers.set('content-length', String(size));
    return readable;
  }

  // The body of a response: by content-length, chunked, or until the end.
  // The pieces of the app go to the stream as they are (views, no copy):
  // also the data of a large chunk, before its end.
  bridgeBody(c) {
    if (c.done) return;
    const pieces = c.in;
    if (c.chunked) {
      while (pieces.size && !c.done) {
        if (c.left > 0) {
          const part = pieces.next(c.left);
          c.left -= part.length;
          this.bridgeWrite(c, part);
          if (c.left === 0) c.left = -2;  // then the CRLF of the chunk
          continue;
        }
        if (c.left < 0) {
          const n = Math.min(-c.left, pieces.size);
          pieces.drop(n);
          c.left += n;
          continue;
        }
        // The size line of the next chunk (a chunk extension after ";").
        const line = pieces.peek(Math.min(pieces.size, CHUNK_LINE));
        const nl = line.indexOf(10);
        if (nl < 0) {
          if (line.length >= CHUNK_LINE) this.bridgeBad(c);
          return;
        }
        const size = parseInt(new TextDecoder().decode(line.subarray(0, nl)), 16);
        pieces.drop(nl + 1);
        if (size === 0) return this.bridgeDone(c);
        if (!(size > 0)) return this.bridgeBad(c);
        c.left = size;
      }
      return;
    }
    while (pieces.size && c.length !== 0) {
      const part = pieces.next(c.length ?? Infinity);
      if (c.length !== null) c.length -= part.length;
      this.bridgeWrite(c, part);
    }
    if (c.length === 0) this.bridgeDone(c);
  }

  // A part of the body to the client. A write to a stream that the client
  // closed fails, and writer.closed then ends the connection.
  bridgeWrite(c, part) {
    if (c.writer) c.wrote = c.writer.write(part).catch(() => {});
  }

  // fn for the connection c (an event of the app). An exception ends c:
  // 502 before the head of the response, else the end of the stream or of
  // the WebSocket. Before, it stopped the thread of the VM, and so the VM.
  bridgeGuard(c, fn) {
    try {
      fn();
    } catch (e) {
      this.log(`beam: the response of ${c.path} failed (${e.message}): the connection ends`);
      if (c.ws) {
        try { c.ws.close(1011); } catch {}
        this.socketGone(c);
        this.conns.delete(c);
        this.tcps.delete(c.id);
        this.event({ t: 'tcp_closed', id: c.id });
        this.bridgeRelease(c);
      } else if (!c.status) {
        this.bridgeRefuse(c, new Response('bad gateway\n', { status: 502 }));
      } else {
        this.bridgeFinish(c, (w) => w.abort(e));
        this.bridgeDone(c);
      }
    }
  }

  // A chunked body that is not HTTP/1.1: the stream of the response
  // fails, and the app gets the end of the connection.
  bridgeBad(c) {
    console.log(`beam: a bad chunked body from the app for ${c.path}: the response stops`);
    this.bridgeFinish(c, (w) => w.abort(new Error('a bad chunked body from the app')));
    this.bridgeDone(c);
  }

  // The end of the body of the response of c (once): end(writer) closes
  // or aborts the stream, after the upload of c. workerd sends a response
  // only at the end of its body, and it cannot read the request body after
  // that. So the host can read the rest of the request body until then
  // (drain), and the next request on the connection of the client works.
  bridgeFinish(c, end) {
    const writer = c.writer;
    if (!writer) return;
    c.writer = null;
    const run = () => end(writer).catch(() => {});
    if (c.upload) c.upload.then(run, run);
    else run();
  }

  bridgeDone(c) {
    if (c.done) return;
    c.done = true;
    this.bridgeRoom(c);
    this.bridgeFinish(c, (w) => w.close());
    this.conns.delete(c);
    this.tcps.delete(c.id);
    this.event({ t: 'tcp_closed', id: c.id });
    this.bridgeRelease(c);
  }

  // The request of c can end (once).
  bridgeRelease(c) {
    if (c.released) return;
    c.released = true;
    if (c.h) { c.h.sockets--; c.h.wake?.(); }
    this.notePeak();
  }

  // The app closed the connection.
  bridgeEnd(c) {
    clearTimeout(c.timer);
    this.tcps.delete(c.id);
    if (!c.status) {
      c.status = 502;
      c.resolve(new Response('bad gateway\n', { status: 502 }));
      c.finished();
    }
    if (c.ws) {
      try { c.ws.close(); } catch {}
      this.socketGone(c);
      this.conns.delete(c);
      this.bridgeRelease(c);
    } else {
      this.bridgeCut(c);
      this.bridgeDone(c);
    }
  }

  // The app ended the connection, or its writes, before the end of the
  // body of c: chunks with no last chunk, or fewer bytes than the
  // content-length (Bandit, when a plug raises after send_chunked/2). The
  // stream of the client fails, and it does not end normally. With no
  // content-length and no chunks, the end of the connection is the end of
  // the body. True when the stream fails.
  bridgeCut(c) {
    if (!c.writer || !(c.chunked || c.length > 0)) return false;
    this.log(`beam: the app ended the connection before the end of the body of ${c.path}: the response stops`);
    this.bridgeFinish(c, (w) => w.abort(new Error('the app ended the connection before the end of the body')));
    return true;
  }

  // No head of a response in BEAM_REQUEST_TIMEOUT seconds: 504 for the
  // client, and the end of the connection for the app (tcp_closed).
  bridgeTimeout(c, seconds) {
    if (c.status || c.done) return;
    c.status = 504;
    c.resolve(this.late(`no response for ${c.path}`, seconds));
    c.finished();
    this.bridgeDone(c);
  }

  // The answer of BEAM_REQUEST_TIMEOUT.
  late(what, seconds) {
    console.log(`beam: ${what} in ${seconds} s: 504`);
    return new Response('The app did not answer in time.\n', { status: 504, headers: { 'content-type': 'text/plain' } });
  }

  // A WebSocket: the client end to the browser, frames to the app. The 101
  // of the client has the headers of the 101 of the app (the subprotocol
  // of sec-websocket-protocol, a set-cookie), without the headers of the
  // handshake and of the connection: the runtime makes its own.
  bridgeUpgrade(c, appHeaders = new Headers()) {
    const headers = new Headers();
    for (const [k, v] of appHeaders) if (!UPGRADE_OWN.has(k)) headers.append(k, v);
    const [client, server] = Object.values(new WebSocketPair());
    server.accept();
    server.binaryType = 'arraybuffer';
    c.ws = server;
    c.counted = true;
    this.sockets++;
    c.frames = [];  // the parts of a message in fragments
    // The messages of the client go while less than UPLOAD_WINDOW bytes
    // are unread in the VM; the others wait here (Inbound).
    c.inbound = new Inbound(c, (b) => this.bridgeSend(c, b), () => {
      console.log(`beam: the app reads the WebSocket of ${c.path} too slowly: it closes (1008)`);
      closeSocket(server, 1008);
    });
    server.addEventListener('message', (e) => {
      const text = typeof e.data === 'string';
      c.inbound.push(frame(text ? 1 : 2, text ? new TextEncoder().encode(e.data) : new Uint8Array(e.data)));
    });
    server.addEventListener('close', (e) => {
      this.socketGone(c);
      const code = wireCode(e.code);
      c.inbound.push(frame(8, new Uint8Array([code >> 8, code & 255])), true);
    });
    c.resolve(new Response(null, { status: 101, webSocket: client, headers }));
    c.finished();
    this.bridgeFrames(c);
  }

  // WebSocket frames from the app (not masked) to messages for the client.
  bridgeFrames(c) {
    const pieces = c.in;
    for (;;) {
      // The head of a frame (2 to 10 bytes), then its payload in one array.
      const b = pieces.peek(Math.min(pieces.size, 10));
      if (b.length < 2) return;
      let len = b[1] & 127, at = 2;
      if (len === 126) { if (b.length < 4) return; len = (b[2] << 8) | b[3]; at = 4; }
      else if (len === 127) { if (b.length < 10) return; len = Number(new DataView(b.buffer, b.byteOffset).getBigUint64(2)); at = 10; }
      if (pieces.size < at + len) return;
      const fin = b[0] & 128, op = b[0] & 15;
      pieces.drop(at);
      const data = pieces.take(len);
      if (op === 9) { this.event({ t: 'tcp_data', id: c.id }, frame(10, data)); continue; }
      if (op === 10) continue;
      if (op === 8) { closeSocket(c.ws, len >= 2 ? (data[0] << 8) | data[1] : 1000); continue; }
      if (op !== 0) c.op = op;
      c.frames.push(data);
      if (!fin) continue;
      const all = new Uint8Array(c.frames.reduce((n, f) => n + f.length, 0));
      let i = 0;
      for (const f of c.frames) { all.set(f, i); i += f.length; }
      c.frames = [];
      // The client can close at any time: a send after it is dropped.
      try { c.ws.send(c.op === 1 ? new TextDecoder().decode(all) : all); } catch {}
    }
  }

  // A connection to a listener of wasm_tcp: a WebSocket to /.tcp/PORT. In a
  // plain Worker it belongs to the handler h of its request.
  tcpAccept(port, request, h, finished) {
    const listener = this.listeners.get(port);
    finished();
    if (!listener) return new Response(`no listener on ${port}\n`, { status: 404 });
    const maxSockets = limit(this.env.BEAM_MAX_WEBSOCKETS, 0);
    if (maxSockets && this.sockets >= maxSockets) return this.busy('WebSockets');
    const id = `w${this.nextId++}`;
    const [client, server] = Object.values(new WebSocketPair());
    server.accept();
    server.binaryType = 'arraybuffer';  // (the default can be Blob)
    if (h) h.sockets++;
    const counted = { counted: true };
    this.sockets++;
    const t = { send: (b) => { try { server.send(b); } catch {} }, close: () => { this.socketGone(counted); try { server.close(); } catch {} }, h };
    // A WebSocket has no end of one direction: a shutdown of write closes
    // it (docs/WORKERS.md).
    t.shutdown = () => t.close();
    const win = { sent: 0, read: 0 };
    const inbound = new Inbound(win, (b) => this.tcpIn(id, win, b), () => {
      console.log(`beam: the app reads the connection ${id} to port ${port} too slowly: it closes (1008)`);
      closeSocket(server, 1008);
    });
    t.ack = (n) => { win.read += n; inbound.flush(); };
    this.tcps.set(id, t);
    this.event({ t: 'tcp_accept', id: listener, conn: id, host: request.headers.get('cf-connecting-ip') ?? '0.0.0.0', port: 0, ack: true, sent: true });
    server.addEventListener('message', (e) => {
      inbound.push(typeof e.data === 'string' ? new TextEncoder().encode(e.data) : new Uint8Array(e.data));
    });
    server.addEventListener('close', () => {
      this.socketGone(counted);
      this.tcpClosed(id);
      if (h) { h.sockets--; h.wake?.(); }
    });
    return new Response(null, { status: 101, webSocket: client });
  }

  // A TCP socket of wasm_tcp: net.connect() of node:net. In a plain
  // Worker it belongs to the handler h, and closes with that request.
  // A connect of the VM (specs/FetchPath.tla). HTTP goes through fetch()
  // first (fetchFirst); the other protocols use connect(). direct: the
  // tunnel of wasm_host_fetch, which never goes back to the fetch path.
  async tcpConnect({ id, host, port, direct }, h) {
    let socket, inbound;
    if (h) h.sockets++;
    const allowed = connectAllowed(this.env.BEAM_CONNECT, host, port);
    const fetchPath = this.listeners.has('fetch') && !direct;
    if (allowed && fetchPath && this.fetchFirst(host, port)) return this.fetchPair(id, host, port, h);
    try {
      if (!allowed) throw new Error('not in BEAM_CONNECT');
      socket = net.connect({ host, port });
      // A send resolves when the bytes are written; a close sends the
      // bytes that wait, and then ends the socket.
      const t = {
        send: (b) => new Promise((resolve) => socket.write(b, () => resolve())),
        close: () => socket.end(() => socket.destroy()),
        shutdown: () => socket.end(),
        h,
      };
      // The data of the peer goes while less than UPLOAD_WINDOW bytes are
      // unread in the VM; else the socket pauses.
      const win = { sent: 0, read: 0 };
      inbound = new Inbound(win, (b) => this.tcpIn(id, win, b), () => {});
      t.ack = (n) => {
        win.read += n;
        inbound.flush();
        if (!inbound.full()) socket.resume();
      };
      this.tcps.set(id, t);
      await new Promise((resolve, reject) => {
        socket.once('connect', resolve);
        socket.once('error', reject);
      });
    } catch (e) {
      console.log(`beam: connect ${host}:${port}: ${e.message}`);
      socket?.destroy();
      this.tcps.delete(id);
      // connect() of Cloudflare fails for a host behind Cloudflare, with the
      // error of any other failure: the addresses of the name tell them
      // apart. A host of Cloudflare goes through fetch() (specs/FetchPath.tla).
      // Only on Cloudflare: Deno and a web page have no such block.
      const cloudflare = (this.env.BEAM_HOST ?? 'cloudflare') === 'cloudflare';
      if (allowed && fetchPath && cloudflare && (port === 443 || port === 80) && await this.isCloudflare(host)) {
        console.log(`beam: connect ${host}:${port}: through fetch()`);
        return this.fetchPair(id, host, port, h);
      }
      this.event({ t: 'tcp_error', id, reason: 'econnrefused' });
      if (h) { h.sockets--; h.wake?.(); }
      return;
    }
    this.event({ t: 'tcp_open', id, ack: true, sent: true });
    await new Promise((resolve) => {
      socket.on('data', (b) => {
        inbound.push(new Uint8Array(b.buffer, b.byteOffset, b.byteLength), true);
        if (inbound.full()) socket.pause();
      });
      socket.on('error', () => {});
      socket.once('close', resolve);
    });
    this.tcpClosed(id);
    if (h) { h.sockets--; h.wake?.(); }
  }

  // The route of a connect (Route of specs/FetchPath.tla): true when it
  // goes to fetch() with no connect(). The host sees the port, not the
  // protocol:
  // - Port 80 is HTTP.
  // - Port 443 is HTTPS. It goes to fetch() only when the trust store of the
  //   VM holds the CA of wasm_host_fetch (a build with --cacerts), so that
  //   the program trusts the server of the VM (TlsOnlyWithTrust).
  // - Another port goes to fetch() only when a rule of BEAM_FETCH names it
  //   ("host:8080", "*:8080"): a protocol that is not HTTP (a database,
  //   SMTP) must not go to the server of the VM (TcpNeverFetch).
  // BEAM_FETCH has the rules of BEAM_CONNECT. A rule with no port ("host",
  // "*.domain", "*") gives ports 80 and 443. With no BEAM_FETCH: ports 80
  // and 443 of all hosts. An empty BEAM_FETCH: none.
  fetchFirst(host, port) {
    const list = this.env.BEAM_FETCH;
    if (port === 443 && !this.listeners.has('fetch-tls')) return false;
    if (list === undefined) return port === 80 || port === 443;
    return connectAllowed(list, host, port, port !== 80 && port !== 443);
  }

  // The name is a host of Cloudflare: one of its addresses is in the ranges
  // of Cloudflare. The addresses come from DNS over HTTPS (a fetch(), which
  // reaches Cloudflare), and stay 5 minutes.
  async isCloudflare(host) {
    if (ipBits(host)) return inRanges(host);
    const name = String(host).toLowerCase().replace(/\.$/, '');
    const now = Date.now(), seen = this.dns.get(name);
    if (seen && now - seen.at < 300000) return seen.addresses.some((a) => inRanges(a));
    const addresses = [];
    try {
      for (const type of ['A', 'AAAA']) {
        const r = await fetch(`https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(name)}&type=${type}`,
                              { headers: { accept: 'application/dns-json' } });
        const answer = r.ok ? (await r.json()).Answer ?? [] : [];
        for (const a of answer) if (a.type === 1 || a.type === 28) addresses.push(a.data);
      }
    } catch (e) {
      console.log(`beam: resolve ${name}: ${e.message}`);
    }
    // At most DNS_MAX names: a new name removes the oldest.
    this.dns.delete(name);
    if (this.dns.size >= DNS_MAX) this.dns.delete(this.dns.keys().next().value);
    this.dns.set(name, { at: now, addresses });
    return addresses.some((a) => inRanges(a));
  }

  // The fetch path: the socket id of the program and a connection of the
  // listener of wasm_host_fetch, as a pair in the host. The program sees
  // an open connection to host:port. The pair ends when one side closes.
  async fetchPair(id, host, port, h) {
    const conn = `x${this.nextId++}`;
    let done, pairEnd;
    const ended = new Promise((r) => { done = r; });
    const end = (other) => {
      if (!this.fetchConns.has(conn)) return;
      this.fetchConns.delete(conn);
      this.tcps.delete(id);
      this.tcps.delete(conn);
      // The fetches of this connection: no one reads their bodies now.
      for (const ac of this.fetches.values()) if (ac.conn === conn) ac.abort();
      pairEnd();
      this.event({ t: 'tcp_closed', id: other });
      done();
    };
    this.fetchConns.set(conn, { host, port, h });
    // A send of one socket ends when the other socket read the bytes
    // (tcp_read): so the window of the sender (tcp_sent) holds them.
    const toConn = relay((b) => this.event({ t: 'tcp_data', id: conn }, b));
    const toId = relay((b) => this.event({ t: 'tcp_data', id }, b));
    pairEnd = () => { toConn.end(); toId.end(); };
    // A shutdown of write of one socket: the other one gets the end of the
    // data (tcp_closed with half), after the data, and can still send.
    const half = (other) => this.event({ t: 'tcp_closed', id: other, half: true });
    this.tcps.set(id, { send: toConn.send, close: () => end(conn), shutdown: () => half(conn), ack: toId.read, h });
    this.tcps.set(conn, { send: toId.send, close: () => end(id), shutdown: () => half(id), ack: toConn.read, h });
    this.event({ t: 'tcp_open', id, ack: true, sent: true });
    this.event({ t: 'tcp_accept', id: this.listeners.get('fetch'), conn, host, port, ack: true, sent: true });
    await ended;
    if (h) { h.sockets--; h.wake?.(); }
  }

  // A port of the VM (Module.beamHost.spawn of jspi_lib.js): see openPort.
  // A plain Worker uses the bindings of the last request, and its I/O
  // starts in that request. The port counts as a socket of that request
  // (serve): so the request, and the jobs of the VM in it, stay until the
  // end of the port, also after the response.
  spawnPort(spec, events) {
    const enter = this.plain ? this.inRequest : null;
    return openPort(this.bindings ?? this.env, spec, events, {
      log: (s) => this.log(s),
      dead: () => !!this.dead,
      ports: this.ports,
      keep: (p) => {
        const h = this.plain ? this.handlers.at(-1) : null;
        if (!h) return;
        h.sockets++;
        p.finally(() => { h.sockets--; h.wake?.(); });
      },
      run: enter ? (f) => new Promise((resolve) => enter(() => resolve(f()))) : (f) => f(),
    });
  }

  // A request of wasm_host_fetch: fetch() of the URL of the host and the
  // port of the connect, and the response as fetch_head, fetch_data and
  // fetch_end (or fetch_error). fetch() gives the body decoded.
  async fetchRequest(msg, body, h) {
    const c = this.fetchConns.get(msg.conn);
    if (h) h.sockets++;
    this.fetchPending++;
    const ac = new AbortController();
    ac.conn = msg.conn;
    // ack: wasm_host_fetch tells the host what it read (fetch_read). The
    // body then goes while less than UPLOAD_WINDOW bytes are unread.
    ac.sent = 0;
    ac.read = 0;
    ac.signal.addEventListener('abort', () => ac.room?.());
    this.fetches.set(msg.id, ac);
    try {
      const url = c && fetchUrl(c.host, c.port, msg.tls, msg.path);
      if (!url) throw new Error(c ? 'the path is not a path of the host' : 'no connection');
      const headers = new Headers();
      for (const [k, v] of msg.headers ?? []) headers.append(k, v);
      const init = { method: msg.method, headers, redirect: 'manual', signal: ac.signal };
      if (!['GET', 'HEAD'].includes(msg.method)) init.body = body;
      const res = await fetch(url, init);
      const out = [...res.headers].filter(([k]) => k !== 'set-cookie');
      for (const v of res.headers.getSetCookie?.() ?? []) out.push(['set-cookie', v]);
      this.event({ t: 'fetch_head', id: msg.id, status: res.status, reason: res.statusText, headers: out });
      if (res.body) {
        // A BYOB read of FETCH_READ bytes: the default reader of workerd
        // gives pieces of 4 KB, and each piece is an event of the VM. A
        // body that is not a byte stream has only the default reader.
        let byob = null;
        try { byob = res.body.getReader({ mode: 'byob' }); } catch {}
        const reader = byob ?? res.body.getReader();
        for (;;) {
          const { done, value } = byob ? await byob.read(new Uint8Array(FETCH_READ)) : await reader.read();
          if (done) break;
          if (!value?.byteLength) continue;
          this.event({ t: 'fetch_data', id: msg.id }, value);
          ac.sent += value.byteLength;
          while (msg.ack && ac.sent - ac.read >= UPLOAD_WINDOW && !ac.signal.aborted) {
            await new Promise((resolve) => { ac.room = resolve; });
          }
          if (ac.signal.aborted) throw new Error('the fetch stopped');
        }
      }
      this.event({ t: 'fetch_end', id: msg.id });
    } catch (e) {
      this.event({ t: 'fetch_error', id: msg.id, message: String(e?.message ?? e) });
    } finally {
      this.fetches.delete(msg.id);
      this.fetchPending--;
      if (h) { h.sockets--; h.wake?.(); }
    }
  }

  // Data of a TCP socket: to Erlang (then true), or to its peer after a
  // splice.
  tcpData(id, bytes) {
    const t = this.tcps.get(id);
    const peer = t?.peer && this.tcps.get(t.peer);
    if (peer) this.run(() => peer.send(bytes), peer.h);
    else this.event({ t: 'tcp_data', id }, bytes);
    return !peer;
  }

  // Data of a peer for the socket id, with the window win of Inbound: the
  // bytes that go to Erlang count, and the bytes to a spliced peer do not
  // (no tcp_read comes for them).
  tcpIn(id, win, bytes) {
    if (this.tcpData(id, bytes)) win.sent += bytes.length;
  }

  // A send of the VM to the socket t. The host tells the VM how many bytes
  // the peer took (tcp_sent), after each ACK_BYTES: wasm_tcp holds a send
  // while SEND_WINDOW bytes wait in the host. A send that fails counts
  // too, because the socket then ends.
  tcpSend(id, t, body) {
    const done = () => {
      t.took = (t.took ?? 0) + body.length;
      if (t.took >= ACK_BYTES) {
        this.event({ t: 'tcp_sent', id, n: t.took });
        t.took = 0;
      }
    };
    let r;
    try {
      r = t.send(body);
    } finally {
      if (typeof r?.then !== 'function') done();
    }
    if (typeof r?.then === 'function') r.then(done, done);
  }

  // A shutdown of write of the socket t of the VM (tcp_shutdown): a
  // connect() socket ends its writes (end() of node:net closes the writer
  // of cloudflare:sockets), and a socket of the fetch path gives the end to
  // the other socket. A connection of bridge() ends its response, and the
  // rest of the request body still goes to the app (bridgeHalf).
  tcpShutdown(id, t) {
    if (t.shutdown) return t.shutdown();
    for (const c of this.conns) {
      if (c.id === id) return this.bridgeGuard(c, () => this.bridgeHalf(c));
    }
  }

  // The app ended its writes on the connection c of bridge(): the response
  // ends, as with the end of a body that has no length. The request body
  // still goes to the app; then the connection ends, as a client ends it
  // after the response. With no head of a response, or for a WebSocket,
  // it is the end of the connection (bridgeEnd). Before the end of a body
  // with chunks or a content-length, the response fails (bridgeCut).
  bridgeHalf(c) {
    if (!c.status || c.ws) return this.bridgeEnd(c);
    clearTimeout(c.timer);
    if (!this.bridgeCut(c)) c.writer?.close().catch(() => {});
    c.writer = null;
    const done = () => this.bridgeDone(c);
    if (c.upload) c.upload.then(done, done);
    else done();
  }

  // The end of a TCP socket: to Erlang, and the end of its peer too.
  tcpClosed(id) {
    const t = this.tcps.get(id);
    this.tcps.delete(id);
    this.event({ t: 'tcp_closed', id });
    const peer = t?.peer && this.tcps.get(t.peer);
    if (peer) {
      this.tcps.delete(t.peer);
      this.run(() => peer.close(), peer.h);
      this.event({ t: 'tcp_closed', id: t.peer });
    }
  }

  // A message of the VM (jspi_host_send). It runs in the thread of the VM:
  // an exception of the host must not stop that thread, so it goes to the
  // log.
  onsend(bytes) {
    try {
      this.onsendEvent(bytes);
    } catch (e) {
      this.log(`beam: the host failed on a message of the VM (${e?.message ?? e})`);
    }
  }

  onsendEvent(bytes) {
    const nl = bytes.indexOf(10);
    const msg = JSON.parse(new TextDecoder().decode(bytes.subarray(0, nl)));
    // bytes is a new array (jspi_host_send): the body is a view of it.
    const body = bytes.subarray(nl + 1);
    switch (msg.t) {
      case 'ready':
        this.onready();
        break;
      case 'boot_point':
        this.run(() => this.bootPoint());
        break;
      case 'tcp_connect': {
        const h = this.handlers.at(-1);
        this.run(() => this.tcpConnect(msg, h), h);
        break;
      }
      case 'sql': {
        const h = this.handlers.at(-1);
        this.run(() => this.sqlQuery(msg, body, h), h);
        break;
      }
      case 'wasm': {
        const h = this.handlers.at(-1);
        this.run(() => this.wasmRequest(msg, body, h), h);
        break;
      }
      case 'fetch': {
        const h = this.fetchConns.get(msg.conn)?.h ?? this.handlers.at(-1);
        this.run(() => this.fetchRequest(msg, body, h), h);
        break;
      }
      case 'fetch_cancel':
        this.fetches.get(msg.id)?.abort();
        break;
      // wasm_host_fetch read n bytes of the body of a fetch().
      case 'fetch_read': {
        const ac = this.fetches.get(msg.id);
        if (ac) { ac.read += msg.n; ac.room?.(); }
        break;
      }
      case 'tcp_send': {
        const t = this.tcps.get(msg.id);
        if (t) this.run(() => this.tcpSend(msg.id, t, body), t.h);
        break;
      }
      // wasm_tcp: the app read n bytes of a socket.
      case 'tcp_read': {
        this.tcps.get(msg.id)?.ack?.(msg.n, msg);
        break;
      }
      case 'tcp_close': {
        const t = this.tcps.get(msg.id);
        this.tcps.delete(msg.id);
        if (t) this.run(() => t.close(), t.h);
        break;
      }
      // gen_tcp:shutdown(S, write) of wasm_tcp: the peer gets the end of
      // the data, and the socket still reads.
      case 'tcp_shutdown': {
        const t = this.tcps.get(msg.id);
        if (t) this.run(() => this.tcpShutdown(msg.id, t), t.h);
        break;
      }
      // wasm_tcp:splice/2: the data of each socket goes to the other one,
      // no longer through Erlang.
      case 'tcp_splice': {
        const a = this.tcps.get(msg.a), b = this.tcps.get(msg.b);
        if (a && b) { a.peer = msg.b; b.peer = msg.a; }
        break;
      }
      // The listener of wasm_host_fetch: apart from the ports, so that no
      // WebSocket to /.tcp/PORT reaches it.
      case 'tcp_listen':
        if (msg.fetch) {
          this.listeners.set('fetch', msg.id);
          if (msg.tls) this.listeners.set('fetch-tls', msg.id);
          this.event({ t: 'tcp_listening', id: msg.id });
        } else if (this.listeners.has(msg.port)) {
          this.event({ t: 'tcp_error', id: msg.id, reason: 'eaddrinuse' });
        } else {
          this.listeners.set(msg.port, msg.id);
          this.event({ t: 'tcp_listening', id: msg.id });
          for (const r of this.waitListen.get(msg.port) ?? []) r();
          this.waitListen.delete(msg.port);
        }
        break;
      case 'tcp_unlisten':
        for (const [port, id] of this.listeners) if (id === msg.id) this.listeners.delete(port);
        break;
    }
  }
}

// The types of the static files, by extension.
const TYPES = {
  html: 'text/html; charset=utf-8', htm: 'text/html; charset=utf-8', txt: 'text/plain; charset=utf-8',
  css: 'text/css; charset=utf-8', js: 'text/javascript; charset=utf-8', mjs: 'text/javascript; charset=utf-8',
  json: 'application/json', map: 'application/json', webmanifest: 'application/manifest+json',
  xml: 'application/xml', wasm: 'application/wasm', pdf: 'application/pdf',
  svg: 'image/svg+xml', png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif',
  webp: 'image/webp', avif: 'image/avif', ico: 'image/vnd.microsoft.icon',
  woff: 'font/woff', woff2: 'font/woff2', ttf: 'font/ttf', otf: 'font/otf',
  mp4: 'video/mp4', webm: 'video/webm', mp3: 'audio/mpeg', ogg: 'audio/ogg',
};

// A GET or HEAD request for a static file of the release (statics of
// appFiles), as Plug.Static of Phoenix gives it: an ETag, and a cache of
// one year for a request with the parameter vsn. Else null: the VM
// answers.
export function staticResponse(statics, request) {
  if (request.method !== 'GET' && request.method !== 'HEAD') return null;
  const url = new URL(request.url);
  let path;
  try { path = decodeURIComponent(url.pathname); } catch { return null; }
  // Only PATH.gz (Phoenix digests give both, some packages only the
  // .gz file): its data, with no gzip.
  const plain = statics.get(path);
  const s = plain ?? statics.get(`${path}.gz`);
  if (!s) return null;
  const gz = !plain;
  // The size of the data of a stored gzip file: its last 4 bytes (ISIZE).
  const size = !gz ? s.size : s.deflated || s.data.length < 18 ? null
    : new DataView(s.data.buffer, s.data.byteOffset + s.data.length - 4, 4).getUint32(0, true);
  const etag = `"${s.crc.toString(16).padStart(8, '0')}${s.size.toString(16)}${gz ? '-gz' : ''}"`;
  const headers = {
    'content-type': TYPES[path.slice(path.lastIndexOf('.') + 1).toLowerCase()] ?? 'application/octet-stream',
    'cache-control': url.searchParams.has('vsn') ? 'public, max-age=31536000, immutable' : 'public',
    etag,
  };
  if (request.headers.get('if-none-match') === etag) return new Response(null, { status: 304, headers });
  if (size !== null) headers['content-length'] = String(size);
  if (request.method === 'HEAD') return new Response(null, { headers });
  let body = new Blob([s.data]).stream();
  if (s.deflated) body = body.pipeThrough(new DecompressionStream('deflate-raw'));
  if (gz) body = body.pipeThrough(new DecompressionStream('gzip'));
  return new Response(body, { headers });
}

// The result of a wait that passed its time limit.
const LATE = Symbol('late');

// The headers of the 101 of the app that the client does not get
// (bridgeUpgrade): the runtime makes the handshake and the connection of
// the WebSocket of the client, with its own compression.
const UPGRADE_OWN = new Set(['connection', 'upgrade', 'sec-websocket-accept', 'sec-websocket-extensions',
  'content-length', 'transfer-encoding']);

// A request body (bridgeUpload): the bytes that can be unread in the VM,
// the smallest part of an event (except the last one), and the size of a
// read in workerd and of the largest piece of a client chunk. A client chunk can be 2 KB (workerd), and each event
// costs a turn of the VM.
const UPLOAD_WINDOW = 256 * 1024;
const UPLOAD_PART = 32 * 1024;
const UPLOAD_LARGE = 1024 * 1024;
// The time that the head of a request waits for the first bytes of its
// body (bridgeUpload), in ms.
const HEAD_WAIT = 20;
const UPLOAD_READ = 64 * 1024;
// The size of a BYOB read of the body of a fetch response (fetchRequest).
const FETCH_READ = 64 * 1024;
// The rest of a request body that the app did not read (drain): the
// bytes that the host reads at most before the end of the response, the
// ms with no new bytes, and the ms in all.
const DRAIN_BYTES = 64 * 1024 * 1024;
const DRAIN_IDLE = 5000;
const DRAIN_TIME = 60000;

// The rest of a request body, read and dropped before the end of the
// response, when the app answered before it read the whole body (a 413,
// for example). workerd sends a response at the end of its body, and it
// cannot read the request body after that: it then closes the connection
// with the bytes that were not read. wrangler dev uses that connection
// again, and its next request fails with 500. The read stops after
// DRAIN_BYTES, after DRAIN_IDLE ms with no bytes, or after DRAIN_TIME ms,
// and then cancel() ends the body. read() gives { value, done }. limits
// replaces the bounds (a test).
export async function drain(read, cancel, { bytes = DRAIN_BYTES, idle = DRAIN_IDLE, time = DRAIN_TIME } = {}) {
  const end = Date.now() + time;
  let n = 0;
  try {
    for (;;) {
      const r = await within(read(), Math.min(idle, end - Date.now()));
      if (r === LATE) break;
      if (r.done) return;
      n += r.value?.byteLength ?? 0;
      if (n > bytes || Date.now() >= end) break;
    }
  } catch {
    return;  // the client stopped the body
  }
  try { await cancel(); } catch {}
}

// The promise p, or LATE after ms ms.
function within(p, ms) {
  let timer;
  const late = new Promise((r) => { timer = setTimeout(r, Math.max(ms, 0), LATE); });
  return Promise.race([p, late]).finally(() => clearTimeout(timer));
}

// The size bytes of the list parts, as one array.
function join(parts, size) {
  const b = new Uint8Array(size);
  let at = 0;
  for (const p of parts) { b.set(p, at); at += p.length; }
  return b;
}

// A chunk of a chunked body, and the end of the body.
const CHUNKS_END = new TextEncoder().encode('0\r\n\r\n');
function chunk(data) {
  const size = new TextEncoder().encode(`${data.length.toString(16)}\r\n`);
  const b = new Uint8Array(size.length + data.length + 2);
  b.set(size);
  b.set(data, size.length);
  b.set([13, 10], size.length + data.length);
  return b;
}

// A limit of a var: a number above 0, else the default (0: no limit).
// "0" turns a limit with a default off.
function limit(text, fallback) {
  if (text === undefined || text === null || text === '') return fallback;
  const n = Number(text);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

// The position of the bytes pat in b, or -1.
// The longest size line of a chunk of a response (with its extensions),
// and the longest head of a response.
const CHUNK_LINE = 4096;
const HEAD_MAX = 1 << 20;
// The longest wait of a request for a snapshot that the VM makes.
const SNAPSHOT_WAIT = 10000;
// Flow control of the sockets: wasm_tcp gives tcp_read after each
// ACK_BYTES that the app read, and the host gives tcp_sent after each
// ACK_BYTES that a peer took. Above SOCKET_QUEUE bytes from a peer that
// wait for the app (Inbound), a WebSocket closes.
const ACK_BYTES = 64 * 1024;
const SOCKET_QUEUE = 16 * 1024 * 1024;

// The names of the fetch path in the cache of isCloudflare.
const DNS_MAX = 1024;

// Bytes as text of one character for each byte (ISO-8859-1), and back.
function latin1(b) {
  let s = '';
  for (let i = 0; i < b.length; i += 8192) s += String.fromCharCode(...b.subarray(i, i + 8192));
  return s;
}
function latin1Bytes(s) {
  const b = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i);
  return b;
}

// The close code of a client for the app: 1005, 1006 and 1015 are not
// codes for the wire (RFC 6455).
function wireCode(code) {
  if (code === 1006 || code === 1015) return 1001;
  return code && code !== 1005 ? code : 1000;
}

// close(code) of a WebSocket, with a code that it takes (else 1000), and
// no exception for a socket that is closed already.
function closeSocket(ws, code) {
  try {
    ws.close(code === 1000 || (code >= 3000 && code <= 4999) || (code >= 1001 && code <= 1014 && ![1004, 1005, 1006].includes(code)) ? code : 1000);
  } catch {}
}

// Bytes in pieces (views of the arrays that came, no copy), joined only
// when a reader needs them in one array (peek, take).
// The bytes from a peer to a socket of the VM, with flow control: they go
// while less than UPLOAD_WINDOW bytes are unread in the VM (win.sent, and
// win.read from tcp_read), and the others wait here. Above SOCKET_QUEUE
// bytes that wait, over() runs once, and the next bytes are dropped. A
// forced push always waits (the end of a WebSocket).
export class Inbound {
  constructor(win, send, over) {
    Object.assign(this, { win, send, over, queue: [], queued: 0, overflow: false });
  }

  full() {
    return this.win.sent - this.win.read >= UPLOAD_WINDOW;
  }

  push(bytes, force = false) {
    if (!this.queue.length && !this.full()) return this.send(bytes);
    if (!force && (this.overflow || this.queued + bytes.length > SOCKET_QUEUE)) {
      if (!this.overflow) {
        this.overflow = true;
        this.over();
      }
      return;
    }
    this.queue.push(bytes);
    this.queued += bytes.length;
  }

  // After a tcp_read: the bytes that wait, while the window has room.
  flush() {
    while (this.queue.length && !this.full()) {
      const bytes = this.queue.shift();
      this.queued -= bytes.length;
      this.send(bytes);
    }
  }
}

// The bytes from one socket of the VM to another one in the host (the
// fetch path): deliver gives them to the other socket. A send ends when
// the other socket read them (read, from its tcp_read), so the window of
// the sender (tcp_sent) holds the bytes that wait. end() ends each send.
export function relay(deliver) {
  let sent = 0, read = 0;
  const waits = [];
  return {
    send: (b) => {
      deliver(b);
      sent += b.length;
      if (read >= sent) return undefined;
      const mark = sent;
      return new Promise((resolve) => waits.push([mark, resolve]));
    },
    read: (n) => {
      read += n;
      while (waits.length && waits[0][0] <= read) waits.shift()[1]();
    },
    end: () => { for (const [, resolve] of waits.splice(0)) resolve(); },
  };
}

export class Pieces {
  constructor() { this.list = []; this.size = 0; }
  push(b) {
    if (!b.length) return;
    this.list.push(b);
    this.size += b.length;
  }
  // The first n bytes in one array. A view when the first piece has them;
  // else a join, which then is the first piece.
  peek(n) {
    if (!this.list.length || this.list[0].length >= n) return (this.list[0] ?? new Uint8Array(0)).subarray(0, n);
    const out = new Uint8Array(n);
    let at = 0;
    for (const p of this.list) {
      if (at >= n) break;
      const k = Math.min(p.length, n - at);
      out.set(p.subarray(0, k), at);
      at += k;
    }
    this.drop(n);
    this.list.unshift(out);
    this.size += n;
    return out;
  }
  drop(n) {
    this.size -= n;
    while (n > 0) {
      const p = this.list[0];
      if (p.length <= n) { this.list.shift(); n -= p.length; }
      else { this.list[0] = p.subarray(n); n = 0; }
    }
  }
  take(n) {
    const b = this.peek(n);
    this.drop(n);
    return b;
  }
  // At most max bytes of the first piece (a view).
  next(max) {
    const b = this.list[0].subarray(0, Math.min(max, this.list[0].length));
    this.drop(b.length);
    return b;
  }
}

function indexOf(b, pat) {
  outer: for (let i = 0; i + pat.length <= b.length; i++) {
    for (let j = 0; j < pat.length; j++) if (b[i + j] !== pat[j]) continue outer;
    return i;
  }
  return -1;
}

// A WebSocket frame from a client (masked, as RFC 6455 asks).
function frame(op, data) {
  const n = data.length;
  const ext = n < 126 ? 0 : n < 65536 ? 2 : 8;
  const f = new Uint8Array(2 + ext + 4 + n);
  f[0] = 128 | op;
  if (ext === 0) f[1] = 128 | n;
  else if (ext === 2) { f[1] = 128 | 126; f[2] = n >> 8; f[3] = n & 255; }
  else { f[1] = 128 | 127; new DataView(f.buffer).setBigUint64(2, BigInt(n)); }
  const mask = crypto.getRandomValues(new Uint8Array(4));
  f.set(mask, 2 + ext);
  for (let i = 0; i < n; i++) f[2 + ext + 4 + i] = data[i] ^ mask[i & 3];
  return f;
}
