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
      jspiQueue.port = ch.port2;
    }
    jspiQueue.port.postMessage(0);
  },
  $jspiQueue: { fns: [], port: null },
  $jspiTimer: (f, ms) => Module['jspiSchedule']?.timer(f, ms) ?? setTimeout(f, ms),
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
  jspi_suspend: (t, ms) => new Promise((resolve) => {
    if (jspi.early.delete(t)) return resolve(1);
    let timer = null;
    jspi.waiters.set(t, () => { if (timer !== null) jspiClear(timer); jspi.waiters.delete(t); resolve(1); });
    if (ms >= 0) timer = jspiTimer(() => { jspi.waiters.delete(t); resolve(0); }, ms);
  }),
  jspi_resume__deps: ['$jspi'],
  jspi_resume__sig: 'vp',
  jspi_resume: (t) => {
    const w = jspi.waiters.get(t);
    if (w) queueMicrotask(w); else jspi.early.add(t);
  },
  // Messages between the host and Erlang (wasm_host_nif.c):
  // Module.beamHost.push(bytes) gives an event to Erlang, and
  // Module.beamHost.onsend(bytes) gets what Erlang sends.
  $jspiHost: { queue: [], waiter: null },
  $jspiHost__postset: `Module['beamHost'] = {
    onsend: null,
    push(bytes) {
      jspiHost.queue.push(bytes);
      const w = jspiHost.waiter;
      if (w) { jspiHost.waiter = null; w(bytes.length); }
    },
  };`,
  jspi_host_wait__deps: ['$jspiHost'],
  jspi_host_wait__async: true,
  jspi_host_wait__sig: 'i',
  jspi_host_wait: () => new Promise((resolve) => {
    if (jspiHost.queue.length) resolve(jspiHost.queue[0].length);
    else jspiHost.waiter = resolve;
  }),
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
  jspi_yield__deps: ['$jspiLater'],
  jspi_yield__async: true,
  jspi_yield__sig: 'v',
  jspi_yield: () => new Promise((r) => jspiLater(r)),
});
