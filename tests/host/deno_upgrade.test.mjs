// The upgrade of a WebSocket in Deno (WebSocketPair of deno.js): the
// subprotocol of the 101 of the app goes to Deno.upgradeWebSocket, and its
// other headers go to the response of Deno. "node --test tests/host". Deno
// and the VM are stand-ins: deno/worker.js gives the 101 of the test.
import { register } from 'node:module';
import { test } from 'node:test';
import assert from 'node:assert/strict';

register(`data:text/javascript,${encodeURIComponent(`
  const vm = 'export class Vm { constructor() { this.ready = Promise.resolve(); } fetch(r) { return globalThis.app(r); } }';
  export async function resolve(spec, ctx, next) {
    return spec === './deno/worker.js' && ctx.parentURL?.endsWith('/deno/deno.js')
      ? { url: 'data:text/javascript,' + encodeURIComponent(vm), shortCircuit: true }
      : next(spec, ctx);
  }`)}`);

const NodeResponse = globalThis.Response;
// Deno.upgradeWebSocket as Deno 2.9 has it: a protocol must be in the list
// of the client, split at ", ", and the headers of its response can change
// until the handler returns it (immutable: they cannot).
const calls = [];
let immutable = false;
globalThis.Deno = {
  env: { get: () => undefined, toObject: () => ({ BEAM_SQLITE: 'off' }) },
  openKv: async () => null,
  readDirSync: () => { throw new Error('no static files'); },
  upgradeWebSocket(request, options = {}) {
    calls.push(options);
    const offered = (request.headers.get('sec-websocket-protocol') ?? '').split(', ');
    if (options.protocol && !offered.includes(options.protocol)) {
      throw new TypeError(`Protocol '${options.protocol}' not in the request's protocol list (non negotiable)`);
    }
    const response = new NodeResponse(null, { headers: options.protocol ? { 'sec-websocket-protocol': options.protocol } : {} });
    if (immutable) Object.defineProperty(response, 'headers', { value: { append() { throw new TypeError('Headers are immutable.'); } } });
    const socket = Object.assign(new EventTarget(), { readyState: 0, send() {}, close() {} });
    return { socket, response };
  },
};
globalThis.addEventListener ??= () => {};
const { default: handler } = await import('../../priv/wasm_host/deno/deno.js');

// The app answers the upgrade with a 101 of these headers.
function app(headers) {
  globalThis.app = () => {
    const [client] = Object.values(new WebSocketPair());
    return new Response(null, { status: 101, webSocket: client, headers });
  };
}
const ask = (protocols) => handler.fetch(new Request('http://localhost/socket', {
  headers: { upgrade: 'websocket', ...(protocols ? { 'sec-websocket-protocol': protocols } : {}) },
}));

test('the subprotocol of the app goes to Deno.upgradeWebSocket, and its cookies to the response', async () => {
  calls.length = 0;
  const headers = new Headers({ 'sec-websocket-protocol': 'graphql-transport-ws', 'x-app': 'yes' });
  headers.append('set-cookie', 'a=1; Path=/');
  headers.append('set-cookie', 'b=2; Path=/');
  app(headers);
  const r = await ask('graphql-transport-ws, other');
  assert.deepEqual(calls, [{ protocol: 'graphql-transport-ws' }]);
  assert.equal(r.headers.get('sec-websocket-protocol'), 'graphql-transport-ws');
  assert.deepEqual(r.headers.getSetCookie(), ['a=1; Path=/', 'b=2; Path=/']);
  assert.equal(r.headers.get('x-app'), 'yes');
});

test('a protocol that Deno does not find in the list of the client goes as a header', async () => {
  calls.length = 0;
  app({ 'sec-websocket-protocol': 'a' });
  const r = await ask('a,b');
  assert.deepEqual(calls, [{ protocol: 'a' }, {}]);
  assert.equal(r.headers.get('sec-websocket-protocol'), 'a');
});

test('a 101 with no subprotocol, and a response whose headers Deno does not let change', async () => {
  calls.length = 0;
  app({});
  await ask();
  assert.deepEqual(calls, [{}]);
  immutable = true;
  try {
    app({ 'set-cookie': 'a=1' });
    const r = await ask();
    assert.ok(r instanceof NodeResponse);
  } finally {
    immutable = false;
  }
});
