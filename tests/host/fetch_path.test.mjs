// The fetch path of worker.js (specs/FetchPath.tla, wasm_host_fetch.erl):
// the ranges of Cloudflare, the URL of a request, the choice of the
// fallback in tcpConnect, the pair of sockets, and fetchRequest.
// "node --test tests/host". The imports of the runtime and node:net are
// stand-ins: these tests start no VM and open no connection.
import { register } from 'node:module';
import { test } from 'node:test';
import assert from 'node:assert/strict';

register(`data:text/javascript,${encodeURIComponent(`
  const net = \`
    import { EventEmitter } from 'node:events';
    // A connect() that opens for "open.example", and else fails as connect()
    // of Cloudflare does for any host on port 443.
    export default {
      connect({ host }) {
        const s = new EventEmitter();
        s.write = (b, cb) => cb?.();
        s.end = (cb) => cb?.();
        s.destroy = () => {};
        setTimeout(() => host === 'open.example'
          ? s.emit('connect')
          : s.emit('error', new Error('proxy request failed, cannot connect to the specified address')));
        return s;
      },
    };\`;
  const stub = { './beam.mjs': 'export default () => {};', './beam.wasm': 'export default null;', 'node:net': net };
  export async function resolve(spec, ctx, next) {
    return spec in stub ? { url: 'data:text/javascript,' + encodeURIComponent(stub[spec]), shortCircuit: true }
                        : next(spec, ctx);
  }`)}`);
const { Vm, inRanges, ipBits, fetchUrl, connectAllowed } = await import('../../priv/wasm_host/worker/worker.js');

test('the ranges of Cloudflare', () => {
  for (const a of ['104.16.0.1', '172.67.1.2', '1.1.1.1', '2606:4700::6810:84e5', '[2606:4700::1]', '::ffff:104.16.0.1']) {
    assert.ok(inRanges(a), a);
  }
  for (const a of ['140.82.112.3', '127.0.0.1', '10.255.255.1', '2001:db8::1', 'api.cloudflare.com', '1.2.3']) {
    assert.ok(!inRanges(a), a);
  }
  assert.equal(ipBits('::1').bits, 1n);
  assert.equal(ipBits('1:2:3:4:5:6:7:8').size, 128);
  assert.equal(ipBits('1:2:3'), null);
  assert.equal(ipBits('256.1.1.1'), null);
});

test('the URL is the host and the port of the connect, and the path', () => {
  assert.equal(fetchUrl('api.cloudflare.com', 443, true, '/client/v4/ips?a=1'), 'https://api.cloudflare.com/client/v4/ips?a=1');
  assert.equal(fetchUrl('example.com', 80, false, '/'), 'http://example.com/');
  assert.equal(fetchUrl('example.com', 8443, true, '/x'), 'https://example.com:8443/x');
  assert.equal(fetchUrl('2606:4700::1', 443, true, '/'), 'https://[2606:4700::1]/');
  for (const path of ['//evil.example/x', '@evil.example/x', 'http://evil.example/', '', undefined]) {
    assert.equal(fetchUrl('api.cloudflare.com', 443, true, path), null, String(path));
  }
});

// A Vm with stand-ins for the VM: the events that it gets.
function vm(env = {}) {
  const v = Object.create(Vm.prototype);
  const events = [];
  Object.assign(v, {
    env, plain: false, nextId: 1, tcps: new Map(), listeners: new Map(), fetchConns: new Map(),
    fetches: new Map(), dns: new Map(), fetchPending: 0, handlers: [],
    event: (header, body) => events.push({ ...header, body: body && new TextDecoder().decode(body) }),
  });
  return { v, events };
}

const tick = () => new Promise((r) => setTimeout(r, 5));

test('the listener of wasm_host_fetch is apart from the ports, and says if the VM trusts its CA', () => {
  const { v, events } = vm();
  const msg = (m) => new TextEncoder().encode(JSON.stringify(m) + '\n');
  v.onsend(msg({ t: 'tcp_listen', id: 'l1', port: 0, fetch: true }));
  assert.equal(v.listeners.get('fetch'), 'l1');
  assert.equal(v.listeners.has('fetch-tls'), false);
  assert.equal(v.listeners.has(0), false);
  assert.deepEqual(events.map((e) => e.t), ['tcp_listening']);
  v.onsend(msg({ t: 'tcp_unlisten', id: 'l1' }));
  assert.equal(v.listeners.has('fetch'), false);
  v.onsend(msg({ t: 'tcp_listen', id: 'l2', port: 0, fetch: true, tls: true }));
  assert.equal(v.listeners.get('fetch-tls'), 'l2');
  v.onsend(msg({ t: 'tcp_unlisten', id: 'l2' }));
  assert.equal(v.listeners.size, 0);
});

test('the rules of BEAM_CONNECT and BEAM_FETCH', () => {
  assert.ok(connectAllowed(undefined, 'a.example', 1));
  assert.ok(!connectAllowed('', 'a.example', 80));
  assert.ok(connectAllowed('*', 'a.example', 5432));
  assert.ok(connectAllowed('*:443', 'A.Example.', 443));
  assert.ok(!connectAllowed('*:443', 'a.example', 80));
  assert.ok(connectAllowed('db.local, *.example.com', 'api.example.com', 1));
  assert.ok(!connectAllowed('*.example.com', 'example.org', 1));
});

// The route of a connect: fetch() first, or connect(). open.example is up,
// so connect() gives tcp_open only, and fetch() gives tcp_open and
// tcp_accept.
test('fetch first: port 80, port 443 when the VM trusts its CA, BEAM_FETCH, and direct', async () => {
  for (const [env, port, tls, direct, route] of [
    [{}, 80, false, false, 'fetch'],
    [{}, 443, false, false, 'connect'],
    [{}, 443, true, false, 'fetch'],
    [{}, 5432, true, false, 'connect'],
    [{}, 80, true, true, 'connect'],
    [{ BEAM_HOST: 'deno' }, 80, false, false, 'fetch'],
    [{ BEAM_FETCH: '' }, 80, true, false, 'connect'],
    [{ BEAM_FETCH: 'open.example:8080' }, 8080, false, false, 'fetch'],
    [{ BEAM_FETCH: 'open.example:8080' }, 80, false, false, 'connect'],
    [{ BEAM_CONNECT: 'other.example' }, 80, true, false, 'none'],
  ]) {
    const { v, events } = vm(env);
    v.listeners.set('fetch', 'lf');
    if (tls) v.listeners.set('fetch-tls', 'lf');
    v.tcpConnect({ id: 't1', host: 'open.example', port, direct });
    for (let i = 0; i < 200 && events.length === 0; i++) await tick();
    await tick();
    const got = events.map((e) => e.t).join(',');
    const want = { fetch: 'tcp_open,tcp_accept', connect: 'tcp_open', none: 'tcp_error' }[route];
    assert.equal(got, want, JSON.stringify([env, port, tls, direct]));
  }
});

test('a refused connect to a host of Cloudflare joins the fetch listener', async () => {
  const { v, events } = vm();
  v.listeners.set('fetch', 'lf');
  v.tcpConnect({ id: 't1', host: '104.16.0.1', port: 443 });
  for (let i = 0; i < 200 && !events.some((e) => e.t === 'tcp_accept'); i++) await tick();
  assert.deepEqual(events.map((e) => e.t), ['tcp_open', 'tcp_accept']);
  const conn = events[1].conn;
  assert.deepEqual(events[1], { t: 'tcp_accept', id: 'lf', conn, host: '104.16.0.1', port: 443, ack: true, sent: true, body: undefined });
  // The bytes of each side go to the other side.
  v.tcps.get('t1').send(new TextEncoder().encode('hello'));
  v.tcps.get(conn).send(new TextEncoder().encode('world'));
  assert.deepEqual(events.slice(2), [
    { t: 'tcp_data', id: conn, body: 'hello' },
    { t: 'tcp_data', id: 't1', body: 'world' },
  ]);
  // A close of one side ends both: the other side gets tcp_closed.
  v.tcps.get('t1').close();
  assert.deepEqual(events.at(-1), { t: 'tcp_closed', id: conn, body: undefined });
  assert.equal(v.tcps.size, 0);
  assert.equal(v.fetchConns.size, 0);
});

test('no fallback for a host that is not of Cloudflare, out of BEAM_CONNECT, on another port, or off Cloudflare', async () => {
  for (const [env, host, port] of [
    [{}, '140.82.112.3', 443],
    [{ BEAM_CONNECT: 'example.com' }, '104.16.0.1', 443],
    [{}, '104.16.0.1', 5432],
    [{ BEAM_HOST: 'deno' }, '104.16.0.1', 443],
  ]) {
    const { v, events } = vm(env);
    v.listeners.set('fetch', 'lf');
    await v.tcpConnect({ id: 't1', host, port });
    assert.deepEqual(events.map((e) => e.t), ['tcp_error'], JSON.stringify([env, host, port]));
  }
});

test('the name of a host: its addresses from DNS over HTTPS, in a cache', async () => {
  const { v } = vm();
  const asked = [];
  const old = globalThis.fetch;
  globalThis.fetch = async (url) => {
    asked.push(String(url));
    const type = new URL(url).searchParams.get('type');
    const Answer = type === 'A' ? [{ type: 5, data: 'x.cdn.example.' }, { type: 1, data: '104.18.1.1' }] : [];
    return Response.json({ Answer });
  };
  try {
    assert.ok(await v.isCloudflare('API.Example.com.'));
    assert.ok(await v.isCloudflare('api.example.com'));
    assert.equal(asked.length, 2);
    assert.match(asked[0], /^https:\/\/cloudflare-dns\.com\/dns-query\?name=api\.example\.com&type=A$/);
  } finally {
    globalThis.fetch = old;
  }
});

test('BEAM_FETCH sends a host through fetch() with no connect', async () => {
  const { v, events } = vm({ BEAM_FETCH: '*.example.com,local.test:8080' });
  v.listeners.set('fetch', 'lf');
  v.tcpConnect({ id: 't1', host: 'local.test', port: 8080 });
  await tick();
  assert.deepEqual(events.map((e) => e.t), ['tcp_open', 'tcp_accept']);
});

test('fetchRequest: the URL of the connect, the headers, the body, and the response', async () => {
  const { v, events } = vm();
  v.fetchConns.set('x1', { host: 'api.cloudflare.com', port: 443 });
  const old = globalThis.fetch;
  let got;
  globalThis.fetch = async (url, init) => {
    got = { url, method: init.method, auth: init.headers.get('authorization'), redirect: init.redirect,
            body: init.body && new TextDecoder().decode(init.body) };
    const headers = new Headers([['content-type', 'application/json'], ['content-encoding', 'gzip']]);
    headers.append('set-cookie', 'a=1');
    headers.append('set-cookie', 'b=2');
    return new Response('{"ok":true}', { status: 201, statusText: 'Created', headers });
  };
  try {
    await v.fetchRequest({ id: 'f1', conn: 'x1', tls: true, method: 'POST', path: '/v4/x?y=1',
                           headers: [['authorization', 'Bearer t']] }, new TextEncoder().encode('{}'));
  } finally {
    globalThis.fetch = old;
  }
  assert.deepEqual(got, { url: 'https://api.cloudflare.com/v4/x?y=1', method: 'POST', auth: 'Bearer t',
                          redirect: 'manual', body: '{}' });
  const head = events[0];
  assert.equal(head.t, 'fetch_head');
  assert.equal(head.status, 201);
  assert.deepEqual(head.headers.filter(([k]) => k === 'set-cookie'), [['set-cookie', 'a=1'], ['set-cookie', 'b=2']]);
  assert.deepEqual(events.slice(1).map((e) => [e.t, e.body]), [['fetch_data', '{"ok":true}'], ['fetch_end', undefined]]);
  assert.equal(v.fetchPending, 0);
});

test('fetchRequest: no connection, a bad path, and a failure of fetch()', async () => {
  const { v, events } = vm();
  v.fetchConns.set('x1', { host: 'api.cloudflare.com', port: 443 });
  const old = globalThis.fetch;
  globalThis.fetch = async () => { throw new Error('network down'); };
  try {
    await v.fetchRequest({ id: 'f1', conn: 'nope', tls: true, method: 'GET', path: '/' });
    await v.fetchRequest({ id: 'f2', conn: 'x1', tls: true, method: 'GET', path: '@evil.example/' });
    await v.fetchRequest({ id: 'f3', conn: 'x1', tls: true, method: 'GET', path: '/' });
  } finally {
    globalThis.fetch = old;
  }
  assert.deepEqual(events.map((e) => [e.t, e.id, e.message]), [
    ['fetch_error', 'f1', 'no connection'],
    ['fetch_error', 'f2', 'the path is not a path of the host'],
    ['fetch_error', 'f3', 'network down'],
  ]);
});

test('a snapshot waits while a fetch() runs', async () => {
  const { v } = vm();
  v.fetchConns.set('x1', { host: 'api.cloudflare.com', port: 443 });
  const old = globalThis.fetch;
  let release;
  globalThis.fetch = () => new Promise((r) => { release = () => r(new Response('')); });
  try {
    const p = v.fetchRequest({ id: 'f1', conn: 'x1', tls: true, method: 'GET', path: '/' });
    await tick();
    assert.equal(v.fetchPending, 1);
    release();
    await p;
    assert.equal(v.fetchPending, 0);
  } finally {
    globalThis.fetch = old;
  }
});

test('the end of a fetch connection stops its fetches, and only them', async () => {
  const { v, events } = vm();
  v.listeners.set('fetch', 'lf');
  v.tcpConnect({ id: 't1', host: '104.16.0.1', port: 443 });
  for (let i = 0; i < 200 && !events.some((e) => e.t === 'tcp_accept'); i++) await tick();
  const conn = events.find((e) => e.t === 'tcp_accept').conn;
  v.fetchConns.set('x99', { host: 'api.cloudflare.com', port: 443 });
  const old = globalThis.fetch;
  globalThis.fetch = (url, init) => new Promise((_, reject) => {
    init.signal.addEventListener('abort', () => reject(new Error('aborted')));
  });
  try {
    const mine = v.fetchRequest({ id: 'f1', conn, tls: true, method: 'GET', path: '/' });
    v.fetchRequest({ id: 'f2', conn: 'x99', tls: true, method: 'GET', path: '/' });
    await tick();
    v.tcps.get('t1').close();
    await mine;
    assert.ok(events.some((e) => e.t === 'fetch_error' && e.id === 'f1'));
    assert.ok(!events.some((e) => e.id === 'f2'), 'the fetch of another connection stopped');
    assert.deepEqual([...v.fetches.keys()], ['f2']);
    v.fetches.get('f2').abort();
  } finally {
    globalThis.fetch = old;
  }
});

test('the cache of names holds at most 1024 names, and a new name removes the oldest', async () => {
  const { v } = vm();
  const old = globalThis.fetch;
  globalThis.fetch = async () => Response.json({ Answer: [] });
  try {
    for (let i = 0; i < 1030; i++) await v.isCloudflare(`h${i}.example.com`);
    assert.equal(v.dns.size, 1024);
    assert.ok(!v.dns.has('h5.example.com'));
    assert.ok(v.dns.has('h6.example.com'));
    assert.ok(v.dns.has('h1029.example.com'));
  } finally {
    globalThis.fetch = old;
  }
});
