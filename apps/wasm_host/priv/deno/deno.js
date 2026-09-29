// The BEAM on Deno (Deno Deploy): worker.js of the Workers, with the parts of
// the Workers runtime that it uses given by Deno: connect() of
// cloudflare:sockets (deno/sockets.js), the module imports of beam.wasm and
// release.bin (deno.json), WebSocketPair, caches.default, and the SQL
// storage of a Durable Object (node:sqlite).
//
// A prototype: put deno.js, deno.json and deno/ next to worker.js in the
// output of "beam.com INPUT -o DIR --target wasm32", then in DIR:
//   deno serve --allow-net --allow-read --allow-env --allow-write=/tmp deno.js
import { AsyncLocalStorage } from 'node:async_hooks';

const current = new AsyncLocalStorage();  // the request of this call

// WebSocketPair: Deno upgrades the request itself (Deno.upgradeWebSocket).
// The client end holds the response of the upgrade, and the server end is
// the socket of Deno, with accept() of Workers.
const UPGRADE = Symbol('upgrade');
globalThis.WebSocketPair = class {
  constructor() {
    const { socket, response } = Deno.upgradeWebSocket(current.getStore());
    const queue = [];
    let open = socket.readyState === 1;
    socket.addEventListener('open', () => { open = true; for (const m of queue.splice(0)) socket.send(m); });
    const server = new Proxy(socket, {
      get(s, k) {
        if (k === 'accept') return () => {};
        if (k === 'send') return (m) => (open ? s.send(m) : queue.push(m));
        const v = Reflect.get(s, k);
        return typeof v === 'function' ? v.bind(s) : v;
      },
      set(s, k, v) { return Reflect.set(s, k, v); },
    });
    this[0] = { [UPGRADE]: response };
    this[1] = server;
  }
};

// new Response(null, { status: 101, webSocket }) of Workers: the response
// of the upgrade.
const NativeResponse = Response;
globalThis.Response = class extends NativeResponse {
  constructor(body, init) {
    if (init?.webSocket?.[UPGRADE]) return init.webSocket[UPGRADE];
    super(body, init);
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
const env = Deno.env.toObject();
const ctx = { waitUntil: (p) => { p?.catch?.((e) => console.error(e)); } };
let sql = null;
if (env.BEAM_SQLITE !== 'off') {
  const { DatabaseSync } = await import('node:sqlite');
  sql = new SqlStorage(new DatabaseSync(env.BEAM_SQLITE ?? ':memory:'));
}
let vm;  // the VM of this isolate

export default {
  fetch(request) {
    if (!vm) {
      const v = vm = new Vm(env, { sql });
      v.ready.catch(() => { if (vm === v) vm = undefined; });
    }
    return current.run(request, () => vm.fetch(request, ctx));
  },
};
