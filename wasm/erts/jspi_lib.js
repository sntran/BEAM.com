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
    if (ENVIRONMENT_IS_NODE && !Module['beamKeepProcess']) {
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
  // A turn of the host for a scheduler that computes (jspi_host_yield of
  // jspi_pthread.c, after a count of reductions). Module.jspiTurn
  // (worker.js) decides what it is. Else setImmediate in Node.js: it runs
  // after the poll of the I/O of the host. A task of jspiLater is not
  // enough there, because tasks can run one after the other with no poll
  // of the network.
  jspi_host_turn__deps: ['$jspiLater'],
  jspi_host_turn__async: true,
  jspi_host_turn__sig: 'v',
  jspi_host_turn: () => new Promise((r) => {
    if (Module['jspiTurn']) Module['jspiTurn'](r);
    else if (ENVIRONMENT_IS_NODE) setImmediate(r);
    else jspiLater(r);
  }),

  // The spawn of a program by the host (sys_drivers.c, in place of
  // erl_child_setup): Module.beamHost.spawn({path, argv, env, cwd}, {data,
  // exit}) starts a VM, and gives {write(bytes), end()}. The host refuses
  // a path that is not the program of the VM (it throws an Error with an
  // errno). The bytes that the port writes go to write(); data(bytes)
  // goes to the port; exit(code) ends the port and gives its exit status.
  $jspiSpawn__deps: ['$FS', '$PIPEFS'],
  $jspiSpawn: { pid: 1000 },
  // Caution: Emscripten gives EAGAIN, not 0, for the read of a pipe with no
  // data and no write end. A port then waits for an end of file forever.
  // This read gives 0 there, as POSIX does.
  $jspiSpawn__postset: `{
    const read = PIPEFS.stream_ops.read;
    PIPEFS.stream_ops.read = function (stream, buffer, offset, length, position) {
      const pipe = stream.node.pipe;
      if (pipe.writeClosed && length > 0 && !(pipe.buckets ?? []).some((b) => b.offset > b.roffset)) return 0;
      return read.call(this, stream, buffer, offset, length, position);
    };
  }`,
  jspi_spawn_host__deps: ['$jspiSpawn', '$jspiStdio'],
  jspi_spawn_host__sig: 'i',
  jspi_spawn_host: () => Module['beamHost']?.spawn ? 1 : 0,
  jspi_spawn_start__deps: ['$jspiSpawn', '$FS', '$UTF8ArrayToString'],
  jspi_spawn_start__sig: 'iiiiiiiiiiii',
  jspi_spawn_start: (inFd, outFd, errFd, sigchldFd, protoSize, hasPort, portId, actionAt, action, portAt, statusAt) => {
    const input = FS.getStream(inFd), output = FS.getStream(outFd);
    // The command, as spawn_start of sys_drivers.c writes it: the size
    // (native order), the flags, the command, the directory, an optional
    // directory, an empty string, the environment, and the arguments
    // (network order for each count).
    let body;
    try {
      const head = new Uint8Array(4);
      if (FS.read(input, head, 0, 4) !== 4) return -{{{ cDefs.EIO }}};
      const size = new DataView(head.buffer).getInt32(0, true);
      body = new Uint8Array(size);
      for (let got = 0; got < size;) got += FS.read(input, body, got, size - got);
    } catch (e) {
      return -{{{ cDefs.EIO }}};
    }
    const view = new DataView(body.buffer);
    let at = 4;
    const str = () => { const end = body.indexOf(0, at); const v = UTF8ArrayToString(body, at, end - at); at = end + 1; return v; };
    const count = () => { const n = view.getInt32(at, false); at += 4; return n; };
    const path = str(), cwd = str();
    const wd = body[at] ? str() : null;
    at++;
    const env = Array.from({ length: count() }, str);
    const argv = at < body.length ? Array.from({ length: count() }, str) : [path];
    let child, done = false, skip = protoSize;
    const exit = (code) => {
      if (done) return;
      done = true;
      for (const s of [input, output]) try { FS.close(s); } catch (e) {}
      if (!hasPort) return;
      const msg = new Uint8Array(protoSize), dv = new DataView(msg.buffer);
      dv.setInt32(actionAt, action, true);
      dv.setInt32(portAt, portId, true);
      // A status of waitpid(): the exit code in the second byte.
      dv.setInt32(statusAt, (code & 255) << 8, true);
      FS.write(FS.getStream(sigchldFd), msg, 0, protoSize);
    };
    try {
      child = Module['beamHost'].spawn({ path, argv, env, cwd: wd ?? cwd }, {
        data: (bytes) => { if (!done) try { FS.write(output, bytes, 0, bytes.length); } catch (e) { child.end(); } },
        exit,
      });
    } catch (e) {
      return -(e.errno ?? {{{ cDefs.ENOENT }}});
    }
    // The standard error of the program goes to the host (printErr).
    if (errFd !== outFd) FS.close(FS.getStream(errFd));
    // The bytes of the port: first the Ack of the port (protoSize bytes,
    // for erl_child_setup), then the input of the program.
    const buf = new Uint8Array(65536);
    const drain = () => {
      while (!done) {
        let n;
        try { n = FS.read(input, buf, 0, buf.length); } catch (e) { if (e.errno === {{{ cDefs.EAGAIN }}}) return; n = 0; }
        if (n === 0) { child.end(); return; }
        let part = buf.subarray(0, n);
        if (skip) { const k = Math.min(skip, n); skip -= k; part = part.subarray(k); }
        if (part.length) child.write(part.slice());
      }
    };
    input.node.addListener(() => queueMicrotask(drain));
    queueMicrotask(drain);
    return ++jspiSpawn.pid;
  },
  // The standard input and output of a VM that a host spawn started: two
  // pipes on fd 0 and fd 1, so the port {fd, 0, 1} of the program (for
  // example the peer module) can poll them. Call it in preRun. It gives
  // {write(bytes), end()}; onData(bytes) gets each output.
  $jspiStdio__deps: ['$FS', '$PIPEFS'],
  $jspiStdio__postset: `Module['beamStdioPipes'] = (onData) => jspiStdio(onData);`,
  $jspiStdio: (onData) => {
    if (!FS.initialized) FS.init();
    const to = PIPEFS.createPipe(), from = PIPEFS.createPipe();
    for (const [fd, end] of [[0, to.readable_fd], [1, from.writable_fd]]) {
      FS.close(FS.getStream(fd));
      FS.dupStream(FS.getStream(end), fd);
      FS.close(FS.getStream(end));
    }
    const input = FS.getStream(to.writable_fd), output = FS.getStream(from.readable_fd);
    const buf = new Uint8Array(65536);
    const drain = () => {
      for (;;) {
        let n;
        try { n = FS.read(output, buf, 0, buf.length); } catch (e) { return; }
        if (n === 0) return;
        onData(buf.slice(0, n));
      }
    };
    output.node.addListener(() => queueMicrotask(drain));
    return {
      write: (bytes) => FS.write(input, bytes, 0, bytes.length),
      end: () => { try { FS.close(input); } catch (e) {} },
    };
  },
  jspi_yield__deps: ['$jspiLater'],
  jspi_yield__async: true,
  jspi_yield__sig: 'v',
  jspi_yield: () => new Promise((r) => jspiLater(r)),
});
