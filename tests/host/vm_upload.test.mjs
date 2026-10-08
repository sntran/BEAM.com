// A request body to the app in chunks, with flow control (bridgeUpload of
// worker.js, tcp_read of wasm_tcp), and BEAM_MAX_BODY. "node --test
// tests/host". The imports of the runtime are stand-ins, because these
// tests do not start a VM.
import { register } from 'node:module';
import { test } from 'node:test';
import assert from 'node:assert/strict';

register(`data:text/javascript,${encodeURIComponent(`
  const stub = { './beam.mjs': 'export default () => {};', './beam.wasm': 'export default null;' };
  export async function resolve(spec, ctx, next) {
    return spec in stub ? { url: 'data:text/javascript,' + encodeURIComponent(stub[spec]), shortCircuit: true }
                        : next(spec, ctx);
  }`)}`);
const { Vm, drain } = await import('../../priv/wasm_host/worker/worker.js');

// A Vm with the state of a VM that is ready, and the events that it gives
// to the app in sent.
function vm(env = {}) {
  const v = Object.create(Vm.prototype);
  const sent = [];
  Object.assign(v, {
    env: { BEAM_REQUEST_TIMEOUT: '0', ...env }, vars: {}, scheme: true, nextId: 0, tcps: new Map(),
    listeners: new Map([[4000, 'l0']]), conns: new Set(), sockets: 0, peak: 0, dead: null, onDead: null,
    died: new Promise(() => {}), markDead: () => {}, handlers: [], jobs: [],
    beam: { HEAPU8: new Uint8Array(1 << 20) },
    listening: async () => {},
    event: (header, body) => { if (!v.dead) sent.push({ header, body }); },
  });
  return { v, sent };
}

const url = 'https://app.example.com/upload';
const bridge = (v, r) => v.bridge(r, new URL(r.url), false, undefined, () => {});
const text = (b) => new TextDecoder().decode(b);
const data = (sent) => sent.filter((s) => s.header.t === 'tcp_data');
// All the bytes that the app got, as text: the head, then the body. The
// head goes in the event of the first part of the body.
const all = (sent) => data(sent).map((s) => text(s.body)).join('');
const headOf = (sent) => all(sent).slice(0, all(sent).indexOf('\r\n\r\n') + 4);
// The body bytes that the app got (after the head).
const bodyBytes = (sent) => data(sent).reduce((n, s) => n + s.body.length, 0) - headOf(sent).length;
const settle = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)); };

// True when the promise p does not settle in a few turns.
const waiting = (p) => Promise.race([p.then(() => false, () => false), settle().then(() => true)]);

// A body of n chunks of size bytes each, which the test gives one by one.
function source() {
  let ctl;
  const stream = new ReadableStream({ start(c) { ctl = c; } });
  return { stream, push: (n) => ctl.enqueue(new Uint8Array(n).fill(120)), end: () => ctl.close() };
}

test('a body goes in chunks, and waits while 256 KB are unread', async () => {
  const { v, sent } = vm();
  const src = source();
  const pending = bridge(v, new Request(url, {
    method: 'POST', body: src.stream, duplex: 'half', headers: { 'content-length': String(3 * 200000) },
  }));
  await settle();
  const accept = sent.find((s) => s.header.t === 'tcp_accept');
  assert.equal(accept.header.ack, true);
  src.push(200000);
  src.push(200000);
  src.push(200000);
  src.end();
  await settle();
  const head = headOf(sent);
  assert.match(head, /^POST \/upload HTTP\/1.1\r\n/);
  assert.match(head, /content-length: 600000\r\n/);
  // Parts went while less than 256 KB was unread; the rest waits for room.
  // A chunk of 200000 bytes goes in pieces: no part is above 80 KB.
  const first = bodyBytes(sent);
  assert.ok(head.length + first >= 256 * 1024, `${first}`);
  assert.ok(first < 600000, `${first}`);
  for (const s of data(sent)) assert.ok(s.body.length <= 80 * 1024 + head.length, `${s.body.length}`);
  const id = accept.header.conn;
  // The app reads all that it got, in rounds, until the body ends.
  let read = 0;
  for (let i = 0; i < 10 && bodyBytes(sent) < 600000; i++) {
    const got = head.length + bodyBytes(sent);
    v.tcps.get(id).ack(got - read);
    read = got;
    await settle();
  }
  assert.equal(bodyBytes(sent), 600000);
  v.tcps.get(id).send(new TextEncoder().encode('HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok'));
  assert.equal((await pending).status, 200);
});

