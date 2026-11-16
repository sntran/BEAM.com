// The swap of a VM (BEAM_SWAP of worker.js), the stop of its threads, and
// the free of its memory. "node --test tests/host". The imports of the
// runtime are stand-ins, because these tests do not start a VM.
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
const worker = await import('../../priv/wasm_host/worker/worker.js');
const durable = await import('../../priv/wasm_host/worker/durable.js');
const { Vm, swapMark } = worker;

const MB = 1 << 20;

// The time of the tests moves 20 s at each call of later(), so that the
// limit of one swap in each 10 s does not apply between two tests.
let shift = 0;
const realNow = Date.now;
Date.now = () => realNow() + shift;
const later = () => { shift += 20000; };

// The exports of the runtime: the threads return after `steps` checks.
function runtime({ steps = 2, used = 8 * MB, hibernate = null } = {}) {
  const calls = [];
  let live = steps;
  return {
    calls,
    erts_wasm_hibernate: hibernate ?? (() => { calls.push('hibernate'); }),
    erts_wasm_resume: () => { calls.push('resume'); },
    jspi_live_threads: () => (live > 0 ? live-- : 0),
    jspi_heap_used: () => used,
  };
}

// A Vm with the state of a VM that is ready, with `mb` MB of memory. The
// owner gives onSwap; the old VM answers "old" (request).
function vm({ mb = 100, mark = 64, plain = false, exports = runtime(), halt = true } = {}) {
  const v = Object.create(Vm.prototype);
  const logs = [];
  const halts = [];
  let markDead;
  Object.assign(v, {
    env: {}, plain, swapMark: mark, up: true, dead: null, swapping: null, parked: false, halted: false,
    conns: new Set(), sockets: 0, ports: new Set(), tcps: new Map(), handlers: [], jobs: [],
    timers: new Map(), handles: new Map(), stopWaits: new Set(), fetches: new Map(),
    sqlPending: 0, fetchPending: 0, wasmPending: 0, wasm: null,
    died: new Promise((r) => { markDead = r; }),
    beam: { HEAPU8: { length: mb * MB }, ...(halt ? { jspiHalt: () => halts.push('halt') } : {}) },
    exports, onDead: null,
    onSwap: async () => new Response('new'),
    request: async () => new Response('old'),
    log: (t) => logs.push(t),
  });
  v.markDead = markDead;
  return { v, logs, halts };
}

const quiet = async (f) => {
  const log = console.log;
  console.log = () => {};
  try { return await f(); } finally { console.log = log; }
};

test('swapMark: a number of MB, "off", and a default for a stateless Worker only', () => {
  assert.equal(swapMark({}, true), 64);
  assert.equal(swapMark({ BEAM_SWAP: '' }, true), 64);
  assert.equal(swapMark({}, false), 0);
  assert.equal(swapMark(undefined, false), 0);
  assert.equal(swapMark({ BEAM_SWAP: 'off' }, true), 0);
  assert.equal(swapMark({ BEAM_SWAP: '48' }, false), 48);
  assert.equal(swapMark({ BEAM_SWAP: 96 }, true), 96);
  for (const bad of ['0', '-1', '12.5', '64MB', 'on', '123456']) assert.equal(swapMark({ BEAM_SWAP: bad }, true), null);
});

test('a value of BEAM_SWAP that is not correct gives no swap and one log line', async () => {
  const lines = [];
  const log = console.log;
  console.log = (t) => lines.push(t);
  try {
    assert.equal(Vm.prototype.checkMark({ BEAM_SWAP: 'big' }, true), 0);
  } finally {
    console.log = log;
  }
  assert.deepEqual(lines, ['beam: BEAM_SWAP is "big", not a number of MB or "off": no swap']);
});

// workerd takes each export of the main module as an entrypoint, and
// refuses a number or a text: the runtime directory has worker.js and
// durable.js as main modules.
test('worker.js and durable.js export only functions and objects', () => {
  for (const [name, mod] of [['worker.js', worker], ['durable.js', durable]]) {
    for (const [key, value] of Object.entries(mod)) {
      const ok = typeof value === 'function' || (typeof value === 'object' && value !== null);
      assert.ok(ok, `${name} exports ${key} as a ${typeof value}`);
    }
  }
});

test('a swap is due only for an idle VM at the mark, with a free part', () => {
  later();
  assert.equal(vm().v.swapDue(), true);
  assert.equal(vm({ mb: 63 }).v.swapDue(), false, 'below the mark');
  assert.equal(vm({ mark: 0 }).v.swapDue(), false, 'no mark');
  assert.equal(vm({ exports: runtime({ used: 90 * MB }) }).v.swapDue(), false, 'less than 16 MB free');
  const old = runtime();
  delete old.jspi_heap_used;
  assert.equal(vm({ exports: old }).v.swapDue(), true, 'a runtime with no jspi_heap_used: the mark decides');
  const cases = {
    'an open request': (v) => v.conns.add({}),
    'a WebSocket': (v) => { v.sockets = 1; },
    'a port': (v) => v.ports.add({}),
    'a TCP socket': (v) => v.tcps.set('t1', {}),
    'a SQL call': (v) => { v.sqlPending = 1; },
    'a snapshot to make': (v) => { v.makeKey = 'k'; },
    'a snapshot in progress': (v) => { v.snapping = Promise.resolve(); },
    'a VM that is not up': (v) => { v.up = false; },
    'a VM that stopped': (v) => { v.dead = 'exit status 1'; },
    'no owner for a swap': (v) => { v.onSwap = null; },
    'a swap in progress': (v) => { v.swapping = Promise.resolve(true); },
  };
  for (const [what, set] of Object.entries(cases)) {
    const { v } = vm();
    set(v);
    assert.equal(v.swapDue(), false, what);
  }
});

