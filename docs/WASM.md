# ERTS on WebAssembly: a spike

The goal: `beam.com build --target wasm32` makes one WebAssembly file of
an application with **all of OTP**, which runs where there are no threads:
Cloudflare Workers, Deno Deploy, the browser. This file records the
spike: what was tried, what works, and what blocks.

## Why not the other ways

- **AtomVM** (a small BEAM VM with a WebAssembly build) has only a part of
  OTP. Not a goal.
- **ERTS with real threads** (`wasm32-wasip1-threads`) runs in Wasmtime and
  in browsers, but Workers and Deno Deploy give no threads.
- **Ahead-of-time compilation of Erlang to WebAssembly** (the way of
  Firefly, formerly Lumen) needs a new runtime with all the BIFs.

## The way: green threads on JSPI

ERTS needs threads (the schedulers, the dirty schedulers, the aux and poll
threads): since OTP 21 it has no build without them. JSPI (JavaScript
Promise Integration, a standard WebAssembly feature) lets a WebAssembly
call wait for a JavaScript promise: the engine keeps its stack and
continues it later. So:

- Each thread of ERTS is one call of a `promising` export, with its own
  engine stack. All of them run on one host thread, in one linear memory.
- A thread that must wait (a mutex, a condition variable, a join, a
  sleep, `sched_yield`) calls a `Suspending` import. Its promise resolves
  when another thread signals it (or at a timeout), and the event loop of
  the host runs the others meanwhile.
- No shared memory and no atomic operation: one host thread runs all the
  threads. So `SharedArrayBuffer` is not needed.

## Phase A: the mechanism (done)

`wasm/jspi/` has a pthread library on JSPI and a test of the parts of
pthreads that ERTS uses:

| File | What |
|---|---|
| `jspi_pthread.c` | threads, mutexes (also recursive), condition variables (also with a timeout), join, keys, `pthread_once`, `sched_yield` |
| `sp.S` | the shadow stack pointer, and the entry of a thread (WebAssembly assembly) |
| `include/pthread.h` | the pthread API (the types of musl in wasi-libc) |
| `run.mjs` | the host: `node:wasi`, and the imports `spawn`, `suspend`, `resume`, `yield` |
| `test.c` | the test |
| `build.sh` | builds and runs it: `NODE=/path/to/node wasm/jspi/build.sh` |

### Results (Node.js 26.10, V8 14.6: JSPI with no flag)

| Test | Result |
|---|---|
| A mutex: 4 threads, 1000 increments each, a switch in the lock | 4000 |
| A condition variable: a producer and a consumer, a queue of 4 | sum 500500 |
| Keys and shadow stacks: 8 threads, 50 switches each | each thread keeps its values |
| Nested frames: 4 threads, recursion of depth 8 with an array at each level, a switch and a new 1 KB frame on the way down and back | all frames intact |
| A timed wait | `ETIMEDOUT` after 100 ms; with a signal: signaled |
| The cost of a switch (ping-pong on a condition variable) | **0.45 µs** (40,000 in 18 ms) |

The test file is 156 KB (`-O2`). No compiler warnings (`-Wall -Wextra`).

### What was found

- **The shadow stack pointer is one global.** The engine keeps the stack
  of each call, but the locals in linear memory (arrays, locals whose
  address is taken) are on a shadow stack whose pointer is the global
  `__stack_pointer`. Each thread has its own shadow stack, and puts its
  own value back after each wait. Without this, a new frame made right
  after a switch goes over the live frames of another thread: the test of
  nested frames fails then (3 of 4 threads lose their frames at `-O2`).
  At `-O0` it passes by chance, because each function puts the global
  back when it returns; the optimized builds need the restore.
- **The entry of a thread must not be C.** A C function can put its frame
  on the shadow stack before its first statement, which is the stack of
  another thread at that point (a thread starts when another one waits).
  The first version did this at `-O0`, and the test stopped. The entry is
  now a few instructions of assembly (`sp.S`) that set the stack pointer,
  then call the C code.
- **Thread-local storage of the compiler is not available** without
  shared memory: `wasm-ld` defines `__tls_base` only with
  `--shared-memory`, and the wasi-libc without threads refuses it. ERTS
  can use `pthread_key_*` (its `ethr_tsd`) in place of `__thread`, and the
  library keeps the keys of each thread.
- **`errno` is one global** in the wasi-libc without threads. A switch
  happens only when a thread waits, and ERTS reads `errno` right after the
  call that set it, so this is expected to be safe.
- **A reactor does not run `exit()`**, so the library flushes stdio after
  `main`.
- **WASI names `main` in two ways** (`main(void)`, `main(int, char **)`);
  `__main_void()` of wasi-libc calls either.

### What ERTS already does well for this

- The spin loops of `ethr_event` call `ETHR_YIELD()` (`sched_yield`)
  every 50 loops, so a thread that spins gives the host thread to the
  others (the spin count can also be 0).
- `setjmp`/`longjmp` is only in the SIGSEGV check of stack overflow
  (`sys/unix/sys.c`), which a WebAssembly build does not need.

## The Blink spike: beam.com, as it is, in an x86-64 emulator (done)

