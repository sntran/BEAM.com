// The reset of the Durable Object after its VM stopped (durable.js).
// "node --test tests/host". The imports of the runtime are stand-ins.
import { register } from 'node:module';
import { test } from 'node:test';
import assert from 'node:assert/strict';

register(`data:text/javascript,${encodeURIComponent(`
  const stub = {
    './beam.mjs': 'export default () => {};',
    './beam.wasm': 'export default null;',
    'cloudflare:workers': 'export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }',
  };
  export async function resolve(spec, ctx, next) {
    return spec in stub ? { url: 'data:text/javascript,' + encodeURIComponent(stub[spec]), shortCircuit: true }
                        : next(spec, ctx);
  }`)}`);
const { Beam } = await import('../../priv/wasm_host/worker/durable.js');

test('the object resets after its VM stopped', () => {
  const aborts = [];
  const beam = new Beam({ abort: (r) => aborts.push(r) }, {});
  beam.vm = {};
  beam.resetting = true;
  beam.reset('the VM stopped');
  assert.deepEqual(aborts, ['the VM stopped']);
  assert.equal(beam.resetting, true);
});

test('an object that the host cannot abort takes the next request', () => {
  const beam = new Beam({ abort: () => { throw new Error('not supported'); } }, {});
  beam.resetting = true;
  const log = console.log, lines = [];
  console.log = (t) => lines.push(t);
  try {
    beam.reset('the VM stopped');
  } finally {
    console.log = log;
  }
  assert.equal(beam.resetting, false);
  assert.deepEqual(lines, ['beam: the object did not reset (not supported): the next request starts a new VM']);
});
