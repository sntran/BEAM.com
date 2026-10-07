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
const { forward } = await import('../../priv/wasm_host/worker/durable.js');

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
