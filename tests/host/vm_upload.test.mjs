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
const { Vm } = await import('../../priv/wasm_host/worker/worker.js');

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
// The body bytes that the app got (after the head).
const bodyBytes = (sent) => data(sent).slice(1).reduce((n, s) => n + s.body.length, 0);
const settle = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)); };

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
  const head = text(data(sent)[0].body);
  assert.match(head, /^POST \/upload HTTP\/1.1\r\n/);
  assert.match(head, /content-length: 600000\r\n/);
  src.push(200000);
  src.push(200000);
  src.push(200000);
  src.end();
  await settle();
  // Parts went while less than 256 KB was unread; the rest waits for room.
  // A chunk of 200000 bytes goes in pieces: no part is above 80 KB.
  const first = bodyBytes(sent);
  assert.ok(head.length + first >= 256 * 1024, `${first}`);
  assert.ok(first < 600000, `${first}`);
  for (const s of data(sent).slice(1)) assert.ok(s.body.length <= 80 * 1024, `${s.body.length}`);
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
  const parts = data(sent).map((s) => text(s.body));
  assert.match(parts[0], /transfer-encoding: chunked\r\n/);
  assert.doesNotMatch(parts[0], /content-length/);
  assert.deepEqual(parts.slice(1), ['3\r\nxxx\r\n', '0\r\n\r\n']);
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
  const r = await pending;
  assert.equal(r.status, 413);
  await settle();
  const id = sent.find((s) => s.header.t === 'tcp_accept').header.conn;
  assert.ok(sent.some((s) => s.header.t === 'tcp_closed' && s.header.id === id));
  assert.equal(data(sent).length, 1);  // the head: 6 bytes are not a part
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
  assert.equal((await pending).status, 503);
  await settle();
  assert.equal(data(sent).length, before);
});

test('small chunks of a byte stream reach the app in parts of 16 KB or more', async () => {
  const { v, sent } = vm();
  let ctl;
  const stream = new ReadableStream({ type: 'bytes', start(c) { ctl = c; } });
  bridge(v, new Request(url, {
    method: 'POST', body: stream, duplex: 'half', headers: { 'content-length': String(20 * 2048) },
  }));
  for (let i = 0; i < 20; i++) ctl.enqueue(new Uint8Array(2048).fill(120));
  ctl.close();
  await settle();
  const parts = data(sent).slice(1).map((s) => s.body.length);
  assert.equal(parts.reduce((a, b) => a + b, 0), 20 * 2048);
  assert.ok(parts.length < 20, `parts: ${parts}`);
  for (const n of parts.slice(0, -1)) assert.ok(n >= 16384, `parts: ${parts}`);
});

// The option min of a BYOB read errors a stream that closes with fewer
// bytes (Node.js 26, Chromium): outside workerd, the host gathers the
// chunks of the default reader.
test('small chunks of a stream that is not a byte stream also go in parts of 16 KB or more', async () => {
  const { v, sent } = vm();
  const src = source();
  bridge(v, new Request(url, {
    method: 'POST', body: src.stream, duplex: 'half', headers: { 'content-length': String(20 * 2048 + 5) },
  }));
  for (let i = 0; i < 20; i++) src.push(2048);
  src.push(5);
  src.end();
  await settle();
  const parts = data(sent).slice(1).map((s) => s.body.length);
  assert.equal(parts.reduce((a, b) => a + b, 0), 20 * 2048 + 5);
  assert.ok(parts.length < 20, `parts: ${parts}`);
  for (const n of parts.slice(0, -1)) assert.ok(n >= 16384, `parts: ${parts}`);
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
  const parts = data(sent).map((s) => text(s.body));
  assert.match(parts[0], /content-length: 5\r\n/);
  assert.equal(parts.slice(1).join(''), 'a=b&c');
});
