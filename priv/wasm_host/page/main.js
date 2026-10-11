// The start of the page (index.html): the VM in a SharedWorker (vm.js), the
// service worker of the frame of the app (sw.js), and the frame. The page
// of beam.com INPUT -o DIR --target wasm32 imports it next to it, and a
// site that runs a native app.com imports it from the npm package beam.com
// (a CDN), with the options:
// - app: the URL of app.com, relative to the page;
// - vm: the URL of the script of the VM on the site (default ./vm.js). A
//   SharedWorker and a service worker must come from the origin of the
//   site, so its vm.js and sw.js import the ones of the package;
// - ports: the URL of a module of the site, relative to the page. The VM
//   imports it, and each export is a binding of env, as on Workers: an
//   object with a method port(stdin, { argv }) is the port /env/NAME
//   (docs/WORKERS.md, "Ports to bindings").
const status = document.getElementById('status'), bar = document.getElementById('bar');
const say = (text, error = false) => { status.textContent = text; status.className = error ? 'err' : ''; };
const fail = (text) => { bar.remove(); say(text, true); };
// The site is the directory of this page. The app is in the frame app/.
const SITE = new URL('./', location.href);
const APP = new URL('./app/', SITE);

// The path of the frame is in the fragment of the URL of this page
// (SITE#/users/log-in), so a reload and a link keep the page of the app.
// Only a path: it starts with "/", not with "//", and it stays in app/ of
// this origin. Another fragment opens the home page of the app.
function startUrl() {
  const path = location.hash.slice(1);
  if (!path.startsWith('/') || path.startsWith('//')) return APP.href;
  const url = new URL(APP.pathname.replace(/\/$/, '') + path, SITE);
  return url.origin === SITE.origin && url.pathname.startsWith(APP.pathname) ? url.href : APP.href;
}

// The variables of the VM (env.json, from the build). A secret gets a
// random value, one for each browser. It stays in localStorage, so that
// the snapshot of the VM (its key has the variables) serves the next visit.
function secret(name) {
  const key = `beam-page:${SITE.pathname}:${name}`;
  try {
    const old = localStorage.getItem(key);
    if (old) return old;
  } catch {}
  const bytes = crypto.getRandomValues(new Uint8Array(48));
  const value = btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_');
  try { localStorage.setItem(key, value); } catch {}
  return value;
}

// The name of the app on the page.
function named(name) {
  document.title = name;
  document.getElementById('name').textContent = name;
  document.getElementById('app').title = name;
}

