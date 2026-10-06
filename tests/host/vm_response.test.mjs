// A response of the app to the client (bridgeData and bridgeBody of
// worker.js): the pieces of the app go to the stream as they are, with no
// copy of the whole buffer for each piece. "node --test tests/host". The
// imports of the runtime are stand-ins, because these tests do not start
// a VM.
import { register } from 'node:module';
import { test } from 'node:test';
import assert from 'node:assert/strict';

register(`data:text/javascript,${encodeURIComponent(`
  const stub = { './beam.mjs': 'export default () => {};', './beam.wasm': 'export default null;' };
  export async function resolve(spec, ctx, next) {
    return spec in stub ? { url: 'data:text/javascript,' + encodeURIComponent(stub[spec]), shortCircuit: true }
                        : next(spec, ctx);
  }`)}`);
const { Vm, Pieces } = await import('../../priv/wasm_host/worker/worker.js');

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

const enc = (t) => new TextEncoder().encode(t);
const settle = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)); };

// A request to the VM, and send(bytes), which gives the bytes of the app
// for it.
async function request(method = 'GET') {
  const { v, sent } = vm();
  const pending = v.bridge(new Request('https://app.example.com/x', { method }), new URL('https://app.example.com/x'), false, undefined, () => {});
  await settle();
  const id = sent.find((s) => s.header.t === 'tcp_accept').header.conn;
  return { v, sent, pending, send: (b) => v.tcps.get(id).send(typeof b === 'string' ? enc(b) : b) };
}

// The bytes of b in pieces of n bytes.
function* split(b, n) {
  for (let i = 0; i < b.length; i += n) yield b.subarray(i, i + n);
}

test('a response with content-length in small pieces', async () => {
  const { pending, send } = await request();
  const body = new Uint8Array(100000).map((_, i) => i % 251);
  for (const p of split(enc(`HTTP/1.1 200 OK\r\ncontent-length: ${body.length}\r\n\r\n`), 3)) send(p);
  for (const p of split(body, 997)) send(p);
  const r = await pending;
  assert.equal(r.status, 200);
  assert.deepEqual(new Uint8Array(await r.arrayBuffer()), body);
});

test('a large chunk goes to the client before its end', async () => {
  const { pending, send } = await request();
  const body = new Uint8Array(1 << 20).map((_, i) => i % 253);
  send(`HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n${body.length.toString(16)}\r\n`);
  const r = await pending;
  const reader = r.body.getReader();
  const pieces = [...split(body, 1000)];
  send(pieces[0]);
  // The first piece of the chunk is in the stream, with no wait for the
  // rest of the chunk.
  const first = await reader.read();
  assert.deepEqual(first.value, pieces[0]);
  for (const p of pieces.slice(1)) send(p);
  send('\r\n0\r\n\r\n');
  const got = [first.value];
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    got.push(value);
  }
  assert.deepEqual(Buffer.concat(got), Buffer.from(body));
});

test('chunks with extensions, and a size line in two pieces', async () => {
  const { pending, send } = await request();
  send('HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5;name=value\r\nhel');
  send('lo\r\n6');
  send('\r\n world\r\n0\r\n\r\n');
  assert.equal(await (await pending).text(), 'hello world');
});

test('a bad chunk size stops the response', async () => {
  const { pending, send, v } = await request();
  send('HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\nzz\r\nxx\r\n');
  const r = await pending;
  await assert.rejects(r.text());
  assert.equal(v.conns.size, 0);
});

test('a size line with no end stops the response', async () => {
  const { pending, send } = await request();
  send('HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n');
  send('1'.repeat(5000));
  await assert.rejects((await pending).text());
});

test('a HEAD response with transfer-encoding: chunked ends at its head', async () => {
  const { pending, send, v } = await request('HEAD');
  send('HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n');
  const r = await pending;
  assert.equal(r.status, 200);
  await settle();
  assert.equal(v.conns.size, 0);
});

