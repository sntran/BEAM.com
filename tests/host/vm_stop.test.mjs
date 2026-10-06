// A VM that stops, the time limit of a request, and the limits of the host
// (Vm of worker.js). "node --test tests/host". The imports of the runtime
// are stand-ins, because these tests do not start a VM.
import { register } from 'node:module';
import { test } from 'node:test';
import assert from 'node:assert/strict';

register(`data:text/javascript,${encodeURIComponent(`
  const stub = { './beam.mjs': 'export default () => {};', './beam.wasm': 'export default null;' };
  export async function resolve(spec, ctx, next) {
    return spec in stub ? { url: 'data:text/javascript,' + encodeURIComponent(stub[spec]), shortCircuit: true }
                        : next(spec, ctx);
  }`)}`);
const { Vm, Persist } = await import('../../priv/wasm_host/worker/worker.js');

// A Vm with the state of a VM that is ready, and the events that it gives
// to the app in sent. listening: the listener of the app on port 4000.
// listens: the app listens on its port (the listener of wasm_tcp).
function vm(env = {}, { listening = async () => {}, listens = true } = {}) {
  const v = Object.create(Vm.prototype);
  const sent = [];
  let markDead;
  Object.assign(v, {
    env, vars: {}, scheme: true, nextId: 0, tcps: new Map(), listeners: new Map(listens ? [[4000, 'l0']] : []), waitListen: new Map(),
    conns: new Set(), sockets: 0, peak: 0, dead: null, onDead: null, handlers: [], jobs: [],
    died: new Promise((r) => { markDead = r; }),
    statics: Promise.resolve(null), ready: Promise.resolve(),
    beam: { HEAPU8: new Uint8Array(1 << 20) },
    listening,
    event: (header, body) => { if (!v.dead) sent.push({ header, body }); },
  });
  v.markDead = markDead;
  return { v, sent };
}

const request = (path = '/', init = {}) => new Request(`https://app.example.com${path}`, init);
const bridge = (v, r, upgrade = false) => v.bridge(r, new URL(r.url), upgrade, undefined, () => {});

// The bytes of the request reached the app.
async function delivered(sent) {
  for (let i = 0; i < 100 && !sent.some((s) => s.header.t === 'tcp_data'); i++) await null;
  assert.ok(sent.some((s) => s.header.t === 'tcp_data'), 'no bytes for the app');
}

test('a VM that stops answers its open requests with 503, and the owner drops it', async () => {
  const { v, sent } = vm();
  let reason = null;
  v.onDead = (r) => { reason = r; };
  const pending = bridge(v, request('/upload', { method: 'POST', body: 'x' }));
  await delivered(sent);
  v.die('exit status 1');
  const r = await pending;
  assert.equal(r.status, 503);
  assert.equal(r.headers.get('retry-after'), '1');
  assert.equal(reason, 'exit status 1');
  assert.equal(v.conns.size, 0);
  assert.equal(v.tcps.size, 0);
});

// A plain Worker: a thread of the VM can run in the context of a request
// that ended, where I/O throws. The stop works in the request of each
// connection (its handler h).
test('a plain Worker answers each open request in its own request', async () => {
  const { v, sent } = vm();
  v.plain = true;
  const h = { jobs: [], wake: () => {}, sockets: 1 };
  const pending = v.bridge(request('/'), new URL('https://app.example.com/'), false, h, () => {});
  await delivered(sent);
  v.die('exit status 3');
  assert.equal(h.jobs.length, 1);
  for (const f of h.jobs.splice(0)) f();
  assert.equal((await pending).status, 503);
  assert.equal(h.sockets, 1);  // bridge() added 1, and the stop took it away
});

test('a log line that throws goes to an open request', () => {
  const { v } = vm();
  v.plain = true;
  const h = { jobs: [], wake: () => {} };
  v.handlers.push(h);
  const lines = [];
  const log = console.log;
  console.log = () => { throw new Error('Cannot perform I/O on behalf of a different request'); };
  try {
    v.log('beam: a line');
  } finally {
    console.log = log;
  }
  assert.equal(h.jobs.length, 1);
  console.log = (line) => lines.push(line);
  try {
    h.jobs[0]();
  } finally {
    console.log = log;
  }
  assert.deepEqual(lines, ['beam: a line']);
});

test('after the stop, a new request gets 503 at once', async () => {
  const { v, sent } = vm();
  v.die('exit status 2');
  const r = await v.request(request('/'), undefined, () => {});
  assert.equal(r.status, 503);
  assert.equal(sent.length, 0);
});

test('a request that waits for the listener of the app gets 503 when the VM stops', async () => {
  const { v } = vm({}, { listens: false });
  const pending = bridge(v, request('/'));
  await null;
  v.die('exit status 1');
  assert.equal((await pending).status, 503);
});

test('a WebSocket of a VM that stops closes with 1011', () => {
  const { v } = vm();
  const closed = [];
  const c = { ws: { close: (code) => closed.push(code) }, counted: true, status: 101 };
  v.conns.add(c);
  v.sockets = 1;
  v.die('exit status 1');
  assert.deepEqual(closed, [1011]);
  assert.equal(v.sockets, 0);
});

test('no head of a response in BEAM_REQUEST_TIMEOUT seconds: 504, and the app gets the end', async () => {
  const { v, sent } = vm({ BEAM_REQUEST_TIMEOUT: '0.05' });
  const pending = bridge(v, request('/slow'));
  await delivered(sent);
  const r = await pending;
  assert.equal(r.status, 504);
  const id = sent.find((s) => s.header.t === 'tcp_data').header.id;
  assert.ok(sent.some((s) => s.header.t === 'tcp_closed' && s.header.id === id));
  assert.equal(v.conns.size, 0);
});

