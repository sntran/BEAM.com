// The files of SQLite in the host (HostFiles of worker.js) on a
// MemoryStore: "node --test tests/host". The imports of Cloudflare and of
// the runtime are stand-ins, because these tests do not start a VM.
import { register } from 'node:module';
import { test } from 'node:test';
import assert from 'node:assert/strict';

register(`data:text/javascript,${encodeURIComponent(`
  const stub = { 'cloudflare:sockets': 'export const connect = () => {};',
                 './beam.mjs': 'export default () => {};', './beam.wasm': 'export default null;' };
  export async function resolve(spec, ctx, next) {
    return spec in stub ? { url: 'data:text/javascript,' + encodeURIComponent(stub[spec]), shortCircuit: true }
                        : next(spec, ctx);
  }`)}`);
const { HostFiles, MemoryStore } = await import('../../apps/wasm_host/priv/worker/worker.js');

// The operations of sqlite_vfs.c, and the codes of SQLite.
const OPEN = 1, CLOSE = 2, READ = 3, WRITE = 4, SYNC = 6, SIZE = 7, LOCK = 8, UNLOCK = 9, ACCESS = 11;
const BUSY = 5, FULL = 13, SHARED = 1, RESERVED = 2, NONE = 0;

// The memory of the VM: a name at 0, a buffer at 1024.
function vm() {
  const heap = new Uint8Array(1 << 20);
  const mem = { heap: () => heap, string: (p) => new TextDecoder().decode(heap.subarray(p, heap.indexOf(0, p))) };
  heap.set(new TextEncoder().encode('/data/app.db\0'), 0);
  return { heap, mem };
}

function host(store, opts) {
  const files = new HostFiles(store, opts), { heap, mem } = vm();
  const call = (op, id, offset = 0, buf = 0, n = 0) => files.call(op, id, offset, buf, n, mem);
  return {
    open: () => call(OPEN, 0, 0, 0, 6),
    access: () => call(ACCESS, 0, 0, 0, 0),
    close: (id) => call(CLOSE, id),
    lock: (id, level) => call(LOCK, id, 0, 0, level),
    unlock: (id, level) => call(UNLOCK, id, 0, 0, level),
    sync: (id) => call(SYNC, id),
    async write(id, offset, text) {
      const b = new TextEncoder().encode(text);
      heap.set(b, 1024);
      return call(WRITE, id, offset, 1024, b.length);
    },
    async read(id, offset, n) {
      const got = await call(READ, id, offset, 1024, n);
      return new TextDecoder().decode(heap.subarray(1024, 1024 + got));
    },
    async size(id) {
      await call(SIZE, id, 0, 2048, 8);
      return new DataView(heap.buffer).getFloat64(2048, true);
    },
  };
}

// A write transaction as SQLite makes it.
async function put(h, id, offset, text) {
  await h.lock(id, SHARED);
  const r = await h.lock(id, RESERVED);
  if (r) { await h.unlock(id, NONE); return r; }
  await h.write(id, offset, text);
  const c = await h.sync(id);
  await h.unlock(id, NONE);
  return c;
}

test('a commit is visible to a new read and to another VM', async () => {
  const store = new MemoryStore(), a = host(store), b = host(store);
  const fa = await a.open(), fb = await b.open();
  assert.equal(await a.access(), 0);
  assert.equal(await put(a, fa, 0, 'hello'), 0);
  assert.equal(await a.access(), 1);
  await b.lock(fb, SHARED);
  assert.equal(await b.read(fb, 0, 5), 'hello');
  assert.equal(await b.size(fb), 5);
  await b.unlock(fb, NONE);
});

test('a read keeps its version while another VM commits', async () => {
  const store = new MemoryStore(), a = host(store), b = host(store);
  const fa = await a.open(), fb = await b.open();
  await put(a, fa, 0, 'one');
  await b.lock(fb, SHARED);
  assert.equal(await b.read(fb, 0, 3), 'one');
  assert.equal(await put(a, fa, 0, 'two'), 0);
  assert.equal(await b.read(fb, 0, 3), 'one');
  await b.unlock(fb, NONE);
  await b.lock(fb, SHARED);
  assert.equal(await b.read(fb, 0, 3), 'two');
  await b.unlock(fb, NONE);
});

test('a write from an old version gets SQLITE_BUSY, and a new read can write', async () => {
  const store = new MemoryStore(), a = host(store), b = host(store);
  const fa = await a.open(), fb = await b.open();
  await put(a, fa, 0, 'one');
  await b.lock(fb, SHARED);
  await put(a, fa, 0, 'two');
  assert.equal(await b.lock(fb, RESERVED), BUSY);
  await b.unlock(fb, NONE);
  assert.equal(await put(b, fb, 0, 'six'), 0);
  await a.lock(fa, SHARED);
  assert.equal(await a.read(fa, 0, 3), 'six');
  await a.unlock(fa, NONE);
});

test('the write lock stops a second writer until the first one ends', async () => {
  const store = new MemoryStore(), a = host(store), b = host(store);
  const fa = await a.open(), fb = await b.open();
  await a.lock(fa, SHARED);
  assert.equal(await a.lock(fa, RESERVED), 0);
  await b.lock(fb, SHARED);
  assert.equal(await b.lock(fb, RESERVED), BUSY);
  await b.unlock(fb, NONE);
  await a.write(fa, 0, 'mine');
  assert.equal(await a.sync(fa), 0);
  await a.unlock(fa, SHARED);
  assert.equal(await put(b, fb, 4, '+b'), 0);
  await a.unlock(fa, NONE);
  await a.lock(fa, SHARED);
  assert.equal(await a.read(fa, 0, 6), 'mine+b');
  await a.unlock(fa, NONE);
});

test('a write lock ends after its lease, and a close ends it', async () => {
  const store = new MemoryStore(), a = host(store, { lease: 0 }), b = host(store);
  const fa = await a.open(), fb = await b.open();
  await a.lock(fa, SHARED);
  assert.equal(await a.lock(fa, RESERVED), 0);
  assert.equal(await put(b, fb, 0, 'b'), 0);
  const c = host(store), fc = await c.open();
  await b.lock(fb, SHARED);
  assert.equal(await b.lock(fb, RESERVED), 0);
  await b.close(fb);
  assert.equal(await put(c, fc, 0, 'c'), 0);
});

test('a commit that is too large gets SQLITE_FULL and changes nothing', async () => {
  const store = new MemoryStore(), a = host(store, { maxBlocks: 1 });
  const fa = await a.open();
  await a.lock(fa, SHARED);
  await a.lock(fa, RESERVED);
  await a.write(fa, 0, 'x');
  await a.write(fa, 4096, 'y');
  assert.equal(await a.sync(fa), FULL);
  await a.unlock(fa, NONE);
  assert.equal(await a.access(), 0);
});
