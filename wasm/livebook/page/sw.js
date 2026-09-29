// The service worker of the Livebook page (index.html), for the requests
// of its scope app/ (the Livebook frame):
// - a static file of Livebook (app/static.json lists them) comes from the
//   site, as it is;
// - another request goes to the VM, in the tab of index.html (the tab that
//   sent "boot"), with a port for the reply. The VM gets the path without
//   the prefix of the scope, as behind a proxy (LIVEBOOK_BASE_URL_PATH).
// The page of an HTML reply gets ws-shim.js: the WebSocket of LiveView
// then goes to the VM too.
const SCOPE = new URL(registration.scope);
const BOOT = new URL('../', SCOPE);
let bootId = null;
let statics = null;

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('message', (e) => {
  if (e.data?.type === 'boot') bootId = e.source.id;
});

async function staticFiles() {
  statics ??= fetch(new URL('static.json', SCOPE)).then((r) => r.json()).then((list) => new Set(list));
  return statics;
}

// The tab of the VM: the one that sent "boot", else a tab of index.html (after
// a restart of this service worker).
async function bootClient() {
  if (bootId) {
    const c = await self.clients.get(bootId);
    if (c) return c;
  }
  const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  const c = all.find((w) => { const u = new URL(w.url); return u.origin === BOOT.origin && (u.pathname === BOOT.pathname || u.pathname === `${BOOT.pathname}index.html`); });
  bootId = c?.id ?? null;
  return c;
}

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (url.origin !== SCOPE.origin || !url.pathname.startsWith(SCOPE.pathname)) return;
  e.respondWith(handle(e.request, url));
});

async function handle(request, url) {
  const rest = url.pathname.slice(SCOPE.pathname.length - 1);  // "/..." of the app
  if (request.method === 'GET' && (await staticFiles()).has(rest)) return fetch(request);
  const client = await bootClient();
  if (!client) {
    return new Response(`<p>Livebook runs in the tab of <a href="${BOOT.href}" target="_top">this page</a>. Open it again.</p>`,
                        { status: 503, headers: { 'content-type': 'text/html; charset=utf-8' } });
  }
  const body = ['GET', 'HEAD'].includes(request.method) ? null : await request.arrayBuffer();
  const { port1, port2 } = new MessageChannel();
  const reply = new Promise((resolve) => { port1.onmessage = (m) => resolve(m.data); });
  client.postMessage({ type: 'fetch', req: { path: rest + url.search, method: request.method,
                                             headers: [...request.headers], body } },
                     body ? [port2, body] : [port2]);
  const r = await reply;
  if (r.error) return new Response(r.error, { status: 502 });
  if (r.status >= 300 && r.status < 400 && r.location) {
    return Response.redirect(new URL(r.location, url).href, [301, 302, 303, 307, 308].includes(r.status) ? r.status : 302);
  }
  const headers = new Headers(r.headers);
  let data = r.body;
  if ((headers.get('content-type') ?? '').startsWith('text/html') && data) {
    const html = new TextDecoder().decode(data);
    const shim = `<script src="${new URL('ws-shim.js', BOOT).pathname}"></script>`;
    data = html.replace(/<head[^>]*>/i, (h) => h + shim);
    headers.delete('content-length');
  }
  const nullBody = [101, 204, 205, 304].includes(r.status);
  return new Response(nullBody ? null : data, { status: r.status, statusText: r.statusText, headers });
}
