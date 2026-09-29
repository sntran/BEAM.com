// The BEAM in a web page: worker.js of the Workers, with the parts of the
// Workers runtime that it uses given by the page. The page needs JSPI
// (WebAssembly.Suspending), and this import map before its first module:
//
//   <script type="importmap">{ "imports": {
//     "cloudflare:sockets": "./browser/sockets.js",
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
// the status 101, so the response keeps the client end in webSocket.
const NativeResponse = Response;
globalThis.Response = class extends NativeResponse {
  constructor(body, init) {
    const webSocket = init?.webSocket;
    super(webSocket ? null : body, webSocket ? { status: 200 } : init);
    if (webSocket) this.webSocket = webSocket;
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

// Boots the release of the URL release, with the environment env (the
// "vars" of a Worker). BEAM_HOST is "browser".
export async function start({ release = './release.bin', env = {} } = {}) {
  if (typeof WebAssembly.Suspending !== 'function') {
    throw new Error('this browser has no JSPI (WebAssembly.Suspending)');
  }
  const { Vm } = await import('./worker.js');
  const vm = new Vm({ BEAM_HOST: 'browser', ...env, RELEASE_URL: new URL(release, document.baseURI).href },
                    { plain: false });
  await vm.ready;
  const origin = new URL('http://localhost');
  return {
    vm,
    fetch: (path, init) => vm.fetch(request(new URL(path, origin), init)),
    async socket(path) {
      const response = await vm.fetch(request(new URL(path, origin), { headers: { upgrade: 'websocket' } }));
      const socket = response.webSocket;
      if (!socket) throw new Error(`${path}: no WebSocket (status ${response.status})`);
      setTimeout(() => socket.emit(new Event('open')));
      return socket;
    },
  };
}
