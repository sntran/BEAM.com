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
  // After the pending I/O and timers of the host (a macrotask).
  $jspiLater: (f) => typeof setImmediate == 'function' ? setImmediate(f) : setTimeout(f, 0),
  // Node.js: the program gets the environment of the process.
  $jspiEnv__deps: ['$ENV'],
  $jspiEnv__postset: "if (ENVIRONMENT_IS_NODE) Object.assign(ENV, process.env);",
  $jspiEnv: {},
  jspi_spawn__deps: ['$jspi', '$jspiLater', '$jspiExit', '$jspiEnv'],
  jspi_spawn: (t) => {
    jspi.entry ??= WebAssembly.promising(wasmExports['jspi_thread_entry']);
    jspiLater(() => jspi.entry(t).catch(jspiExit));
  },
  jspi_suspend__deps: ['$jspi'],
  jspi_suspend__async: true,
  jspi_suspend: (t, ms) => new Promise((resolve) => {
    if (jspi.early.delete(t)) return resolve(1);
    let timer = null;
    jspi.waiters.set(t, () => { if (timer) clearTimeout(timer); jspi.waiters.delete(t); resolve(1); });
    if (ms >= 0) timer = setTimeout(() => { jspi.waiters.delete(t); resolve(0); }, ms);
  }),
  jspi_resume__deps: ['$jspi'],
  jspi_resume: (t) => {
    const w = jspi.waiters.get(t);
    if (w) queueMicrotask(w); else jspi.early.add(t);
  },
  jspi_yield__deps: ['$jspiLater'],
  jspi_yield__async: true,
  jspi_yield: () => new Promise((r) => jspiLater(r)),
});
