// The VM in one Durable Object, in place of one VM for each isolate: one
// instance for all the requests (a server whose state must be in one
// place), which runs all the time while it is in memory, and whose SQLite
// storage is the database of Ecto SQLite. All the requests go to the object
// "main" (BEAM_OBJECT names another one).
//
// Tenants: with the var BEAM_TENANTS, each tenant has its own object (its
// own VM, state and SQLite storage), and the request header x-beam-tenant
// gives its name to the app:
// - "cookie": GET /.tenant/NAME sets the cookie beam_tenant, and the cookie
//   names the object (for a workers.dev URL);
// - "host": the first label of the host names the object (NAME.example.com);
// - "path": /t/NAME/... names the object. The front Worker removes the
//   prefix, and the VM gets BEAM_TENANT=NAME and BEAM_TENANT_PATH=/t/NAME,
//   the base path of the URLs that the app writes. A request from an
//   iframe of another site has no cookie, but it has its path.
// A name has 1 to 32 characters: a-z, 0-9 and "-".
//
// Instances (path tenants, with the var BEAM_INSTANCES): each visitor can
// start an instance (the button of the page of /), with a random name and
// a time limit. At the limit, the object deletes its storage and stops.
// The object ".registry" admits the visitors:
// - BEAM_INSTANCES: the instances at one time (then a queue);
// - BEAM_INSTANCE_TTL: the life of an instance in seconds (1800);
// - BEAM_INSTANCE_HOURS: the hours of instances in each UTC day (24), a
//   bound for the Durable Objects of the Free plan;
// - BEAM_INSTANCES_PER_IP: the instances at one time for one address (2).
// The VM gets BEAM_INSTANCE_EXPIRES (Unix seconds). A cron trigger (each
// 30 minutes) calls sweep(): the registry deletes the storage of each
// instance past its limit (if its alarm did not), and once the storage of
// each object that BEAM_RETIRE names ("a,b,c": objects of an earlier mode,
// which the registry did not make).
//
//   wrangler deploy -c wrangler.durable.jsonc
import { DurableObject } from 'cloudflare:workers';
import { Vm, drain } from './worker.js';

const valid = (name) => /^[a-z0-9-]{1,32}$/.test(name ?? '');

// The request to the object stub. workerd pipes the body from the client
// to the object, and that pipe reads on after the response has gone when
// the object stops its read early. The read then fails with no handler:
// "Uncaught TypeError: Can't read from request stream after response has
// been sent". Here the pipe is one of this Worker, with a handler. A
// FixedLengthStream (workerd) keeps the length of the body.
export function forward(stub, request) {
  if (!request.body) return stub.fetch(request);
  const length = Number(request.headers.get('content-length') ?? NaN);
  const pass = Number.isSafeInteger(length) && typeof FixedLengthStream === 'function'
    ? new FixedLengthStream(length) : new TransformStream();
  request.body.pipeTo(pass.writable).catch(() => {});
  return stub.fetch(new Request(request, { body: pass.readable, duplex: 'half' }));
}

// The rest of a request body that no one reads, read and dropped before an
// answer of the host itself (drain of worker.js: 64 MiB at most, and a stop
// after 5 s with no bytes, or after 60 s). workerd cannot read a request
// body after the response has gone, and it then closes the connection with
// the bytes that it did not read: wrangler dev uses that connection again,
// and its next request gets 500.
export async function dropBody(body) {
  if (!body || body.locked) return;
  const reader = body.getReader();
  await drain(() => reader.read(), () => reader.cancel());
}

const REGISTRY = '.registry';
const EXPIRES = 'beam:expires';