test('a body of no declared length goes as chunked', async () => {
  const { v, sent } = vm();
  const src = source();
  bridge(v, new Request(url, { method: 'POST', body: src.stream, duplex: 'half' }));
  src.push(3);
  src.end();
  await settle();
  const head = headOf(sent);
  assert.match(head, /transfer-encoding: chunked\r\n/);
  assert.doesNotMatch(head, /content-length/);
  assert.equal(all(sent).slice(head.length), '3\r\nxxx\r\n0\r\n\r\n');
});

test('a request with no body asks for no tcp_read', async () => {
  const { v, sent } = vm();
  bridge(v, new Request('https://app.example.com/'));
  await settle();
  assert.equal(sent.find((s) => s.header.t === 'tcp_accept').header.ack, false);
  assert.doesNotMatch(text(data(sent)[0].body), /content-length|transfer-encoding/);
});

test('a declared length above BEAM_MAX_BODY gets 413 before the app reads it', async () => {
  const { v, sent } = vm({ BEAM_MAX_BODY: '10' });
  const r = await bridge(v, new Request(url, { method: 'POST', body: 'x'.repeat(11), headers: { 'content-length': '11' } }));
  assert.equal(r.status, 413);
  assert.equal(sent.length, 0);
});

test('a body that grows above BEAM_MAX_BODY gets 413, and the app gets the end', async () => {
  const { v, sent } = vm({ BEAM_MAX_BODY: '10' });
  const src = source();
  const pending = bridge(v, new Request(url, { method: 'POST', body: src.stream, duplex: 'half' }));
  src.push(6);
  src.push(6);
  // The response waits while the host reads the rest of the body (drain).
  assert.equal(await waiting(pending), true);
  src.push(6);
  src.end();
  const r = await pending;
  assert.equal(r.status, 413);
  await settle();
  const id = sent.find((s) => s.header.t === 'tcp_accept').header.conn;
  assert.ok(sent.some((s) => s.header.t === 'tcp_closed' && s.header.id === id));
  assert.equal(data(sent).length, 1);  // the head and the first 6 bytes
  assert.equal(v.conns.size, 0);
});

test('a VM that stops ends the upload that waits for room', async () => {
  const { v, sent } = vm();
  const src = source();
  const pending = bridge(v, new Request(url, {
    method: 'POST', body: src.stream, duplex: 'half', headers: { 'content-length': '600000' },
  }));
  src.push(300000);
  src.push(300000);
  await settle();
  const before = data(sent).length;
  assert.ok(bodyBytes(sent) < 600000);
  v.die('exit status 1');
  src.end();
  assert.equal((await pending).status, 503);
  await settle();
  assert.equal(data(sent).length, before);
});

test('small chunks of a byte stream reach the app in parts of 32 KB or more', async () => {
  const { v, sent } = vm();
  let ctl;
  const stream = new ReadableStream({ type: 'bytes', start(c) { ctl = c; } });
  bridge(v, new Request(url, {
    method: 'POST', body: stream, duplex: 'half', headers: { 'content-length': String(100 * 2048) },
  }));
  for (let i = 0; i < 100; i++) ctl.enqueue(new Uint8Array(2048).fill(120));
  ctl.close();
  await settle();
  assert.equal(bodyBytes(sent), 100 * 2048);
  // The first event: the head and the first read. Then parts of 32 KB.
  const parts = data(sent).slice(1).map((s) => s.body.length);
  assert.ok(parts.length < 10, `parts: ${parts}`);
  for (const n of parts.slice(0, -1)) assert.ok(n >= 32768, `parts: ${parts}`);
});

