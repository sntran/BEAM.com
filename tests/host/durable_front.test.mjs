// forward() of durable.js: the request of the front Worker to the object,
// with a body that the front pipes. "node --test tests/host". The imports
// of the runtime are stand-ins.
import { register } from 'node:module';
import { test } from 'node:test';
import assert from 'node:assert/strict';

register(`data:text/javascript,${encodeURIComponent(`
  const stub = {
    './beam.mjs': 'export default () => {};',
    './beam.wasm': 'export default null;',
    'cloudflare:workers': 'export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }',
  };
  export async function resolve(spec, ctx, next) {
    return spec in stub ? { url: 'data:text/javascript,' + encodeURIComponent(stub[spec]), shortCircuit: true }
                        : next(spec, ctx);
  }`)}`);
const { default: front, forward, Beam } = await import('../../priv/wasm_host/worker/durable.js');

const settle = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)); };

test('the object gets the body and the headers of the request', async () => {
  const object = {
    async fetch(request) {
      const body = new Uint8Array(await request.arrayBuffer());
      return new Response(`${request.method} ${request.headers.get('x-a')} ${body.length}`);
    },
  };
  const request = new Request('https://app.example.com/upload', {
    method: 'POST', body: new Uint8Array(100000), headers: { 'x-a': 'b' },
  });
  assert.equal(await (await forward(object, request)).text(), 'POST b 100000');
});

test('a request with no body goes as it is', async () => {
  const request = new Request('https://app.example.com/');
  const object = { fetch: (r) => { assert.equal(r, request); return new Response('ok'); } };
  assert.equal(await (await forward(object, request)).text(), 'ok');
});

// workerd: a read of the body after the response has gone fails. That
// error has a handler: node --test fails a test with an unhandled
// rejection.
test('an error of the body after the answer of the object has a handler', async () => {
  let ctl;
  const body = new ReadableStream({ start(c) { ctl = c; } });
  const object = {
    async fetch(request) {
      await request.body.getReader().read();
      return new Response('too large', { status: 413 });
    },
  };
  ctl.enqueue(new Uint8Array(10));
  const request = new Request('https://app.example.com/upload', { method: 'POST', body, duplex: 'half' });
  assert.equal((await forward(object, request)).status, 413);
  ctl.error(new TypeError("Can't read from request stream after response has been sent."));
  await settle();
});

// A body of n chunks; read() tells how many of them the host read, and
// cancelled() if the host cancelled it.
function body(n, size = 1000) {
  let pulled = 0, cancelled = false;
  const stream = new ReadableStream({
    pull(c) { if (pulled < n) { pulled++; c.enqueue(new Uint8Array(size)); } else c.close(); },
    cancel() { cancelled = true; },
  }, { highWaterMark: 0 });
  return { stream, read: () => pulled, cancelled: () => cancelled };
}
const post = (url, b, headers = {}) => new Request(url, { method: 'POST', body: b.stream, duplex: 'half', headers });

// wrangler dev: the next request on the connection of an answer that did
// not read the body got 500 (the problem of 0.1.0-rc.4).
test('the answers of the front read the whole body first', async () => {
  for (const [env, url, status] of [
    [{ BEAM_TENANTS: 'path' }, 'https://app.example.com/x', 404],
    [{ BEAM_TENANTS: 'path' }, 'https://app.example.com/t/Bad!/x', 400],
    [{ BEAM_TENANTS: 'path' }, 'https://app.example.com/t/one', 301],
    [{ BEAM_TENANTS: 'cookie' }, 'https://app.example.com/.tenant/Bad!', 400],
    [{ BEAM_TENANTS: 'cookie' }, 'https://app.example.com/.tenant/one', 303],
    [{ BEAM_TENANTS: 'host' }, 'https://Bad!.example.com/', 400],
  ]) {
    const b = body(20);
    const r = await front.fetch(post(url, b), env);
    assert.equal(r.status, status, url);
    assert.equal(b.read(), 20, url);
    assert.equal(b.cancelled(), false, url);
  }
});

test('a request that goes to the object keeps its body for the object', async () => {
  const b = body(5);
  let got = 0;
  const object = { async fetch(request) { got = (await request.arrayBuffer()).byteLength; return new Response('ok'); } };
  const env = { BEAM_TENANTS: 'path', BEAM: { idFromName: (n) => n, get: () => object } };
  const r = await front.fetch(post('https://app.example.com/t/one/x', b), env);
  assert.equal(await r.text(), 'ok');
  assert.equal(got, 5000);
});

test('the object reads the whole body before its 503 while it resets, and before the 410 of an instance', async () => {
  const resetting = new Beam({}, {});
  resetting.resetting = true;
  const b = body(20);
  const r = await resetting.fetch(post('https://app.example.com/x', b));
  assert.equal(r.status, 503);
  assert.equal(b.read(), 20);
  const instance = new Beam({ storage: { get: async () => null } }, { BEAM_INSTANCES: '1', BEAM_TENANTS: 'path' });
  const b2 = body(20);
  const r2 = await instance.fetch(post('https://app.example.com/x', b2));
  assert.equal(r2.status, 410);
  assert.equal(b2.read(), 20);
});
