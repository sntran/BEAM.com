// The 101 of a WebSocket of the app (bridgeUpgrade of worker.js): the
// client gets the headers of the 101 of the app, without the headers of
// the handshake and of the connection. "node --test tests/host". The
// imports of the runtime are stand-ins, because these tests do not start a
// VM.
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

// A stand-in for WebSocketPair of workerd.
class End extends EventTarget {
  accept() {}
  send() {}
  close() {}
}
globalThis.WebSocketPair = function () { return { 0: new End(), 1: new End() }; };
// The Response of Node.js refuses the status 101: the stand-in keeps the
// status and the headers of the 101.
const NodeResponse = globalThis.Response;
globalThis.Response = class extends NodeResponse {
  constructor(body, init) {
    super(body, init?.status === 101 ? { ...init, status: 200 } : init);
    if (init?.status === 101) Object.defineProperty(this, 'status', { value: 101 });
    this.webSocket = init?.webSocket;
  }
};

const enc = (t) => new TextEncoder().encode(t);
const settle = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)); };

// A Vm with the state of a VM that is ready, and the events that it gives
// to the app in sent.
function vm() {
  const v = Object.create(Vm.prototype);
  const sent = [];
  Object.assign(v, {
    env: { BEAM_REQUEST_TIMEOUT: '0' }, vars: {}, scheme: true, nextId: 0, tcps: new Map(),
    listeners: new Map([[4000, 'l0']]), conns: new Set(), sockets: 0, peak: 0, dead: null, onDead: null,
    died: new Promise(() => {}), markDead: () => {}, handlers: [], jobs: [],
    beam: { HEAPU8: new Uint8Array(1 << 20) },
    listening: async () => {},
    event: (header, body) => { if (!v.dead) sent.push({ header, body }); },
  });
  return { v, sent };
}

// An upgrade request of a client, and the 101 of the app for it (head).
async function upgrade(head, headers = {}) {
  const { v, sent } = vm();
  const request = new Request('https://app.example.com/socket', { headers: { upgrade: 'websocket', ...headers } });
  const pending = v.bridge(request, new URL(request.url), true, undefined, () => {});
  await settle();
  const id = sent.find((s) => s.header.t === 'tcp_accept').header.conn;
  const asked = new TextDecoder().decode(sent.find((s) => s.header.t === 'tcp_data').body);
  v.tcps.get(id).send(enc(head));
  return { response: await pending, asked, v };
}

test('the 101 of the client has the subprotocol and the cookies of the app', async () => {
  const { response, asked } = await upgrade(
    'HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\n' +
    'sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nsec-websocket-protocol: graphql-transport-ws\r\n' +
    'set-cookie: a=1; Path=/\r\nset-cookie: b=2; Path=/\r\nx-app: yes\r\n\r\n',
    { 'sec-websocket-protocol': 'graphql-transport-ws, other' });
  // The app got the offer of the client.
  assert.match(asked, /\r\nsec-websocket-protocol: graphql-transport-ws, other\r\n/);
  assert.equal(response.status, 101);
  assert.ok(response.webSocket);
  assert.equal(response.headers.get('sec-websocket-protocol'), 'graphql-transport-ws');
  assert.deepEqual(response.headers.getSetCookie(), ['a=1; Path=/', 'b=2; Path=/']);
  assert.equal(response.headers.get('x-app'), 'yes');
});

test('the headers of the handshake and of the connection of the app do not go to the client', async () => {
  const { response } = await upgrade(
    'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
    'Sec-WebSocket-Accept: x\r\nSec-WebSocket-Extensions: permessage-deflate\r\n' +
    'Content-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n');
  assert.equal(response.status, 101);
  assert.deepEqual([...response.headers.keys()].filter((k) => k !== 'content-type'), []);
});

test('a 101 of the app with no other headers: the client gets none', async () => {
  const { response, v } = await upgrade('HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\n\r\n');
  assert.equal(response.status, 101);
  assert.equal(response.headers.get('sec-websocket-protocol'), null);
  assert.equal(v.sockets, 1);
});