// The option min of a BYOB read errors a stream that closes with fewer
// bytes (Node.js 26, Chromium): outside workerd, the host gathers the
// chunks of the default reader.
test('small chunks of a stream that is not a byte stream also go in parts of 32 KB or more', async () => {
  const { v, sent } = vm();
  const src = source();
  bridge(v, new Request(url, {
    method: 'POST', body: src.stream, duplex: 'half', headers: { 'content-length': String(100 * 2048 + 5) },
  }));
  for (let i = 0; i < 100; i++) src.push(2048);
  src.push(5);
  src.end();
  await settle();
  assert.equal(bodyBytes(sent), 100 * 2048 + 5);
  const parts = data(sent).slice(1).map((s) => s.body.length);
  assert.ok(parts.length < 10, `parts: ${parts}`);
  for (const n of parts.slice(0, -1)) assert.ok(n >= 32768, `parts: ${parts}`);
});

test('with a body, BEAM_REQUEST_TIMEOUT starts at the end of the body', async () => {
  const { v } = vm({ BEAM_REQUEST_TIMEOUT: '0.05' });
  const src = source();
  const pending = bridge(v, new Request(url, { method: 'POST', body: src.stream, duplex: 'half' }));
  let status = null;
  pending.then((r) => { status = r.status; });
  src.push(10);
  await new Promise((r) => setTimeout(r, 120));
  assert.equal(status, null);  // the body has not ended: no time limit yet
  src.end();
  assert.equal((await pending).status, 504);
});

// The web page (browser.js) gives an object with url, method, headers and
// body (a stream of a Response), not a Request.
test('a request object as browser.js gives it', async () => {
  const { v, sent } = vm();
  const r = {
    url, method: 'POST', headers: new Headers({ 'content-length': '5' }),
    body: new Response('a=b&c').body,
  };
  bridge(v, r);
  await settle();
  assert.match(headOf(sent), /content-length: 5\r\n/);
  assert.equal(all(sent).slice(headOf(sent).length), 'a=b&c');
  // A small body goes with its head, in one event.
  assert.equal(data(sent).length, 1);
});

test('a client that sends no body yet: the head goes alone after 20 ms', async () => {
  const { v, sent } = vm();
  const src = source();
  bridge(v, new Request(url, {
    method: 'POST', body: src.stream, duplex: 'half', headers: { 'content-length': '3' },
  }));
  await new Promise((r) => setTimeout(r, 100));
  assert.equal(data(sent).length, 1);
  assert.match(headOf(sent), /content-length: 3\r\n/);
  assert.equal(bodyBytes(sent), 0);
  src.push(3);
  src.end();
  await settle();
  assert.equal(all(sent).slice(headOf(sent).length), 'xxx');
});

test('an app that answers before the end of the body: the response goes after the host read the rest', async () => {
  const { v, sent } = vm();
  const src = source();
  const pending = bridge(v, new Request(url, {
    method: 'POST', body: src.stream, duplex: 'half', headers: { 'content-length': '400000' },
  }));
  src.push(100000);
  await settle();
  const id = sent.find((s) => s.header.t === 'tcp_accept').header.conn;
  const app = v.tcps.get(id);
  app.send(new TextEncoder().encode('HTTP/1.1 413 Payload Too Large\r\ncontent-length: 0\r\n\r\n'));
  app.close();
  assert.equal(await waiting(pending), true);
  const before = data(sent).length;
  src.push(300000);
  assert.equal(await waiting(pending), true);
  src.end();
  assert.equal((await pending).status, 413);
  // The rest went to no app: the app closed its connection.
  assert.equal(data(sent).length, before);
});

