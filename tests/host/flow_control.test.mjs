// The flow control of the sockets in the host (worker.js), in the two
// directions: tcp_sent (the peer took the bytes of a send of the VM) and
// tcp_read (the VM read the bytes of a peer). "node --test tests/host".
// The imports of the runtime are stand-ins, because these tests do not
// start a VM.
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
const { Vm, Inbound, relay } = await import('../../priv/wasm_host/worker/worker.js');

const WINDOW = 256 * 1024;
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
    died: new Promise(() => {}), markDead: () => {}, handlers: [], jobs: [], fetchConns: new Map(),
    fetches: new Map(), fetchPending: 0,
    beam: { HEAPU8: new Uint8Array(1 << 20) },
    listening: async () => {},
    event: (header, body) => { if (!v.dead) sent.push({ header, body }); },
  });
  return { v, sent };
}

// The bytes that tcp_sent gave for the socket id.
const took = (sent, id) => sent.filter((s) => s.header.t === 'tcp_sent' && s.header.id === id)
  .reduce((n, s) => n + s.header.n, 0);

test('Inbound: the bytes wait while the window is full, and go after tcp_read', () => {
  const win = { sent: 0, read: 0 };
  const got = [];
  const inbound = new Inbound(win, (b) => { win.sent += b.length; got.push(b.length); }, () => assert.fail('over'));
  inbound.push(new Uint8Array(WINDOW));
  inbound.push(new Uint8Array(10));
  inbound.push(new Uint8Array(20));
  assert.deepEqual(got, [WINDOW]);
  assert.ok(inbound.full());
  win.read += 100;
  inbound.flush();
  assert.deepEqual(got, [WINDOW, 10, 20]);
});

test('Inbound: above 16 MiB that wait, over() runs once and the next bytes drop; a forced push waits', () => {
  const win = { sent: WINDOW, read: 0 };
  let over = 0;
  const got = [];
  const inbound = new Inbound(win, (b) => { win.sent += b.length; got.push(b[0]); }, () => over++);
  for (let i = 0; i < 16; i++) inbound.push(new Uint8Array(1 << 20).fill(1));
  inbound.push(new Uint8Array(1).fill(2));
  inbound.push(new Uint8Array(1).fill(3));
  inbound.push(new Uint8Array(1).fill(8), true);
  assert.equal(over, 1);
  assert.equal(inbound.queue.length, 17);
  win.read = Infinity;
  inbound.flush();
  assert.deepEqual(got.slice(-2), [1, 8]);
});

test('relay: a send ends when the other socket read its bytes, or at the end', async () => {
  const delivered = [];
  const r = relay((b) => delivered.push(b.length));
  let first = false, second = false;
  r.send(new Uint8Array(100)).then(() => { first = true; });
  r.send(new Uint8Array(50)).then(() => { second = true; });
  assert.deepEqual(delivered, [100, 50]);
  r.read(100);
  await settle();
  assert.deepEqual([first, second], [true, false]);
  r.end();
  await settle();
  assert.equal(second, true);
  r.read(50);
  assert.equal(r.send(new Uint8Array(0)), undefined);
});

test('tcpSend: tcp_sent after each 64 KB that the peer took, also for a send that failed', async () => {
  const { v, sent } = vm();
  let release;
  const t = { send: () => new Promise((r) => { release = r; }) };
  v.tcpSend('t1', t, new Uint8Array(40000));
  v.tcpSend('t1', t, new Uint8Array(40000));
  await settle();
  assert.equal(took(sent, 't1'), 0);
  release();
  await settle();
  assert.equal(took(sent, 't1'), 0, 'the bytes of one send are below 64 KB');
  const failing = { send: () => Promise.reject(new Error('reset')) };
  v.tcpSend('t2', failing, new Uint8Array(70000));
  const sync = { send: () => {} };
  v.tcpSend('t3', sync, new Uint8Array(65536));
  await settle();
  assert.equal(took(sent, 't2'), 70000);
  assert.equal(took(sent, 't3'), 65536);
});

