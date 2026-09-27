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

## Phase B: ERTS itself (the spike works)

ERTS of OTP 29.1.1 (the interpreter, `FLAVOR=emu`) is compiled to
WebAssembly with Emscripten, with the green threads of phase A. It boots
kernel and stdlib and runs Erlang code in Node.js 26, in Deno 2.9 and in
Cloudflare's `workerd`, with no change of the `.beam` files.

```sh
# EMSDK: an emsdk; BOOTSTRAP: a native build of the same OTP (build/otp)
EMSDK=... BOOTSTRAP=... wasm/erts/build.sh            # Node.js and Deno
BOOTSTRAP=... wasm/erts/run.sh -S 1 -- -noshell -eval 'io:format("hello~n"), halt().'
WORKER=1 EMSDK=... BOOTSTRAP=... wasm/erts/build.sh   # also the Worker variant
workerd serve wasm/erts/build/worker/worker.capnp     # GET /?eval=EXPR
```

### How it is built

| File | What |
|---|---|
| `wasm/erts/jspi_pthread.c`, `sp.S` | the green threads of phase A, for Emscripten; also `poll()` and `nanosleep()` that suspend, and no sockets for now |
| `wasm/erts/jspi_lib.js` | the host side (an Emscripten JS library: `__async` functions are `Suspending` imports) |
| `wasm/erts/erl-xcomp-wasm32-emscripten.conf` | the cross-compilation settings of OTP (`erl_xcomp_*`): no JIT, no kernel poll, no SSL, no `socket` NIF |
| `wasm/erts/otp.patch` | four small changes of ERTS (below) |
| `wasm/erts/build.sh`, `run.sh` | build from a clean OTP clone (3 minutes), and run in Node.js |
| `wasm/erts/worker/` | the Worker (`worker.js`: `erl -eval` for each request) and its `workerd` configuration |

- **Emscripten 6.0.10**, not wasi-libc: it has much more of POSIX, a file
  system, and JSPI support. Its `poll()` already suspends under JSPI and
  wakes up when a file is ready (for example the wake-up pipe of the
  schedulers).
- **Our pthreads replace the stubs of Emscripten's libc**
  (`--allow-multiple-definition`: the first definition, ours, is used).
- **Only the emulator is compiled.** The `.beam` files do not depend on
  the platform: the ones of the native build are used. The build uses
  the `escript` and `yielding_c_fun` of the native bootstrap system.
- **Node.js and Deno** read the files of the host (`NODERAWFS`). **The
  Worker variant** has the stripped kernel and stdlib (2.3 MB) in the
  memory of the module (`/otp`), and uses the WebAssembly module that the
  Worker imports (a Worker may not compile WebAssembly at run time).

### The changes of ERTS (`otp.patch`)

