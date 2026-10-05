// The VM of the Livebook page, in a module Web Worker, so that its work does
// not stop the page. index.html sends it:
// - {type: 'start', base}: boot Livebook with the base path of its frame;
// - {type: 'fetch', req} with a port: an HTTP request of the frame (sw.js);
// - {type: 'ws', path, protocols} with a port: a WebSocket of the frame
//   (ws-shim.js).
// The cookies of Livebook stay here (a service worker cannot set them in
// the browser): each request and each upgrade gets them. The listener is
// here before any import, so the first message does not come before it.

let beam = null;
let base = '';  // the path of the frame on the site: the VM gets the rest
const jar = new Map();
const pending = [];

const post = (m) => self.postMessage(m);

function cookie() {
  return [...jar].map(([k, v]) => `${k}=${v}`).join('; ');
}

function keep(response) {
  for (const line of response.setCookies ?? []) {
    const [pair, ...attrs] = line.split(';');
    const at = pair.indexOf('=');
    if (at < 1) continue;
    const name = pair.slice(0, at).trim(), value = pair.slice(at + 1).trim();
    const gone = attrs.some((a) => /^\s*max-age\s*=\s*(0|-)/i.test(a))
      || attrs.some((a) => /^\s*expires\s*=/i.test(a) && Date.parse(a.split('=').slice(1).join('=')) < Date.now());
    if (gone) jar.delete(name); else jar.set(name, value);
  }
}

async function fetchVm({ path, method, headers, body }, port) {
  try {
    // No accept-encoding: a body that the app compresses would reach the frame as it is.
    const h = Object.fromEntries(headers.filter(([k]) => !['cookie', 'host', 'accept-encoding'].includes(k)));
    h.cookie = cookie();
    h.host = 'localhost';
    const r = await beam.fetch(path, { method, headers: h, body });
    keep(r);
    const out = [...r.headers].filter(([k]) => k !== 'set-cookie');
    const data = method === 'HEAD' ? null : await r.arrayBuffer();
    port.postMessage({ status: r.status, statusText: r.statusText, headers: out,
                       location: r.headers.get('location'), body: data }, data ? [data] : []);
  } catch (e) {
    port.postMessage({ error: String(e?.message ?? e) });
  }
}

async function socketVm({ path, protocols }, port) {
  let socket;
  try {
    const headers = { cookie: cookie(), host: 'localhost', origin: 'http://localhost' };
    if (protocols.length) headers['sec-websocket-protocol'] = protocols.join(', ');
    socket = await beam.socket(path.startsWith(`${base}/`) ? path.slice(base.length) : path, { headers });
  } catch (e) {
    port.postMessage({ close: true, code: 1006, error: String(e?.message ?? e) });
    return;
  }
  socket.addEventListener('message', (e) => {
    const data = e.data instanceof Uint8Array ? e.data.slice().buffer : e.data;
    port.postMessage({ message: data });
  });
  socket.addEventListener('close', (e) => port.postMessage({ close: true, code: e.code, reason: e.reason }));
  port.onmessage = (e) => {
    if (e.data.close) socket.close(e.data.code, e.data.reason);
    else socket.send(e.data.message);
  };
  port.postMessage({ open: true, protocol: protocols[0] ?? '' });
}

function handle(e) {
  const m = e.data;
  if (m.type === 'fetch') fetchVm(m.req, e.ports[0]);
  else if (m.type === 'ws') socketVm(m, e.ports[0]);
}

self.addEventListener('message', async (e) => {
  if (e.data.type !== 'start') {
    if (beam) handle(e); else pending.push(e);
    return;
  }
  try {
    base = e.data.base;
    const { start } = await import('./browser.js');
    const config = await fetch(new URL('./config.json', import.meta.url)).then((r) => r.json());
    beam = await start({
      app: './app.com',
      env: {
        LIVEBOOK_PORT: '4000', LIVEBOOK_DEFAULT_RUNTIME: 'embedded', LIVEBOOK_TOKEN_ENABLED: 'false',
        LIVEBOOK_DATA_PATH: '/tmp', LIVEBOOK_HOME: '/tmp', LIVEBOOK_BASE_URL_PATH: base,
        // The iframe page of Kino: on this site, under the scope of sw.js, so
        // that its imports from Livebook go to the VM too.
        LIVEBOOK_IFRAME_URL: config.iframe_url ?? `${location.origin}${base}/iframe/${config.iframe_page}`,
      },
    });
    post({ type: 'ready' });
    for (const p of pending.splice(0)) handle(p);
  } catch (err) {
    post({ type: 'error', message: `The VM did not start: ${err?.message ?? err}` });
  }
});