test('a response: tcp_sent comes when the client reads, not before', async () => {
  const { v, sent } = vm();
  const pending = v.bridge(new Request('https://app.example.com/x'), new URL('https://app.example.com/x'), false, undefined, () => {});
  await settle();
  const accept = sent.find((s) => s.header.t === 'tcp_accept').header;
  assert.equal(accept.sent, true);
  const id = accept.conn;
  const part = 64 * 1024;
  v.tcpSend(id, v.tcps.get(id), enc(`HTTP/1.1 200 OK\r\ncontent-length: ${4 * part}\r\n\r\n`));
  for (let i = 0; i < 4; i++) v.tcpSend(id, v.tcps.get(id), new Uint8Array(part));
  const r = await pending;
  await settle();
  assert.equal(took(sent, id), 0, 'the client read nothing');
  assert.equal((await r.arrayBuffer()).byteLength, 4 * part);
  await settle();
  assert.ok(took(sent, id) >= 4 * part - part, `tcp_sent gave ${took(sent, id)} bytes`);
});

test('the fetch pair: a send of one side ends when the other side read the bytes', async () => {
  const { v, sent } = vm();
  v.listeners.set('fetch', 'lf');
  v.fetchPair('t1', 'api.example.com', 443);
  const conn = sent.find((s) => s.header.t === 'tcp_accept').header.conn;
  assert.deepEqual(sent.map((s) => [s.header.t, s.header.ack, s.header.sent]),
                   [['tcp_open', true, true], ['tcp_accept', true, true]]);
  v.tcpSend('t1', v.tcps.get('t1'), new Uint8Array(70000));
  await settle();
  assert.equal(took(sent, 't1'), 0);
  v.tcps.get(conn).ack(70000);
  await settle();
  assert.equal(took(sent, 't1'), 70000);
  // The end of the pair ends the sends that wait.
  v.tcpSend(conn, v.tcps.get(conn), new Uint8Array(70000));
  v.tcps.get('t1').close();
  await settle();
  assert.equal(took(sent, conn), 70000);
});

test('a fetch() with ack: the body goes while less than 256 KB is unread', async () => {
  const { v, sent } = vm();
  v.fetchConns.set('x1', { host: 'api.example.com', port: 443 });
  const old = globalThis.fetch;
  const part = 64 * 1024;
  globalThis.fetch = async () => new Response(new ReadableStream({
    start(c) { for (let i = 0; i < 8; i++) c.enqueue(new Uint8Array(part)); c.close(); },
  }));
  try {
    const done = v.fetchRequest({ id: 'f1', conn: 'x1', tls: true, method: 'GET', path: '/', ack: true });
    await settle();
    const data = () => sent.filter((s) => s.header.t === 'fetch_data').length;
    assert.equal(data(), 4);
    v.fetches.get('f1').read += 2 * part;
    v.fetches.get('f1').room();
    await settle();
    assert.equal(data(), 6);
    v.fetches.get('f1').abort();
    await done;
    assert.ok(sent.some((s) => s.header.t === 'fetch_error'));
  } finally {
    globalThis.fetch = old;
  }
});

test('a fetch() with no ack sends all its body', async () => {
  const { v, sent } = vm();
  v.fetchConns.set('x1', { host: 'api.example.com', port: 443 });
  const old = globalThis.fetch;
  globalThis.fetch = async () => new Response(new Uint8Array(1 << 20));
  try {
    await v.fetchRequest({ id: 'f1', conn: 'x1', tls: true, method: 'GET', path: '/' });
    const bytes = sent.filter((s) => s.header.t === 'fetch_data').reduce((n, s) => n + s.body.byteLength, 0);
    assert.equal(bytes, 1 << 20);
    assert.equal(sent.at(-1).header.t, 'fetch_end');
  } finally {
    globalThis.fetch = old;
  }
});