test('an app that does not listen in BEAM_REQUEST_TIMEOUT seconds: 504', async () => {
  const { v, sent } = vm({ BEAM_REQUEST_TIMEOUT: '0.05' }, { listens: false });
  const r = await bridge(v, request('/'));
  assert.equal(r.status, 504);
  assert.equal(sent.length, 0);
  assert.equal(v.conns.size, 0);
  // The request that ended waits no more.
  assert.equal(v.waitListen.size, 0);
  assert.equal(v.stopWaits.size, 0);
});

test('BEAM_REQUEST_TIMEOUT=0 sets no time limit', async () => {
  const { v, sent } = vm({ BEAM_REQUEST_TIMEOUT: '0' });
  const pending = bridge(v, request('/slow'));
  await delivered(sent);
  const c = [...v.conns][0];
  assert.equal(c.timer, undefined);
  v.die('end of the test');
  assert.equal((await pending).status, 503);
});

test('the head of the response stops the time limit', async () => {
  const { v, sent } = vm({ BEAM_REQUEST_TIMEOUT: '0.05' });
  const pending = bridge(v, request('/'));
  await delivered(sent);
  const id = sent.find((s) => s.header.t === 'tcp_data').header.id;
  v.tcps.get(id).send(new TextEncoder().encode('HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok'));
  const r = await pending;
  assert.equal(r.status, 200);
  assert.equal(await r.text(), 'ok');
  // After the time limit: no 504, and only the end of the response closed
  // the connection.
  await new Promise((done) => setTimeout(done, 100));
  assert.equal(sent.filter((s) => s.header.t === 'tcp_closed' && s.header.id === id).length, 1);
  assert.equal(v.conns.size, 0);
});

test('above BEAM_MAX_REQUESTS, a request gets 503 before the app reads it', async () => {
  const { v, sent } = vm({ BEAM_MAX_REQUESTS: '1' });
  const first = bridge(v, request('/a'));
  await delivered(sent);
  const r = await bridge(v, request('/b', { method: 'POST', body: 'big' }));
  assert.equal(r.status, 503);
  assert.equal(r.headers.get('retry-after'), '1');
  assert.equal(sent.filter((s) => s.header.t === 'tcp_accept').length, 1);
  v.die('end of the test');
  assert.equal((await first).status, 503);
});

test('above BEAM_MAX_WEBSOCKETS, an upgrade gets 503', async () => {
  const { v, sent } = vm({ BEAM_MAX_WEBSOCKETS: '1' });
  v.sockets = 1;
  const r = await bridge(v, request('/live/websocket', { headers: { upgrade: 'websocket' } }), true);
  assert.equal(r.status, 503);
  assert.equal(sent.length, 0);
});

test('the memory log: one line for each 8 MB of growth', () => {
  const { v } = vm();
  const lines = [];
  const log = console.log;
  console.log = (line) => lines.push(line);
  try {
    v.peak = 1;
    v.notePeak();
    v.beam.HEAPU8 = new Uint8Array(9 << 20);
    v.notePeak();
    v.notePeak();
  } finally {
    console.log = log;
  }
  assert.deepEqual(lines, ['beam: memory 9 MB (a new peak of this VM)']);
  assert.equal(v.peak, 9);
});

// The turns of a scheduler that computes (jspiSchedule.turn): in a Durable
// Object, each turnEvery-th turn is a timer, so that the I/O of the object
// runs; the others are tasks. A plain Worker gives only tasks.
test('a turn is a timer once for each BEAM_YIELD_REDS reductions', async () => {
  const { v } = vm();
  const posted = [];
  Object.assign(v, { plain: false, turns: 0, turnEvery: 3, post: (f) => posted.push(f) });
  const timed = [];
  for (let i = 0; i < 6; i++) v.turn(() => timed.push(i));
  assert.equal(posted.length, 4);
  await new Promise((r) => setTimeout(r, 10));
  assert.deepEqual(timed, [2, 5]);
});

test('a plain Worker gives a turn to its open request', () => {
  const { v } = vm();
  let woke = 0;
  Object.assign(v, { plain: true, turns: 0, turnEvery: 1, jobs: [] });
  v.handlers.push({ wake: () => woke++ });
  v.turn(() => {});
  assert.equal(v.jobs.length, 1);
  assert.equal(woke, 1);
});

// BEAM_PERSIST: a write saves after 1 s. A stop of the VM in that time
// saves the file at once, so the stop loses no write.
test('a VM that stops saves the files that it wrote after the last save', () => {
  const rows = [];
  const sql = { exec: (q, ...a) => { rows.push([q.split(' ')[0], ...a]); return []; } };
  const persist = new Persist(sql, ['/data']);
  const FS = {
    cwd: () => '/', write() {}, close() {}, truncate() {}, mkdir() {}, unlink() {}, rmdir() {}, rename() {},
    lookupPath: () => ({ node: { mode: 0o100644 } }),
    isDir: () => false, isFile: () => true,
    readFile: () => new Uint8Array([1, 2, 3]),
  };
  persist.attach(FS);
  FS.write({ path: '/data/a.db' });
  assert.ok(persist.flush, 'no timer for the save');
  assert.ok(persist.dirty.has('/data/a.db'));
  const { v } = vm();
  v.persist = persist;
  v.die('exit status 1');
  assert.equal(persist.flush, null);
  assert.equal(persist.dirty.size, 0);
  assert.ok(rows.some(([q, path, , size]) => q === 'INSERT' && path === '/data/a.db' && size === 3), 'the file did not save');
});
