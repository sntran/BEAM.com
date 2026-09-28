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
// wasm_host_server.erl; outgoing wasm_tcp sockets use connect().
//
// "beam.com INPUT -o DIR --target wasm32" writes this file into DIR, with
// the runtime (beam.mjs, beam.wasm) and the release (release.bin).
import { connect } from 'cloudflare:sockets';
import createBeam from './beam.mjs';
import wasm from './beam.wasm';

async function loadRelease(env) {
  if (env.APP) return (await env.APP.fetch('http://app/release.bin')).arrayBuffer();
  if (env.RELEASE_URL) return (await fetch(env.RELEASE_URL)).arrayBuffer();
  return (await import('./release.bin')).default;
}

// release.bin: "BEAMFS1\n", then (length, path, length, data) for each file.
function unpack(FS, bytes) {
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
function releaseMeta(bytes) {
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

// The memory and the open files of a VM whose threads all returned
// (erts_wasm_hibernate), as snapshot.bin. The files that the boot wrote
// are the ones that are not views of release.bin (unpack: canOwn).
function capture(m, release, listeners, bootPoint = false) {
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
      if (p === '/dev' || p === '/proc') continue;
      const node = m.FS.lookupPath(p).node;
      if (m.FS.isDir(node.mode)) walk(p);
      else if (m.FS.isFile(node.mode) && node.contents?.buffer !== release) {
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
  const head = new TextEncoder().encode(JSON.stringify({
    size: heap.length, pages, fs: { files, streams }, listeners: Object.fromEntries(listeners),
    boot_point: bootPoint,
  }));
  const out = new Uint8Array(12 + head.length + pages.length * PAGE);
  out.set(new TextEncoder().encode('BEAMSNP1'));
  new DataView(out.buffer).setUint32(8, head.length);
  out.set(head, 12);
  pages.forEach((p, i) => out.set(heap.subarray(p * PAGE, (p + 1) * PAGE), 12 + head.length + i * PAGE));
  return out;
}

// snapshot.bin (optional, beside release.bin): the memory of a booted VM
// whose threads all returned to the host (erts_wasm_hibernate), and the
// files and pipes of that moment. "BEAMSNP1", a 32-bit length and a JSON
// header, then the 64 KiB pages of the header (the others are zero).
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

function parseSnapshot(bytes) {
  const b = new Uint8Array(bytes);
  if (new TextDecoder().decode(b.subarray(0, 8)) !== 'BEAMSNP1') throw new Error('snapshot.bin: not a snapshot');
  const len = new DataView(b.buffer, b.byteOffset).getUint32(8);
  const head = JSON.parse(new TextDecoder().decode(b.subarray(12, 12 + len)));
  return { ...head, pagesData: b.subarray(12 + len) };
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
      const v = vm = new Vm(env);
      v.ready.catch(() => { if (vm === v) vm = undefined; });
    }
    return vm.fetch(request, ctx);
  },
};

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
export class Vm {
  // release and snapshot: the bytes of release.bin and snapshot.bin, for a
  // VM that the global scope of a Worker restores (global.js).
  // id: the id of the Durable Object (with sql).
  constructor(env, { plain = true, sql = null, id = null, release = null, snapshot = null } = {}) {
    this.given = release && { release, snapshot };
    this.handles = new Map();  // id -> setTimeout handle: timers after adopt()
    this.id = id;
    this.sql = sql;            // ctx.storage.sql of a Durable Object (Ecto SQLite)
    this.tcps = new Map();     // id -> {send, close, h}: a TCP socket of wasm_tcp
    this.listeners = new Map(); // port -> the id of its listener (wasm_tcp)
    this.nextId = 1;
    this.plain = plain;
    this.handlers = [];        // the open requests (plain)
    this.jobs = [];            // the wake-ups of the threads (plain)
    this.timers = new Map();   // id -> {at, f}: the timers of the threads (plain)
    this.nextTimer = 1;
    this.env = env;
    this.waitListen = new Map();  // port -> the resolve functions of listening()
    this.ready = this.boot(env);
  }

  async boot(env) {
    const t0 = Date.now();
    const [release, bundled] = this.given
      ? [this.given.release, this.given.snapshot]
      : await Promise.all([loadRelease(env), loadSnapshot(env)]);
    // A snapshot of the build (snapshot.bin), else one that a Worker made
    // (BEAM_SNAPSHOT = "off" turns them off).
    let snapBytes = bundled, key = null;
    if (!snapBytes && env.BEAM_SNAPSHOT !== 'off') {
      // A Durable Object with Ecto SQLite (sql of .release.json): the
      // snapshot is made at the boot point (wasm_host_server), before the
      // program starts and runs its migrations. So all the objects (the
      // tenants) share it, and each one runs the program on its own storage.
      const meta = releaseMeta(release);
      const atBoot = !this.plain && this.sql && (meta.sql ?? true);
      key = await snapshotKey(env, meta, this.plain ? 'worker' : atBoot ? 'durable boot-point' : 'durable');
      snapBytes = await snapshots.get(env, key);
      if (!snapBytes && !snapshots.unavailable && atBoot) this.bootKey = key;
    }
    const snap = snapBytes && parseSnapshot(snapBytes);
    this.bootPointSnap = !!snap?.boot_point;
    // No snapshot yet: this VM makes it, before its first request.
    this.makeKey = !snap && !snapshots.unavailable && !this.bootKey && key;
    this.release = release;
    const t1 = Date.now();
    return new Promise((resolve, reject) => {
      const snapKB = snapBytes ? snapBytes.byteLength >> 10 : 0;
      this.onready = () => { console.log(`beam: ready in ${Date.now() - t0} ms (release ${release.byteLength >> 10} KB${snap ? `, snapshot ${snapKB} KB` : ''} in ${t1 - t0} ms), ${this.memory()}`); resolve(); };
      createBeam({
        noInitialRun: !!snap,
        onRuntimeInitialized: snap ? () => {
          try {
            this.listeners = new Map(Object.entries(snap.listeners ?? {}).map(([p, id]) => [Number(p), id]));
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
            // The copy is in the memory of the VM now: free the buffer (an
            // isolate has 128 MB).
            snap.pagesData = null;
            this.onready();
          } catch (e) { reject(e); }
        } : undefined,
        // The boot arguments are set in preRun, after the release is unpacked.
        arguments: [],
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
          // The files that the boot of the snapshot wrote.
          for (const [p, b64] of Object.entries(snap?.fs.files ?? {})) {
            m.FS.mkdirTree(p.slice(0, p.lastIndexOf('/')));
            m.FS.writeFile(p, Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)));
          }
          // -c false (no time correction) for a snapshot: the monotonic time
          // then follows the system time, which goes on after a restore (the
          // OS monotonic time of a new instance starts again at 0).
          m.arguments.push('-S', '1', '-SDcpu', '1', '-A', '0', ...(this.makeKey || this.bootKey ? ['-c', 'false'] : []), '--',
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
          const vars = Object.fromEntries(Object.entries(env).filter(([, v]) => typeof v === 'string'));
          // The environment that "go" gives to a VM of a boot point snapshot.
          this.envVars = { ...relEnv, ...vars };
          Object.assign(m.ENV, {
            ROOTDIR: '/app', BINDIR: '/app/bin', EMU: 'beam', PROGNAME: 'erl', HOME: '/',
            RELEASE_ROOT: '/app', RELEASE_NAME: name, RELEASE_VSN: vsn, RELEASE_MODE: 'interactive',
            RELEASE_TMP: '/app/tmp', RELEASE_SYS_CONFIG: '/app/tmp/run.runtime', RELEASE_PROG: name,
            WASM_HOST: '1',
          }, relEnv, vars, this.bootKey ? { WASM_HOST_BOOT_POINT: 'wait' } : {});
          m.beamHost.onsend = (bytes) => this.onsend(bytes);
        }],
        print: (s) => console.log(s),
        printErr: (s) => console.log(s),
        // Workers compile no WebAssembly at run time: use the imported module.
        instantiateWasm: (imports, done) => {
          WebAssembly.instantiate(wasm, imports).then((instance) => { this.exports = instance.exports; done(instance); });
          return {};
        },
        onExit: (code) => reject(new Error(`beam exited with status ${code}`)),
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
    if (bytes === 'busy') this.makeKey = key;
    else if (bytes) this.store(key, bytes);
  }

  // The boot point (wasm_host_server): the snapshot of a VM that loaded the
  // modules of its boot and did not start the program; then the boot goes
  // on (go).
  async bootPoint() {
    const key = this.bootKey;
    this.bootKey = null;
    if (key) {
      const bytes = await this.snapshot(true);
      if (bytes && bytes !== 'busy') this.store(key, bytes);
      else console.log(`beam: no snapshot at the boot point (${bytes})`);
    }
    this.go();
  }

  go() {
    this.event({ t: 'go' }, new TextEncoder().encode(JSON.stringify(this.envVars ?? {})));
  }

  store(key, bytes) {
    console.log(`beam: snapshot ${bytes.length >> 10} KB (${key.slice(0, 12)})`);
    const put = snapshots.put(this.env, key, bytes).catch((e) => console.log(`beam: snapshot not stored: ${e.message}`));
    this.waitUntil?.(put);
  }

  // All the threads return (erts_wasm_hibernate), the memory is copied, and
  // the threads go on: about 1 ms of the VM, and the time of the copy.
  // 'busy': not a quiet moment (I/O of the host); null: no snapshot.
  async snapshot(bootPoint) {
    const x = this.exports;
    const tick = () => new Promise((r) => setTimeout(r, 1));
    const busy = () => this.sqlPending > 0 || this.tcps.size > 0;
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
      return capture(this.beam, this.release, this.listeners, bootPoint);
    } finally {
      x.erts_wasm_resume();
    }
  }

  // A VM that the global scope restored (plain: its jobs ran between
  // microtasks) becomes the VM of a Durable Object: its jobs run on a
  // MessageChannel, and its timers on setTimeout (durable-global.js).
  adopt({ sql = null, id = null } = {}) {
    this.sql = sql;
    this.id = id;
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

  memory() {
    return `memory ${this.beam.HEAPU8.length >> 20} MB`;
  }

  event(header, body) {
    const h = new TextEncoder().encode(JSON.stringify(header) + '\n');
    if (!body || !body.byteLength) return this.beam.beamHost.push(h);
    const b = new Uint8Array(h.length + body.byteLength);
    b.set(h);
    b.set(new Uint8Array(body), h.length);
    this.beam.beamHost.push(b);
  }

  // ctx: the context of a request to a plain Worker (none in a Durable Object).
  async fetch(request, ctx) {
    if (ctx) this.waitUntil = (p) => ctx.waitUntil(p);
    let finished = () => {};
    const h = this.plain ? this.serve(ctx, new Promise((r) => { finished = r; })) : undefined;
    try {
      return await this.request(request, h, finished);
    } catch (e) {
      finished();
      throw e;
    }
  }

  async request(request, h, finished) {
    await this.ready;
    if (this.resume) {
      const f = this.resume;
      this.resume = null;
      f();
    }
    if (this.makeKey) await this.makeSnapshot();
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

  // A listener on port, once there is one.
  listening(port) {
    if (this.listeners.has(port)) return Promise.resolve();
    return new Promise((r) => this.waitListen.set(port, [...(this.waitListen.get(port) ?? []), r]));
  }

  // The request as a TCP connection to the HTTP server of the
  // app on PORT. Bandit does the HTTP; here only the bytes are framed.
  async bridge(request, url, upgrade, h, finished) {
    const port = Number(this.env.PORT ?? 4000);
    await this.listening(port);
    const id = `b${this.nextId++}`;
    const headers = new Headers(request.headers);
    headers.set('host', url.host);
    headers.delete('transfer-encoding');
    headers.delete('sec-websocket-extensions');  // no compression: frames as they are
    // The Workers runtime compresses the response for each client: the app
    // does not (the edge adds Accept-Encoding to the requests).
    headers.delete('accept-encoding');
    if (upgrade) {
      headers.set('connection', 'Upgrade');
      headers.set('sec-websocket-key', btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16)))));
      headers.set('sec-websocket-version', '13');
    } else {
      headers.set('connection', 'close');
    }
    const body = request.method === 'GET' || request.method === 'HEAD' || upgrade
      ? new Uint8Array(0) : new Uint8Array(await request.arrayBuffer());
    if (body.length || !['GET', 'HEAD'].includes(request.method)) headers.set('content-length', String(body.length));
    let head = `${request.method} ${url.pathname}${url.search} HTTP/1.1\r\n`;
    for (const [k, v] of headers) head += `${k}: ${v}\r\n`;
    head = new TextEncoder().encode(head + '\r\n');
    const bytes = new Uint8Array(head.length + body.length);
    bytes.set(head);
    bytes.set(body, head.length);
    return new Promise((resolve) => {
      const c = { id, buf: new Uint8Array(0), resolve, finished, upgrade, head: request.method === 'HEAD', h };
      if (h) h.sockets++;
      this.tcps.set(id, { send: (b) => this.bridgeData(c, b), close: () => this.bridgeEnd(c), h });
      this.event({ t: 'tcp_accept', id: this.listeners.get(port), conn: id, host: request.headers.get('cf-connecting-ip') ?? '0.0.0.0', port: 0 });
      this.event({ t: 'tcp_data', id }, bytes);
    });
  }

  // Bytes from the HTTP server of the app to the connection c of bridge().
  bridgeData(c, data) {
    const b = new Uint8Array(c.buf.length + data.length);
    b.set(c.buf);
    b.set(data, c.buf.length);
    c.buf = b;
    if (!c.status) {
      const end = indexOf(c.buf, [13, 10, 13, 10]);
      if (end < 0) return;
      const lines = new TextDecoder().decode(c.buf.subarray(0, end)).split('\r\n');
      c.status = Number(lines[0].split(' ')[1]);
      const headers = new Headers();
      for (const l of lines.slice(1)) {
        const i = l.indexOf(':');
        headers.append(l.slice(0, i).trim(), l.slice(i + 1).trim());
      }
      c.buf = c.buf.slice(end + 4);
      if (c.status === 101 && c.upgrade) return this.bridgeUpgrade(c);
      c.length = headers.has('content-length') ? Number(headers.get('content-length')) : null;
      c.chunked = /chunked/i.test(headers.get('transfer-encoding') ?? '');
      headers.delete('transfer-encoding');
      headers.delete('connection');
      if (c.head || c.status === 204 || c.status === 304) c.length = 0;
      const { readable, writable } = new TransformStream();
      c.writer = writable.getWriter();
      // The app compressed the body (Bandit: gzip, deflate): the runtime
      // must send it as it is, not compress it again.
      const encodeBody = headers.has('content-encoding') ? 'manual' : 'automatic';
      c.resolve(new Response(c.length === 0 ? null : readable, { status: c.status, headers, encodeBody }));
      c.finished();
    }
    if (c.ws) return this.bridgeFrames(c);
    this.bridgeBody(c);
  }

  // The body of a response: by content-length, chunked, or until the end.
  bridgeBody(c) {
    if (c.done) return;
    if (c.chunked) {
      for (;;) {
        const nl = indexOf(c.buf, [13, 10]);
        if (nl < 0) return;
        const size = parseInt(new TextDecoder().decode(c.buf.subarray(0, nl)), 16);
        if (size === 0) return this.bridgeDone(c);
        if (c.buf.length < nl + 2 + size + 2) return;
        c.writer.write(c.buf.slice(nl + 2, nl + 2 + size));
        c.buf = c.buf.slice(nl + 2 + size + 2);
      }
    }
    if (c.buf.length) {
      const part = c.length === null ? c.buf : c.buf.subarray(0, c.length);
      if (part.length) c.writer.write(part.slice());
      if (c.length !== null) c.length -= part.length;
      c.buf = new Uint8Array(0);
    }
    if (c.length === 0) this.bridgeDone(c);
  }

  bridgeDone(c) {
    if (c.done) return;
    c.done = true;
    c.writer?.close().catch(() => {});
    this.tcps.delete(c.id);
    this.event({ t: 'tcp_closed', id: c.id });
    this.bridgeRelease(c);
  }

  // The request of c can end (once).
  bridgeRelease(c) {
    if (c.released) return;
    c.released = true;
    if (c.h) { c.h.sockets--; c.h.wake?.(); }
  }

  // The app closed the connection.
  bridgeEnd(c) {
    this.tcps.delete(c.id);
    if (!c.status) {
      c.resolve(new Response('bad gateway\n', { status: 502 }));
      c.finished();
    }
    if (c.ws) { try { c.ws.close(); } catch {} this.bridgeRelease(c); }
    else this.bridgeDone(c);
  }

  // A WebSocket: the client end to the browser, frames to the app.
  bridgeUpgrade(c) {
    const [client, server] = Object.values(new WebSocketPair());
    server.accept();
    server.binaryType = 'arraybuffer';
    c.ws = server;
    c.frames = [];  // the parts of a message in fragments
    server.addEventListener('message', (e) => {
      const text = typeof e.data === 'string';
      this.event({ t: 'tcp_data', id: c.id }, frame(text ? 1 : 2, text ? new TextEncoder().encode(e.data) : new Uint8Array(e.data)));
    });
    server.addEventListener('close', (e) => {
      const code = e.code && e.code !== 1005 ? e.code : 1000;
      this.event({ t: 'tcp_data', id: c.id }, frame(8, new Uint8Array([code >> 8, code & 255])));
    });
    c.resolve(new Response(null, { status: 101, webSocket: client }));
    c.finished();
    this.bridgeFrames(c);
  }

  // WebSocket frames from the app (not masked) to messages for the client.
  bridgeFrames(c) {
    for (;;) {
      const b = c.buf;
      if (b.length < 2) return;
      let len = b[1] & 127, at = 2;
      if (len === 126) { if (b.length < 4) return; len = (b[2] << 8) | b[3]; at = 4; }
      else if (len === 127) { if (b.length < 10) return; len = Number(new DataView(b.buffer, b.byteOffset).getBigUint64(2)); at = 10; }
      if (b.length < at + len) return;
      const fin = b[0] & 128, op = b[0] & 15, data = b.slice(at, at + len);
      c.buf = b.slice(at + len);
      if (op === 9) { this.event({ t: 'tcp_data', id: c.id }, frame(10, data)); continue; }
      if (op === 10) continue;
      if (op === 8) { c.ws.close(len >= 2 ? (data[0] << 8) | data[1] : 1000); continue; }
      if (op !== 0) c.op = op;
      c.frames.push(data);
      if (!fin) continue;
      const all = new Uint8Array(c.frames.reduce((n, f) => n + f.length, 0));
      let i = 0;
      for (const f of c.frames) { all.set(f, i); i += f.length; }
      c.frames = [];
      c.ws.send(c.op === 1 ? new TextDecoder().decode(all) : all);
    }
  }

  // A connection to a listener of wasm_tcp: a WebSocket to /.tcp/PORT. In a
  // plain Worker it belongs to the handler h of its request.
  tcpAccept(port, request, h, finished) {
    const listener = this.listeners.get(port);
    finished();
    if (!listener) return new Response(`no listener on ${port}\n`, { status: 404 });
    const id = `w${this.nextId++}`;
    const [client, server] = Object.values(new WebSocketPair());
    server.accept();
    server.binaryType = 'arraybuffer';  // (the default can be Blob)
    if (h) h.sockets++;
    this.tcps.set(id, { send: (b) => server.send(b), close: () => server.close(), h });
    this.event({ t: 'tcp_accept', id: listener, conn: id, host: request.headers.get('cf-connecting-ip') ?? '0.0.0.0', port: 0 });
    server.addEventListener('message', (e) => {
      this.tcpData(id, typeof e.data === 'string' ? new TextEncoder().encode(e.data) : e.data);
    });
    server.addEventListener('close', () => {
      this.tcpClosed(id);
      if (h) { h.sockets--; h.wake?.(); }
    });
    return new Response(null, { status: 101, webSocket: client });
  }

  // A TCP socket of wasm_tcp: connect() of cloudflare:sockets. In a plain
  // Worker it belongs to the handler h, and closes with that request.
  async tcpConnect({ id, host, port }, h) {
    let socket;
    if (h) h.sockets++;
    try {
      socket = connect({ hostname: host, port });
      const writer = socket.writable.getWriter();
      this.tcps.set(id, { send: (b) => writer.write(b), close: () => socket.close().catch(() => {}), h });
      await socket.opened;
    } catch (e) {
      console.log(`beam: connect ${host}:${port}: ${e.message}`);
      this.tcps.delete(id);
      this.event({ t: 'tcp_error', id, reason: 'econnrefused' });
      if (h) { h.sockets--; h.wake?.(); }
      return;
    }
    this.event({ t: 'tcp_open', id });
    try {
      const reader = socket.readable.getReader();
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        this.tcpData(id, value);
      }
    } catch (e) {}
    this.tcpClosed(id);
    if (h) { h.sockets--; h.wake?.(); }
  }

  // Data of a TCP socket: to Erlang, or to its peer after a splice.
  tcpData(id, bytes) {
    const t = this.tcps.get(id);
    const peer = t?.peer && this.tcps.get(t.peer);
    if (peer) this.run(() => peer.send(bytes), peer.h);
    else this.event({ t: 'tcp_data', id }, bytes);
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

  onsend(bytes) {
    const nl = bytes.indexOf(10);
    const msg = JSON.parse(new TextDecoder().decode(bytes.subarray(0, nl)));
    const body = bytes.slice(nl + 1);
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
      case 'tcp_send': {
        const t = this.tcps.get(msg.id);
        if (t) this.run(() => t.send(body), t.h);
        break;
      }
      case 'tcp_close': {
        const t = this.tcps.get(msg.id);
        this.tcps.delete(msg.id);
        if (t) this.run(() => t.close(), t.h);
        break;
      }
      // wasm_tcp:splice/2: the data of each socket goes to the other one,
      // no longer through Erlang.
      case 'tcp_splice': {
        const a = this.tcps.get(msg.a), b = this.tcps.get(msg.b);
        if (a && b) { a.peer = msg.b; b.peer = msg.a; }
        break;
      }
      case 'tcp_listen':
        if (this.listeners.has(msg.port)) {
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

// The position of the bytes pat in b, or -1.
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