test('a fetch() body that is a byte stream goes in reads of 64 KB, not in its small pieces', async () => {
  const { v, sent } = vm();
  v.fetchConns.set('x1', { host: 'api.example.com', port: 443 });
  const old = globalThis.fetch;
  const bytes = new Uint8Array(32 * 4096).map((_, i) => i & 255);
  globalThis.fetch = async () => new Response(new ReadableStream({
    type: 'bytes',
    start(c) { for (let i = 0; i < 32; i++) c.enqueue(bytes.slice(i * 4096, (i + 1) * 4096)); c.close(); },
  }));
  try {
    await v.fetchRequest({ id: 'f1', conn: 'x1', tls: true, method: 'GET', path: '/' });
    const data = sent.filter((s) => s.header.t === 'fetch_data').map((s) => s.body);
    assert.deepEqual(data.map((b) => b.byteLength), [65536, 65536]);
    assert.deepEqual(Buffer.concat(data), Buffer.from(bytes));
    assert.equal(sent.at(-1).header.t, 'fetch_end');
  } finally {
    globalThis.fetch = old;
  }
});

test('a VM that stops ends its fetch() calls', async () => {
  const { v } = vm();
  const ac = new AbortController();
  v.fetches.set('f1', ac);
  v.die('exit status 1');
  assert.ok(ac.signal.aborted);
});

test('a connect() socket pauses while 256 KB is unread in the VM, and goes on after tcp_read', async () => {
  const { v, sent } = vm();
  const total = 4 << 20;
  const server = net.createServer((s) => s.end(Buffer.alloc(total)));
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const got = () => sent.filter((s) => s.header.t === 'tcp_data').reduce((n, s) => n + s.body.length, 0);
  try {
    const closed = v.tcpConnect({ id: 't1', host: '127.0.0.1', port: server.address().port });
    for (let i = 0; i < 500 && got() < WINDOW; i++) await new Promise((r) => setTimeout(r, 10));
    await new Promise((r) => setTimeout(r, 100));
    const open = sent.find((s) => s.header.t === 'tcp_open').header;
    assert.deepEqual([open.ack, open.sent], [true, true]);
    assert.ok(got() >= WINDOW && got() < WINDOW + (1 << 20), `the VM got ${got()} bytes with no read`);
    // The app reads all that it gets, until the end.
    let read = 0;
    for (let i = 0; i < 2000 && !sent.some((s) => s.header.t === 'tcp_closed'); i++) {
      const n = got() - read;
      if (n) { read += n; v.tcps.get('t1')?.ack(n); }
      await new Promise((r) => setTimeout(r, 2));
    }
    await closed;
    assert.equal(got(), total);
  } finally {
    server.close();
  }
});

// A stand-in for WebSocketPair of workerd: the server end gets the events
// of the test.
class FakeSocket extends EventTarget {
  accept() {}
  send() {}
  close(code) { this.closed = code; }
}

test('a WebSocket: the messages of the client wait while 256 KB is unread, and the end comes last', async () => {
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
    const pending = v.bridge(new Request('https://app.example.com/ws', { headers: { upgrade: 'websocket' } }),
                             new URL('https://app.example.com/ws'), true, undefined, () => {});
    await settle();
    const accept = sent.find((s) => s.header.t === 'tcp_accept').header;
    assert.deepEqual([accept.ack, accept.sent], [true, true]);
    const id = accept.conn;
    const head = sent.find((s) => s.header.t === 'tcp_data').body.length;
    v.tcps.get(id).ack(head);
    v.tcpSend(id, v.tcps.get(id), enc('HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\n\r\n'));
    await pending;
    const frames = () => sent.filter((s) => s.header.t === 'tcp_data').length - 1;
    for (let i = 0; i < 8; i++) {
      const e = new Event('message');
      e.data = new ArrayBuffer(64 * 1024);
      server.dispatchEvent(e);
    }
    const end = new Event('close');
    end.code = 1000;
    server.dispatchEvent(end);
    assert.equal(frames(), 4);
    v.tcps.get(id).ack(8 * 64 * 1024);
    assert.equal(frames(), 9);
    // The close frame of the client is the last one.
    assert.equal(sent.at(-1).body[0], 0x88);
  } finally {
    globalThis.WebSocketPair = old;
    globalThis.Response = OldResponse;
  }
});
