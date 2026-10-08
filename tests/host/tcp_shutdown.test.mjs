// tcp_shutdown of wasm_tcp (gen_tcp:shutdown(S, write)) in worker.js: the
// peer gets the end of the data, and the socket of the VM still reads.
// "node --test tests/host". The imports of the runtime are stand-ins,
// because these tests do not start a VM.
import { register } from 'node:module';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';

register(`data:text/javascript,${encodeURIComponent(`
  const stub = { './beam.mjs': 'export default () => {};', './beam.wasm': 'export default null;' };
  export async function resolve(spec, ctx, next) {
    return spec in stub ? { url: 'data:text/javascript,' + encodeURIComponent(stub[spec]), shortCircuit: true }
                        : next(spec, ctx);
  }`)}`);
const { Vm } = await import('../../priv/wasm_host/worker/worker.js');

const enc = (t) => new TextEncoder().encode(t);
const text = (b) => new TextDecoder().decode(b);
const settle = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)); };

// A Vm with the state of a VM that is ready, and the events that it gives
// to the app in sent.
function vm() {
  const v = Object.create(Vm.prototype);
  const sent = [];
  Object.assign(v, {
    env: { BEAM_REQUEST_TIMEOUT: '0' }, vars: {}, scheme: true, nextId: 0, tcps: new Map(),
    listeners: new Map([[4000, 'l0']]), conns: new Set(), sockets: 0, peak: 0, dead: null, onDead: null,
    died: new Promise(() => {}), markDead: () => {}, handlers: [], jobs: [], fetchConns: new Map(),
    fetches: new Map(), fetchPending: 0,
    beam: { HEAPU8: new Uint8Array(1 << 20) },
    listening: async () => {},
    event: (header, body) => { if (!v.dead) sent.push({ header, body }); },
  });
  return { v, sent };
}

// A message of the VM to the host, as jspi_host_send gives it.
const message = (v, header, body = new Uint8Array(0)) => {
  const h = enc(JSON.stringify(header) + '\n');
  const b = new Uint8Array(h.length + body.length);
  b.set(h);
  b.set(body, h.length);
  v.onsend(b);
};

const closed = (sent, id) => sent.filter((s) => s.header.t === 'tcp_closed' && s.header.id === id);

test('a response with no length ends at the shutdown, and the request body still goes', async () => {
  const { v, sent } = vm();
  let ctl;
  const body = new ReadableStream({ start(c) { ctl = c; } });
  const pending = v.bridge(new Request('https://app.example.com/up', { method: 'POST', body, duplex: 'half' }),
                           new URL('https://app.example.com/up'), false, undefined, () => {});
  await settle();
  const id = sent.find((s) => s.header.t === 'tcp_accept').header.conn;
  message(v, { t: 'tcp_send', id }, enc('HTTP/1.1 200 OK\r\nconnection: close\r\n\r\nhello'));
  message(v, { t: 'tcp_shutdown', id, how: 'write' });
  await settle();
  // The connection stays for the rest of the body.
  assert.equal(closed(sent, id).length, 0);
  ctl.enqueue(enc('late'));
  ctl.close();
  const r = await pending;
  assert.equal(await r.text(), 'hello');
  await settle();
  const got = sent.filter((s) => s.header.t === 'tcp_data').map((s) => text(s.body)).join('');
  assert.ok(got.endsWith('late\r\n0\r\n\r\n'), got);
  assert.equal(closed(sent, id).length, 1);
  assert.ok(!v.tcps.has(id));
});

test('a shutdown with no body to read ends the connection after the response', async () => {
  const { v, sent } = vm();
  const pending = v.bridge(new Request('https://app.example.com/x'), new URL('https://app.example.com/x'),
                           false, undefined, () => {});
  await settle();
  const id = sent.find((s) => s.header.t === 'tcp_accept').header.conn;
  message(v, { t: 'tcp_send', id }, enc('HTTP/1.1 200 OK\r\n\r\nall'));
  message(v, { t: 'tcp_shutdown', id, how: 'write' });
  assert.equal(await (await pending).text(), 'all');
  await settle();
  assert.equal(closed(sent, id).length, 1);
});