test('Pieces: peek, take, drop and next give the bytes in order, for each split', () => {
  const all = new Uint8Array(500).map((_, i) => i % 256);
  for (const n of [1, 2, 7, 64, 499, 500]) {
    const p = new Pieces();
    for (const b of split(all, n)) p.push(b);
    p.push(new Uint8Array(0));
    assert.equal(p.size, 500);
    assert.deepEqual(p.peek(10), all.subarray(0, 10));
    assert.deepEqual(p.take(3), all.subarray(0, 3));
    p.drop(4);
    assert.deepEqual(p.next(5).length <= 5, true);
    const rest = [];
    while (p.size) rest.push(p.next(Infinity));
    const front = 3 + 4 + (500 - 7 - rest.reduce((k, b) => k + b.length, 0));
    assert.deepEqual(Buffer.concat(rest), Buffer.from(all.subarray(front)));
  }
});

// The request head that the app got.
const appHead = (sent) => new TextDecoder('latin1').decode(sent.find((s) => s.header.t === 'tcp_data').body);
const closed = (sent) => sent.some((s) => s.header.t === 'tcp_closed');

test('a 100 Continue of the app, then the head of the response', async () => {
  const { pending, send } = await request();
  send('HTTP/1.1 100 Continue\r\n\r\n');
  send('HTTP/1.1 103 Early Hints\r\nlink: </a.css>; rel=preload\r\n\r\nHTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok');
  const r = await pending;
  assert.equal(r.status, 200);
  assert.equal(await r.text(), 'ok');
});

test('the app gets no expect header, and the head of the request as bytes', async () => {
  const { v, sent } = vm();
  v.bridge(new Request('https://app.example.com/x', { method: 'POST', body: 'a', headers: { expect: '100-continue', 'x-name': 'café' } }),
    new URL('https://app.example.com/x'), false, undefined, () => {});
  await settle();
  const head = appHead(sent);
  assert.doesNotMatch(head, /^expect:/im);
  // One byte for each character of the value (é is 0xE9).
  assert.match(head, /x-name: café\r\n/);
});

test('a header value of bytes above 0x7F (UTF-8 of the app) goes as bytes', async () => {
  const { pending, send, v } = await request();
  send(new Uint8Array([...enc('HTTP/1.1 200 OK\r\nx-title: '), 0xc3, 0xa9, ...enc('\r\ncontent-length: 0\r\n\r\n')]));
  const r = await pending;
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('x-title'), 'Ã©');
  assert.equal(v.dead, null);
});

test('a status that a Response does not take gives 502, and the VM goes on', async () => {
  const { pending, send, v, sent } = await request();
  send('HTTP/1.1 600 Odd\r\ncontent-length: 0\r\n\r\n');
  assert.equal((await pending).status, 502);
  assert.equal(v.dead, null);
  assert.ok(closed(sent));
  assert.equal(v.conns.size, 0);
});

test('a client that cancels the body: the app gets the end of the connection', async () => {
  const { pending, send, sent, v } = await request();
  send('HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n3\r\nabc\r\n');
  const r = await pending;
  const reader = r.body.getReader();
  await reader.read();
  await reader.cancel();
  await settle();
  assert.ok(closed(sent));
  assert.equal(v.conns.size, 0);
  // The app sends more: the host drops it.
  assert.equal(v.tcps.size, 0);
});

test('a request to an app that listens leaves no wait behind', async () => {
  const { v } = vm();
  for (let i = 0; i < 3; i++) {
    const { send, pending } = await (async () => {
      const p = v.bridge(new Request('https://app.example.com/x'), new URL('https://app.example.com/x'), false, undefined, () => {});
      await settle();
      const id = [...v.tcps.keys()].at(-1);
      return { pending: p, send: (t) => v.tcps.get(id).send(enc(t)) };
    })();
    send('HTTP/1.1 204 No Content\r\n\r\n');
    assert.equal((await pending).status, 204);
  }
  assert.equal(v.stopWaits?.size ?? 0, 0);
  assert.equal(v.conns.size, 0);
});
