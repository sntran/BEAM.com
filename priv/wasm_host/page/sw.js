// The service worker of the page (index.html), for the requests of its
// scope app/ (the frames of the app):
// - a static file (app/static.json lists the files of priv/static of the
//   app) comes from the site, as it is;
// - another request goes to the VM, with a port for the reply. A service
//   worker cannot open a SharedWorker, so a page gives the request to the
//   VM. First the frame that sent the request (its ws-shim.js gives the
//   request to its tab), else a tab of index.html that said "boot" (a
//   visible one first), else any tab of index.html. A tab with no VM
//   answers noVm, and the next one gets the request.
//   The VM gets the path without the prefix of the scope, as behind a
//   proxy. The app makes its links with the prefix (BEAM_BASE_PATH, see
//   wasm_host_base).
// The page of an HTML reply gets ws-shim.js: the WebSocket of LiveView
// then goes to the VM too. A redirect to a path of this origin outside the
// scope goes to the same path in the scope (scope.js).
import { inScope } from './scope.js';

const SCOPE = new URL(registration.scope);
const BOOT = new URL('../', SCOPE);
const tabs = new Set();    // the tabs of index.html that said "boot"
const frames = new Set();  // the frames with ws-shim.js
let statics = null;

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
// Only the page index.html (a tab of the VM) can say "boot", and only a page
// of the scope can say "frame": another page of this origin cannot take the
// requests of the app.
const isBootPage = (href) => {
  const u = new URL(href);
  return u.origin === BOOT.origin && (u.pathname === BOOT.pathname || u.pathname === `${BOOT.pathname}index.html`);
};
const isFramePage = (href) => {
  const u = new URL(href);
  return u.origin === SCOPE.origin && u.pathname.startsWith(SCOPE.pathname);
};
self.addEventListener('message', (e) => {
  if (!e.source?.url) return;
  if (e.data?.type === 'boot' && isBootPage(e.source.url)) tabs.add(e.source.id);
  else if (e.data?.type === 'frame' && isFramePage(e.source.url)) frames.add(e.source.id);
});

async function staticFiles() {
  statics ??= fetch(new URL('static.json', SCOPE)).then((r) => (r.ok ? r.json() : []))
    .catch(() => []).then((list) => new Set(list));
  return statics;
}

// The pages that can give a request to the VM, in order.
async function relays(clientId) {
  const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  const alive = new Set(all.map((c) => c.id));
  for (const set of [tabs, frames]) for (const id of set) if (!alive.has(id)) set.delete(id);
  const frame = frames.has(clientId) ? all.filter((c) => c.id === clientId) : [];
  const rank = (c) => (tabs.has(c.id) ? 0 : 4) + (c.focused ? 0 : 1) + (c.visibilityState === 'visible' ? 0 : 2);
  return [...frame, ...all.filter((c) => isBootPage(c.url)).sort((a, b) => rank(a) - rank(b))];
}

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (url.origin !== SCOPE.origin || !url.pathname.startsWith(SCOPE.pathname)) return;
  e.respondWith(handle(e.request, url, e.clientId));
});

async function handle(request, url, clientId) {
  const rest = url.pathname.slice(SCOPE.pathname.length - 1);  // "/..." of the app
  if (request.method === 'GET' && (await staticFiles()).has(rest)) return fetch(request);
  const body = ['GET', 'HEAD'].includes(request.method) ? null : await request.arrayBuffer();
  const req = { path: rest + url.search, method: request.method, headers: [...request.headers], body };
  let r = null;
  for (const client of await relays(clientId)) {
    const { port1, port2 } = new MessageChannel();
    const reply = new Promise((resolve) => { port1.onmessage = (m) => resolve(m.data); });
    client.postMessage({ type: 'fetch', req }, [port2]);
    r = await reply;
    if (!r.noVm) break;
  }
  if (!r || r.noVm) {
    return new Response(`<p>The app runs in the tab of <a href="${BOOT.href}" target="_top">this page</a>. Open it again.</p>`,
                        { status: 503, headers: { 'content-type': 'text/html; charset=utf-8' } });
  }
  if (r.error) return new Response(r.error, { status: 502 });
  if (r.status >= 300 && r.status < 400 && r.location) {
    return Response.redirect(inScope(new URL(r.location, url), SCOPE), [301, 302, 303, 307, 308].includes(r.status) ? r.status : 302);
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
