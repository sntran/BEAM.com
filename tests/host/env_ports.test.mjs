// The ports to the bindings of env (worker.js, spawnPort): the port
// {spawn_executable, "/env/NAME"} of the VM runs the binding NAME. "node
// --test tests/host". The imports of the runtime are stand-ins, because
// these tests do not start a VM.
import { register } from 'node:module';
import { test } from 'node:test';
import assert from 'node:assert/strict';

register(`data:text/javascript,${encodeURIComponent(`
  const stub = { './beam.mjs': 'export default () => {};', './beam.wasm': 'export default null;' };
  export async function resolve(spec, ctx, next) {
    return spec in stub ? { url: 'data:text/javascript,' + encodeURIComponent(stub[spec]), shortCircuit: true }
                        : next(spec, ctx);
  }`)}`);
const { Vm, openPort, portNames, PORT_DIR, PORT_CLAIM_MS } = await import('../../priv/wasm_host/worker/worker.js');

const enc = (t) => new TextEncoder().encode(t);
const dec = (parts) => new TextDecoder().decode(Buffer.concat(parts));

// A Vm with only the state of its ports.
function vm(env) {
  const v = Object.create(Vm.prototype);
  const logs = [];
  Object.assign(v, { env, ports: new Set(), dead: null, log: (s) => logs.push(s) });
  return { v, logs };
}

// The events of a port, as jspi_lib.js gives them: the bytes for the VM,
// and a promise of the exit status.
function events() {
  const data = [];
  let exited;
  const exit = new Promise((r) => { exited = r; });
  return { data, exit, events: { data: (b) => data.push(Buffer.from(b)), exit: (code) => exited(code) } };
}

// A port program: the bytes of the VM in capitals, with the arguments first.
const upper = {
  port(stdin, { argv }) {
    return stdin.pipeThrough(new TransformStream({
      start(c) { c.enqueue(enc(`${argv.join(' ')}:`)); },
      transform(chunk, c) { c.enqueue(enc(new TextDecoder().decode(chunk).toUpperCase())); },
    }));
  },
};

test('portNames: the bindings with port() and the Durable Object namespaces, not the others', () => {
  const env = {
    UPPER: upper,
    OBJECTS: { idFromName: () => {}, get: () => {}, newUniqueId: () => {} },
    PHX_HOST: 'example.com',
    KV: { get: () => {}, put: () => {} },
    'A.B': upper,
    NONE: null,
  };
  assert.deepEqual(portNames(env), ['UPPER', 'OBJECTS']);
  assert.deepEqual(portNames(undefined), []);
  assert.equal(PORT_DIR, '/env');
});

test('a port to a binding: the bytes of the VM go to port(), and its bytes come back, then exit 0', async () => {
  const { v } = vm({ UPPER: upper });
  const e = events();
  const p = v.spawnPort({ path: '/env/UPPER', argv: ['/env/UPPER', 'a', 'b'] }, e.events);
  assert.equal(v.ports.size, 1);
  p.write(enc('hello '));
  p.write(enc('world'));
  p.end();
  assert.equal(await e.exit, 0);
  assert.equal(dec(e.data), 'a b:HELLO WORLD');
  assert.equal(v.ports.size, 0);
});

test('a Durable Object namespace: the object of the first argument, or a new one', async () => {
  const calls = [];
  const ns = {
    idFromName: (n) => `name:${n}`,
    newUniqueId: () => 'unique',
    get: (id) => { calls.push(id); return upper; },
  };
  const { v } = vm({ OBJECTS: ns });
  for (const argv of [['/env/OBJECTS', 'x1'], ['/env/OBJECTS']]) {
    const e = events();
    const p = v.spawnPort({ path: '/env/OBJECTS', argv }, e.events);
    p.end();
    assert.equal(await e.exit, 0);
  }
  assert.deepEqual(calls, ['name:x1', 'unique']);
});

test('a path that is not a port: ENOENT, and nothing starts', () => {
  const { v } = vm({ UPPER: upper, PHX_HOST: 'example.com' });
  for (const path of ['/env/NONE', '/env/PHX_HOST', '/usr/bin/sh', '/env/UPPER/x', '/env/']) {
    assert.throws(() => v.spawnPort({ path, argv: [path] }, events().events), (e) => e.errno === 44);
  }
  assert.equal(v.ports.size, 0);
});

test('a port() that fails, or a stream that fails: exit 1 and a line in the log', async () => {
  const { v, logs } = vm({
    BAD: { port() { throw new Error('no such method'); } },
    BROKEN: { port: () => new ReadableStream({ pull(c) { c.error(new Error('the object stopped')); } }) },
  });
  for (const name of ['BAD', 'BROKEN']) {
    const e = events();
    v.spawnPort({ path: `/env/${name}`, argv: [`/env/${name}`] }, e.events);
    assert.equal(await e.exit, 1);
  }
  assert.match(logs[0], /\/env\/BAD: no such method/);
  assert.match(logs[1], /\/env\/BROKEN: the object stopped/);
});

