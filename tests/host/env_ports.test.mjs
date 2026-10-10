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
const { Vm, portNames, PORT_DIR } = await import('../../priv/wasm_host/worker/worker.js');

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