async function main({ app = null, vm: vmScript = './vm.js', ports = null } = {}) {
  // A native app.com: its release has the name and the environment of the
  // app, so the page gives only the variables of a page. Else env.json of
  // the build (beam.com INPUT -o DIR --target wasm32).
  const config = app
    ? { name: null, env: { PORT: '4000', HOME: '/tmp', PHX_HOST: 'localhost' }, secrets: ['SECRET_KEY_BASE'] }
    : await (await fetch(new URL('env.json', SITE))).json();
  if (config.name) named(config.name);
  // JSPI (WebAssembly JavaScript Promise Integration) is in Chrome and
  // Edge 137 or later, and in Firefox 153 or later. Safari 27 also has
  // it, but nobody has tested this page in Safari yet.
  if (typeof WebAssembly.Suspending !== 'function' || !('serviceWorker' in navigator)) {
    return fail('This browser cannot run the VM. Open this page in Chrome or Edge 137 or later, or in Firefox 153 or later.');
  }
  const env = { ...config.env };
  for (const name of config.secrets ?? []) env[name] = secret(name);
  const start = { type: 'start', base: APP.pathname.replace(/\/$/, ''), env, app: app && new URL(app, SITE).href,
                  ports: ports && new URL(ports, SITE).href };
  const t0 = performance.now();
  say('Loading the runtime and the release…');
  // vm: the port of the SharedWorker of the VM, or the Worker of the VM in
  // this tab. With no VM, this tab answers noVm to the service worker,
  // which then gives the request to another tab.
  let vm = null;
  const relay = (data, port) => (vm ? vm.postMessage(data, [port]) : port.postMessage({ noVm: true }));
  // The requests of the service worker (sw.js, not another worker of this
  // origin) go to the VM with their reply port.
  const SW = new URL('./sw.js', SITE).href;
  navigator.serviceWorker.addEventListener('message', (e) => {
    if (e.source?.scriptURL === SW && e.data?.type === 'fetch') relay(e.data, e.ports[0]);
  });
  // The WebSockets and the requests of the frame of the app, and of the
  // frames in it (ws-shim.js).
  const inFrame = (w) => {
    for (let n = 0; w && n < 10; n++, w = w.parent) {
      if (w === document.getElementById('app').contentWindow) return true;
      if (w === w.parent) return false;
    }
    return false;
  };
  addEventListener('message', (e) => {
    if (e.origin === location.origin && ['ws', 'fetch'].includes(e.data?.type) && inFrame(e.source)) relay(e.data, e.ports[0]);
    // The path of the frame of the app (ws-shim.js), for the fragment.
    if (e.origin === location.origin && e.data?.type === 'path' && e.source === document.getElementById('app').contentWindow
        && typeof e.data.path === 'string' && e.data.path.startsWith('/') && !e.data.path.startsWith('//')) {
      history.replaceState(history.state, '', e.data.path === '/' ? location.pathname + location.search : `#${e.data.path}`);
    }
  });
  // This page is outside the scope, so navigator.serviceWorker.ready does
  // not apply: wait for the registration to be active.
  const active = navigator.serviceWorker.register(SW, { scope: APP.pathname, type: 'module' }).then((reg) =>
    new Promise((resolve) => {
      const check = () => { if (reg.active) resolve(reg.active); };
      check();
      for (const w of [reg.installing, reg.waiting]) w?.addEventListener('statechange', check);
      reg.addEventListener('updatefound', () => reg.installing?.addEventListener('statechange', check));
    }));
  // The answer of the VM to start: ready or error. An error that the VM
  // answered (vm: true) can go away at a second start, for example a
  // network error on release.bin. An error event of the worker (its script
  // did not load) occurs one time only.
  const started = (port, worker) => new Promise((resolve, reject) => {
    port.onmessage = (e) => {
      if (e.data.type === 'ready') resolve(e.data);
      else if (e.data.type === 'error') reject(Object.assign(new Error(e.data.message), { vm: true }));
    };
    worker.addEventListener('error', (e) => reject(new Error(e.message || 'the VM stopped')));
    port.postMessage(start);
  });
  const script = new URL(vmScript, SITE);
  let info = null, where = 'shared';
  // One VM for all the tabs of the site, in a SharedWorker. The sites of
  // one origin (USER.github.io/A/ and USER.github.io/B/) have different
  // scripts, so different VMs.
  // The VM stops 30 s after the last tab of the site leaves (vm.js), so a
  // reload keeps the VM and its data. A tab says "bye" when it leaves, and
  // "hello" when it comes back from the back/forward cache.
  // extendedLifetime (Chrome 148 or later) lets the SharedWorker live
  // after its last tab, until that timer of vm.js ends.
  if (typeof SharedWorker === 'function') {
    try {
      const shared = new SharedWorker(script, { type: 'module', name: `beam-page:${SITE.pathname}`, extendedLifetime: true });
      vm = shared.port;
      // A failed boot of the VM gets one more start on the same port, so that
      // an error that occurs one time does not make two VMs for one site.
      info = await started(shared.port, shared).catch((e) => {
        if (!e.vm) throw e;
        console.log(`beam: the VM did not start in the SharedWorker (${e.message}): one more start`);
        return started(shared.port, shared);
      });
      addEventListener('pagehide', () => shared.port.postMessage({ type: 'bye' }));
      addEventListener('pageshow', (e) => { if (e.persisted) shared.port.postMessage({ type: 'hello' }); });
    } catch (e) {
      console.log(`beam: the VM did not start in a SharedWorker (${e.message}): it runs in this tab`);
      vm?.postMessage({ type: 'bye' });
      vm?.close();
      vm = null;
    }
  }
  // Else one VM in one tab: the other tabs of the site show a message.
  if (!info) {
    where = 'tab';
    const lock = await new Promise((resolve) =>
      navigator.locks.request(`beam-page:${SITE.pathname}`, { ifAvailable: true }, (l) => {
        resolve(l);
        return l ? new Promise(() => {}) : undefined;
      }));
    if (!lock) return fail('The app runs in another tab of this site. Use that tab, or close it and load this page again.');
    const worker = new Worker(script, { type: 'module' });
    vm = worker;
    info = await started(worker, worker);
  }
  (await active).postMessage({ type: 'boot' });  // this tab can reach the VM
  if (info.name) named(info.name);
  const ms = Math.round(performance.now() - t0);
  // For the browser check (tests/page/check.mjs).
  document.body.dataset.vm = where;
  document.body.dataset.restored = String(info.restored);
  console.log(`beam: the VM started in ${ms} ms (${where === 'shared' ? 'a SharedWorker' : 'this tab'}${info.restored ? ', from the snapshot' : ''})`);
  say(`Opening the app (the VM started in ${ms} ms)…`);
  const frame = document.getElementById('app');
  frame.addEventListener('load', () => document.body.classList.add('running'), { once: true });
  frame.src = startUrl();
}

export function start(options) {
  main(options).catch((e) => { fail(e.message); console.error(e); });
}