test('a VM that stops ends its ports: the stdin of port() ends', async () => {
  let ended;
  const gone = new Promise((r) => { ended = r; });
  const { v } = vm({
    WAIT: {
      port(stdin) {
        (async () => { for await (const _ of stdin); ended(); })();
        return new ReadableStream({});
      },
    },
  });
  const e = events();
  const p = v.spawnPort({ path: '/env/WAIT', argv: ['/env/WAIT'] }, e.events);
  p.write(enc('x'));
  await new Promise((r) => setImmediate(r));
  v.dead = 'exit status 1';
  for (const port of v.ports) port.stop();
  await gone;
  await e.exit;
  // A VM that stopped starts no port.
  assert.throws(() => v.spawnPort({ path: '/env/WAIT', argv: ['/env/WAIT'] }, events().events), (err) => err.errno === 44);
});

const WINDOW = 256 * 1024;
const settle = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)); };

// All the bytes of a stream.
async function all(stream) {
  const parts = [];
  for await (const p of stream) parts.push(Buffer.from(p));
  return Buffer.concat(parts);
}

test('flow control from the VM: write() gives false at a full window, and a read of port() asks for more', async () => {
  let stdin;
  const { v } = vm({ HOLD: { port(s) { stdin = s.getReader(); return new ReadableStream({}); } } });
  const e = events();
  let pulls = 0;
  e.events.pull = () => { pulls++; };
  const p = v.spawnPort({ path: '/env/HOLD', argv: ['/env/HOLD'] }, e.events);
  await settle();
  assert.equal(p.write(new Uint8Array(WINDOW / 2)), true);
  assert.equal(p.write(new Uint8Array(WINDOW / 2)), false);
  const before = pulls;
  const { value } = await stdin.read();
  await settle();
  assert.equal(value.byteLength, WINDOW / 2);
  assert.ok(pulls > before, 'a read of port() calls pull()');
  p.stop();
  assert.equal(p.write(enc('x')), false, 'a port that ended takes no bytes');
  assert.equal(await e.exit, 0);
});

test('flow control to the VM: a false of data() stops the reads of port() until room()', async () => {
  let reads = 0;
  let cancelled = false;
  const source = {
    port: () => new ReadableStream({
      pull(c) { reads++; c.enqueue(new Uint8Array(1024)); },
      cancel() { cancelled = true; },
    }, { highWaterMark: 0 }),
  };
  const { v } = vm({ SOURCE: source });
  const e = events();
  let free;
  let closed = false;
  e.events.data = (b) => { e.data.push(Buffer.from(b)); return false; };
  e.events.room = () => new Promise((r) => { free = r; });
  e.events.closed = () => closed;
  v.spawnPort({ path: '/env/SOURCE', argv: ['/env/SOURCE'] }, e.events);
  await settle();
  assert.equal(reads, 1);
  assert.equal(e.data.length, 1);
  free();
  await settle();
  assert.equal(reads, 2, 'room() gives one more read');
  // The VM closed the port: the result of port() stops.
  closed = true;
  free();
  assert.equal(await e.exit, 0);
  assert.equal(cancelled, true);
  assert.equal(reads, 2);
});

test('BEAM_PORT_OUTPUT=response: the result waits for claim(), and goes to the writer, not to the VM', async () => {
  const { v } = vm({ UPPER: upper });
  const e = events();
  const p = v.spawnPort({ path: '/env/UPPER', argv: ['/env/UPPER', 'x'], env: ['BEAM_PORT_OUTPUT=response'], pid: 7 }, e.events);
  assert.equal(p.pid, 7);
  p.write(enc('abc'));
  p.end();
  await settle();
  assert.equal(e.data.length, 0);
  const { readable, writable } = new TransformStream();
  assert.equal(p.claim(writable.getWriter()), true);
  assert.equal(p.claim(new WritableStream().getWriter()), false, 'one claim only');
  assert.equal((await all(readable)).toString(), 'x:ABC');
  assert.equal(await e.exit, 0);
  assert.equal(e.data.length, 0);
});

test('BEAM_PORT_OUTPUT=response: a port that ended drops its result after claimMs with no claim', async () => {
  assert.equal(PORT_CLAIM_MS, 10000);
  let cancelled = false;
  const env = { GIVE: { port: () => new ReadableStream({ pull(c) { c.enqueue(enc('x')); }, cancel() { cancelled = true; } }) } };
  const e = events();
  const p = openPort(env, { path: '/env/GIVE', argv: ['/env/GIVE'], env: ['BEAM_PORT_OUTPUT=response'], pid: 8 }, e.events, { claimMs: 0 });
  await settle();
  p.end();
  assert.equal(await e.exit, 0);
  assert.equal(cancelled, true);
  assert.equal(e.data.length, 0);
  assert.equal(p.claim(new WritableStream().getWriter()), false);
});