A test of the other way: do not port ERTS, but run the x86-64 file of
`beam.com` in [Blink](https://github.com/jart/blink), the x86-64 Linux
emulator of Justine Tunney, compiled to WebAssembly. Blink runs the
programs of Cosmopolitan (APE files), and it has code for Emscripten.

`wasm/blink/build.sh` builds it and runs a program:

```sh
EMSDK=/path/to/emsdk NODE=/path/to/node wasm/blink/build.sh beam.com version
```

### How it is built

- **Emscripten 6.0.10, not wasi-libc.** Blink needs `setjmp`/`longjmp`,
  `termios`, signals and other POSIX parts that wasi-libc does not have;
  Emscripten has them, and Blink already has code for it.
- **Guest threads are Emscripten pthreads** (a Worker for each one, with
  `SharedArrayBuffer`), and Blink runs in a pthread
  (`PROXY_TO_PTHREAD`), so it can block. This is the quick way for the
  spike; the JSPI green threads of phase A are the way for Workers and
  Deno Deploy, which have no Workers of their own.
- No JIT (Blink has no JIT for WebAssembly), no sockets, no `fork`. The
  files of the host are in `NODERAWFS`.
- `wasm/blink/blink.patch` (35 lines) has the fixes: the command line of
  the APE loader, `poll()` with a timeout, and the exit
  (docs/UPSTREAM.md, B1 to B3). The configure of Blink gets a
  `CONFIG_RUNNER` (Node.js) for its tests.
- One change in ERTS: without `socketpair(AF_UNIX)`, it runs without
  `erl_child_setup`, as without `fork()` (docs/UPSTREAM.md, O16).
- The JIT of ERTS must use one mapping (`+JMsingle true`): Blink in
  WebAssembly cannot map a file two times (shared).

### Results (Node.js 26.10; 4 CPUs)

`beam.com version` (the JIT build, 4 schedulers) runs to its end and
exits with status 0. The Erlang code:

```erlang
lists:foldl(fun(X, A) -> (A + X*X) rem 1000003 end, 0, lists:seq(1, 1000000))
```

(in `-eval`, so `erl_eval` runs it), and 10,000 `spawn/1`, with
`+S 1 +SDcpu 1 +SDio 1 +A 0`:

| | Native | Blink, native | Blink in WebAssembly |
|---|---|---|---|
| `beam.com version` (start, output, exit) | 0.2 s | 54 s | 62 s |
| The fold (1 million) | 0.58 s | 229 s (390×) | 315 s (540×) |
| 10,000 spawns | 0.048 s | 16.9 s (350×) | 22.8 s (480×) |
| Peak memory (RSS of Node.js) | | | 1.3 to 1.4 GB |
| Size | | | `blink.wasm` 488 KB (154 KB with gzip), and the 49 MB `beam.com` |

A small x86-64 program (a loop of 100 million) is 290 times slower in
WebAssembly than native.

### What was found

- **It works**: all of OTP, the JIT, the NIFs, the schedulers, in
  WebAssembly, from the file that runs on the other systems, with a
  35-line patch of Blink and one small change of ERTS.
- **It is 400 to 550 times slower than native.** Blink interprets each
  x86-64 instruction (also the code that the JIT of ERTS makes).
  WebAssembly adds only 1.4 times to native Blink: the interpreter is the
  cost, not WebAssembly.
- **The start takes one minute and 1.4 GB.** A Worker has 128 MB of
  memory and a limit of CPU time for each request, and Deno Deploy has
  limits of the same kind. So this way cannot serve requests there. It could run Erlang
  code in a browser tab for a demonstration.
- **Each layer needed a fix**: the exit of Blink with threads, the
  `emscripten_sleep()` of its Emscripten code, the command line of the
  APE loader, `socketpair()` in ERTS, the double mapping of the JIT.
- A JIT of Blink for WebAssembly (x86-64 blocks compiled to WebAssembly
  modules at run time, as the emulator v86 does for 32-bit x86) could
  make it 10 or more times faster, but that is a large new project, and
  still far from native.

**Result:** the Blink way proves that all of OTP can run in WebAssembly,
but not at a usable speed or size. Phase B (ERTS compiled to WebAssembly,
with the JSPI threads of phase A) stays the way.

## Phase B: ERTS itself (next)

Cross-compile `beam-emu` (the interpreter) for `wasm32-wasip1` with this
library, and boot it with `-noshell -eval` (a `hello`, a `gen_server`, a
`receive ... after`). The known work:

- The configure of ERTS for `wasm32-wasi`: no JIT, no ports (no `fork`
  and `exec`), no signals, `ethr_tsd` in place of `__thread`, pthread
  events in place of futexes, one scheduler (`+S 1`).
- **The poll thread and the waits of the schedulers must suspend**, not
  block the host thread: `poll_oneoff` of WASI blocks it. The waits of
  ERTS go through `ethr_event` (pthread condition variables here), and
  check I/O needs a poll that suspends (a JSPI import).
- Memory: no `mmap` of carriers (the allocators on `malloc`).
- The files of the release (the `.beam` files) through WASI: a preopened
  directory in Node, a virtual file system in a Worker.
- Sockets: WASI preview 1 has none; the network would go through `fetch`
  of the host (a later question).

## Limits of the way

- Threads switch only when one waits: a long NIF or BIF stops all the
  others (Erlang processes are still preempted by reductions).
- The CPU time of a request in Workers applies to all the threads.
- Nothing keeps a process between requests on Workers and Deno Deploy.