test('a shutdown before the head of the response gives 502', async () => {
  const { v, sent } = vm();
  const pending = v.bridge(new Request('https://app.example.com/x'), new URL('https://app.example.com/x'),
                           false, undefined, () => {});
  await settle();
  const id = sent.find((s) => s.header.t === 'tcp_accept').header.conn;
  message(v, { t: 'tcp_shutdown', id, how: 'write' });
  assert.equal((await pending).status, 502);
});

test('the fetch pair: the other socket gets the end after the data, and can still send', async () => {
  const { v, sent } = vm();
  v.listeners.set('fetch', 'lf');
  v.fetchPair('t1', 'api.example.com', 80);
  const conn = sent.find((s) => s.header.t === 'tcp_accept').header.conn;
  message(v, { t: 'tcp_send', id: 't1' }, enc('GET / HTTP/1.1\r\n\r\n'));
  message(v, { t: 'tcp_shutdown', id: 't1', how: 'write' });
  await settle();
  const toConn = sent.filter((s) => s.header.id === conn && s.header.t !== 'tcp_accept');
  assert.deepEqual(toConn.map((s) => [s.header.t, s.header.half]), [['tcp_data', undefined], ['tcp_closed', true]]);
  message(v, { t: 'tcp_send', id: conn }, enc('HTTP/1.1 200 OK\r\n\r\n'));
  await settle();
  assert.ok(sent.some((s) => s.header.t === 'tcp_data' && s.header.id === 't1'));
  assert.equal(closed(sent, 't1').length, 0);
  // The end of the other socket ends the pair.
  message(v, { t: 'tcp_close', id: conn });
  await settle();
  assert.equal(closed(sent, 't1').length, 1);
});

test('a connect() socket: the peer gets the end, and its data still comes', async () => {
  let peerEnd;
  const ended = new Promise((r) => { peerEnd = r; });
  const server = net.createServer({ allowHalfOpen: true }, (s) => {
    s.on('end', () => { peerEnd(); s.end('after the end'); });
    s.resume();
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  try {
    const { v, sent } = vm();
    const done = v.tcpConnect({ id: 't1', host: '127.0.0.1', port: server.address().port });
    for (let i = 0; i < 500 && !sent.some((s) => s.header.t === 'tcp_open'); i++) await new Promise((r) => setTimeout(r, 10));
    message(v, { t: 'tcp_send', id: 't1' }, enc('ping'));
    message(v, { t: 'tcp_shutdown', id: 't1', how: 'write' });
    await ended;
    await done;
    const got = sent.filter((s) => s.header.t === 'tcp_data').map((s) => text(s.body)).join('');
    assert.equal(got, 'after the end');
    assert.equal(closed(sent, 't1').length, 1);
  } finally {
    server.close();
  }
});

// A stand-in for WebSocketPair of workerd: the server end gets the events
// of the test.
class FakeSocket extends EventTarget {
  accept() {}
  send() {}
  close(code) { this.closed = code ?? 1000; }
}

test('a WebSocket of /.tcp/PORT has no half: a shutdown closes it', async () => {
  const old = globalThis.WebSocketPair;
  let server;
  globalThis.WebSocketPair = function () { server = new FakeSocket(); return { 0: new FakeSocket(), 1: server }; };
  const OldResponse = globalThis.Response;
  // The Response of Node.js refuses the status 101.
  globalThis.Response = class extends OldResponse {
    constructor(body, init) { super(body, init?.status === 101 ? { ...init, status: 200 } : init); }
  };
  try {
    const { v, sent } = vm();
    v.tcpAccept(4000, new Request('https://app.example.com/.tcp/4000'), undefined, () => {});
    const id = sent.find((s) => s.header.t === 'tcp_accept').header.conn;
    message(v, { t: 'tcp_shutdown', id, how: 'write' });
    assert.equal(server.closed, 1000);
  } finally {
    globalThis.WebSocketPair = old;
    globalThis.Response = OldResponse;
  }
});