test('a swap: the threads return, the VM stops, and the request goes to a new VM', async () => {
  later();
  const exports = runtime();
  const { v, logs, halts } = vm({ exports });
  let reason = null;
  v.onDead = (r) => { reason = r; };
  v.timers.set(1, { at: 0, f: () => {} });
  // A timer after the park: free() stops it.
  let ran = false;
  v.handles.set(2, setTimeout(() => { ran = true; }, 200));
  const r = await v.fetch(new Request('https://app.example.com/'));
  assert.equal(await r.text(), 'new');
  assert.deepEqual(exports.calls, ['hibernate']);
  assert.equal(reason, 'swap');
  assert.equal(v.dead, 'swap');
  assert.equal(v.parked, true);
  assert.equal(v.halted, true);
  assert.deepEqual(halts, ['halt']);
  assert.equal(v.beam, null);
  assert.equal(v.exports, null);
  assert.equal(v.timers.size, 0);
  assert.equal(v.handles.size, 0);
  assert.match(logs[0], /^beam: memory 100 MB \(8 MB used\): a new VM takes the next requests$/);
  // A request that comes to the old VM later also goes to the new VM.
  assert.equal(await (await v.fetch(new Request('https://app.example.com/x'))).text(), 'new');
  await new Promise((r) => setTimeout(r, 250));
  assert.equal(ran, false, 'a timer of the stopped VM ran');
});

test('the requests during a swap wait for it, and go to the new VM', async () => {
  later();
  const { v } = vm({ exports: runtime({ steps: 5 }) });
  const answers = await Promise.all([1, 2, 3].map((i) => v.fetch(new Request(`https://app.example.com/${i}`))));
  assert.deepEqual(await Promise.all(answers.map((r) => r.text())), ['new', 'new', 'new']);
});

test('one swap in an isolate each 10 s at most', async () => {
  later();
  await vm().v.fetch(new Request('https://app.example.com/'));
  const { v } = vm();
  assert.equal(v.swapDue(), false);
  later();
  assert.equal(v.swapDue(), true);
});

test('a thread that does not return: no swap, and the VM goes on', async () => {
  later();
  const exports = runtime({ hibernate: () => { throw new Error('no hibernate'); } });
  const { v, logs, halts } = vm({ exports });
  const r = await v.fetch(new Request('https://app.example.com/'));
  assert.equal(await r.text(), 'old');
  assert.deepEqual(exports.calls, ['resume']);
  assert.equal(v.dead, null);
  assert.equal(v.halted, false);
  assert.equal(v.swapping, null);
  assert.deepEqual(halts, []);
  assert.deepEqual(logs, ['beam: the threads of the VM did not return (no hibernate)',
    'beam: memory 100 MB: no swap, because a thread of the VM did not return']);
});

test('a plain Worker runs the threads of the swap in the request', async () => {
  later();
  const { v } = vm({ plain: true });
  const kept = [];
  const ctx = { waitUntil: (p) => kept.push(p) };
  const r = await v.fetch(new Request('https://app.example.com/'), ctx);
  assert.equal(await r.text(), 'new');
  assert.equal(kept.length, 1, 'the handler of the swap in the request');
  await kept[0];
  assert.equal(v.handlers.length, 0);
});

test('a VM that stopped ends the waits of its threads, and drops its module', () => {
  const { v, halts } = vm();
  v.die('exit status 3');
  assert.deepEqual(halts, ['halt']);
  assert.equal(v.halted, true);
  assert.equal(v.beam, null);
  // After the stop, the host takes no job of the threads.
  v.post(() => assert.fail('a job of the stopped VM ran'));
  assert.equal(v.queue, undefined);
  v.free();  // a second free does nothing
});

test('a runtime with no jspiHalt: one log line, the memory stays', () => {
  const { v, logs } = vm({ halt: false });
  v.die('exit status 3');
  assert.equal(logs.at(-1), 'beam: this runtime cannot end the waits of the stopped VM: its memory stays in this isolate');
});

test('a Durable Object: a swap starts a new VM in the same instance, with no reset', async () => {
  const aborts = [];
  const beam = new durable.Beam({ abort: (r) => aborts.push(r) }, {});
  const vmA = {};
  beam.vm = vmA;
  beam.vmStopped(vmA, 'swap');
  assert.equal(beam.vm, null);
  assert.equal(beam.resetting, false);
  const vmB = {};
  beam.vm = vmB;
  await quiet(() => beam.vmStopped(vmB, 'exit status 3'));
  assert.equal(beam.resetting, true);
  await new Promise((r) => setTimeout(r, 150));
  assert.deepEqual(aborts, ['the VM stopped']);
});