1. **A driver is called with the type of its start function** (`io.c`).
   ERTS calls the start function of every driver with 3 arguments, but
   the normal drivers (`inet_drv` and others) take 2. Native code accepts
   this; WebAssembly checks the type of each indirect call ("function
   signature mismatch").
2. **No `erl_child_setup`** (`sys_drivers.c`): there is no `fork()`, so
   `open_port/2` for a program returns `enosys` (as the Windows case of
   BEAM.com).
3. **The signal dispatcher waits with `poll()`** (`sys.c`): Emscripten's
   pipes do not block, and a read that blocks would stop all threads.
4. **`erl_crash_dump.c` without `-fexceptions`** (a build flag; configure
   adds it), and `HAVE_MALLOPT` off in `config.h` (Emscripten does not
   declare it).

### Results

The same computer as the Blink spike (4 CPUs). "Native" is the same OTP
built for x86-64 with Cosmopolitan.

| | Native interpreter | Native JIT | WebAssembly (Node.js 26) |
|---|---|---|---|
| Start, `-eval 'halt().'` | 0.10 s | 0.17 s | 0.25 to 0.30 s |
| Fold over 1 million small integers (`erl_eval`) | 0.85 s | 0.44 s | 4.8 s (5.6×) |
| `lists:sort/1` of 200,000 | 0.19 s | 0.11 s | 0.90 s (4.8×) |
| A map of 100,000, and `maps:fold/3` | 0.23 s | 0.14 s | 1.15 s (5.1×) |
| 10,000 `spawn/1` | 0.085 s | 0.048 s | 0.27 s (3.1×) |

(The factor is against the native interpreter.) Other numbers:

- **Size:** `beam.wasm` 3.3 MB (1.2 MB with gzip), and 155 KB of
  JavaScript. The Worker variant, with kernel and stdlib: 5.2 MB (3.0 MB
  with gzip).
- **Memory:** the Node.js process peaks at 150 MB (Node.js itself is
  about 45 MB). In `workerd`, the WebAssembly memory is 43 MB for a
  hello, and 61 MB with 10,000 processes; the limit of a Worker is 128
  MB.
- **Idle costs nothing:** a `timer:sleep(3000)` takes no more CPU time
  than a direct `halt()`; the schedulers wait on timers of the host.
- **`workerd`:** a request boots a new VM and runs the code in about
  0.7 s (processes, messages, `receive ... after`, ETS and timers
  work). **Deno** runs the Node.js build as it is (0.44 s).

Compared with the Blink spike: the start is 200 times faster (0.3 s, not
62 s), Erlang code is about 50 to 85 times faster, and the memory is 10
times smaller.

### What was found

- **The stack of a green thread must be aligned to 16 bytes.** The
  compiler takes the shadow stack pointer as aligned to 16 bytes, and
  can compute `sp + 10` as `sp | 10`. `malloc()` aligns to 8 on wasm32,
  so a term that `ets:match/2` builds on the stack had a wrong pointer,
  and the call failed with `badarg` (kernel did not start). Phase A had
  the same error, without a test that showed it; both are fixed.
- **Suspends inside Emscripten need the stack pointer back too.**
  Emscripten's `poll()` suspends, and the other threads run meanwhile:
  our `poll()` puts the shadow stack pointer and the current thread back
  after it, as the waits of phase A do.
- **A green thread that calls `exit()`** (Erlang `halt/1`) gets the
  `ExitStatus` of Emscripten in its promise: the host ends the process
  (Node.js) or calls `onExit` (the Worker answers the request).
- **The link of ERTS has no `-O` flag**, so Emscripten linked at `-O0`
  (no `wasm-opt`, with assertions): the link needs `-O2`.
- Without `erlexec`, the emulator flags start with `-` (`-S 1`, not
  `+S 1`).
- **wasm32 is a 32-bit target:** small integers have 28 bits, so
  arithmetic over 2^27 makes bignums (native x86-64 has 60 bits), so the
  tests above use small integers.
- **About 5 times slower than native**, where WebAssembly usually costs
  1.5 to 2.5 times. A likely cause is the dispatch of the interpreter:
  WebAssembly has no computed `goto`, so the threaded code of the
  interpreter becomes a table switch.

### Next

- **Sockets:** `gen_tcp` and `inet` through the network of the host
  (`fetch` and `connect()` of Workers, `node:net` in Node.js), as a
  driver or a NIF. `socket()` fails now.
- **Speed:** the dispatch of the interpreter; `-O3`; later a JIT that
  makes WebAssembly modules at run time (where the host allows it).
- **wasm64** (`-sMEMORY64`): 60-bit small integers as on native, and more
  than 4 GB. Node.js 26 has memory64.
- **Workers:** keep a VM between requests (a Durable Object), or a
  snapshot of the booted VM, so that a request does not pay the start.
- **`beam.com build --target wasm32`:** an application (and Elixir) in
  one Worker module.
- **NIFs:** `crypto` (OpenSSL compiled with Emscripten, or WebCrypto).

## Limits of the way

- Threads switch only when one waits: a long NIF or BIF stops all the
  others (Erlang processes are still preempted by reductions).
- The CPU time of a request in Workers applies to all the threads.
- Nothing keeps a process between requests on Workers and Deno Deploy.
