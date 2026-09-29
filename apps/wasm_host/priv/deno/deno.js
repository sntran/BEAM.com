// The BEAM on Deno (Deno Deploy): worker.js of the Workers, with the parts of
// the Workers runtime that it uses given by Deno: connect() of
// cloudflare:sockets (deno/sockets.js), the module imports of beam.wasm,
// release.bin and snapshot.bin (deno.json), WebSocketPair, caches.default,
// and a store for Ecto SQLite (Deno KV, or node:sqlite).
//
// A Deno isolate keeps its VM between requests, as a Durable Object does.
// So the VM runs as in a Durable Object (plain: false): its timers run
// between requests, and an app with Ecto SQLite makes its snapshot at the
// boot point, before its migrations.
//
// Ecto SQLite (BEAM_SQLITE):
// - unset or "kv": SQLite in the VM (exqlite of the runtime), with the
//   pages of its databases in Deno KV (Deno.openKv(BEAM_KV)): all the
//   isolates share them, and they stay after a deploy;
// - "memory", or the path of a file: node:sqlite in this isolate runs the
//   SQL (a database for each isolate, or a file);
// - "off": SQLite in the VM, in its memory.
// When Deno KV does not open (no database for the app on Deno Deploy, or
// no --unstable-kv), "kv" becomes "memory".
//
// "beam.com INPUT -o DIR --target wasm32" writes deno.js, deno.json and
// deno/ into DIR, next to worker.js. In DIR:
//   deno serve --allow-net --allow-read --allow-env --allow-write=/tmp deno.js
// or "deno deploy" with the entrypoint deno.js.

// WebSocketPair: Deno upgrades the request itself (Deno.upgradeWebSocket),
// and only with the request. The VM can make the pair outside the call of
// the request (a Durable Object runs the VM all the time). So the server
// end is a socket with no connection yet. fetch() connects it when it
// gets the response of the upgrade (upgrade).
const UPGRADE = Symbol('upgrade');
globalThis.WebSocketPair = class {
  constructor() {
    const listeners = { message: [], close: [], error: [] };
    const queue = [];  // the messages before the socket opens
    let socket = null, closed = null;
    const server = {
      binaryType: 'arraybuffer',
      accept() {},
      addEventListener(type, f) { listeners[type]?.push(f); },
      send(m) { if (socket?.readyState === 1) socket.send(m); else if (!closed) queue.push(m); },
      close(code, reason) {
        if (socket) { try { socket.close(code, reason); } catch {} } else closed = [code, reason];
      },
    };
    const connect = (request) => {
      const { socket: s, response } = Deno.upgradeWebSocket(request);
      socket = s;
      s.binaryType = server.binaryType;
      for (const type of Object.keys(listeners)) {
        s.addEventListener(type, (e) => { for (const f of listeners[type]) f(e); });
      }
      s.addEventListener('open', () => {
        for (const m of queue.splice(0)) s.send(m);
        if (closed) s.close(...closed);
      });
      return response;
    };
    this[0] = { [UPGRADE]: connect };
    this[1] = server;
  }
};

// new Response(null, { status: 101, webSocket }) of Workers: a response
// that fetch() changes to the response of the upgrade (Deno refuses the
// status 101 here).
const NativeResponse = Response;
globalThis.Response = class extends NativeResponse {
  constructor(body, init) {
    const connect = init?.webSocket?.[UPGRADE];
    super(connect ? null : body, connect ? { status: 200 } : init);
    if (connect) this[UPGRADE] = connect;
  }
};

// The Cache API of Workers has caches.default.
if (globalThis.caches && !caches.default) {
  try { caches.default = await caches.open('beam'); } catch {}
}

// Workers log a rejected promise that no code handles, and go on. Deno
// stops the process: so log it here, as Workers do.
addEventListener('unhandledrejection', (e) => {
  e.preventDefault();
  console.error('beam: unhandled rejection:', e.reason?.message ?? e.reason);
});