test('BEAM_PORT_OUTPUT=response: a result that fails after the claim aborts the writer, then exit 1', async () => {
  const { v, logs } = vm({
    BROKEN: {
      port: () => new ReadableStream({
        start(c) { c.enqueue(enc('part')); },
        pull(c) { c.error(new Error('the object stopped')); },
      }),
    },
  });
  const e = events();
  const p = v.spawnPort({ path: '/env/BROKEN', argv: ['/env/BROKEN'], env: ['BEAM_PORT_OUTPUT=response'], pid: 9 }, e.events);
  const { readable, writable } = new TransformStream();
  assert.equal(p.claim(writable.getWriter()), true);
  await assert.rejects(all(readable), /the object stopped/);
  assert.equal(await e.exit, 1);
  assert.match(logs[0], /\/env\/BROKEN: the object stopped/);
});

// A Vm with the state of a VM that is ready, the ports of env, and the
// events that it gives to the app in sent (as in vm_response.test.mjs).
function bridgeVm(env) {
  const v = Object.create(Vm.prototype);
  const sent = [];
  Object.assign(v, {
    env: { BEAM_REQUEST_TIMEOUT: '0', ...env }, vars: {}, scheme: true, nextId: 0, tcps: new Map(),
    listeners: new Map([[4000, 'l0']]), conns: new Set(), sockets: 0, peak: 0, dead: null, onDead: null,
    died: new Promise(() => {}), markDead: () => {}, handlers: [], jobs: [], ports: new Set(), log: () => {},
    beam: { HEAPU8: new Uint8Array(1 << 20) },
    listening: async () => {},
    event: (header, body) => { if (!v.dead) sent.push({ header, body }); },
  });
  return { v, sent };
}

// A port of the VM that waits for a response (pid), and a request to the
// VM: send(text) gives the bytes of the app for it.
async function splice(method = 'GET') {
  const { v, sent } = bridgeVm({ UPPER: upper });
  const e = events();
  const port = v.spawnPort({ path: '/env/UPPER', argv: ['/env/UPPER', 'x'], env: ['BEAM_PORT_OUTPUT=response'], pid: 1001 }, e.events);
  port.write(enc('hello'));
  port.end();
  const pending = v.bridge(new Request('https://app.example.com/x', { method }), new URL('https://app.example.com/x'), false, undefined, () => {});
  await settle();
  const id = sent.find((s) => s.header.t === 'tcp_accept').header.conn;
  return { v, e, port, pending, send: (t) => v.tcps.get(id).send(enc(t)) };
}

test('x-beam-port: the result of the port is the body of the response, and the bytes of the app after the head go nowhere', async () => {
  const { e, pending, send } = await splice();
  send('HTTP/1.1 200 OK\r\nx-beam-port: 1001\r\ncontent-type: text/plain\r\ncontent-length: 3\r\n\r\nabc');
  const r = await pending;
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('x-beam-port'), null);
  assert.equal(r.headers.get('content-length'), null, 'the length of the app is not the length of the port');
  assert.equal(r.headers.get('content-type'), 'text/plain');
  assert.equal(await r.text(), 'x:HELLO');
  assert.equal(await e.exit, 0);
  assert.equal(e.data.length, 0);
});

// workerd has FixedLengthStream (a stand-in here: Node.js has none).
test('x-beam-port-length: the body goes through a FixedLengthStream of that length', async () => {
  const lengths = [];
  globalThis.FixedLengthStream = class extends TransformStream {
    constructor(n) { super(); lengths.push(n); }
  };
  try {
    const { pending, send } = await splice();
    send('HTTP/1.1 200 OK\r\nx-beam-port: 1001\r\nx-beam-port-length: 7\r\ntransfer-encoding: chunked\r\n\r\n0\r\n\r\n');
    const r = await pending;
    assert.equal(r.headers.get('x-beam-port-length'), null);
    assert.equal(r.headers.get('content-length'), '7');
    assert.equal(await r.text(), 'x:HELLO');
    assert.deepEqual(lengths, [7]);
  } finally {
    delete globalThis.FixedLengthStream;
  }
});

test('x-beam-port of no port that waits: 502', async () => {
  for (const pid of ['999', 'abc']) {
    const { port, e, pending, send } = await splice();
    send(`HTTP/1.1 200 OK\r\nx-beam-port: ${pid}\r\ncontent-length: 0\r\n\r\n`);
    const r = await pending;
    assert.equal(r.status, 502);
    port.stop();
    assert.equal(await e.exit, 0);
  }
});

