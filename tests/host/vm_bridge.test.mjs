// Vm.bridge of worker.js: the request that the HTTP server of the app gets
// on its TCP connection. "node --test tests/host". The imports of the
// runtime are stand-ins, because these tests do not start a VM.
import { register } from 'node:module';
import { test } from 'node:test';
import assert from 'node:assert/strict';

register(`data:text/javascript,${encodeURIComponent(`
  const stub = { './beam.mjs': 'export default () => {};', './beam.wasm': 'export default null;' };
  export async function resolve(spec, ctx, next) {
    return spec in stub ? { url: 'data:text/javascript,' + encodeURIComponent(stub[spec]), shortCircuit: true }
                        : next(spec, ctx);
  }`)}`);
const { Vm } = await import('../../priv/wasm_host/worker/worker.js');

// The head of the request that bridge() gives to the app, as lines.
async function head(request, { scheme = true } = {}) {
  const vm = Object.create(Vm.prototype);
  const sent = [];
  Object.assign(vm, {
    env: {}, vars: {}, scheme, nextId: 0, tcps: new Map(), listeners: new Map([[4000, 'l0']]),
    listening: async () => {},
    event: (header, body) => sent.push({ header, body }),
  });
  vm.bridge(request, new URL(request.url), false, undefined, () => {});
  for (let i = 0; i < 100 && !sent.some((s) => s.header.t === 'tcp_data'); i++) await null;
  const data = sent.find((s) => s.header.t === 'tcp_data');
  assert.ok(data, 'no bytes for the app');
  const text = new TextDecoder().decode(data.body);
  return text.slice(0, text.indexOf('\r\n\r\n')).split('\r\n');
}

test('x-forwarded-proto is the scheme of the client', async () => {
  assert.ok((await head(new Request('https://app.example.com/a?b=1'))).includes('x-forwarded-proto: https'));
  assert.ok((await head(new Request('http://localhost:8787/'))).includes('x-forwarded-proto: http'));
});

test('the value of the Worker replaces the x-forwarded-proto of a client', async () => {
  const lines = await head(new Request('http://localhost:8787/', { headers: { 'x-forwarded-proto': 'https' } }));
  assert.deepEqual(lines.filter((l) => l.startsWith('x-forwarded-proto:')), ['x-forwarded-proto: http']);
});

// The web page (browser.js) asks for http://localhost and gives https, so
// that an app with force_ssl does not redirect to https://localhost/.
test('with scheme: false, the x-forwarded-proto of the host stays', async () => {
  const request = new Request('http://localhost/', { headers: { 'x-forwarded-proto': 'https' } });
  const lines = await head(request, { scheme: false });
  assert.deepEqual(lines.filter((l) => l.startsWith('x-forwarded-proto:')), ['x-forwarded-proto: https']);
});

test('the request line and the host', async () => {
  const lines = await head(new Request('https://app.example.com/a?b=1'));
  assert.equal(lines[0], 'GET /a?b=1 HTTP/1.1');
  assert.ok(lines.includes('host: app.example.com'));
});