export class Beam extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.vm = null;
    this.expires = undefined;
    this.resetting = false;
  }

  // The VM starts at the first request: a path tenant gives its name there.
  // The storage of the object keeps the secrets that the VM makes, and the
  // host of the request is the default PHX_HOST (Vm.autoVars).
  makeVm(vars, host) {
    return new Vm(this.env, { plain: false, sql: this.ctx.storage.sql, id: this.ctx.id.toString(), vars,
                              secrets: this.ctx.storage, host });
  }

  async fetch(request) {
    if (this.resetting) {
      await dropBody(request.body);
      return new Response('The app stopped. Try again.\n',
        { status: 503, headers: { 'content-type': 'text/plain', 'retry-after': '1' } });
    }
    if (this.env.BEAM_INSTANCES && this.env.BEAM_TENANTS === 'path') {
      this.expires ??= (await this.ctx.storage.get(EXPIRES)) ?? null;
      if (!this.expires || this.expires <= Date.now()) {
        if (this.expires) await this.expire();
        await dropBody(request.body);
        return page(410, 'This instance is not available', `<p>An instance stops at its time limit, and its files are deleted.</p>
<form method="post" action="/.instance"><button>Start a new instance</button></form>`);
      }
    }
    if (!this.vm) {
      const vars = {};
      const tenant = request.headers.get('x-beam-tenant');
      if (this.env.BEAM_TENANTS === 'path' && valid(tenant)) {
        vars.BEAM_TENANT = tenant;
        vars.BEAM_TENANT_PATH = `/t/${tenant}`;
      }
      if (this.expires) vars.BEAM_INSTANCE_EXPIRES = String(Math.floor(this.expires / 1000));
      const vm = this.vm = this.makeVm(vars, new URL(request.url).hostname);
      vm.onDead = () => this.vmStopped(vm);
      vm.ready.catch(() => this.vmStopped(vm));
    }
    return this.vm.fetch(request);
  }

  // The VM stopped (erlang:halt, or a trap such as an allocation that
  // failed), or its boot failed. Its open requests got 503. The memory of
  // WebAssembly does not shrink, so the object resets after these answers:
  // a new instance of the object, with a new VM, takes the next request.
  vmStopped(vm) {
    if (this.vm !== vm) return;
    this.vm = null;
    this.resetting = true;
    setTimeout(() => this.reset('the VM stopped'), 100);
  }

  // A new instance of the object. When the host cannot abort the object,
  // the next request starts a new VM in this instance: no request stays
  // at 503.
  reset(reason) {
    try {
      this.ctx.abort(reason);
    } catch (e) {
      console.log(`beam: the object did not reset (${e.message}): the next request starts a new VM`);
      this.resetting = false;
    }
  }

  // An instance: its time limit (from the registry).
  async start(expires) {
    await this.ctx.storage.put(EXPIRES, expires);
    await this.ctx.storage.setAlarm(expires);
    this.expires = expires;
  }

  async alarm() {
    await this.expire();
  }

  // The end of an instance: its storage (the files of BEAM_PERSIST, the
  // database) is deleted, and the VM stops.
  async expire() {
    this.expires = null;
    await this.ctx.storage.deleteAll();
    if (this.vm) setTimeout(() => this.reset('the instance expired'), 0);
  }

  // The registry (the object ".registry") admits a visitor: a ticket and a
  // hash of its address. It gives {name, expires} of a new or running
  // instance, the place in the queue, or a limit.
  async admit(ticket, address) {
    const env = this.env, sql = this.ctx.storage.sql, now = Date.now();
    // A limit that is not a number is the default (NaN would be no limit).
    const max = limit(env.BEAM_INSTANCES, 1);
    const ttl = limit(env.BEAM_INSTANCE_TTL, 1800);
    const hours = limit(env.BEAM_INSTANCE_HOURS, 24);
    const perAddress = limit(env.BEAM_INSTANCES_PER_IP, 2);
    this.tables();
    // A visitor that did not refresh its page for 60 s left the queue.
    sql.exec('DELETE FROM beam_waiting WHERE seen < ?', now - 60000);
    // The rows of the instances past their limit stay until sweep().
    const one = (q, ...a) => [...sql.exec(q, ...a)][0];
    const mine = one('SELECT name, expires FROM beam_instances WHERE ticket = ? AND expires > ?', ticket, now);
    if (mine) return { name: mine.name, expires: mine.expires, running: true };
    const count = one('SELECT count(*) AS n FROM beam_instances WHERE expires > ?', now).n;
    const next = one('SELECT min(expires) AS t FROM beam_instances WHERE expires > ?', now).t;
    if (one('SELECT count(*) AS n FROM beam_instances WHERE address = ? AND expires > ?', address, now).n >= perAddress) {
      return { limit: 'address', next };
    }
    const day = new Date(now).toISOString().slice(0, 10);
    const used = one('SELECT seconds FROM beam_budget WHERE day = ?', day)?.seconds ?? 0;
    if (used + ttl > hours * 3600) return { limit: 'day' };
    // An address has at most perAddress places in the queue, so that one
    // client with many tickets cannot fill it.
    const queued = one('SELECT count(*) AS n FROM beam_waiting WHERE address = ? AND ticket <> ?', address, ticket).n;
    if (queued >= perAddress) return { limit: 'address', next };
    sql.exec('INSERT INTO beam_waiting VALUES (?, ?, ?, ?) ON CONFLICT(ticket) DO UPDATE SET seen = excluded.seen',
      ticket, address, now, now);
    const since = one('SELECT since FROM beam_waiting WHERE ticket = ?', ticket).since;
    const position = one('SELECT count(*) AS n FROM beam_waiting WHERE since < ? OR (since = ? AND ticket < ?)',
      since, since, ticket).n + 1;
    if (position > max - count) {
      return { position, waiting: one('SELECT count(*) AS n FROM beam_waiting').n, next };
    }
    const name = randomName();
    const expires = now + ttl * 1000;
    sql.exec('INSERT INTO beam_instances VALUES (?, ?, ?, ?)', name, ticket, address, expires);
    sql.exec('DELETE FROM beam_waiting WHERE ticket = ?', ticket);
    sql.exec('DELETE FROM beam_budget WHERE day < ?', day);
    sql.exec('INSERT INTO beam_budget VALUES (?, ?) ON CONFLICT(day) DO UPDATE SET seconds = seconds + excluded.seconds',
      day, ttl);
    return { name, expires };
  }

  // The registry: deletes the storage of the instances past their limit,
  // and of the objects that BEAM_RETIRE names (once). Gives the counts.
  async sweep() {
    const env = this.env, sql = this.ctx.storage.sql, now = Date.now();
    this.tables();
    const stub = (name) => env.BEAM.get(env.BEAM.idFromName(name));
    let expired = 0, retired = 0;
    // An error of one object does not stop the sweep of the others.
    for (const { name } of [...sql.exec('SELECT name FROM beam_instances WHERE expires <= ?', now)]) {
      try {
        await stub(name).expire();
        sql.exec('DELETE FROM beam_instances WHERE name = ?', name);
        expired++;
      } catch (e) {
        console.log(`beam: sweep: ${name}: ${e}`);
      }
    }
    const done = new Set([...sql.exec('SELECT name FROM beam_retired')].map((r) => r.name));
    for (const name of (env.BEAM_RETIRE ?? '').split(',').map((n) => n.trim()).filter(valid)) {
      if (done.has(name)) continue;
      try {
        await stub(name).expire();
        sql.exec('INSERT INTO beam_retired VALUES (?, ?)', name, now);
        retired++;
      } catch (e) {
        console.log(`beam: sweep: ${name}: ${e}`);
      }
    }
    return { expired, retired };
  }

  // The registry: the instances in use, for the page of /.
  async usage() {
    this.tables();
    const n = [...this.ctx.storage.sql.exec('SELECT count(*) AS n FROM beam_instances WHERE expires > ?', Date.now())][0].n;
    return { used: n, max: Number(this.env.BEAM_INSTANCES), ttl: Number(this.env.BEAM_INSTANCE_TTL ?? 1800) };
  }

  tables() {
    const sql = this.ctx.storage.sql;
    sql.exec('CREATE TABLE IF NOT EXISTS beam_instances (name TEXT PRIMARY KEY, ticket TEXT, address TEXT, expires INTEGER)');
    sql.exec('CREATE TABLE IF NOT EXISTS beam_waiting (ticket TEXT PRIMARY KEY, address TEXT, since INTEGER, seen INTEGER)');
    sql.exec('CREATE TABLE IF NOT EXISTS beam_budget (day TEXT PRIMARY KEY, seconds INTEGER)');
    sql.exec('CREATE TABLE IF NOT EXISTS beam_retired (name TEXT PRIMARY KEY, time INTEGER)');
  }
}

