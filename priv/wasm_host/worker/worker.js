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
function capture(m, release, listeners, bootPoint = false, skip = () => false) {
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

function parseSnapshot(bytes) {
  const b = new Uint8Array(bytes);
  if (new TextDecoder().decode(b.subarray(0, 8)) !== 'BEAMSNP1') throw new Error('snapshot.bin: not a snapshot');
  const len = new DataView(b.buffer, b.byteOffset).getUint32(8);
  const head = JSON.parse(new TextDecoder().decode(b.subarray(12, 12 + len)));
  return { ...head, pagesData: b.subarray(12 + len) };
}

// BEAM_CONNECT: the hosts that the VM can connect to, separated by commas:
// "host", "host:port", or "*.domain" (the subdomains of domain). The host
// resolves a name, so the VM cannot reach another address through it.
// With no BEAM_CONNECT, the VM can connect to all hosts.
function connectAllowed(list, host, port) {
  if (list === undefined) return true;
  const name = String(host).toLowerCase().replace(/\.$/, '');
  return list.split(',').map((r) => r.trim().toLowerCase()).filter(Boolean).some((rule) => {
    const i = rule.lastIndexOf(':');
    const [pattern, p] = i > 0 && !rule.includes(']') ? [rule.slice(0, i), rule.slice(i + 1)] : [rule, undefined];
    if (p !== undefined && Number(p) !== port) return false;
    return pattern.startsWith('*.') ? name.endsWith(pattern.slice(1)) : name === pattern;
  });
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

class Persist {
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
      this.flush ??= setTimeout(() => {
        this.flush = null;
        for (const p of [...this.dirty]) this.save(FS, p);
      }, 1000);
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
    }
    return vm.fetch(request, ctx);
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
  constructor(env, { plain = true, sql = null, id = null, release = null, snapshot = null, vars = {}, files = null,
                     secrets = null, host = null } = {}) {
    this.vars = vars;
    this.secrets = secrets;
    this.host = host;
    this.hostFiles = files && new HostFiles(files, { debug: env.BEAM_SQLITE_DEBUG === '1' });
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
    await this.autoVars(env, releaseMeta(release));
    // A snapshot of the build (snapshot.bin), else one that a Worker made
    // (BEAM_SNAPSHOT = "off" turns them off).
    let snapBytes = bundled, key = null;
    if (!snapBytes && env.BEAM_SNAPSHOT !== 'off') {
      // A Durable Object with Ecto SQLite (sql of .release.json): the
      // snapshot is made at the boot point (wasm_host_server), before the
      // program starts and runs its migrations. So all the objects (the
      // tenants) share it, and each one runs the program on its own storage.
      // Tenants (BEAM_TENANTS) share the snapshot too, so it is made at the
      // boot point, before the program has the state of one tenant.
      const meta = releaseMeta(release);
      const atBoot = !this.plain && (this.sql || this.hostFiles)
        && ((meta.sql ?? true) || !!env.BEAM_PERSIST || !!env.BEAM_TENANTS || ownVars > 0);
      key = await snapshotKey(env, meta, this.plain ? 'worker' : atBoot ? 'durable boot-point' : 'durable');
      snapBytes = await snapshots.get(env, key);
      if (!snapBytes && !snapshots.unavailable && atBoot) this.bootKey = key;
    }
    const snap = snapBytes && parseSnapshot(snapBytes);
    const nifs = await nifModules();
    // restored: this VM comes from a snapshot (the page shows it).
    this.restored = !!snap;
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
          m.arguments.push('-S', '1', '-SDcpu', '1', '-A', '0', ...flags, ...(this.makeKey || this.bootKey ? ['-c', 'false'] : []), '--',
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
        }],
        print: (s) => console.log(s),
        printErr: (s) => console.log(s),
        nifModule: (file) => nifModule(nifs, file),
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
      if (bytes && bytes !== 'busy') this.store(key, bytes);
      else console.log(`beam: no snapshot at the boot point (${bytes})`);
    }
    this.go();
  }

  go() {
    this.event({ t: 'go' }, new TextEncoder().encode(JSON.stringify({ ...this.envVars, WASM_HOST_SQL: this.hostSql() })));
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
      return capture(this.beam, this.release, this.listeners, bootPoint, (p) => !!this.persist?.under(p));
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
    const statics = await this.statics;
    const file = statics && staticResponse(statics, request);
    if (file) {
      finished();
      return file;
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
    if (this.snapping) await this.snapping;
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
  // until the answer, as a D1 call does.
  async wasmRequest(msg, body, h) {
    if (h) h.sockets++;
    let reply;
    try {
      this.wasm ??= new WasmHost();
      reply = await this.wasm.op(msg.op, JSON.parse(new TextDecoder().decode(body)));
    } catch (e) {
      reply = { error: String(e?.message ?? e) };
    } finally {
      if (h) { h.sockets--; h.wake?.(); }
    }
    this.event({ t: 'wasm_reply', id: msg.id }, new TextEncoder().encode(JSON.stringify(reply)));
  }

  // A listener on port, once there is one.
  listening(port) {
    if (this.listeners.has(port)) return Promise.resolve();
    return new Promise((r) => this.waitListen.set(port, [...(this.waitListen.get(port) ?? []), r]));
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
  async bridge(request, url, upgrade, h, finished) {
    const port = Number(this.env.PORT ?? 4000);
    await this.listening(port);
    const id = `b${this.nextId++}`;
    const headers = new Headers(request.headers);
    headers.set('host', url.host);
    // The scheme of the client: the app gets a TCP connection with no TLS,
    // and Plug.SSL (force_ssl of Phoenix) reads x-forwarded-proto, as on
    // Deno and in a web page. The value of the Worker replaces the value
    // that a client sends.
    headers.set('x-forwarded-proto', url.protocol.slice(0, -1));
    const origin = this.appOrigin(headers.get('origin'), url);
    if (origin) headers.set('origin', origin);
    headers.delete('transfer-encoding');
    headers.delete('sec-websocket-extensions');  // no compression: frames as they are
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
      const c = { id, buf: new Uint8Array(0), resolve, finished, upgrade, head: request.method === 'HEAD', h, origin: request.headers.get('origin'), path: url.pathname };
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
      if (c.upgrade && c.status === 403) {
        console.log(`beam: the app refused the WebSocket of ${c.path} (403) from the origin ${c.origin}. ` +
          `A Phoenix app compares the Origin with the host of its config (PHX_HOST=${this.env.PHX_HOST ?? this.vars.PHX_HOST ?? ''}): see check_origin.`);
      }
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

  // A TCP socket of wasm_tcp: net.connect() of node:net. In a plain
  // Worker it belongs to the handler h, and closes with that request.
  async tcpConnect({ id, host, port }, h) {
    let socket;
    if (h) h.sockets++;
    try {
      if (!connectAllowed(this.env.BEAM_CONNECT, host, port)) throw new Error('not in BEAM_CONNECT');
      socket = net.connect({ host, port });
      // A send resolves when the bytes are written; a close sends the
      // bytes that wait, and then ends the socket.
      this.tcps.set(id, {
        send: (b) => new Promise((resolve) => socket.write(b, () => resolve())),
        close: () => socket.end(() => socket.destroy()),
        h,
      });
      await new Promise((resolve, reject) => {
        socket.once('connect', resolve);
        socket.once('error', reject);
      });
    } catch (e) {
      console.log(`beam: connect ${host}:${port}: ${e.message}`);
      socket?.destroy();
      this.tcps.delete(id);
      this.event({ t: 'tcp_error', id, reason: 'econnrefused' });
      if (h) { h.sockets--; h.wake?.(); }
      return;
    }
    this.event({ t: 'tcp_open', id });
    await new Promise((resolve) => {
      socket.on('data', (b) => this.tcpData(id, new Uint8Array(b.buffer, b.byteOffset, b.byteLength)));
      socket.on('error', () => {});
      socket.once('close', resolve);
    });
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
      case 'wasm': {
        const h = this.handlers.at(-1);
        this.run(() => this.wasmRequest(msg, body, h), h);
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
