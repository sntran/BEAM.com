// The BEAM on Deno (Deno Deploy): worker.js of the Workers, with the parts of
// the Workers runtime that it uses given by Deno: connect() of
// cloudflare:sockets (deno/sockets.js), the module imports of beam.wasm,
// release.bin and snapshot.bin (deno.json), WebSocketPair, caches.default,
// and the SQL storage of a Durable Object (node:sqlite).
//
// A Deno isolate keeps its VM between requests, as a Durable Object does.
// So the VM runs as in a Durable Object (plain: false): its timers run
// between requests, and an app with Ecto SQLite makes its snapshot at the
// boot point, before its migrations. The database is in memory, one for
// each isolate (BEAM_SQLITE = a file path gives a file).
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

// Ecto SQLite: the SQL storage of a Durable Object (exec, raw, columnNames),
// on node:sqlite. BEAM_SQLITE is the file of the database (default: in
// memory, for this isolate only).
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
let sql = null;
if (env.BEAM_SQLITE !== 'off') {
  const { DatabaseSync } = await import('node:sqlite');
  sql = new SqlStorage(new DatabaseSync(env.BEAM_SQLITE ?? ':memory:'));
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
      const v = vm = new Vm(env, { plain: false, sql, vars });
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