// 20 characters of a-z and 2-7: 100 random bits.
function randomName() {
  const abc = 'abcdefghijklmnopqrstuvwxyz234567';
  return [...crypto.getRandomValues(new Uint8Array(20))].map((b) => abc[b & 31]).join('');
}

// A limit of the vars: a number of 0 or more, else the default.
function limit(value, fallback) {
  const n = Number(value);
  return value !== undefined && value !== '' && Number.isFinite(n) && n >= 0 ? n : fallback;
}

// The address of a client for its limits: an IPv6 client has a whole /64,
// so the limits count the /64.
function clientKey(ip) {
  if (!ip.includes(':')) return ip;
  const [head, tail = ''] = ip.split('::');
  const h = head ? head.split(':') : [], t = tail ? tail.split(':') : [];
  const all = ip.includes('::') ? [...h, ...Array(8 - h.length - t.length).fill('0'), ...t] : h;
  return all.slice(0, 4).map((x) => x.toLowerCase().replace(/^0+(?=.)/, '')).join(':') + '::/64';
}

const hex = (bytes) => [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');

function cookie(request, name) {
  return new RegExp(`(?:^|;\\s*)${name}=([^;]*)`).exec(request.headers.get('cookie') ?? '')?.[1];
}

function tenant(request, env) {
  if (env.BEAM_TENANTS === 'host') return new URL(request.url).hostname.split('.')[0];
  if (env.BEAM_TENANTS === 'cookie') return cookie(request, 'beam_tenant');
  return null;
}

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

function page(status, title, body, headers = {}) {
  return new Response(`<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>${esc(title)}</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:40rem;margin:4rem auto;padding:0 1rem;color:#1f2937}
button{font:inherit;padding:.5rem 1rem;border-radius:.5rem;border:0;background:#4f46e5;color:#fff;cursor:pointer}</style>
</head><body><h1>${esc(title)}</h1>${body}</body></html>`,
  { status, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', ...headers } });
}

const minutes = (ms) => Math.max(1, Math.ceil(ms / 60000));

// A static file of the app, in the front Worker (no request to the
// object): BEAM_STATICS (serve(app) of the npm package gives it, for the
// static files in app.com), else, with assets, the static assets of the
// binding ASSETS (wasm/erts/host/static.mjs). Cloudflare serves the
// assets of the root before the Worker runs, so only a path tenant asks
// ASSETS (after its prefix).
async function staticFile(env, request, assets = false) {
  if (request.method !== 'GET' && request.method !== 'HEAD') return null;
  if (env.BEAM_STATICS) return env.BEAM_STATICS(request);
  if (!assets || !env.ASSETS) return null;
  const asset = await env.ASSETS.fetch(request);
  return asset.status !== 404 ? asset : null;
}

// The instances: the page of /, and POST (the button) or GET (the refresh
// of the queue) of /.instance. Only a POST makes a ticket, so a crawler
// that reads / starts no instance.
async function instances(request, env, url) {
  const registry = env.BEAM.get(env.BEAM.idFromName(REGISTRY));
  if (url.pathname === '/' && request.method === 'GET') {
    const { used, max, ttl } = await registry.usage();
    return page(200, env.BEAM_INSTANCE_TITLE ?? 'Start an instance', `<p>Each visitor gets an instance of its own, for ${minutes(ttl * 1000)} minutes.
At the end, the instance stops, and its files are deleted.</p>
<p>${used} of ${max} instances are in use.</p>
<form method="post" action="/.instance"><button>Start an instance</button></form>`);
  }
  if (url.pathname !== '/.instance' || (request.method !== 'POST' && request.method !== 'GET')) {
    return new Response('not found\n', { status: 404 });
  }
  // Only the navigation of a page (the button, the refresh) gets the name
  // of an instance: a script of a page of another instance, on this same
  // origin, cannot read it with fetch().
  const mode = request.headers.get('sec-fetch-mode');
  if (mode && mode !== 'navigate') return new Response('forbidden\n', { status: 403 });
  let ticket = cookie(request, 'beam_ticket');
  const headers = {};
  if (!/^[0-9a-f]{32}$/.test(ticket ?? '')) {
    if (request.method === 'GET') return Response.redirect(new URL('/', url), 303);
    ticket = hex(crypto.getRandomValues(new Uint8Array(16)));
    headers['set-cookie'] = `beam_ticket=${ticket}; Path=/; Secure; HttpOnly; SameSite=Lax`;
  }
  // A hash of the address and the day, not the address.
  const day = new Date().toISOString().slice(0, 10);
  const digest = await crypto.subtle.digest('SHA-256',
    new TextEncoder().encode(`${clientKey(request.headers.get('cf-connecting-ip') ?? '')} ${day}`));
  const r = await registry.admit(ticket, hex(new Uint8Array(digest).slice(0, 16)));
  if (r.name) {
    if (!r.running) await env.BEAM.get(env.BEAM.idFromName(r.name)).start(r.expires);
    return new Response(null, { status: 303, headers: { ...headers, location: `/t/${r.name}/` } });
  }
  if (r.limit === 'day') {
    return page(503, 'No more instances today', '<p>The instances of today are used. They start again at 00:00 UTC.</p>', headers);
  }
  const wait = r.next ? `The next instance stops in about ${minutes(r.next - Date.now())} minutes.` : '';
  if (r.limit === 'address') {
    return page(429, 'Too many instances', `<p>Your address has the most instances that it can have at one time. ${wait}</p>`, headers);
  }
  return page(200, 'You are in the queue', `<p>Your place: ${r.position} of ${r.waiting}. ${wait}</p>
<p>This page refreshes each 10 seconds. Keep it open to keep your place.</p>`,
  { ...headers, refresh: '10; url=/.instance' });
}

const front = {
  // The cron trigger of the instances (see sweep()).
  async scheduled(controller, env, ctx) {
    if (!env.BEAM_INSTANCES) return;
    const registry = env.BEAM.get(env.BEAM.idFromName(REGISTRY));
    ctx.waitUntil(registry.sweep().then((r) => console.log(`beam: sweep: ${r.expired} expired, ${r.retired} retired`)));
  },

  // The answers of the front itself (a page, a redirect, an error, a
  // static file) read the rest of the body first. forward() pipes the body
  // to the object, and so locks it.
  async fetch(request, env) {
    const body = request.body;
    const response = await front.route(request, env);
    await dropBody(body);
    return response;
  },

  // The route of a request: an answer of the front, or the response of the
  // object of the tenant.
  async route(request, env) {
    const url = new URL(request.url);
    if (env.BEAM_TENANTS === 'path') {
      const m = /^\/t\/([^/]+)(\/.*)?$/.exec(url.pathname);
      if (!m) {
        // A path of the app with no prefix (Livebook writes some so).
        const asset = await staticFile(env, request);
        if (asset) return asset;
        if (env.BEAM_INSTANCES) return instances(request, env, url);
        return new Response('not found\n', { status: 404 });
      }
      if (!valid(m[1])) return new Response('bad tenant name\n', { status: 400 });
      if (m[2] === undefined) return Response.redirect(new URL(`/t/${m[1]}/`, url), 301);
      // The path of the app, with no prefix, on the same origin (a path
      // "//host/..." must not change the host).
      const inner = new URL(url);
      inner.pathname = m[2];
      const asset = await staticFile(env, new Request(inner, request), true);
      if (asset) return asset;
      // All the tenants share this origin. A service worker of one tenant
      // could take the requests of the others, so none can register.
      if (request.headers.get('service-worker') === 'script') {
        return new Response('no service workers for tenants\n', { status: 403 });
      }
      // The app can trust the header: a client cannot give it.
      request = new Request(inner, request);
      request.headers.set('x-beam-tenant', m[1]);
      const response = await forward(env.BEAM.get(env.BEAM.idFromName(m[1])), request);
      if (!response.headers.has('service-worker-allowed')) return response;
      const out = new Response(response.body, response);
      out.headers.delete('service-worker-allowed');
      return out;
    }
    const set = env.BEAM_TENANTS === 'cookie' && /^\/\.tenant\/([^/]+)$/.exec(url.pathname);
    if (set) {
      if (!valid(set[1])) return new Response('bad tenant name\n', { status: 400 });
      return new Response(null, {
        status: 303,
        headers: { location: '/', 'set-cookie': `beam_tenant=${set[1]}; Path=/; Secure; HttpOnly; SameSite=Lax` },
      });
    }
    const asset = await staticFile(env, request);
    if (asset) return asset;
    let name = env.BEAM_OBJECT ?? 'main';
    const t = tenant(request, env);
    if (t !== undefined && t !== null && !valid(t)) return new Response('bad tenant name\n', { status: 400 });
    name = t ?? name;
    request = new Request(request);
    if (env.BEAM_TENANTS) request.headers.set('x-beam-tenant', name);
    else request.headers.delete('x-beam-tenant');
    return forward(env.BEAM.get(env.BEAM.idFromName(name)), request);
  },
};

export default front;
