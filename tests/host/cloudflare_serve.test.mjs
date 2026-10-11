// serve(app) of the npm package in a Worker (cloudflare/index.js), with
// the binding of a Durable Object. "node --test tests/host". The imports
// of the runtime and of workerd are stand-ins: these tests start no VM.
import { register } from 'node:module';
import { test } from 'node:test';
import assert from 'node:assert/strict';

register(`data:text/javascript,${encodeURIComponent(`
  const stub = {
    './beam.mjs': 'export default () => {};',
    './beam.wasm': 'export default null;',
    '../runtime-id.js': 'export default "test";',
    'cloudflare:workers': 'export const env = {}; export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }',
  };
  export async function resolve(spec, ctx, next) {
    if (spec in stub) return { url: 'data:text/javascript,' + encodeURIComponent(stub[spec]), shortCircuit: true };
    // The npm package has copies of worker.js and durable.js in cloudflare/.
    if (ctx.parentURL?.endsWith('/cloudflare/index.js') && (spec === './worker.js' || spec === './durable.js')) {
      return { url: new URL('.' + spec, ctx.parentURL).href, shortCircuit: true };
    }
    return next(spec, ctx);
  }`)}`);
const { serve } = await import('../../priv/wasm_host/worker/cloudflare/index.js');

// The object of the name: it gives the tenant header and the body that it got.
const object = (names) => ({
  getByName(n) {
    names.push(n);
    return {
      async fetch(request) {
        return Response.json({ tenant: request.headers.get('x-beam-tenant'), body: await request.text() });
      },
    };
  },
});

test('a name function: the object gets no x-beam-tenant of the client, and the body', async () => {
  const names = [];
  const beam = serve(new Uint8Array(0), { name: (request) => new URL(request.url).pathname.split('/')[1] });
  const request = new Request('https://app.example.com/one/x', {
    method: 'POST', body: 'hello', headers: { 'x-beam-tenant': 'admin' },
  });
  const r = await beam.fetch(request, { BEAM: object(names) }, {});
  assert.deepEqual(await r.json(), { tenant: null, body: 'hello' });
  assert.deepEqual(names, ['one']);
});

test('a name function with BEAM_TENANTS = "path": still no x-beam-tenant of the client', async () => {
  const beam = serve(new Uint8Array(0), { name: () => 'main' });
  const request = new Request('https://app.example.com/', { headers: { 'x-beam-tenant': 'other' } });
  const r = await beam.fetch(request, { BEAM: object([]), BEAM_TENANTS: 'path' }, {});
  assert.equal((await r.json()).tenant, null);
});

test('a static file from the front, with no read of the other files of the release', async () => {
  const { zip } = await import('./zip.mjs');
  // A Phoenix app whose .beam file has a bad CRC-32: only a full read of
  // the release (a VM) checks it.
  const app = await zip([
    { name: 'lib/web-1.0/ebin/web.beam', data: 'not checked by the front', crc: 1234 },
    { name: 'lib/web-1.0/priv/static/app.js', data: 'console.log(1)', method: 8 },
    { name: '.wasm/.release.json', data: JSON.stringify({ name: 'web', vsn: '1.0', runtime: 'test', env: { PHX_SERVER: 'true' } }) },
  ]);
  const beam = serve(app);
  const objects = { get() { throw new Error('no request to the object'); }, idFromName: () => 'main' };
  const r = await beam.fetch(new Request('https://app.example.com/app.js'), { BEAM: objects }, { waitUntil() {} });
  assert.equal(r.status, 200);
  assert.equal(await r.text(), 'console.log(1)');
});
