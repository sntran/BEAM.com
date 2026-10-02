// The host side of jspi_pthread.c: green threads on JSPI (Emscripten -sJSPI).
addToLibrary({
  $jspi: {
    waiters: new Map(), // thread -> resolve function of its suspend
    early: new Set(),   // resumed before it suspended
    entry: null,
  },
  // A thread called exit() (Erlang halt/1): end the process, with the
  // pending timers and I/O of the other threads.
  $jspiExit: (e) => {
    if (!(e instanceof ExitStatus)) { err(e); e = new ExitStatus(2); }
    Module['onExit']?.(e.status);
    if (ENVIRONMENT_IS_NODE) {
      if (process.env.JSPI_STATS) err(`jspi: memory ${wasmMemory.buffer.byteLength >> 20} MB`);
      process.exit(e.status);
    }
    ABORT = true;
  },
  // After the pending I/O and timers of the host (a macrotask): setImmediate
  // in Node.js, else a MessageChannel message. setTimeout(0), and the
  // setImmediate of workerd, wait about 1 ms (a timer tick), and ERTS yields
  // often: its boot took 3 s so in workerd, not 0.5 s.
  //
  // Module.jspiSchedule (optional) takes the wake-ups and timers of the
  // threads: {later(f), timer(f, ms) -> id, clear(id)}. A plain Worker
  // runs them in an open request (I/O and timers belong to a request).
  $jspiLater__deps: ['$jspiQueue'],
  $jspiLater: (f) => {
    const s = Module['jspiSchedule'];
    if (s) return s.later(f);
    if (ENVIRONMENT_IS_NODE) return setImmediate(f);
    jspiQueue.fns.push(f);
    if (!jspiQueue.port) {
      const ch = new MessageChannel();
      ch.port1.onmessage = () => jspiQueue.fns.shift()?.();
      // Keep port1: a Worker can collect a port that only its handler
      // holds, and its messages are then lost (a boot stopped).
      jspiQueue.recv = ch.port1;
      jspiQueue.port = ch.port2;
    }
    jspiQueue.port.postMessage(0);
  },
  $jspiQueue: { fns: [], port: null, recv: null },
  // A timer waits 1 ms at least. The clock of a Cloudflare Worker moves
  // only by the delay of a timer (and at I/O), not during work or at
  // setTimeout(0): a thread that waits for a time less than 1 ms away (a
  // timed wait rounds it down to 0) would wait again and again, and the
  // VM of a Durable Object then used the CPU all the time.
  $jspiTimer: (f, ms) => Module['jspiSchedule']?.timer(f, ms) ?? setTimeout(f, Math.max(1, ms)),
  $jspiClear: (id) => { const s = Module['jspiSchedule']; if (s) s.clear(id); else clearTimeout(id); },
  // Node.js: the program gets the environment of the process.
  $jspiEnv__deps: ['$ENV'],
  $jspiEnv__postset: "if (ENVIRONMENT_IS_NODE) Object.assign(ENV, process.env);",
  $jspiEnv: {},
  jspi_spawn__deps: ['$jspi', '$jspiLater', '$jspiExit', '$jspiEnv'],
  jspi_spawn__sig: 'vp',
  jspi_spawn: (t) => {
    jspi.entry ??= WebAssembly.promising(wasmExports['jspi_thread_entry']);
    // A pointer argument of a wasm64 export is a BigInt.
    jspiLater(() => jspi.entry({{{ MEMORY64 ? 'BigInt(t)' : 't' }}}).catch(jspiExit));
  },
  jspi_suspend__deps: ['$jspi', '$jspiTimer', '$jspiClear'],
  jspi_suspend__async: true,
  jspi_suspend__sig: 'ipi',
  // A timer can fire, and its thread can wait to run, while another thread
  // wakes it: runJobs of worker.js runs all the due timers in one task.
  // Then the waiter of the thread is a function that does nothing, so the
  // wake does not go to jspi.early. Else the next suspend of the thread
  // returns at once, while the thread is in a wait queue
  // (specs/GreenThreads.tla).
  jspi_suspend: (t, ms) => new Promise((resolve) => {
    if (jspi.early.delete(t)) return resolve(1);
    let timer = null;
    const w = () => { if (timer !== null) jspiClear(timer); resolve(1); };
    jspi.waiters.set(t, w);
    if (ms >= 0) {
      timer = jspiTimer(() => {
        if (jspi.waiters.get(t) === w) jspi.waiters.set(t, () => {});
        resolve(0);
      }, ms);
    }
  }),
  jspi_resume__deps: ['$jspi'],
  jspi_resume__sig: 'vp',
  // The resume puts a function that does nothing in place of the waiter:
  // so a waiter runs once, a second resume before the thread runs does
  // nothing, and no resume removes the waiter of a later suspend.
  jspi_resume: (t) => {
    const w = jspi.waiters.get(t);
    if (w) { jspi.waiters.set(t, () => {}); queueMicrotask(w); } else jspi.early.add(t);
  },
  // Messages between the host and Erlang (wasm_host_nif.c):
  // Module.beamHost.push(bytes) gives an event to Erlang, and
  // Module.beamHost.onsend(bytes) gets what Erlang sends.
  // Each event also writes a byte into the pipe of wasm_host (fd): its
  // enif_select wakes the pump (wasm_host_nif.c).
  $jspiHost__deps: ['$FS'],
  $jspiHost: { queue: [], fd: -1 },
  $jspiHost__postset: `Module['beamHost'] = {
    onsend: null,
    push(bytes) {
      jspiHost.queue.push(bytes);
      const s = jspiHost.fd >= 0 && FS.getStream(jspiHost.fd);
      if (s) FS.write(s, new Uint8Array([1]), 0, 1);
    },
  };`,
  jspi_host_set_fd__deps: ['$jspiHost'],
  jspi_host_set_fd__sig: 'vi',
  jspi_host_set_fd: (fd) => { jspiHost.fd = fd; },
  jspi_host_next_size__deps: ['$jspiHost'],
  jspi_host_next_size__sig: 'i',
  jspi_host_next_size: () => jspiHost.queue.length ? jspiHost.queue[0].length : -1,
  jspi_host_take__deps: ['$jspiHost'],
  jspi_host_take__sig: 'vp',
  jspi_host_take: (ptr) => { HEAPU8.set(jspiHost.queue.shift(), ptr); },
  jspi_host_send__sig: 'vpp',
  jspi_host_send: (ptr, size) => { Module['beamHost'].onsend?.(HEAPU8.slice(ptr, ptr + size)); },
  // poll() with a timeout (jspi_pthread.c): wait until one of the files
  // changes (1) or the timeout (0, with the timers of jspiSchedule).
  jspi_poll_wait__deps: ['$FS', '$jspiTimer', '$jspiClear'],
  jspi_poll_wait__async: true,
  jspi_poll_wait__sig: 'ipii',
  jspi_poll_wait: (fds, n, ms) => new Promise((resolve) => {
    const regs = [];
    let timer = null, done = false;
    const finish = (v) => {
      if (done) return;
      done = true;
      for (const r of regs) r.listeners.delete(r.entry);
      if (timer !== null) jspiClear(timer);
      resolve(v);
    };
    for (let i = 0; i < n; i++) {
      const stream = FS.getStream(HEAP32[(fds + i * 8) >> 2]);
      if (stream) regs.push(stream.node.addListener(() => finish(1)));
    }
    if (ms >= 0) timer = jspiTimer(() => finish(0), ms);
  }),
  // The files of the host for SQLite (sqlite_vfs.c): Module.beamHost.files
  // (worker.js) takes each operation, and gives a promise of an integer.
  // A path is a C string in buf; data is n bytes at buf. The memory can
  // grow during the wait: heap() gives the current view of it.
  jspi_host_files__sig: 'i',
  jspi_host_files: () => Module['beamHost']?.files ? 1 : 0,
  jspi_file_wait__deps: ['$UTF8ToString'],
  jspi_file_wait__async: true,
  jspi_file_wait__sig: 'iiidpi',
  jspi_file_wait: (op, id, offset, buf, n) =>
    Module['beamHost'].files.call(op, id, offset, buf, n, { heap: () => HEAPU8, string: UTF8ToString }),
  // The main thread of ERTS may return from main() where the runtime stays
  // after it (not Node.js, which exits then): no wait of it in a snapshot.
  jspi_main_may_return__sig: 'i',
  jspi_main_may_return: () => ENVIRONMENT_IS_NODE ? 0 : 1,
  jspi_yield__deps: ['$jspiLater'],
  jspi_yield__async: true,
  jspi_yield__sig: 'v',
  jspi_yield: () => new Promise((r) => jspiLater(r)),
});
