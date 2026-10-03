// The VM of the page, in a module SharedWorker: one VM for all the tabs of
// the site. Without SharedWorker, it is a module Web Worker of one tab
// (index.html). So its work does not stop the page. A tab sends it:
// - {type: 'start', base, env}: boot the release with the variables env
//   (env.json), and the base path of the frame in BEAM_BASE_PATH. The
//   first start boots the VM. A later start (another tab) gets the reply
//   of the same boot;
// - {type: 'fetch', req} with a port: an HTTP request of a frame (sw.js);
// - {type: 'ws', path, protocols} with a port: a WebSocket of a frame
//   (ws-shim.js).
// The cookies of the VM stay here (a service worker cannot set them in
// the browser), one jar for all the tabs: a login in one tab is a login in
// all the tabs. Each request and each upgrade gets them. The listeners are
// here before any import, so the first message does not come before them.
// The VM stops 30 s after the last tab of the site leaves (see LINGER).

let beam = null;
let booting = null;  // the boot: a promise of the first start
let base = '';  // the path of the frame on the site: the VM gets the rest
const jar = new Map();
const pending = [];

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

// The host of each request is localhost (PHX_HOST of env.json), so that the
// app takes its WebSocket (check_origin). x-forwarded-proto is https, as
// behind a proxy: an app with force_ssl and rewrite_on: [:x_forwarded_proto]
// then does not redirect to https://localhost/.
async function fetchVm({ path, method, headers, body }, port) {
  try {
    // No accept-encoding: a body that the app compresses would reach the frame as it is.
    const h = Object.fromEntries(headers.filter(([k]) => !['cookie', 'host', 'accept-encoding'].includes(k)));
    h.cookie = cookie();
    h.host = 'localhost';
    h['x-forwarded-proto'] = 'https';
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
    const headers = { cookie: cookie(), host: 'localhost', origin: 'http://localhost', 'x-forwarded-proto': 'https' };
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

function boot({ base: path, env }) {
  booting ??= (async () => {
    base = path;
    const { start } = await import('./browser.js');
    beam = await start({ release: './release.bin', env: { ...env, BEAM_BASE_PATH: base } });
    for (const p of pending.splice(0)) handle(p);
    return { type: 'ready', restored: !!beam.vm.restored };
  })().catch((err) => {
    // The next start boots again: a SharedWorker lives while a tab of the
    // site is open, so an error at the first visit must not stay.
    booting = null;
    return { type: 'error', message: `The VM did not start: ${err?.message ?? err}` };
  });
  return booting;
}

// A message of a tab. reply: the answer to its start.
function receive(e, reply) {
  if (e.data.type === 'start') boot(e.data).then(reply);
  else if (beam) handle(e);
  else pending.push(e);
}

// The lifetime of the SharedWorker: the ports of the open tabs. A tab says
// "bye" when it leaves (pagehide), and "hello" when it comes back from the
// back/forward cache. With no open tab, the VM stops after LINGER ms, so a
// reload keeps the VM and its data. There is no heartbeat: a browser slows
// the timers of a hidden tab, and a heartbeat would stop the VM of an open
// tab. A tab that crashes says no "bye": then the VM lives while the
// browser keeps the SharedWorker.
const LINGER = 30000;
const open = new Set();
let linger = null;

function present(port) {
  open.add(port);
  clearTimeout(linger);
  linger = null;
}

function gone(port) {
  open.delete(port);
  if (open.size === 0 && !linger) linger = setTimeout(() => self.close(), LINGER);
}

if ('onconnect' in self) {
  self.addEventListener('connect', (c) => {
    const port = c.ports[0];
    present(port);
    port.onmessage = (e) => {
      if (e.data.type === 'bye') gone(port);
      else if (e.data.type === 'hello') present(port);
      else receive(e, (m) => port.postMessage(m));
    };
  });
} else {
  self.addEventListener('message', (e) => receive(e, (m) => self.postMessage(m)));
}