test('drain reads a body to its end, and cancels it at a bound', async () => {
  const chunks = (n, size) => {
    let left = n, cancelled = false;
    const stream = new ReadableStream({
      pull(c) { if (left-- > 0) c.enqueue(new Uint8Array(size)); else c.close(); },
      cancel() { cancelled = true; },
    });
    const reader = stream.getReader();
    return { read: () => reader.read(), cancel: () => reader.cancel(), cancelled: () => cancelled, left: () => left };
  };
  const all = chunks(10, 1000);
  await drain(all.read, all.cancel);
  assert.equal(all.cancelled(), false);
  assert.ok(all.left() < 0);
  // Above the bytes: cancel.
  const big = chunks(10, 1000);
  await drain(big.read, big.cancel, { bytes: 2500 });
  assert.equal(big.cancelled(), true);
  // No bytes in the idle time: cancel.
  let cancelled = false;
  const silent = new ReadableStream({ cancel() { cancelled = true; } }).getReader();
  await drain(() => silent.read(), () => silent.cancel(), { idle: 20 });
  assert.equal(cancelled, true);
  // A client that stops its body: no cancel, no error.
  const broken = new ReadableStream({ pull(c) { c.error(new Error('the client stopped')); } }).getReader();
  await drain(() => broken.read(), () => assert.fail('no cancel'));
});

test('while a recv of the app waits for many bytes, a part has those bytes', async () => {
  const { v, sent } = vm();
  const src = source();
  const pending = bridge(v, new Request(url, {
    method: 'POST', body: src.stream, duplex: 'half', headers: { 'content-length': String(1000000) },
  }));
  src.push(100000);
  await settle();
  const id = sent.find((s) => s.header.t === 'tcp_accept').header.conn;
  const got = data(sent).reduce((n, s) => n + s.body.length, 0);
  assert.equal(bodyBytes(sent), 100000);
  const before = data(sent).length;
  // wasm_tcp: a recv waits for the other 900000 bytes of the body.
  v.tcps.get(id).ack(got, { t: 'tcp_read', id, n: got, want: 900000, got });
  for (let i = 0; i < 9; i++) src.push(100000);
  src.end();
  await settle();
  assert.equal(bodyBytes(sent), 1000000);
  assert.equal(data(sent).length, before + 1);  // one part of 900000 bytes, not 28
  assert.equal(await waiting(pending), true);  // no response yet
});

const enc = (t) => new TextEncoder().encode(t);
const WINDOW = 256 * 1024;
const conn = (sent) => sent.find((s) => s.header.t === 'tcp_accept').header.conn;

// The app on the connection id, as wasm_tcp gives it: a send waits while
// 256 KB or more of the sends of the socket wait for the client
// (SEND_WINDOW), and goes on at each tcp_sent. read(n) is a tcp_read.
function app(v, id) {
  const t = v.tcps.get(id);
  let waiting = 0;
  const queue = [];
  const pump = () => {
    while (queue.length && waiting < WINDOW) {
      const [b, resolve] = queue.shift();
      waiting += b.length;
      v.tcpSend(id, t, b);
      resolve();
    }
  };
  const event = v.event;
  v.event = (header, body) => {
    event(header, body);
    if (header.t === 'tcp_sent' && header.id === id) queueMicrotask(() => { waiting -= header.n; pump(); });
  };
  return {
    send: (b) => new Promise((resolve) => { queue.push([typeof b === 'string' ? enc(b) : b, resolve]); pump(); }),
    read: (n) => v.tcps.get(id)?.ack(n),
  };
}

// The bytes of a stream to its end.
async function readAll(reader) {
  let n = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) return n;
    n += value.length;
  }
}

