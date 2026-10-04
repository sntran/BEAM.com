// The BEAM in a web page: worker.js of the Workers, with the parts of the
// Workers runtime that it uses given by the page. The page needs JSPI
// (WebAssembly.Suspending), and this import map before its first module:
//
//   <script type="importmap">{ "imports": {
//     "node:net": "./browser/net.js",
//     "./beam.wasm": "./browser/beam-wasm.js",
//     "./release.bin": "./browser/none.js",
//     "./snapshot.bin": "./browser/none.js" } }</script>
//
// Then:
//
//   import { start } from './browser.js';
//   const beam = await start({ release: './release/release.bin' });
//   const response = await beam.fetch('/path');   // a Response of the app
//   const socket = await beam.socket('/ws');      // a WebSocket of the app
//
// It also runs in a module Web Worker, which has no import map: there,
// the page gives a copy of worker.js with those four paths in its imports
// (wasm/livebook/page.sh makes one).
//
// The app runs in the page, as in a Durable Object: its timers run all the
// time. The page has no TCP connections and no SQL storage. The snapshot
// of the booted VM goes to the Cache API of the site (only on HTTPS and on
// localhost), so the next visit starts from it.

// WebSocketPair: two ends in the page. A message to one end is an event of
// the other end.
class End extends EventTarget {
  constructor() {
    super();
    this.readyState = 0;
    this.binaryType = 'arraybuffer';
    this.onopen = this.onmessage = this.onclose = this.onerror = null;
  }

  accept() {}

  send(data) {
    if (this.readyState !== 1) return;
    const peer = this.peer;
    queueMicrotask(() => peer.emit(new MessageEvent('message', { data })));
  }

  close(code = 1000, reason = '') {
    if (this.readyState > 1) return;
    for (const end of [this, this.peer]) end.readyState = 3;
    for (const end of [this.peer, this]) queueMicrotask(() => end.emit(new CloseEvent('close', { code, reason })));
  }

  emit(event) {
    this.dispatchEvent(event);
    this[`on${event.type}`]?.(event);
  }
}

globalThis.WebSocketPair = class {
  constructor() {
    const client = new End(), server = new End();
    client.peer = server;
    server.peer = client;
    client.readyState = server.readyState = 1;
    this[0] = client;
    this[1] = server;
  }
};

// new Response(null, { status: 101, webSocket }) of Workers: a page refuses
// the status 101, so the response keeps the client end in webSocket. A
// page also drops the Set-Cookie headers of a Response: setCookies keeps
// them (a Headers of its own keeps them).
const NativeResponse = Response;
globalThis.Response = class extends NativeResponse {
  constructor(body, init) {
    const webSocket = init?.webSocket;
    super(webSocket ? null : body, webSocket ? { status: 200 } : init);
    if (webSocket) this.webSocket = webSocket;
    this.setCookies = init?.headers ? new Headers(init.headers).getSetCookie() : [];
  }
};

// The Cache API of Workers has caches.default (only in a secure context).
if (globalThis.caches && !caches.default) {
  try { caches.default = await caches.open('beam'); } catch {}
}

// A request to the app. A Request of a page drops the headers Upgrade and
// Sec-*, so the request is an object with the fields that worker.js reads,
// and a Headers of its own.
function request(url, { method = 'GET', headers = {}, body = null } = {}) {
  return {
    url: url.href,
    method,
    headers: new Headers(headers),
    arrayBuffer: () => new NativeResponse(body).arrayBuffer(),
  };
}

// A reader of the bytes of the file of url (app-com.js): one range for each
// read. A server that gives the whole file (no ranges, or no size) gives
// it one time.
async function urlReader(url) {
  const head = await fetch(url, { method: 'HEAD' });
  if (!head.ok) throw new Error(`${url}: status ${head.status}`);
  const size = Number(head.headers.get('content-length'));
  let whole = null;
  const all = async () => {
    const r = await fetch(url);
    if (!r.ok) throw new Error(`${url}: status ${r.status}`);
    whole = new Uint8Array(await r.arrayBuffer());
  };
  if (!size || head.headers.get('content-encoding')) await all();
  return {
    size: whole ? whole.length : size,
    async read(at, n) {
      if (!whole) {
        const r = await fetch(url, { headers: { range: `bytes=${at}-${at + n - 1}` } });
        if (r.status === 206) return new Uint8Array(await r.arrayBuffer());
        if (!r.ok) throw new Error(`${url}: status ${r.status}`);
        whole = new Uint8Array(await r.arrayBuffer());
      }
      return whole.subarray(at, at + n);
    },
  };
}

// Boots the release of the URL release, or of the native app.com of the URL
// app (its edge part, see app-com.js: for this runtime only), with the
// environment env (the "vars" of a Worker). BEAM_HOST is "browser".
export async function start({ release = './release.bin', app = null, env = {} } = {}) {
  if (typeof WebAssembly.Suspending !== 'function') {
    throw new Error('this browser has no JSPI (WebAssembly.Suspending)');
  }
  const { Vm, releaseMeta } = await import('./worker.js');
  const where = globalThis.document?.baseURI ?? location.href;
  let vm;
  if (app) {
    const [{ appFiles }, { default: runtime }] = await Promise.all([import('./app-com.js'), import('./runtime-id.js')]);
    const { read, size } = await urlReader(new URL(app, where).href);
    const bytes = await appFiles(read, size, { runtime });
    vm = new Vm({ BEAM_HOST: 'browser', ...env }, { plain: false, release: bytes, scheme: false });
  } else {
    vm = new Vm({ BEAM_HOST: 'browser', ...env, RELEASE_URL: new URL(release, where).href }, { plain: false, scheme: false });
  }
  await vm.ready;
  const origin = new URL('http://localhost');
  return {
    vm,
    name: releaseMeta(vm.release).name,
    fetch: (path, init) => vm.fetch(request(new URL(path, origin), init)),
    // init.headers: more headers of the upgrade request (a cookie, for example).
    async socket(path, init = {}) {
      const headers = { ...init.headers, upgrade: 'websocket' };
      const response = await vm.fetch(request(new URL(path, origin), { headers }));
      const socket = response.webSocket;
      if (!socket) throw new Error(`${path}: no WebSocket (status ${response.status})`);
      setTimeout(() => socket.emit(new Event('open')));
      return socket;
    },
  };
}