test('a VM that stops ends a port that waits for a claim', async () => {
  const { v } = vm({ UPPER: upper });
  const e = events();
  const p = v.spawnPort({ path: '/env/UPPER', argv: ['/env/UPPER'], env: ['BEAM_PORT_OUTPUT=response'], pid: 3 }, e.events);
  await settle();
  p.stop();
  assert.equal(await e.exit, 0);
  assert.equal(p.claim(new WritableStream().getWriter()), false);
  assert.equal(v.ports.size, 0);
});

test('x-beam-port in a response with no body (HEAD): no body, and the port still waits', async () => {
  const { port, pending, send } = await splice('HEAD');
  send('HTTP/1.1 200 OK\r\nx-beam-port: 1001\r\ncontent-length: 7\r\n\r\n');
  const r = await pending;
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('x-beam-port'), null);
  assert.equal(r.body, null);
  const { readable, writable } = new TransformStream();
  assert.equal(port.claim(writable.getWriter()), true);
  assert.equal((await all(readable)).toString(), 'x:HELLO');
});

// A plain Worker: its VM serves many requests. The port uses the bindings
// of the last request, starts in a job of the runner of that request, and
// counts as a socket of that request until its end.
test('a plain Worker: the port uses the last request, and holds it until the end of the port', async () => {
  const { v } = vm({});
  const h = { sockets: 0, wake: null };
  let jobs = 0;
  Object.assign(v, {
    plain: true,
    handlers: [{ sockets: 0 }, h],
    bindings: { UPPER: upper },
    inRequest: (job) => { jobs++; queueMicrotask(job); },
  });
  const e = events();
  const p = v.spawnPort({ path: '/env/UPPER', argv: ['/env/UPPER', 'y'] }, e.events);
  assert.equal(h.sockets, 1);
  assert.equal(v.handlers[0].sockets, 0);
  assert.equal(jobs, 1);
  p.write(enc('ok'));
  p.end();
  assert.equal(await e.exit, 0);
  await settle();
  assert.equal(dec(e.data), 'y:OK');
  assert.equal(h.sockets, 0);
});

// A byte stream of JavaScript that closes while a BYOB read waits: the
// read ends only with respond(0). So the host reads the result of port()
// with the default reader (not in workerd), and the end of stdin ends a
// BYOB read of port().
test('a byte stream of JavaScript ends the port, and the end of stdin ends a BYOB read of port()', async () => {
  const source = {
    port: () => {
      let n = 0;
      return new ReadableStream({ type: 'bytes', pull(c) { if (n++ < 2) c.enqueue(enc('ab')); else c.close(); } });
    },
  };
  let got = null;
  const reader = {
    port(stdin) {
      const r = stdin.getReader({ mode: 'byob' });
      return new ReadableStream({
        async start(c) {
          const parts = [];
          for (;;) {
            const { done, value } = await r.read(new Uint8Array(64));
            if (done) break;
            parts.push(Buffer.from(value));
          }
          got = Buffer.concat(parts).toString();
          c.close();
        },
      });
    },
  };
  const { v } = vm({ SOURCE: source, READER: reader });
  const a = events();
  v.spawnPort({ path: '/env/SOURCE', argv: ['/env/SOURCE'] }, a.events).end();
  assert.equal(await a.exit, 0);
  assert.equal(dec(a.data), 'abab');
  const b = events();
  const p = v.spawnPort({ path: '/env/READER', argv: ['/env/READER'] }, b.events);
  p.write(enc('xyz'));
  await settle();
  p.end();
  assert.equal(await b.exit, 0);
  assert.equal(got, 'xyz');
});

// A response with x-beam-port-length: the body ends at that length, also
// when the result of the port does not end yet. Else the client closes
// first, and Cloudflare cancels the request and the port.
test('BEAM_PORT_OUTPUT=response: the body ends at its length, before the end of the result', async () => {
  let cancelled = false;
  const { v } = vm({
    SLOW: {
      port: () => new ReadableStream({
        start(c) { c.enqueue(enc('abcdef')); },
        cancel() { cancelled = true; },
      }),
    },
  });
  const e = events();
  const p = v.spawnPort({ path: '/env/SLOW', argv: ['/env/SLOW'], env: ['BEAM_PORT_OUTPUT=response'], pid: 12 }, e.events);
  const { readable, writable } = new TransformStream();
  assert.equal(p.claim(writable.getWriter(), 4), true);
  assert.equal((await all(readable)).toString(), 'abcd');
  assert.equal(await e.exit, 0);
  assert.equal(cancelled, true);
});
