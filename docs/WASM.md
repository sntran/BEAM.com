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