// The store of the SQLite files of the VM (HostFiles of worker.js) in
// Deno KV. The keys: [beam, sqlite, NAME, "m"] is the version and the size
// of the database NAME, and [beam, sqlite, NAME, "b", N, VERSION] is block N
// (4 KiB) as VERSION wrote it, with the version before it (p). A commit is
// one atomic operation with a check of the key "m".
// A local KV is a SQLite file. When two processes use it, an operation
// can fail with "database is locked": then the store tries it again.
class KvStore {
  constructor(kv) { this.kv = kv; }
  key(name, ...rest) { return ['beam', 'sqlite', name, ...rest]; }
  meta(name) {
    return retry(async () => {
      const r = await this.kv.get(this.key(name, 'm'));
      return { version: r.value?.version ?? 0, size: r.value?.size ?? 0, stamp: r.versionstamp };
    });
  }
  block(name, n, version) {
    return retry(async () => {
      const it = this.kv.list({ start: this.key(name, 'b', n, 0), end: this.key(name, 'b', n, version + 1) },
                              { reverse: true, limit: 1 });
      for await (const e of it) return { data: e.value.d, v: e.key.at(-1), prev: e.value.p };
      return null;
    });
  }
  // With release, the commit also removes the write lock. It does not
  // check the lock: the version of the database is the check.
  commit(name, stamp, { version, size, blocks }, release = false) {
    return retry(async () => {
      const op = this.kv.atomic().check({ key: this.key(name, 'm'), versionstamp: stamp });
      for (const b of blocks) {
        op.set(this.key(name, 'b', b.n, version), { d: b.data, p: b.prev });
        if (b.drop) op.delete(this.key(name, 'b', b.n, b.drop));
      }
      op.set(this.key(name, 'm'), { version, size });
      if (release) op.delete(this.key(name, 'w'));
      const r = await op.commit();
      return r.ok ? r.versionstamp : null;
    });
  }
  // The write lock: a key with an owner and an end. The commit does not
  // need it, because it checks the version of the database. The lease is
  // the versionstamp of the lock. With no lock, one atomic operation
  // takes it; else a read finds if the lock is ours or at its end.
  lock(name, stamp, owner, ms) {
    const m = this.key(name, 'm'), w = this.key(name, 'w');
    const take = (mStamp, wStamp) => this.kv.atomic()
      .check({ key: m, versionstamp: mStamp }).check({ key: w, versionstamp: wStamp })
      .set(w, { owner, until: Date.now() + ms }, { expireIn: ms }).commit();
    return retry(async () => {
      let r = await take(stamp, null);
      if (r.ok) return r.versionstamp;
      const [mv, wv] = await this.kv.getMany([m, w]);
      if (mv.versionstamp !== stamp || (wv.value && wv.value.owner !== owner && wv.value.until > Date.now())) return null;
      r = await take(stamp, wv.versionstamp);
      return r.ok ? r.versionstamp : null;
    });
  }
  // One atomic operation: it removes the lock only when it is still that lease.
  unlock(name, lease) {
    const w = this.key(name, 'w');
    return retry(() => this.kv.atomic().check({ key: w, versionstamp: lease }).delete(w).commit());
  }
  async remove(name) {
    const keys = [];
    for await (const e of this.kv.list({ prefix: this.key(name) })) keys.push(e.key);
    for (let i = 0; i < keys.length; i += 500) {
      const op = this.kv.atomic();
      for (const k of keys.slice(i, i + 500)) op.delete(k);
      await op.commit();
    }
  }
}

async function retry(fn) {
  for (let i = 0; ; i++) {
    try {
      return await fn();
    } catch (e) {
      if (i >= 100 || !/database is locked/.test(e.message)) throw e;
      await new Promise((r) => setTimeout(r, 5 + Math.random() * 20));
    }
  }
}

// Ecto SQLite in the host: the SQL storage of a Durable Object (exec, raw,
// columnNames), on node:sqlite.
class SqlStorage {
  constructor(db) { this.db = db; }
  exec(sql, ...params) {
    const st = this.db.prepare(sql);
    const args = params.map((p) => (p instanceof ArrayBuffer ? new Uint8Array(p) : p));
    const columnNames = st.columns().map((c) => c.name);
    let rows = [];
    if (columnNames.length) {
      st.setReturnArrays(true);
      rows = st.all(...args);
    } else {
      st.run(...args);
    }
    const objects = () => rows.map((r) => Object.fromEntries(columnNames.map((c, i) => [c, r[i]])));
    return {
      columnNames,
      raw: () => rows[Symbol.iterator](),
      toArray: objects,
      [Symbol.iterator]: () => objects()[Symbol.iterator](),
    };
  }
}