// 0.1.0-rc.5 held such a response until the end of the upload, and the
// upload waited for the app, which waited for the client: 60 s.
test('a large answer before the app reads the body goes at once, and its end waits for the rest of the body', async () => {
  const { v, sent } = vm();
  const src = source();
  const pending = bridge(v, new Request(url, {
    method: 'POST', body: src.stream, duplex: 'half', headers: { 'content-length': String(2 << 20) },
  }));
  for (let i = 0; i < 8; i++) src.push(65536);
  await settle();
  const a = app(v, conn(sent));
  const size = 512 * 1024;
  a.send(`HTTP/1.1 200 OK\r\ncontent-length: ${size}\r\n\r\n`);
  for (let i = 0; i < 8; i++) a.send(new Uint8Array(65536).fill(i));
  assert.equal(await waiting(pending), false);
  const r = await pending;
  assert.equal(r.status, 200);
  const reader = r.body.getReader();
  let got = 0;
  while (got < size) {
    const { value, done } = await reader.read();
    assert.equal(done, false);
    got += value.length;
  }
  assert.equal(got, size);
  // All the bytes went, and the app got the end of the connection. The end
  // of the response waits while the host reads the rest of the body.
  await settle();
  assert.ok(sent.some((s) => s.header.t === 'tcp_closed'));
  const end = reader.read();
  assert.equal(await waiting(end), true);
  for (let i = 8; i < 32; i++) src.push(65536);
  assert.equal(await waiting(end), true);
  src.end();
  assert.equal((await end).done, true);
});

test('a client that sends no more of the body: the end of the response comes at the bound of drain', async () => {
  const { v, sent } = vm();
  v.drainLimits = { idle: 50 };
  let cancelled = false, ctl;
  const stream = new ReadableStream({ start(c) { ctl = c; }, cancel() { cancelled = true; } });
  const pending = bridge(v, new Request(url, {
    method: 'POST', body: stream, duplex: 'half', headers: { 'content-length': '100000' },
  }));
  ctl.enqueue(new Uint8Array(1000));
  await settle();
  v.tcps.get(conn(sent)).send(enc('HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok'));
  const r = await pending;
  const t0 = Date.now();
  assert.equal(await r.text(), 'ok');
  assert.ok(Date.now() - t0 >= 40, `${Date.now() - t0} ms`);
  assert.equal(cancelled, true);
});

test('a streamed echo of a large body: the response goes while the body comes', { timeout: 20000 }, async () => {
  const { v, sent } = vm();
  const src = source();
  const total = 2 << 20;
  const part = 65536;
  const pending = bridge(v, new Request(url, {
    method: 'POST', body: src.stream, duplex: 'half', headers: { 'content-length': String(total) },
  }));
  src.push(part);
  let pushed = part;
  await settle();
  const head = headOf(sent).length;
  const a = app(v, conn(sent));
  await a.send('HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n');
  const r = await pending;
  const back = readAll(r.body.getReader());
  // The app reads each part of the body, and sends it back as a chunk.
  let seen = 0, echoed = 0;
  while (echoed < total) {
    if (pushed < total) {
      src.push(part);
      pushed += part;
      if (pushed === total) src.end();
    }
    await settle();
    const bytes = data(sent).reduce((n, s) => n + s.body.length, 0);
    if (bytes === seen) continue;
    a.read(bytes - seen);
    const n = bytes - Math.max(seen, head);
    seen = bytes;
    await a.send(`${n.toString(16)}\r\n`);
    await a.send(new Uint8Array(n));
    await a.send('\r\n');
    echoed += n;
  }
  await a.send('0\r\n\r\n');
  assert.equal(await back, total);
});

test('a VM that stops while a response streams and the body comes: the stream fails after the rest of the body', async () => {
  const { v, sent } = vm();
  const src = source();
  const pending = bridge(v, new Request(url, {
    method: 'POST', body: src.stream, duplex: 'half', headers: { 'content-length': '200000' },
  }));
  src.push(1000);
  await settle();
  v.tcps.get(conn(sent)).send(enc('HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n3\r\nabc\r\n'));
  const r = await pending;
  const reader = r.body.getReader();
  assert.equal(text((await reader.read()).value), 'abc');
  v.die('exit status 1');
  const next = reader.read();
  assert.equal(await waiting(next.catch(() => {})), true);
  src.push(199000);
  src.end();
  await assert.rejects(next, /the app stopped/);
});

