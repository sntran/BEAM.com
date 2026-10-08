// A WebSocket of the app in a web page (browser.js): the socket has the
// subprotocol that the app chose and the cookies of its 101. "node --test
// tests/host". The VM is a stand-in: worker.js gives the 101 of the test.
import { register } from 'node:module';
import { test } from 'node:test';
import assert from 'node:assert/strict';

register(`data:text/javascript,${encodeURIComponent(`
  const vm = \`
    export class Vm { constructor() { this.ready = Promise.resolve(); } fetch(r) { return globalThis.app(r); } }
    export const releaseMeta = () => ({ name: 'test' });\`;
  export async function resolve(spec, ctx, next) {
    return spec === './worker.js' && ctx.parentURL?.endsWith('/browser/browser.js')
      ? { url: 'data:text/javascript,' + encodeURIComponent(vm), shortCircuit: true }
      : next(spec, ctx);
  }`)}`);
WebAssembly.Suspending ??= function Suspending() {};
globalThis.location ??= { href: 'http://localhost/' };
const { start } = await import('../../priv/wasm_host/browser/browser.js');

test('the socket of a page has the subprotocol and the cookies of the 101 of the app', async () => {
  let asked;
  globalThis.app = (request) => {
    asked = request.headers;
    const [client] = Object.values(new WebSocketPair());
    const headers = new Headers({ 'sec-websocket-protocol': 'graphql-transport-ws' });
    headers.append('set-cookie', 'a=1; Path=/');
    return new Response(null, { status: 101, webSocket: client, headers });
  };
  const beam = await start();
  const socket = await beam.socket('/socket', { headers: { 'sec-websocket-protocol': 'graphql-transport-ws, other' } });
  assert.equal(asked.get('upgrade'), 'websocket');
  assert.equal(socket.protocol, 'graphql-transport-ws');
  assert.deepEqual(socket.setCookies, ['a=1; Path=/']);
  // An app that chose no subprotocol.
  globalThis.app = () => new Response(null, { status: 101, webSocket: Object.values(new WebSocketPair())[0] });
  const plain = await beam.socket('/socket');
  assert.equal(plain.protocol, '');
  assert.deepEqual(plain.setCookies, []);
});