const { Vm } = await import('./worker.js');
// The environment of the release, as the "vars" of a Worker: the
// variables of the process, without those of Deno and of the host. Some
// of those change for each isolate, and the key of a snapshot holds the
// environment. BEAM_ENV = "NAME,NAME" gives the exact list.
const HOST_VAR = /^(DENO_|OTEL_|K8S_|CDN_LOOP$)/;
const names = Deno.env.get('BEAM_ENV')?.split(',').map((n) => n.trim()).filter(Boolean);
const env = Object.fromEntries(Object.entries(Deno.env.toObject())
  .filter(([k]) => (names ? names.includes(k) || k.startsWith('BEAM_') : !HOST_VAR.test(k))));
// The version of the deploy (as version_metadata of a Worker): a new
// deploy makes a new snapshot.
const deployment = Deno.env.get('DENO_DEPLOY_BUILD_ID');
if (deployment) env.BEAM_VERSION = { id: deployment };
// The host, for the app. The region of Deno Deploy changes for each
// isolate: so it goes to the VM after the boot point (vars), not into the
// key of the snapshot.
env.BEAM_HOST ??= Deno.env.get('DENO_DEPLOY') ? 'deno-deploy' : 'deno';
const region = Deno.env.get('DENO_REGION');
const vars = region ? { BEAM_REGION: region } : {};
let sql = null, files = null;
let mode = env.BEAM_SQLITE ?? 'kv';
if (mode === 'kv') {
  try {
    files = new KvStore(await Deno.openKv(Deno.env.get('BEAM_KV')));
  } catch (e) {
    console.log(`beam: no Deno KV (${e.message}): SQLite runs in node:sqlite, in memory`);
    mode = 'memory';
  }
}
if (mode !== 'kv' && mode !== 'off') {
  const { DatabaseSync } = await import('node:sqlite');
  sql = new SqlStorage(new DatabaseSync(mode === 'memory' ? ':memory:' : mode));
}
let vm;  // the VM of this isolate

// The static assets of the app (static/, from wasm/erts/host/static.mjs),
// as the assets of a Worker: served before the VM.
const TYPES = {
  css: 'text/css', js: 'text/javascript', mjs: 'text/javascript', json: 'application/json',
  html: 'text/html; charset=utf-8', txt: 'text/plain; charset=utf-8', svg: 'image/svg+xml',
  png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp',
  ico: 'image/x-icon', woff: 'font/woff', woff2: 'font/woff2', ttf: 'font/ttf', map: 'application/json',
  wasm: 'application/wasm',
};
const assets = new Set();
const STATIC = new URL('./static/', import.meta.url);
(function walk(dir, prefix) {
  let entries;
  try { entries = [...Deno.readDirSync(dir)]; } catch { return; }
  for (const e of entries) {
    if (e.isDirectory) walk(new URL(`${e.name}/`, dir), `${prefix}${e.name}/`);
    else if (e.isFile) assets.add(`${prefix}${e.name}`);
  }
})(STATIC, '/');

async function asset(request) {
  if (request.method !== 'GET' && request.method !== 'HEAD') return null;
  let path;
  try { path = decodeURIComponent(new URL(request.url).pathname); } catch { return null; }
  if (!assets.has(path)) return null;
  const file = await Deno.open(new URL(`.${path}`, STATIC));
  const type = TYPES[path.split('.').pop().toLowerCase()] ?? 'application/octet-stream';
  return new Response(request.method === 'HEAD' ? null : file.readable, { headers: { 'content-type': type } });
}

export default {
  async fetch(request) {
    const file = await asset(request);
    if (file) return file;
    if (!vm) {
      const v = vm = new Vm(env, { plain: false, sql, vars, files });
      v.ready.catch(() => { if (vm === v) vm = undefined; });
    }
    // The scheme of the client (Cloudflare gives it in x-forwarded-proto,
    // Deno Deploy only in the URL): Plug.SSL and force_ssl read it.
    let r = request;
    if (!request.headers.has('x-forwarded-proto')) {
      const headers = new Headers(request.headers);
      headers.set('x-forwarded-proto', new URL(request.url).protocol.slice(0, -1));
      r = new Request(request, { headers });
    }
    // The upgrade needs the request that Deno gave.
    return Promise.resolve(vm.fetch(r)).then((res) => (res?.[UPGRADE] ? res[UPGRADE](request) : res));
  },
};