// A Request of a host adapter (boot() of Node.js, for example) can give a
// content-length and a stream with other bytes.
function lying(length, ...chunks) {
  let i = 0;
  const stream = new ReadableStream({
    pull(c) { if (i < chunks.length) c.enqueue(enc(chunks[i++])); else c.close(); },
  });
  return new Request(url, { method: 'POST', body: stream, duplex: 'half', headers: { 'content-length': String(length) } });
}
const closedFor = (sent) => sent.some((s) => s.header.t === 'tcp_closed' && s.header.id === conn(sent));

test('a body with more bytes than its content-length gets 400, and the app gets none of them', async () => {
  const smuggled = 'GET /admin HTTP/1.1\r\nhost: x\r\n\r\n';
  const { v, sent } = vm();
  const r = await bridge(v, lying(5, `hello${smuggled}`));
  assert.equal(r.status, 400);
  assert.equal(all(sent), '');
  assert.ok(closedFor(sent));
  // The bytes past the length come in a later read: the app got only the
  // bytes of the length.
  const second = vm();
  const r2 = await bridge(second.v, lying(5, 'hello', smuggled));
  assert.equal(r2.status, 400);
  assert.doesNotMatch(all(second.sent), /admin/);
  assert.ok(bodyBytes(second.sent) <= 5);
  assert.ok(closedFor(second.sent));
  assert.equal(second.v.conns.size, 0);
});

test('a body with fewer bytes than its content-length gets 400, and the app gets the end', async () => {
  const { v, sent } = vm();
  const r = await bridge(v, lying(10, 'abc'));
  assert.equal(r.status, 400);
  assert.ok(bodyBytes(sent) <= 3);
  assert.ok(closedFor(sent));
  assert.equal(v.conns.size, 0);
});

test('a body with the bytes of its content-length goes as it is', async () => {
  const { v, sent } = vm();
  const pending = bridge(v, lying(10, 'abcde', 'fghij'));
  await settle();
  assert.equal(all(sent).slice(headOf(sent).length), 'abcdefghij');
  assert.equal(closedFor(sent), false);
  v.tcps.get(conn(sent)).send(enc('HTTP/1.1 204 No Content\r\n\r\n'));
  assert.equal((await pending).status, 204);
});

test('after the answer of the app, a body with more bytes ends the connection', async () => {
  const { v, sent } = vm();
  let ctl;
  const stream = new ReadableStream({ start(c) { ctl = c; } });
  const pending = bridge(v, new Request(url, { method: 'POST', body: stream, duplex: 'half', headers: { 'content-length': '3' } }));
  ctl.enqueue(enc('abc'));
  await settle();
  v.tcps.get(conn(sent)).send(enc('HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n2\r\nok\r\n'));
  const r = await pending;
  assert.equal(r.status, 200);
  ctl.enqueue(enc('GET / HTTP/1.1\r\n\r\n'));
  ctl.close();
  assert.equal(await r.text(), 'ok');
  assert.ok(closedFor(sent));
  assert.equal(bodyBytes(sent), 3);
});

test('a content-length that is not a number of bytes gets 400 before the app sees the request', async () => {
  for (const declared of ['abc', '-1', '1.5', '5, 5', '1e3', '99999999999999999999']) {
    const { v, sent } = vm();
    const r = await bridge(v, new Request(url, { method: 'POST', body: 'hello', headers: { 'content-length': declared } }));
    assert.equal(r.status, 400, declared);
    assert.equal(sent.length, 0, declared);
  }
});

test('a request with no body gets no content-length of the client', async () => {
  const { v, sent } = vm();
  bridge(v, new Request('https://app.example.com/', { headers: { 'content-length': '10' } }));
  await settle();
  assert.doesNotMatch(headOf(sent), /content-length/);
});
