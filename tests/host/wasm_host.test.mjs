// WasmHost of worker.js (the WebAssembly of wasm_host_wasm.erl):
// "node --test tests/host". The imports of the runtime are stand-ins,
// because these tests do not start a VM.
import { register } from 'node:module';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

register(`data:text/javascript,${encodeURIComponent(`
  const stub = { './beam.mjs': 'export default () => {};', './beam.wasm': 'export default null;' };
  export async function resolve(spec, ctx, next) {
    return spec in stub ? { url: 'data:text/javascript,' + encodeURIComponent(stub[spec]), shortCircuit: true }
                        : next(spec, ctx);
  }`)}`);
const { WasmHost, wasmSignatures } = await import('../../priv/wasm_host/worker/worker.js');

// (module (func (export "add") (param i32 i32) (result i32) ...)
//         (func (export "big") (param i64) (result i64) x * x)
//         (func (export "boom") unreachable) (memory (export "memory") 1))
const small = new Uint8Array([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
  0x01, 0x0f, 0x03, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, 0x60, 0x01, 0x7e, 0x01, 0x7e, 0x60, 0x00, 0x00,
  0x03, 0x04, 0x03, 0x00, 0x01, 0x02,
  0x05, 0x03, 0x01, 0x00, 0x01,
  0x07, 0x1d, 0x04, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x03, 0x62, 0x69, 0x67, 0x00, 0x01,
  0x04, 0x62, 0x6f, 0x6f, 0x6d, 0x00, 0x02, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00,
  0x0a, 0x15, 0x03, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
  0x07, 0x00, 0x20, 0x00, 0x20, 0x00, 0x7e, 0x0b, 0x03, 0x00, 0x00, 0x0b,
]);
const b64 = (b) => Buffer.from(b).toString('base64');
const text = (s) => Buffer.from(s ?? '', 'base64').toString();

async function instance(host, bytes, opts = {}) {
  const m = await host.op('compile', { bytes: b64(bytes) });
  const i = await host.op('instantiate', { module: m.ok, args: opts.args ?? [], env: opts.env ?? [] });
  return i.ok;
}

test('the types of the exported functions', () => {
  assert.deepEqual(wasmSignatures(small), {
    add: { params: [0x7f, 0x7f], results: [0x7f] },
    big: { params: [0x7e], results: [0x7e] },
    boom: { params: [], results: [] },
  });
});

test('a call with i32 and i64 values, a trap and a missing function', async () => {
  const host = new WasmHost(), id = await instance(host, small);
  assert.deepEqual((await host.op('call', { instance: id, name: 'add', args: [1, 2] })).ok, [3]);
  assert.deepEqual((await host.op('call', { instance: id, name: 'big', args: [3] })).ok, [9]);
  // 3037000499 squared is more than 2^53: a string on the wire.
  assert.deepEqual((await host.op('call', { instance: id, name: 'big', args: [3037000499] })).ok,
                   [{ i: '9223372030926249001' }]);
  assert.deepEqual((await host.op('call', { instance: id, name: 'big', args: [{ i: '3037000499' }] })).ok,
                   [{ i: '9223372030926249001' }]);
  assert.match((await host.op('call', { instance: id, name: 'boom', args: [] })).trap, /unreachable/);
  assert.equal((await host.op('call', { instance: id, name: 'none', args: [] })).error, 'not_found');
  assert.equal((await host.op('exists', { instance: id, name: 'add' })).ok, true);
});

test('the memory: size, grow, read and write', async () => {
  const host = new WasmHost(), id = await instance(host, small);
  assert.equal((await host.op('memory_size', { instance: id })).ok, 65536);
  assert.equal((await host.op('write', { instance: id, offset: 10, data: b64(Buffer.from('beam')) })).ok, true);
  assert.equal(text((await host.op('read', { instance: id, offset: 10, length: 4 })).ok), 'beam');
  assert.equal((await host.op('read', { instance: id, offset: 65535, length: 4 })).error, 'out_of_bounds');
  assert.equal((await host.op('memory_grow', { instance: id, pages: 1 })).ok, 1);
  assert.equal((await host.op('memory_size', { instance: id })).ok, 131072);
});

test('a WASI program from C: its output, arguments, environment and exit code', async () => {
  const hello = fs.readFileSync(new URL('../../docs/notebooks/files/hello.wasm', import.meta.url));
  const host = new WasmHost();
  let id = await instance(host, hello, { args: ['hello'], env: [['WHO', 'beam.com']] });
  let r = await host.op('call', { instance: id, name: '_start', args: [] });
  assert.equal(r.exit ?? 0, 0);
  assert.equal(text(r.stdout), 'Hello from C, in WebAssembly.\nWHO=beam.com\n');
  assert.equal(text(r.stderr), 'a line on stderr\n');
  id = await instance(host, hello, { args: ['hello', 'a', 'b'] });
  r = await host.op('call', { instance: id, name: '_start', args: [] });
  assert.equal(r.exit, 3);
  assert.match(text(r.stdout), /argument 2: b\n/);
});

test('a module that imports another thing than WASI', async () => {
  const host = new WasmHost();
  // (module (import "env" "f" (func)))
  const bytes = new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x02, 0x09, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x01, 0x66, 0x00, 0x00]);
  const m = await host.op('compile', { bytes: b64(bytes) });
  await assert.rejects(host.op('instantiate', { module: m.ok, args: [], env: [] }), /only WASI/);
});

test('the bounds of the requests, and release', async () => {
  const host = new WasmHost(), id = await instance(host, small);
  for (const q of [{ offset: -1, length: 4 }, { offset: 0.5, length: 4 }, { offset: '1', length: 4 },
                   { offset: 0, length: -1 }, { offset: 0, length: (16 << 20) + 1 }]) {
    assert.equal((await host.op('read', { instance: id, ...q })).error, 'out_of_bounds', JSON.stringify(q));
  }
  assert.equal((await host.op('write', { instance: id, offset: -1, data: b64(Buffer.from('x')) })).error, 'out_of_bounds');
  assert.equal((await host.op('memory_grow', { instance: id, pages: -1 })).error, 'out_of_bounds');
  assert.equal((await host.op('release', { id })).ok, true);
  assert.equal((await host.op('memory_size', { instance: id })).error, 'unknown instance');
  assert.equal(host.instances.size, 0);
});
