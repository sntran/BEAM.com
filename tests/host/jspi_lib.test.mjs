// The suspend and the resume of the green threads (wasm/erts/jspi_lib.js):
// "node --test tests/host". The test loads the library of Emscripten with
// stand-ins for Module and the timers, and with no VM.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

// The functions of the library, with the globals that Emscripten links.
function library() {
  let lib;
  const text = fs.readFileSync(new URL('../../wasm/erts/jspi_lib.js', import.meta.url), 'utf8')
    .replace(/\{\{\{[^}]*\}\}\}/g, 't');
  new Function('addToLibrary', text)((o) => { lib = o; });
  // The timers of jspiSchedule: run() calls all the due timers in one task,
  // as runJobs of worker.js does.
  const timers = new Map();
  let next = 1;
  const later = [];
  class ExitStatus { constructor(status) { this.status = status; } }
  const scope = {
    jspi: lib.$jspi,
    jspiHalt: lib.$jspiHalt,
    jspiQueue: { fns: [], port: null, recv: null },
    jspiTimer: (f, ms) => { timers.set(next, f); return next++; },
    jspiClear: (id) => timers.delete(id),
    jspiLater: (f) => later.push(f),
    Module: {},
    ENVIRONMENT_IS_NODE: true,
    ExitStatus,
    ABORT: false,
  };
  const bind = (f) => new Function(...Object.keys(scope), `return ${f.toString()}`)(...Object.values(scope));
  scope.jspiWait = bind(lib.$jspiWait);
  // Module.jspiHalt, as the postset of $jspiHalt makes it.
  new Function(...Object.keys(scope), lib.$jspiHalt__postset)(...Object.values(scope));
  return {
    jspi: scope.jspi,
    halt: scope.jspiHalt,
    ExitStatus,
    suspend: bind(lib.jspi_suspend),
    poll: bind(lib.jspi_poll_wait),
    yield: bind(lib.jspi_yield),
    resume: bind(lib.jspi_resume),
    fireAll: () => { const fs = [...timers.values()]; timers.clear(); for (const f of fs) f(); },
    turn: bind(lib.jspi_host_turn),
    Module: scope.Module,
    later,
  };
}

const settled = (p) => Promise.race([p, new Promise((r) => setTimeout(() => r('pending'), 20))]);

test('a resume resolves the suspend with 1, once', async () => {
  const h = library();
  const p = h.suspend(1, 1000);
  h.resume(1);
  h.resume(1);  // a second resume before the thread runs
  assert.equal(await p, 1);
  assert.equal(h.jspi.early.size, 0);
  // The next wait of the thread waits.
  assert.equal(await settled(h.suspend(1, -1)), 'pending');
  h.resume(1);
});

test('a timer resolves the suspend with 0', async () => {
  const h = library();
  const p = h.suspend(1, 5);
  h.fireAll();
  assert.equal(await p, 0);
});

// Two timers fire in one task. The first thread runs first and wakes the
// second, whose timer fired but which did not run yet. The wake must not
// go to jspi.early: else the next suspend of the second thread returns at
// once (specs/GreenThreads.tla).
test('a wake after the timer, before the thread runs', async () => {
  const h = library();
  const p1 = h.suspend(1, 5);
  const p3 = h.suspend(3, 5);
  const first = p1.then(() => h.resume(3));  // thread 1 signals thread 3
  h.fireAll();
  await first;
  assert.equal(await p3, 0);
  assert.equal(h.jspi.early.size, 0);
  // The next wait of thread 3 waits.
  assert.equal(await settled(h.suspend(3, -1)), 'pending');
  h.resume(3);
});

// A resume that runs late does not remove the waiter of a later suspend.
test('a late resume keeps the next waiter', async () => {
  const h = library();
  const p = h.suspend(2, -1);
  h.resume(2);
  assert.equal(await p, 1);
  const q = h.suspend(2, -1);
  assert.equal(h.jspi.waiters.has(2), true);
  h.resume(2);
  assert.equal(await q, 1);
});

// The turn of a scheduler that computes (jspi_host_turn): the host decides
// what it is (Module.jspiTurn of worker.js), else setImmediate (Node.js),
// which runs after the poll of the I/O of the host.
test('a turn goes to Module.jspiTurn of the host', async () => {
  const h = library();
  const turns = [];
  h.Module.jspiTurn = (f) => turns.push(f);
  const p = h.turn();
  assert.equal(turns.length, 1);
  assert.equal(await settled(p), 'pending');
  turns[0]();
  assert.equal(await settled(p), undefined);
});

test('with no jspiTurn, a turn in Node.js waits for setImmediate', async () => {
  const h = library();
  await h.turn();
  assert.equal(h.later.length, 0);
});

// The stop of a VM (Module.jspiHalt, from free() of worker.js): V8 keeps a
// suspended stack of JSPI as a root, so each wait rejects, and the stack of
// its thread unwinds.
test('the stop rejects each wait, and a later wait at once', async () => {
  const h = library();
  const waits = [h.suspend(1, -1), h.suspend(2, 1000), h.turn(), h.yield()];
  h.Module.jspiTurn = () => {};
  assert.equal(h.halt.pending.size, 4);
  h.Module.jspiHalt();
  for (const w of waits) await assert.rejects(w, (e) => e instanceof h.ExitStatus && e.status === 0);
  assert.equal(h.halt.pending.size, 0);
  assert.equal(h.jspi.waiters.size, 0);
  await assert.rejects(h.suspend(3, -1), (e) => e instanceof h.ExitStatus);
  h.Module.jspiHalt();  // a second stop does nothing
  h.resume(1);  // a late wake does nothing
  assert.equal(h.jspi.early.size, 1);
});

test('a wait that ends leaves nothing for the stop', async () => {
  const h = library();
  const p = h.suspend(1, -1);
  h.resume(1);
  assert.equal(await p, 1);
  const q = h.suspend(2, 5);
  h.fireAll();
  assert.equal(await q, 0);
  assert.equal(h.halt.pending.size, 0);
});
