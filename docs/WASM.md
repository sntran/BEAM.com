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

## Phase B: ERTS itself (done)

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
| `wasm/erts/jspi_pthread.c`, `sp.S`, `sp64.S` | the green threads of phase A, for Emscripten; also `poll()` and `nanosleep()` that suspend, no `socket()`, and the wait of `wasm_host` |
| `wasm/erts/jspi_lib.js` | the host side (an Emscripten JS library: `__async` functions are `Suspending` imports); `Module.beamHost` for the messages with Erlang |
| `wasm/erts/wasm_host_nif.c` | a static NIF: messages between Erlang and the JavaScript host |
| `wasm/erts/erl-xcomp-wasm32-emscripten.conf` | the cross-compilation settings of OTP (`erl_xcomp_*`): no JIT, no kernel poll, static crypto and asn1 NIFs, no `socket` NIF |
| `wasm/erts/otp.patch` | seven small changes of ERTS (below) |
| `wasm/erts/build.sh`, `run.sh`, `beam-node.mjs` | build from a clean OTP clone (libcrypto too; 3 to 4 minutes), and run in Node.js; `WASM64=1` for wasm64, `WORKER=1` for the Worker variants |
| `wasm/erts/host/` | `wasm_host.erl`, `wasm_tcp.erl`, and a Node.js host (`server.mjs`: HTTP and WebSockets) |
| `wasm/erts/worker/` | a Worker that runs `erl -eval` for each request |

- **Emscripten 6.0.10**, not wasi-libc: it has much more of POSIX, a file
  system, and JSPI support. Its `poll()` already suspends under JSPI and
  wakes up when a file is ready (for example the wake-up pipe of the
  schedulers).
- **Our pthreads replace the stubs of Emscripten's libc**
  (`--allow-multiple-definition`: the first definition, ours, is used).
- **Only the emulator is compiled.** The `.beam` files do not depend on
  the platform: the ones of the native build are used. The build uses
  the `escript` and `yielding_c_fun` of the native bootstrap system.
- **crypto:** libcrypto of OpenSSL 4.0.2 compiled with Emscripten (no
  threads, no sockets, no assembly code), and the crypto and asn1 NIFs
  linked into the emulator, as in `beam.com`. Hashes, HMAC and PBKDF2
  give the native results.
- **Node.js and Deno** read the files of the host (`NODERAWFS`). **The
  Worker variants** have the files in the memory of the module, or get
  them from the host (see the Phoenix section), and use the WebAssembly
  module that the Worker imports (a Worker may not compile WebAssembly at
  run time).

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
4. **`process_main()` returns after each time slice** (`beam_emu.c`,
   `erl_process.c`, `erl_process.h`): see "Speed" below.
5. **No reservation of address space** (`erl_mmap.h`): Emscripten defines
   `MAP_FIXED` and `MAP_NORESERVE`, but its `mmap()` is `malloc()`.
   64-bit ERTS stopped at the start ("Failed to reserve physical memory
   for descriptors"); now it uses the literal pointer tag.
6. **Hibernate and resume, for a snapshot** (`erl_process.c`,
   `erl_async.c`, `erl_trace.c`, `sys.c`, `beam_emu.c`, `beam_common.c`,
   `ethread.c`): see "A snapshot of the booted VM".
7. Build settings: `erl_crash_dump.c` without `-fexceptions`,
   `HAVE_MALLOPT` off in `config.h` (Emscripten does not declare it), no
   `-export-dynamic` (no dynamic NIFs; it made a JS wrapper for each
   symbol: 1 MB of JS in place of 124 KB).
8. Compiler flags: no security hardening flags (stack canaries, fortify
   checks), but `-fno-strict-aliasing`, `-fno-strict-overflow` and
   `-fno-delete-null-pointer-checks`, which ERTS needs. Configure removes
   these three with `--disable-security-hardening-flags`; without them,
   clang made wrong code (Elixir code stopped with an access out of
   bounds).

### Results

The same computer as the Blink spike (4 CPUs). "Native" is the same OTP
built for x86-64 with Cosmopolitan. "First" is the first build of phase B,
"now" is with the speed fix.

| | Native interpreter | Native JIT | WebAssembly, first | WebAssembly, now |
|---|---|---|---|---|
| Start, `-eval 'halt().'` | 0.10 s | 0.17 s | 0.25 to 0.30 s | 0.27 s |
| Fold over 1 million small integers (`erl_eval`) | 0.85 s | 0.44 s | 4.8 s | 1.2 s (1.4×) |
| `lists:sort/1` of 200,000 | 0.19 s | 0.11 s | 0.90 s | 0.23 s (1.2×) |
| A map of 100,000, and `maps:fold/3` | 0.23 s | 0.14 s | 1.15 s | 0.27 s (1.2×) |
| 10,000 `spawn/1` | 0.085 s | 0.048 s | 0.27 s | 0.10 s (1.2×) |

(The factor is against the native interpreter.) Other numbers:

- **Size:** `beam.wasm` 5.2 MB with crypto (1.9 MB with gzip), and
  110 to 124 KB of JavaScript.
- **Memory:** 40 MB of WebAssembly memory after the start; the Node.js
  process peaks at 150 MB (Node.js itself is about 45 MB).
- **Idle costs nothing:** a `timer:sleep(3000)` takes no more CPU time
  than a direct `halt()`; the schedulers wait on timers of the host.
- **Hosts:** Node.js 26, Deno 2.9 (the Node.js build as it is),
  Cloudflare's `workerd`, and Chromium 141 (see below).

Compared with the Blink spike: the start is 200 times faster (0.3 s, not
62 s), Erlang code is about 150 to 250 times faster, and the memory is 10
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
  tests above use small integers. wasm64 has 60 bits, but it is slower
  (see "wasm64").

### Speed: the interpreter ran in baseline code

The first build was about 5 times slower than the native interpreter.
80% of the time was in `process_main()` (the loop of the interpreter),
and with V8 on TurboFan only (`--no-liftoff`) the same fold took 1.3 s,
not 4.2 s. The reason: V8 first runs a WebAssembly function in baseline
code (Liftoff), and uses the optimized code (TurboFan) of a hot function
at its next call. WebAssembly has no on-stack replacement, and a
scheduler entered `process_main()` once and never left it: the
interpreter stayed in baseline code.

The fix: `process_main()` returns at the end of each time slice (at
`do_schedule1`, with the process and the reductions in the scheduler
data), and the scheduler calls it again. The next call uses the
optimized code. The interpreter is now 1.2 to 1.4 times the native
interpreter, the usual cost of WebAssembly. A plain `switch` in place of
the computed `goto` (`NO_JUMP_TABLE`) and `-O3` do not change the speed.

### wasm64

`WASM64=1 wasm/erts/build.sh` builds ERTS for `wasm64-unknown-emscripten`
(`-sMEMORY64`): the word size is 8 and small integers have 60 bits, as on
native. But it is slower than wasm32 in all tests (the fold 2.0 s, not
1.2 s; sort 0.55 s, not 0.25 s; maps 0.51 s, not 0.30 s; even the fold
with `X*X`, bignums only on wasm32: 2.6 s, not 1.75 s), and it uses more
memory (76 MB, not 40 MB at the start). The bounds checks of 64-bit
memory and the larger terms cost more than the bignums save. wasm32
stays the default.

## Phoenix LiveView on Cloudflare Workers (the spike works)

A Phoenix 1.8 app with a LiveView (a counter, and a timer that pushes
the seconds) runs from the WebAssembly ERTS: in Node.js, and in
Cloudflare's `workerd` (the BEAM runtime Worker, or a Durable Object), with a real
browser (Chromium, with Playwright). Phoenix, LiveView and the `.beam`
files of the app are not changed. The next versions work too:
`PHOENIX=main wasm/phoenix/setup.sh` takes Phoenix 1.9.0-dev and LiveView
1.3.0-dev from their main branches (2026-09-27), and all the checks below
pass with them, with no change of the adapter.

```sh
npm install --prefix wasm                                # ws (the Node.js host), playwright-core (the tests)
BEAM_COM=.../beam.com wasm/phoenix/setup.sh              # mix phx.new, the LiveView, a release
BEAM_COM=.../beam.com [EMSDK=...] wasm/phoenix/build-worker.sh   # beam.com REL -o DIR --target wasm32
workerd serve wasm/phoenix/build/worker/worker.capnp     # workerd: http://localhost:8789/counter
SERVE=1 wasm/phoenix/run.sh                              # the same release.bin in Node.js: http://localhost:4000/counter
node wasm/phoenix/browser-test.mjs http://localhost:8789/counter
```

## Build the Workers with `beam.com` (`--target wasm32`)

`beam.com` makes the Workers of a program, with no toolchain (no
Emscripten, no Node.js):

```sh
beam.com examples/worker -o worker --target wasm32          # what beam.com builds
beam.com _build/prod/rel/hello -o worker --target wasm32    # a release directory (mix release, rebar3)
workerd serve worker/worker.capnp                           # test on this computer
(cd worker/release && wrangler deploy) && (cd worker && wrangler deploy)
```

The input is what `beam.com -o` takes (a `.erl` or `.ex` file, an
application directory, a rebar3 or Mix project), or a release directory
without ERTS. The output is a directory:

| File | What |
|---|---|
| `wrangler.jsonc`, `worker.js`, `beam.mjs`, `beam.wasm` | the runtime Worker (`NAME`): the BEAM, with no program |
| `release/wrangler.jsonc`, `release/app.js`, `release/release.bin` | the Worker with the release (`NAME-release`, with no public URL); the runtime gets `release.bin` from it at the first request of an isolate |
| `durable.js`, `wrangler.durable.jsonc` | the same runtime in one Durable Object (`NAME-durable`: one VM for all the requests, and its SQLite storage for Ecto SQLite): `wrangler deploy -c wrangler.durable.jsonc` |
| `global.js`, `wrangler.global.jsonc` | the runtime Worker `NAME` with the release and a snapshot of the build in it: its global scope restores the VM. First `node wasm/snapshot/snapshot.mjs DIR --warm 4000:/` (with Ecto SQLite: `--boot-point`), then `wrangler deploy -c wrangler.global.jsonc`. See "On Cloudflare: the first deploy" |
| `durable-global.js`, `wrangler.durable-global.jsonc` | the Durable Objects (`NAME-durable`) with the release and a snapshot of the build: the global scope restores a spare VM for the first object of an isolate. See "Tenants, a boot point, a spare VM, a smaller release" |
| `worker.capnp` | both Workers for `workerd` |
| `tcp-proxy.mjs` | a local TCP port for a listener of the program (a WebSocket to `/.tcp/PORT`) |

- **The runtime** (`beam.wasm` and `beam.mjs`, 5.3 MB) is in the zip of
  `beam.com` (the step `wasm_runtime` of `build.sh`). `BEAM_COM_WASM_RUNTIME`
  (a directory) gives another one, and the cache
  (`~/.cache/beam.com/wasm32`) one for a `beam.com` built without it.
- **The application `wasm_host`** (in the zip of every `beam.com`:
  `apps/wasm_host`) goes into the release, and the boot script starts it
  after stdlib, before the applications of the program. In the runtime
  (`WASM_HOST` set) it starts the pump of the host events and makes
  `gen_tcp` use `wasm_tcp`; natively it does nothing. So the program is
  not changed: Bandit, Cowboy (Ranch) and `ssl` listen and connect with
  `gen_tcp`. A release with its own copy of a module of `wasm_host` is an
  error. `DIST_NAME` starts distributed Erlang over `wasm_tcp`.
- **`.release.json`** in `release.bin` has the boot arguments: for a mix
  release, the runtime configuration in `tmp/` (the config providers and
  `runtime.exs` run in the Worker); for a release of `beam.com`, its
  `sys.config`. The flags of `vm.args` stay, except the emulator flags
  (`+S` and the others: the runtime has its own), `-sname`, `-name`,
  `-setcookie`, `-env` and `-noshell`. `PHX_SERVER=true` for a release
  with Phoenix. The text `vars` of the Worker are the environment.
- **The modules of the boot, from a native run.** The build runs the
  release once on this computer (`beam.com` in erl mode, with the boot
  script of the release and `-s wasm_host_app record FILE`, `PORT=0`, and
  a `SECRET_KEY_BASE` if there is none), until the boot ends. The boot
  script of the Worker then loads these modules in one batch
  (`code:ensure_modules_loaded/1`) after kernel. The run starts the
  applications of the program: `BEAM_COM_WASM_NATIVE_RUN=0` turns it off
  (a program that must not start on the build computer), and when the run
  fails, the Worker loads the modules one by one (with a warning). No run
  on Windows (no port programs).
- **NIFs:** the runtime has the NIFs of `crypto` and `asn1`, and those
  of the hex.pm packages of `beam.com` (`bcrypt_elixir` and
  `argon2_elixir`, and the `EXTRA_NIFS` of a custom build), from the same
  recipes as the native file (`build_hex_nif` in `build.sh`, with `emcc`;
  argon2 with no threads). The file `nifs` next to `beam.wasm` lists
  them. A release with a NIF that the runtime does not have (`esqlite`,
  `wasm`) gets a warning. `exqlite` (Ecto SQLite) works through the host:
  see "Ecto SQLite".
- **Password hashes** (`phx.gen.auth`): `examples/notes` has `/hash`.
  In `wrangler dev`, with the default costs of the packages, bcrypt takes
  about 0.6 s and argon2 0.5 to 0.75 s (argon2 also takes 64 MiB, in the
  128 MB of an isolate); with low costs, 4 ms and 6 to 40 ms. So a login
  needs the paid plan (30 s of CPU), not the free plan (10 ms). On
  Cloudflare, the default costs in a Durable Object took 1,513 ms of CPU,
  and argon2 once went over the memory limit of the isolate (see "On
  Cloudflare: the first deploy").

Measured in `workerd` (the first request after a new `workerd`, 7 runs
each, medians; the release directory of the Phoenix demo, 8.5 MB, 1,347
files; `examples/worker`, 7.8 MB):

| | First request | VM ready |
|---|---|---|
| Phoenix, boot modules in one batch (263 modules) | 0.593 s | 0.47 s |
| Phoenix, one by one (`BEAM_COM_WASM_NATIVE_RUN=0`) | 0.680 s | 0.38 s |
| `examples/worker` (Cowboy), 125 modules in one batch | 0.30 to 0.41 s | 0.27 to 0.38 s |
| `examples/worker`, one by one | 0.33 to 0.36 s | 0.26 to 0.30 s |

The batch makes the first request of Phoenix 87 ms shorter (13%): it
loads the modules before the pump is ready (so "VM ready" comes later),
and the requests then find them loaded. For the small Cowboy app it makes
no difference that the noise shows. The next requests take 2.5 to 4 ms.
A build takes 2 s for the Phoenix release directory (with the native run)
and 20 s for `examples/worker` (with the compilation of Cowboy).

### The parts

| Part | What |
|---|---|
| The risk check | libcrypto for WebAssembly; the release (`mix release`, no ERTS) boots as `bin/hello start` does; interactive mode |
| `wasm_host` | a static NIF: `take/0` gives the next event of the host, and `select/0` a message when there is one (the host writes a byte into a pipe for each event: `enif_select`); `send/1`. Events are a JSON header, a newline and the body. (At first `recv/0` waited on a dirty I/O scheduler; that thread could not return for a snapshot) |
| `apps/wasm_host` | the pump of the host events (`wasm_host_server`), and `wasm_tcp`; the first version was a Phoenix endpoint adapter (now removed: Bandit runs unchanged over `wasm_tcp`) |
| `wasm/erts/host/server.mjs` | a Node.js host: `node:http` and WebSockets (`ws`) |
| `apps/wasm_host/priv/worker/worker.js` | the runtime Worker (and a Durable Object wrapper): one VM for all requests of an isolate |
| `wasm_tcp` | TCP client sockets of the host (`node:net`, `connect()` of `cloudflare:sockets`) for `gen_tcp`; `ssl` runs over them |
| `beam_com_wasm` | packs a release into `release.bin` (in Erlang, so no toolchain; first `wasm/worker/pack.erl`); the Worker writes it into the file system of the VM before the boot |

### Results

| | Node.js 26 | `workerd` (Durable Object) |
|---|---|---|
| Boot of the release, until the endpoint is ready | 0.4 to 0.5 s | 0.5 s (first request 0.56 s) |
| WebAssembly memory after the boot | 40 to 58 MB | 48 MB |
| A page (`GET /counter`) | 2.5 to 4 ms | 3.5 to 4 ms |
| LiveView socket connected (Chromium) | 170 ms | 110 to 170 ms |
| A click (a round trip over the socket, Playwright included) | 45 to 66 ms | 50 to 67 ms |
| 20 LiveView sockets at the same time | | 58 to 63 MB; the clicks in all 20 pages take 320 ms |
| `gen_tcp`: HTTP/1.0 to a local server | 200 in 7 ms | 200 in 3 to 7 ms |
| `ssl`: TLS 1.3 (`TLS_AES_256_GCM_SHA384`) | 200 in 200 ms (the first, when `ssl` loads), then 8 ms | 216 ms, then 10 ms |

The Worker: the runtime `beam.wasm` is 5.2 MB (1.9 MB with gzip), and
`release.bin` of the app is 7.5 MB (1,337 files). With `MODULES=file`
(`pack.erl --modules`, not in `beam.com`: a module that a test run did not
load fails later with `undef`), `release.bin` keeps only the `.beam` files of the
modules that a test run loaded (394 modules: `code:all_loaded/0` after
the pages, the LiveView, `gen_tcp` and `ssl`): 3.5 MB (536 files), and
all the checks pass with it. Cloudflare counts only the size without
compression, with a limit of 64 MiB on the free and the paid plans
(its limits page, 2026-09-27), so both sizes fit. The `.beam` files are
compressed already, one by one: stored without compression, the gzip of
the whole is only 4% smaller, and the files take two times more memory.

### What was found

- **Interactive mode, not embedded mode.** Embedded mode loads all the
  modules of all applications at the boot: 1.4 s and 100 MB. Interactive
  mode loads a module at its first use: 0.5 s and 48 MB. With
  `-Mea min` (all allocators on `malloc`) the memory is 33 MB, but
  `erlang:memory/0` fails (`notsup`), and `telemetry_poller` logs an
  error for it.
- **`setImmediate` of `workerd` waits about 1 ms**, as `setTimeout(0)`
  does, and ERTS yields often: the boot took 3.2 s in `workerd`. A
  `MessageChannel` message takes about 5 µs: with it, the boot takes
  0.5 s.
- **The Worker gets its files from the host.** With Emscripten's
  `--embed-file`, each app needed a link with Emscripten. Now one runtime
  (no files) and a data module (`release.bin`, made in Erlang) do the
  same, and `beam.com` itself can run `pack.erl` (the same bytes as the
  `escript` of OTP).
- **`WebSockAdapter` knows only a fixed list of adapters** (Bandit,
  Cowboy, the test adapter of Plug) and stops with "Unknown adapter" for
  any other: `setup.sh` adds one clause to it (docs/UPSTREAM.md).
- **The origin check of the LiveView socket works:** a page on
  `127.0.0.1` gets 403 when the endpoint host is `localhost`.
- **A static NIF is found through `code:priv_dir/1`:** the OTP
  applications need a `priv` directory (empty) in the Worker, else the
  asn1 NIF does not load and TLS cannot decode certificates.
- **Dirty I/O schedulers:** interactive mode reads the `.beam` files with dirty I/O
  NIFs: the release keeps the default number of dirty I/O schedulers (10
  green threads cost almost nothing).

### The BEAM runtime Worker

`worker.js` (`apps/wasm_host/priv/worker`) is a Worker with the runtime and no application
(`worker.js`, `beam.mjs`, `beam.wasm`: 5.3 MB). At the first request of an
isolate, it gets a release, boots it, and keeps the VM for the next
requests to that isolate. The release comes from:

- a service binding `APP` to another Worker (`app.js` with `release.bin`:
  what `beam.com --target wasm32` makes);
- else a text binding `RELEASE_URL` (R2, or any URL);
- else a module `release.bin` in the runtime Worker itself.

The `.beam` files are data for V8, not code, so the rule of Workers
against code at run time does not apply to them: the same runtime runs any
release that it is pointed to. There is no binding to set up for the VM.
A Durable Object is an option, not a mode: `worker.js` exports `Vm`, and a
class of 5 lines holds the VM in an object (the comment of `Vm` shows it;
tested). An object has one context for all its requests, and its VM runs
all the time; it is billed for duration while in memory (the VM is never
eligible for hibernation).

The results with Phoenix 1.9.0-dev, LiveView 1.3.0-dev and the small
`release.bin` (3.5 MB), in `workerd` (the columns are the runtime Worker
with the release from the `APP` Worker, the same with the release in the
runtime Worker, and the Durable Object wrapper):

| | Runtime + `APP` Worker | Release in the runtime | Durable Object |
|---|---|---|---|
| First request (the boot) | 0.60 s (`release.bin` from the other Worker in 5 ms) | 0.55 to 0.73 s | 0.66 s |
| Next requests | 3 ms | 3 ms | 4 to 7 ms |
| After 15 s idle | | 5.5 ms (the same VM) | |
| `gen_tcp`, `ssl` (TLS 1.3) | 12 ms; 250 to 290 ms | 11 ms; 250 to 310 ms | 14 ms; 338 ms, then 10 to 16 ms |
| LiveView: connect, a click | 129 ms, 67 ms | 110 to 130 ms, 66 ms | 143 ms, 69 ms |
| 20 LiveView sockets: connect, clicks | 2.5 s, 342 ms | 2.3 to 2.8 s, 335 to 430 ms | 2.6 s, 346 ms |
| WebAssembly memory | 48 MB | 48 to 58 MB | 48 to 58 MB |

What the runtime Worker needs (a Worker, not a Durable Object):

- **A later request resolves the promises of an earlier one.** The VM of
  the isolate waits for its events on promises made in the first request.
  By default, `workerd` cancels such continuations when the first request
  is done ("A promise was resolved or rejected from a different request
  context"), and the next request hangs. The compatibility flag
  `no_handle_cross_request_promise_resolution` keeps them.
- **An I/O object belongs to the request that made it.** A TCP socket or
  a `WebSocketPair` made in the callbacks of the VM (which run in the
  context of the first request) fails in another request: "Cannot perform
  I/O on behalf of a different request". So each request handler runs the
  host calls that make or use its I/O objects: a TCP socket belongs to the
  request that was open when Erlang connected, and closes with it. This is
  the model of Workers: a connection for each request, not a pool.
- **The VM runs only in open requests.** The wake-ups and timers of the
  threads go to a request handler (`Module.jspiSchedule` in
  `jspi_lib.js`; `poll()` waits with it too). Each open request is an
  event loop of the VM, until it has its response and its sockets are
  closed. With no open request, the VM does not run, and its timers wait
  for the next request: an edge function that wakes at a request and
  sleeps after it, with its state (ETS, processes) kept while the isolate
  is in memory. A LiveView socket keeps its request open, so its timers
  run.
- **Each open request keeps a timer of its own** (at most 1 s): else
  `workerd` takes a request that waits only for the VM (busy in another
  request) as hung ("canceled this request because it detected that your
  Worker's code had hung"), and cancels it with the work of the VM that
  waits in it; then the VM stops. With 20 sockets this came in some runs.
- **A host call that throws** (as a send on a closed socket) must not stop
  the loop of a request handler, else that request hangs.
- An isolate can close at any time (Cloudflare decides): the next request
  boots a new VM (0.6 s).

### Incoming TCP

`wasm_tcp` has `gen_tcp:listen/2` and `accept/1,2` (and `{packet, raw |
1 | 2 | 4 | line}`, and the common options for `inet:getopts/2`). A
listener is a process; the host gives it each new connection
(`tcp_accept`), and the listener gives a socket process to the caller of
`accept`:

- **Node.js:** a server of `node:net` on the port (`TCP_HOST`, default
  127.0.0.1).
- **Workers:** Workers get no TCP connections ("Support for handling
  inbound TCP connections is coming soon", Cloudflare's TCP sockets page,
  2026-09-27). So a WebSocket to `/.tcp/PORT` of the runtime Worker is a
  connection to the listener of PORT, with the bytes in binary messages.
  On the client, `tcp-proxy.mjs LOCAL_PORT wss://host/.tcp/PORT`
  (or `websocat -b`) makes a local port of it. A path with no listener
  gets 404. Cloudflare announced (blog, 2026-08-03, private beta) a
  `connect()` handler of Workers for TCP connections from Spectrum: such a
  socket can go to the same `tcp_accept`, with no change in Erlang.

The tests (the demo app: `GET /listen?port=P` starts an echo server,
`GET /ssh?port=P` starts the SSH server of OTP with a password and an
`exec` of Erlang expressions):

| | Node.js | `workerd` (through `tcp-proxy.mjs`) |
|---|---|---|
| Echo, `{packet, line}` | each line answered | each line answered; 5 clients at the same time |
| SSH: connect and log in (key exchange with Ed25519, password) | 0.47 to 0.55 s | 0.52 to 0.55 s |
| SSH: an `exec` (`lists:sum(lists:seq(1, 1000)).`) | 45 to 51 ms | 49 to 53 ms |

What was found:

- `workerd` (compatibility date 2026-09-01) gives binary WebSocket
  messages as `Blob`: the sockets set `binaryType = 'arraybuffer'`.
- The SSH server asks `inet:getopts(Socket, [buffer])` and stops if the
  answer is empty: `getopts` answers the common options.
- `beam.com` has no `ssh` application: for the test, the release gets
  `ssh` (compiled from the OTP source) through `ERL_LIBS`.
- A connection belongs to the request of its WebSocket (the rules of
  Workers above); a send to a socket that the client is closing fails,
  and the host logs it.
- Anyone who can reach the Worker can reach its listeners: the path needs
  protection (Cloudflare Access, a token) in a real deploy.

### Bandit, unchanged

The first adapter of the spike (`WasmHost.PhoenixAdapter`, `WasmHost.Conn`,
`WasmHost.WebSocket`: 286 lines) replaced Bandit: a `Plug.Conn` adapter of
our own, and a patch of `websock_adapter`. With `gen_tcp:listen/2` in
`wasm_tcp`, Bandit itself runs, as in any Phoenix app, and the adapter
and the patch are removed. `WasmHost.Server` is only the pump of the host
(TCP sockets, listeners, the distribution): the first child of the app
when the host sets `WASM_HOST`.

- **Node.js:** Bandit listens with `gen_tcp`, and the host listens for it
  with `node:net` (`SERVE=tcp wasm/phoenix/run.sh`).
- **Workers:** a Worker gets requests, not TCP connections: `worker.js`
  makes each request a TCP connection to the listener on `PORT` (the
  request as HTTP/1.1 bytes, with `connection: close`), reads the
  response back (`content-length`, `chunked`, or until the end, as a
  stream), and for a WebSocket turns the frames into messages and back
  (masked, as a client does; no compression). HTTP stays in Bandit.
- **Needed:** `wasm_tcp:sendfile/4` (`Plug.Static` sends files with
  `file:sendfile/5`), and `WasmHost.Server` started alone as the first
  child of the app, for the TCP sockets.

All the checks pass with Bandit 1.12.5 and no patch: pages, static files,
`gen_tcp`, TLS, LiveView, 20 LiveView pages at once (Node.js: clicks in
368 ms; `workerd`: in 356 ms). The costs: the HTTP bytes are made and
read two times (in JavaScript and in Bandit), and the Worker has a small
HTTP framing of its own, which is general (it knows no Phoenix). The
benefit: no adapter to keep in step with Phoenix, Plug and Bandit.

**Compressed bodies.** Bandit compresses a response (gzip) when the
request accepts it, and the Workers runtime compresses a body again
unless the response says `encodeBody: "manual"`: the page came twice
compressed (seen with `wrangler dev`; the browser loaded no script, so
LiveView did not connect). `worker.js` now sends a body with
`Content-Encoding` as it is.

### Distributed Erlang

`wasm_tcp_dist` (`-proto_dist wasm_tcp`) is the distribution example of
OTP (`gen_tcp_dist`: distribution processes, as `wasm_tcp` sockets are
processes, not ports), on `wasm_tcp`. There is no epmd (a Worker cannot
run one): all nodes use one port (`-erl_epmd_port`, `DIST_PORT`, 4370).
`WasmHost.Server` starts the distribution after the pump (a listener
waits for an event of the host), from `DIST_NAME`, `DIST_COOKIE`,
`DIST_LISTEN` and `DIST_CONNECT`; `worker.js` adds the boot flags when
`DIST_NAME` is set.

| | Round trip of an `erpc:call/4` |
|---|---|
| A native hub, and the node in Node.js that connects to it | 273 µs (44 ms before `TCP_NODELAY` on the host sockets) |
| A native hub, and a Durable Object in `workerd` that connects to it | 1.2 to 1.6 ms |
| A native node on a computer, to a Durable Object with `DIST_LISTEN=true`, through `tcp-proxy.mjs` | 1.9 ms |

The hub (or the computer) sees the applications, the processes and the
memory of the edge node, and monitors and kills its processes. A node
that only connects (`dist_listen` false) is hidden: it is not in
`nodes()`, and `net_kernel:monitor_nodes/2` needs `{node_type, all}`.
What it gives: a shell into a VM at the edge; Workers as nodes of a
cluster of native `beam.com` nodes (PubSub, `:global`, `:rpc`); code that
a hub sends to the edge.

**A connection keeps a runtime Worker awake.** The VM of the runtime
Worker runs while a request is open, and a connection to its listener
(`DIST_LISTEN=true`, a WebSocket to `/.tcp/4370`) is an open request. In
`workerd`: a native node connected, started a timer on the edge, and
stayed idle for 90 s; the connection stayed up (the distribution drops a
node after 60 s with no tick), the uptime showed the same VM, and an HTTP
request after it took 7 ms (warm). Cloudflare: "There is no hard limit on
duration for HTTP-triggered Workers. As long as the client remains
connected, the Worker can continue processing" (limits page,
2026-09-27). The limits of this:

- Cloudflare updates the runtime a few times a week, and ends open
  requests after 30 s: the other node must connect again (a new isolate,
  a cold boot).
- The connection keeps one isolate awake, in the location near the other
  node. Requests of users in other locations, or to other isolates in the
  same location, can still start cold; only a Durable Object gives one VM
  for all requests.
- A connection out of the Worker (`DIST_CONNECT`) belongs to the request
  that opened it, and ends at most 30 s after that request: to keep the
  Worker awake, the other node connects in.
- While idle, the VM costs almost no CPU time (a tick each 15 s), and
  Workers do not bill wall time. Erlang processes can hibernate to make
  their memory smaller (the limit of an isolate is 128 MB); that does not
  change the CPU time.

Found: the native resolver of OTP is a port program (`inet_gethost`), and
a lookup stopped the VM: `WasmHost.Server` sets the resolver to the hosts
file. The distribution checks the traffic with `inet:getstat/2`:
`wasm_tcp` counts the bytes.

### A proxy that the host runs (`wasm_tcp:splice/2`)

Erlang decides (it accepts a connection, and connects to the server
behind it), then `wasm_tcp:splice/2` joins the two sockets in the host:
the data of each goes to the other one with no copy through the VM, and
they end together. A download of 50 MB through the demo proxy (`GET
/splice`) takes 66 ms in Node.js (36 ms direct), and 2.3 s in `workerd`
through `tcp-proxy.mjs` and a WebSocket. The client proxy
(`tcp-proxy.mjs`) runs on the computer of the client: the bytes go from
there to the edge, through no other server.

### The cold start

**Measured** (the demo app with Phoenix 1.9.0-dev; the Node.js host, where
the clock is correct during the boot, 7 runs, medians; `workerd` for the
first request):

| | Boot until `ready` (Node.js) |
|---|---|
| `beam.wasm` instantiated | about 40 ms |
| kernel and stdlib only (`start_clean`, `halt()`) | about 240 ms more (about 300 ms in all) |
| The Phoenix release, as it is | 538 ms |
| without the Elixir config provider (the values of `runtime.exs` put in `sys.config`) | 466 ms (−72 ms) |
| and 9 applications not started (`ssh`, `runtime_tools`, `sasl`, `ssl`, `public_key`, `asn1`, `dns_cluster`, `bandit`, `thousand_island`) | 415 ms (−51 ms) |
| and the 207 modules of the boot loaded in one batch | 392 ms (−31 ms; 27% less in all) |
| the same batch, but with all 394 recorded modules | 507 ms (worse: it loads modules that the boot does not need) |

In `workerd`, the first request: 0.634 s as it is, 0.49 s with all three
(the release of the table above: VM ready in 404 ms, not 612 ms).

What the parts cost:

- **The config provider** (72 ms): the first evaluation of `runtime.exs`
  takes about 30 ms (the Elixir tokenizer, parser and evaluator load; a
  second evaluation takes 2 ms), and the provider itself (the checks of
  the compile-time config, a new `sys.config` file) the rest.
- **Module loading:** the load work itself (`erlang:prepare_loading/2`)
  is 93 ms for 293 modules; finding the files costs more when the code
  path is long and not cached (`-pa`: 341 ms), but a release caches its
  paths.
- **Applications:** most of the 51 ms is from applications that the app
  asks for (`ssh`, `runtime_tools`, `ssl` and the others); `bandit` and
  `thousand_island` alone (the HTTP server that the host replaces) give
  no measurable gain.
- The floor (ERTS, kernel, stdlib: about 300 ms) stays until a snapshot.

**Tried in `pack.erl`** (the first packer, now `beam_com_wasm`):

- `--boot-modules FILE`: the packed boot script loads the modules of the
  boot in one batch after kernel (`code:ensure_modules_loaded/1`), from
  the list of a run in the Worker. `beam.com --target wasm32` now makes
  the list itself, with a native run (see "Build the Workers with
  `beam.com`").
- `--no-start APPS`: the boot script loads these applications but does
  not start them. Not in `beam.com`: Bandit now serves HTTP itself.

With both (`bandit,thousand_island` and the boot list), and the config
provider kept: 0.634 s → 0.587 s in `workerd` (7%). The rest of the gain
is a choice of the app: no `runtime.exs` (or one that loads no parser: a
compiled config function), and no applications that it does not use.

**Not measured, from a review of the code and of the Cloudflare
documentation (2026-09-27):**

1. **A snapshot of the booted VM:** done since (see "A snapshot of the
   booted VM"): the first request of the Phoenix app takes 0.20 s, not
   0.61 s.
2. **Small ones:** `wasm-opt` on `beam.wasm`; `-init_debug` shows the boot
   steps (but its output makes the boot 3 times slower).
3. **Not possible:** a boot in the global scope of the Worker (no timers or
   random values there, and a limit of 1 s); a Worker cannot choose the
   compiler tier of V8. But a restore of a snapshot of the build works
   there: see "On Cloudflare: the first deploy".

**Cloudflare Pages** does not help: Pages Functions are Workers, with the
same limits and prices (Pages limits and pricing pages). A Durable Object
has the same 128 MB and 30 s of CPU. Containers (paid plan) run a native
BEAM with no WebAssembly, but get only HTTP through a Worker.

### Ecto SQLite: D1 and Durable Objects

There is no SQLite in the runtime: the host runs the SQL. A release with
`exqlite` (the driver of `ecto_sqlite3`) gets, in place of its NIF module
(`Exqlite.Sqlite3NIF`), a module that calls `wasm_host_sqlite`, which
sends each statement to `worker.js`:

- in a Durable Object (`durable.js`), to its SQLite storage
  (`ctx.storage.sql`: on the same machine, and the answer comes at once);
- else to the D1 database of the binding `DB` (`BEAM_D1` names another);
  `wrangler.jsonc` has the binding (`wrangler d1 create NAME`, then its id).

The app is not changed: `examples/notes` (Ecto with a migration, Plug and
Bandit) runs natively on a SQLite file, and on Workers with D1 or with a
Durable Object. Tested with `wrangler dev`: inserts with `RETURNING`,
`Repo.aggregate/2`, a query with `ORDER BY`, blobs, a transaction, the
migration at the boot, and the data after a restart, also on a VM
restored from a snapshot. On Cloudflare too, with D1 and with a Durable
Object (see "On Cloudflare: the first deploy").

How it works: a statement runs on the host at its first `columns/2` or
step, after the binds, and all its rows come back at once (JSON: a blob as
`{"b": base64}`, an integer over 2^53 as `{"i": "..."}`). The number of
parameters comes from the SQL (`?`, `?NNN`, `:name`). For D1, a statement
that gives rows (`SELECT`, `RETURNING`, `PRAGMA`) uses `raw()` (the names
of the columns, and the rows as lists); the others `run()` (changes and
the row id). For a Durable Object, the changes and the row id come from
`SELECT changes(), last_insert_rowid()` (`rowsWritten` also counts the
writes of `sqlite_sequence`: Ecto saw two rows for one insert).

Limits:

- **Transactions:** neither D1 nor the storage of a Durable Object lets
  SQL control a transaction (`BEGIN` is refused). `BEGIN`, `COMMIT`,
  `ROLLBACK` and the savepoints only change `transaction_status/1`: each
  statement commits alone, and a rollback does not undo what ran before.
- A `PRAGMA` that sets a value does nothing (the backends refuse most of
  them); a `PRAGMA` with no value gives the value that was set. A `PRAGMA`
  with an argument (`table_info(t)`) goes to the host.
- `serialize/2`, `deserialize/3`, the hooks and the extensions are not
  there.

Found on the way:

- **The build of Plug failed** in `beam.com` (`EEx.compile_file("lib/plug/templates/...")`
  at compile time): as Mix, the builder now compiles each package with its
  directory as the current one.
- **A snapshot must not hold I/O of the host.** The Worker made its
  snapshot at `ready`, which `wasm_host` sends before the app starts: the
  migration waited for a D1 answer that was not in the snapshot, and the
  restored VM waited forever. Now the Worker waits until the server of the
  app listens (`PORT`), and until no SQL call or socket is open. And a
  Durable Object took its snapshot while the answer to `tcp_listen` was
  still in the pipe of the host: now, after the threads return, all the
  pipes must be empty, else the VM goes on and the Worker tries again.

### A snapshot of the booted VM (on by default)

The first request of an isolate boots the VM: 0.61 s for the Phoenix app
in `workerd`, of which about 0.3 s is the floor of ERTS, kernel and
stdlib. A snapshot of the memory after the boot takes that away: the
runtime Worker copies the memory into a new instance and the VM goes on.

**The Worker makes it itself** (no Node.js, nothing to set up):

- At the first request of a VM with no snapshot, before the Worker serves
  that request, all the threads return (about 1 ms), the Worker copies
  the memory, the threads go on, and the copy goes to the store in the
  background. The first request is about 80 ms longer (the copy).
- The store is the Cache API (of each data center), or the R2 bucket of a
  binding `SNAPSHOTS`. With no store (`workerd` with no cache), the Worker
  makes none.
- The key: the hash of `beam.wasm`, `beam.mjs`, `worker.js` and the
  release (`snapshot_key` in `.release.json`, from the build), of the
  text bindings, of the host (a Worker or a Durable Object), and of the
  version of the deploy (the binding `BEAM_VERSION`, `version_metadata`
  in the `wrangler.jsonc` files). So a new deploy, or a new secret, gives
  a new snapshot, and the snapshot has the real environment of the
  deploy. The version is necessary: the Workers of an account share the
  Cache API, and a boot runs the migrations on the database of its own
  Worker (see "On Cloudflare: the first deploy").
- The snapshot is made before the first request: the state of the app is
  the state after its boot, with no request in it.
- The VM that makes it runs with `-c false` (see "Time" below).
- `BEAM_SNAPSHOT = "off"` (a var of the Worker) turns it off.

Tested with `wrangler dev` (Miniflare: its Cache API keeps the snapshot
on the disk): the first start made it (19 MB for Cowboy, 31 MB for
Phoenix); after a restart, the first request restored it, and LiveView
worked on the restored VM. On Cloudflare (see "On Cloudflare: the first
deploy"): a restore from the Cache API takes 163 to 428 ms of CPU and
345 to 742 ms in all (Cowboy, 19.3 MB); the Worker and the Durable
Object made their snapshots (19.3 MB, and 32.3 MB with a VM of 58 MB)
with no memory error.

**Or at build time**, with Node.js 26 (a snapshot after warm-up
requests; the Worker with the release keeps it as `snapshot.bin`, and
the runtime uses it first):

```sh
beam.com _build/prod/rel/hello -o worker --target wasm32
node wasm/snapshot/snapshot.mjs worker --warm 4000:/counter \
    --env SECRET_KEY_BASE=... --env PHX_HOST=...    # writes worker/release/snapshot.bin
node wasm/snapshot/snapshot.mjs worker --check 4000:/counter  # restore it in Node.js, 3 requests
workerd serve worker/worker.capnp
```

**The problem, and the way.** A thread that waits is a suspended JSPI
stack of the engine, and JavaScript cannot save it. So each thread of
ERTS returns to the host when it has nothing to do, and no stack is left
to save:

- `erts_wasm_hibernate()` (exported) sets a flag and wakes all the threads:
  the normal and the dirty schedulers, the aux thread, the poll thread,
  the async thread, the signal dispatcher and the system-message
  dispatcher (17 threads with `-S 1 -SDcpu 1 -A 0`). Each one returns at
  the place where it waits when idle (a scheduler after
  `scheduler_wait()`, with its run queue as the next `erts_schedule()`
  expects it; the others at the top of their loops), and calls
  `jspi_park(fn, arg)`: the function to start it again. The main thread of
  ERTS returns from `main()` (where the runtime stays after it: not the
  Node.js build).
- ethread does not clean up a parked thread (its event and its keys stay),
  and `jspi_pthread.c` keeps its `struct __pthread` (the same
  `pthread_self()`, keys and stack).
- The host waits until `jspi_live_threads()` is 0 (0.5 to 0.7 ms), and
  copies the non-zero 64 KiB pages of the memory, the files that the boot
  wrote, the open files (the pipes of ERTS, by number) and the listeners
  of `wasm_tcp`.
- In a new instance (`noInitialRun`), `worker.js` writes `release.bin`
  into its files, copies the pages, makes the pipes again with the same
  numbers (`jspi_snapshot_pipe()`), and calls `erts_wasm_resume()`: each
  thread starts again in its function (`jspi_resume_all()`), past the
  initialization.
- `wasm_host:recv/0` waited in a NIF on a dirty I/O scheduler, and that
  thread could not return: now the host writes a byte into a pipe for
  each event, and the pump waits for it with `enif_select` (`select/0`,
  `take/0`), as for a socket. The Workers without a snapshot work the same
  way (the same times).
- **Time:** the VM of the snapshot runs with `-c false` (no time
  correction): the monotonic time follows the system time, and after a
  restore it jumps forward by the gap, so the timers that were due fire at
  once. With time correction, ERTS stops at the first time read after a
  restore ("OS monotonic time stepped backwards": `performance.now()` of
  a new instance starts again at 0). Tested.
- **Random:** the state of OpenSSL is in the memory, so all the isolates
  of one snapshot gave the same random bytes: two restores gave the same
  CSRF token of the Phoenix page. After a restore, `worker.js` sends 48
  random bytes (`crypto.getRandomValues`) in a `restored` event, and
  `wasm_host_server` gives them to `crypto:rand_seed/1` (OpenSSL reseeds
  its primary generator, and the others follow). Then the tokens differ.
  Tested.

**Results** (`workerd`, the first request after a new `workerd`, 7 runs,
medians; the snapshot made after one warm-up request, with its modules
loaded):

| | Without a snapshot | With a snapshot |
|---|---|---|
| Phoenix (`/counter`), first request | 0.612 s | 0.197 s |
| Phoenix, VM ready | 0.49 s | 0.12 s (`release.bin` and `snapshot.bin` from the other Worker in 42 to 52 ms) |
| Cowboy (`examples/worker`), first request | 0.344 s | 0.125 s |
| Next requests | 3 to 5 ms | 3 to 5 ms |
| LiveView: connect, 3 clicks, the pushed seconds | works | works (a click: 67 ms, the same) |
| `snapshot.bin` | | 33.5 MB (Phoenix: 536 of 933 pages), 20.4 MB (Cowboy) |

In Node.js the restore takes about 110 ms from the start of the process
(files 35 ms, memory 25 ms), and the first answer of Phoenix 65 to 87 ms
more: V8 compiles each function of the new instance at its first call.

**Sizes and memory.** The Worker with the release has `release.bin` (8.5
MB) and `snapshot.bin` (33.5 MB): under the 64 MiB of a Worker. The runtime
gets both with a fetch, and frees the snapshot after the copy: the live
memory (58 MB) and `release.bin` stay, in the 128 MB of an isolate.

**What is still open:**

- **The state is shared.** Every isolate starts from the same state (a
  snapshot of the build here; the Worker makes its own before any
  request): the
  counter of `examples/worker` said "request 2" in each new isolate (its
  warm-up request was before the snapshot). Values made at the boot are
  the same everywhere (the `endpoint_id` of Phoenix, tokens made at the
  boot, the seeds of `rand` of the processes that exist). The
  environment too: `SECRET_KEY_BASE` and the other values that
  `runtime.exs` read at the boot are in the snapshot, so a new secret
  needs a new snapshot (or the app reads them again on `restored`).
- **A snapshot of the build** needs Node.js 26 (JSPI) and the same
  `beam.wasm` as the Worker (the memory holds indices of its function
  table: a snapshot of another build is wrong). The snapshots that the
  Worker makes need neither.
- **The idle point.** A thread that waits in another place (a long NIF, a
  port) does not return: `snapshot.mjs` then stops with an error and names
  the thread.
- **A crash dump** of the VM in the Worker fails with `SuspendError`: a
  wait inside the `setjmp` wrappers (`invoke_*`) of `erl_crash_dump.c`
  cannot suspend under JSPI. Not about the snapshot.
- On Cloudflare, `performance.now()` does not move during work: see "On
  Cloudflare: the first deploy".

### Cloudflare's limits (from its limits and pricing pages, 2026-09-28; the limits page was updated 2026-09-05)

- **CPU time for each request:** 10 ms on the free plan, 30 s (up to 5
  min) on the paid plan. Measured: a boot takes 0.4 to 1.4 s of CPU, a
  restore from the Cache API 0.16 to 0.43 s, a restore in the global
  scope with a warm-up about 11 ms, and a warm request 2 to 10 ms. On
  the Free plan, no request failed for its CPU time (see "On
  Cloudflare: the first deploy").
- **Startup:** 1 s for the global scope of the Worker. Measured: 48 ms
  for a restore of a bundled snapshot there, and 84 to 223 ms with a
  warm-up request.
- **Memory:** 128 MB for each isolate, the JavaScript heap and the
  WebAssembly memory together. One VM (48 to 58 MB, and `release.bin` in
  its file system) fits; two VMs in one isolate would not.
- **Size:** 64 MiB without compression, on both plans.
- **Price:** Workers bill requests and CPU time, with no charge for idle
  time. Durable Objects are on the free plan too, and bill duration while
  in memory, except objects that are idle and eligible for hibernation.

### On Cloudflare: the first deploy (2026-09-28)

**The setup.** `beam.com` of main (`26675a4`, the CI artifact), wrangler
4.142.0, an account on the **Free plan**, the data center IAD. The
client reached Cloudflare through a proxy (the TLS connection took 0.13
to 0.46 s), so the times here are those of the server: `cpuTime` and
`wallTime` of `wrangler tail --format json`.

**JSPI works.** The runtime Worker and the Durable Object boot the VM
and serve requests, as in `workerd`. The snapshot works too: the Worker
makes it at its first request and keeps it in the Cache API, and the
next isolates restore it. The Cache API also works in a Durable Object.

**The plain Worker** (`examples/worker`, Cowboy, 7.8 MB release; VM
memory 40 MB):

| | CPU | Wall |
|---|---|---|
| First request of a deploy: boot, and a snapshot of 19.3 MB (2 deploys) | 435 and 553 ms | 796 and 913 ms |
| First request of a new isolate: a restore from the Cache API (11 isolates) | 163 to 428 ms (median 277) | 345 to 742 ms (median 570) |
| The next requests | 2 to 3 ms (the second of an isolate: 9 to 22 ms) | 2 to 4 ms |

At low traffic, Cloudflare sends the requests to many isolates: 14 of
30 requests were the first request of their VM. So the time of a cold
start is the time that a person sees most often.

**A restore in the global scope** (`global.js`, `wrangler.global.jsonc`).
The runtime Worker has the release and a snapshot of the build
(`snapshot.mjs`, 20.4 MB) as modules: 33.4 MB, 11.5 MB with gzip, and
the Free plan took it. The global scope makes the VM and copies the
memory, and the first request starts the threads and reseeds OpenSSL.
Cloudflare measured the startup time at the deploy: 48 ms, and 84 to 223
ms with the warm-up (the limit is 1 s).

| First request of a new isolate | CPU | Wall |
|---|---|---|
| A restore from the Cache API, in the request (above) | 163 to 428 ms | 345 to 742 ms |
| A restore in the global scope (9 isolates) | 72 to 136 ms (median 84) | the same |
| and a warm-up request of `/` there (`BEAM_WARM`; 10 isolates) | 35 to 74 ms (median 40) | the same |
| and a reseed of OpenSSL with zero bytes in the warm-up (13 isolates) | 8 to 21 ms (median 11) | the same |
| (only a test: no reseed at the first request; 16 isolates) | 7 to 17 ms (median 10) | |

- **Why the warm-up:** V8 compiles each function of the WebAssembly
  module at its first call, in each isolate. In the global scope, a
  GET request of `BEAM_WARM` goes to the app (with no timers there: the
  jobs of the threads run between microtasks). Two warm-up requests
  gave no more gain.
- **Why the reseed in the warm-up:** the first reseed of OpenSSL in an
  isolate costs about 30 ms of CPU. The global scope has no random
  values, so the host gives zero bytes to the VM during the warm-up,
  and the first request reseeds with random bytes as before. Tested: 16
  requests to new isolates gave 16 different values of
  `crypto:strong_rand_bytes/1`.
- A warm-up request must not use SQL or sockets (I/O of the host). A
  snapshot of the build has no SQL either, so the build writes no
  `global.js` for Ecto SQLite.
- So the first request of an isolate uses about 11 ms of CPU, near the
  10 ms of the Free plan. A request of a path that the warm-up did not
  use costs more (`/rand`: 9 to 21 ms).

**The Durable Object** (`examples/notes`, Ecto SQLite on the storage of
the object, 16.2 MB release; VM memory 58 MB):

| | CPU | Wall (front Worker) |
|---|---|---|
| Boot, and a snapshot of 32.3 MB | 1,362 ms | 1,252 ms |
| Restore from the Cache API | 142 to 206 ms | 350 to 405 ms |
| `/`, `/notes`, `/tx` on a warm VM | 3 to 10 ms | 13 to 26 ms |
| `/hash` (low costs) | 30 ms | |
| `/hash?cost=default` | 1,513 ms | 1,968 ms |

- `/`, `/notes` (a blob too), `/tx` and `/hash` work.
- **The VM used the CPU all the time** (fixed): 32.5 s of CPU in 34.4 s
  with no requests. The clock of a Worker moves only by the delay of a
  timer, not at `setTimeout(0)`, and a wait of less than 1 ms became a
  timer of 0 ms: a thread waited for the same time again and again
  (docs/UPSTREAM.md W3). Now a timer waits 1 ms at least: 11 to 17 ms
  of CPU in each 5 s with no requests. Then Cloudflare evicted the idle
  object after about 15 s, and the next request restored a new VM.
- **argon2 with the default costs** (64 MiB) went over the 128 MB of
  the isolate: "Durable Object's isolate exceeded its memory limit and
  was reset". A later try passed (1,513 ms of CPU), but the object was
  reset again soon after: the WebAssembly memory does not shrink
  (docs/UPSTREAM.md W5). Use lower argon2 costs, or bcrypt.
- The tail event of a Durable Object comes late, and its wall time (and
  CPU time) runs until the next event of the object. So it is not the
  time of the answer: use the front Worker for that.

**The Free plan.** A Worker on the Free plan cannot set `limits.cpu_ms`
("CPU limits are not supported for the Free plan"). But no request
failed for its CPU time: boots of 435 ms and 1,362 ms, restores of up
to 428 ms, and argon2 with 1,513 ms all passed, in about 150 requests.
So the 10 ms is not a hard limit for each request (Cloudflare does not
document how it applies it); do not count on this.

**Other differences from `workerd`:**

- **The clock** does not move during work: `:timer.tc` in the app gave
  0 ms for hashes of 0.6 s, and `Date.now()` in the global scope does
  not move. A time that Erlang measures in one request is the time of
  the I/O and timers, not of the CPU.
- **The global scope** takes top-level `await`, `WebAssembly.instantiate()`
  and a 64 MB allocation, but no random values, timers or I/O
  (docs/UPSTREAM.md W4). `env` comes from `cloudflare:workers` there.
- **Sizes:** the Free plan took Workers of 11.5 MB with gzip (33.4 MB
  without compression).
- **`PHX_HOST`:** the host of a Worker is `NAME.SUBDOMAIN.workers.dev`
  (the subdomain of the account), not `NAME.workers.dev`. The build now
  writes `NAME.SUBDOMAIN.workers.dev`, to change. (Phoenix was not
  deployed.)
- **The Worker with the release was public:** anyone could get
  `release.bin` from `NAME-release.SUBDOMAIN.workers.dev`. Now it has
  `"workers_dev": false`: the runtime Worker gets it through its service
  binding (tested: the URL gives 404, and the runtime Worker works).
- **The Durable Object had the name of the runtime Worker** (`NAME`), so
  its deploy replaced that Worker. Now it is `NAME-durable`.

**D1** (the runtime Worker `notes` with its release Worker, and a D1
database in the region ENAM):

| | CPU | Wall |
|---|---|---|
| Boot, the migration on D1, and a snapshot of 32.1 MB | 963 ms | 2,107 ms |
| Restore from the Cache API (8 isolates) | 215 to 506 ms | 526 to 1,076 ms |
| `/` on a warm VM (an insert and a count: 2 statements) | 12 to 49 ms | 68 to 97 ms |
| `/notes`, `/tx` on a warm VM | 5 to 17 ms | 31 to 45 ms |
| `/hash` (low costs) | 19 to 48 ms | |
| `/hash?cost=default` | 1,240 and 1,318 ms | 1,264 and 1,342 ms |

- All the routes work. Each statement is a call to D1 (about 25 to 45
  ms), so a request with SQL takes longer on D1 than in a Durable Object
  (13 to 26 ms), which has its SQLite on the same machine.
- argon2 with the default costs passed twice in the plain Worker, with
  no memory error.
- **A snapshot of another Worker** (fixed): the first deploy of `notes`
  restored the snapshot that the Durable Object Worker had made (with
  the same release and no vars, so the same key). That VM had run its
  migration on the storage of the object, so D1 had no table: "no such
  table: notes". The Workers of an account share the Cache API. Now the
  key also has the host and the version of the deploy (`BEAM_VERSION`):
  each deploy boots once, and runs its migrations on its own database.

**Not tested:** Phoenix and LiveView, R2 (not enabled on the account),
and a paid plan.

### Tenants, a boot point, a spare VM, a smaller release (2026-09-28)

After the first deploy: Phoenix LiveView with one Durable Object for each
tenant, and the next steps for its cold start. Measured on Cloudflare
(Free plan, IAD), with the times of `wrangler tail` as before.

**Tenants** (`durable.js`, the var `BEAM_TENANTS`). Each tenant has its
own Durable Object: its own VM, state and SQLite storage. With
`"cookie"`, `GET /.tenant/NAME` sets the cookie `beam_tenant`, and the
cookie names the object (for a workers.dev URL, which has no
subdomains); with `"host"`, the first label of the host names it
(`NAME.example.com`). The front Worker gives the name to the app in the
header `x-beam-tenant`, and removes that header from the request of a
client. `wasm/phoenix/tenants/setup.sh` makes a LiveView app with a
counter that all the visitors of a tenant share (`Phoenix.PubSub` in the
VM of the tenant).

- Deployed at `https://live.fifo.workers.dev` (`/.tenant/NAME`).
- A click of the counter (an event over the LiveView WebSocket, to its
  reply): 42 to 67 ms from a client in the same region. A second visitor
  of the same tenant got the new count; a visitor of another tenant did
  not.
- 12 new tenants at the same time: all answered, with no memory error.
  Cloudflare puts the objects in different isolates.

**A spare VM for Durable Objects** (`durable-global.js`,
`wrangler.durable-global.jsonc`). As `global.js` for a plain Worker: the
Worker has the release and a snapshot of the build as modules, and the
global scope of each isolate restores a spare VM and warms it up
(`BEAM_WARM`). The first object of the isolate takes it (`Vm.adopt`: its
jobs and timers move from the requests to a `MessageChannel` and
`setTimeout`). Another object in the same isolate restores the snapshot
of the Cache API.

**A snapshot at the boot point** (`WASM_HOST_BOOT_POINT`,
`snapshot.mjs --boot-point`). A snapshot after the boot holds the state
of the database that the boot used: the migrations ran on the storage of
one object, and other tenants that restored it had no tables (a fault
of the first version, as with D1). `wasm_host_server` can wait after the
modules of the boot are loaded, before `runtime.exs` and the program,
until the host sends `go` with the environment. A snapshot of that point
holds no database state and no secret. A Durable Object with Ecto SQLite
(`sql` in `.release.json`) makes its snapshot there, all the objects
share it, and each one runs the program and its migrations on its own
storage. The build snapshot of an app with Ecto SQLite uses it too
(`global.js` and `durable-global.js`, with no warm-up request).

| A new tenant (its first request) | CPU | Wall (front Worker) |
|---|---|---|
| Phoenix, a restore from the Cache API | 142 to 435 ms | 1,187 to 1,484 ms |
| Phoenix, the spare VM of the global scope (startup 135 ms) | 52 to 61 ms | 650 to 1,077 ms |
| `notes` (Ecto SQLite), a full boot for each tenant | 629 to 1,138 ms | about 1,400 ms |
| `notes`, the snapshot of the boot point from the Cache API | 248 to 368 ms | 1,015 to 1,115 ms |
| the same, with the smaller `release.bin` (below) | 318 to 441 ms | 709 to 1,157 ms |
| `notes`, the snapshot of the boot point in the global scope | 217 to 267 ms | 870 to 956 ms |

- With the boot point, the first request of a tenant starts the program
  (about 200 ms of CPU for `notes`, and 270 ms in Node.js for Phoenix,
  which then evaluates `runtime.exs` again). So an app with no database
  uses a full snapshot and a warm-up.
- The rest of the wall time is mostly Cloudflare: a new isolate for a
  Worker of 46.5 MB, and the network to the object.

**A smaller `release.bin`.** The builder strips the debug information,
the docs and the checker chunk of Elixir from the `.beam` files that
have them (the dependencies that it compiles; `mix release` strips its
own), and compresses with gzip the modules that the boot does not load.
The loader of ERTS reads them so. `examples/notes`: 16.6 MB to 8.2 MB,
so 8.4 MB less in the memory of each isolate.

- Tried first: those modules in a `lazy.bin` of the Worker with the
  release, fetched when the VM opens their file (the import
  `__syscall_openat` as `WebAssembly.Suspending`). It does not work:
  ERTS opens files under `setjmp` (the `invoke_*` frames of
  Emscripten), where JSPI cannot suspend (docs/UPSTREAM.md EM4).

**Found on the way:**

- **A lost `MessagePort`** (fixed, docs/UPSTREAM.md W6): the boot of the
  Phoenix release in a Durable Object stopped before `init` in most
  tries. `jspiLater` kept only one port of its `MessageChannel`, and the
  runtime collected the other one with its handler.
- **The wait for the threads of a snapshot** used 5,000 steps of
  `setTimeout(0)`: on Cloudflare they do not wait, so the snapshot at the
  boot point failed ("no snapshot at the boot point"). Now the steps are
  1 ms.
- **A deploy resets the objects:** a request during the rollout can get
  "Durable Object reset because its code was updated" (a 500). Seen
  once in 10 deploys.
- **One hang:** the object that made the snapshot of the boot point did
  not answer its first request once (a new VM answered the next one).
  Not seen again in 10 tries.
- The uptime of a restored VM counts from the boot of the snapshot, so
  all the tenants of one snapshot showed the same uptime.

### Livebook in a Durable Object (2026-09-28)

`wasm/livebook/setup.sh` builds Livebook 0.19.10 for Workers, with the
changes of `livebook.patch`. Its embedded runtime evaluates the cells in
the VM of Livebook. Each tenant has its own Durable Object, VM and
storage. The first deploy at `https://livebook.fifo.workers.dev` had a
password and cookie tenants (`/.tenant/NAME`); `setup.sh` now makes
public instances (below).

**Memory.** An isolate has 128 MB. The first deploy stopped after a few
cells. These changes make it stable:

- `BEAM_ERL_FLAGS = "-Mea min"`: no allocators of ERTS, only `malloc`.
  Livebook starts with 42 MB of WebAssembly memory, not 70 MB.
- The runtime grows its memory in small steps
  (`MEMORY_GROWTH_GEOMETRIC_STEP=0`).
- The static files of Livebook (12 MB) are the static assets of the
  Worker (`wasm/erts/host/static.mjs`), not files of `release.bin`.
- After a restore, the Worker frees the bytes of the snapshot (29 MB).
  Before, a closure of the VM kept them, and the object was reset in
  2 of 3 runs of the notebook on Cloudflare.

All the cells of the notebook take the memory from 42 MB to 66 MB
(measured with `wrangler dev`).

**The files of `/data` stay** (the var `BEAM_PERSIST`, a list of
directories). A Durable Object keeps the files of these directories in
its SQLite storage (the tables `beam_fs` and `beam_fs_chunk`, in chunks
of 1 MB). Before the VM starts, the host writes them into the file
system of the VM. The host saves a file when the VM closes it after a
write, or 1 s after a write. It saves a delete, a rename and a new
directory at once. The snapshot does not hold these directories.

- Livebook keeps its settings (`livebook_config.v1.ets`) and its
  autosaved notebooks in `/data`.
- A deploy resets the objects: the new VM of the default tenant got
  back its 4 files (115 KB), and then 5 files (123 KB).

**The snapshot.** With `BEAM_PERSIST`, a Durable Object makes its
snapshot at the boot point, as with Ecto SQLite. So the files and the
settings of a tenant are not in it, and all the tenants share it. The
first request of a new tenant:

| | `wrangler dev` (this computer) | Cloudflare (CPU; wall) |
|---|---|---|
| A full boot | 2.0 s | 1,641 to 2,016 ms; 2.5 s |
| A restore of the boot point | 0.53 to 0.62 s | 1,189 to 3,147 ms (median about 1,600 ms); 1.6 to 2.8 s |

- On Cloudflare, the restore itself takes 137 to 802 ms. Then Livebook
  starts (`runtime.exs` and its applications) and answers. At the first
  cell, 695 modules are loaded: 415 come from the snapshot, and the VM
  loads the others one at a time from gzip.
- Next: the native run of the build could also record the modules of a
  first request, so that the snapshot holds them.

**Root certificates** (`--cacerts FILE`). The runtime has no
certificates of its own, and Livebook, `Req` and `:httpc` need them for
TLS. `beam.com --target wasm32 --cacerts FILE` puts the certificates
of FILE into the release (`etc/cacerts.pem`, 177 KB for the bundle of
Mozilla), and the VM reads them with `-public_key cacerts_path`, as
beam.com does on Windows. With no option, the release has no
certificates.

- The builder does not copy the store of the computer of the build:
  the store of the build machine of this test had 5 CAs of a TLS proxy.
- `setup.sh` gets the bundle of Mozilla from `curl.se` and checks its
  SHA-256. On Cloudflare, the cell that calls
  `Req.get!("https://hex.pm/api/packages/kino")` works.

**Kino and the notebook of the edge.** Kino 0.18 is in the release,
because the embedded runtime has no `Mix.install/2`.
`beam_on_the_edge.livemd` is in the Learn section, after the welcome
notebook, and on the home page. It has these cells:

- The system (`wasm32-unknown-emscripten`, one scheduler, 695 modules).
- 10,000 processes (1,372 bytes each) and a ring of 1,000 processes
  (100,000 messages).
- A trace of messages (`Kino.Process.render_seq_trace/1`).
- A supervisor tree, and a crash that the supervisor repairs.
- A hot code upgrade: the same process answers "version 1, call 3",
  then "version 2, call 4".
- A table of the busiest processes, each second (`Kino.Frame`).
- A TLS request to hex.pm.

All the cells ran with no error on 7 new tenants on Cloudflare. But the
diagrams of Kino did not show there, for two causes:

- Kino draws its JS outputs in an iframe of another site. On HTTPS,
  Livebook 0.19.10 loads it from `livebookusercontent.com/iframe/v6.html`,
  and that host does not have `v6` (docs/UPSTREAM.md L4). `setup.sh` now
  makes a third Worker, `livebook-iframe`, with the iframe pages of the
  release, and sets `LIVEBOOK_IFRAME_URL`.
- The iframe gets the JS of the output from Livebook. A request from an
  iframe of another site has no `SameSite=Lax` cookie, so the cookie of
  the tenant was absent, and the request went to another object (404).
  Path tenants (below) put the name of the tenant in the URL.

With both changes, `wrangler dev` (with a second port for the iframe
Worker) shows the trace of messages and the supervisor tree. A
`Kino.DataTable` that a cell makes again each second stays in its load
state, so the live table of the notebook is Markdown now.

**Public instances (2026-09-28).** A public Livebook with no password,
with bounds for the Free plan. `durable.js` has two new modes:

- `BEAM_TENANTS = "path"`: `/t/NAME/...` names the object. The front
  Worker removes the prefix, looks up a static asset (the binding
  `ASSETS`), and else gives the request to the object. The VM gets
  `BEAM_TENANT` and `BEAM_TENANT_PATH` at the boot point, and
  `livebook.patch` makes `BEAM_TENANT_PATH` the base path of Livebook
  (`LIVEBOOK_BASE_URL_PATH`).
- `BEAM_INSTANCES`: the page of `/` has a button that starts an
  instance (a POST, so a crawler starts none). The object `.registry`
  gives a random name (100 bits), a time limit (`BEAM_INSTANCE_TTL`,
  1,800 s) and an alarm. At most `BEAM_INSTANCES` instances run at one
  time (5 in `setup.sh`), 2 for one address (a hash of the address and
  the day), and the others wait in a queue: a page that refreshes each
  10 s. `BEAM_INSTANCE_HOURS` bounds the instance hours of a UTC day.
- At the limit, the alarm deletes the storage of the object
  (`deleteAll()`) and stops it. A later request gets 410.
- A cron trigger each 30 minutes calls `sweep()` of the registry. It
  deletes the storage of each instance past its limit (if its alarm did
  not), and once the storage of each object that `BEAM_RETIRE` names:
  objects of an earlier mode, which the registry did not make (the
  cookie tenants of the first deploy). Tested with `wrangler dev
  --test-scheduled`: the sweep deleted 2 expired instances and 2
  retired objects, and a second sweep found nothing.
- One Worker holds Livebook: `release.bin` is a module of the runtime
  Worker (`worker.js` imports it when there is no binding `APP`), not a
  second Worker. The iframe pages stay on a second Worker (static files
  only), because the JS outputs of Kino must run on another site than
  Livebook. On workers.dev, a Worker has one host name; with a custom
  domain, one Worker can serve both host names. A name such as
  `iframe.livebook.fifo.workers.dev` does not work: the certificate of
  workers.dev covers one label, and the TLS handshake fails.
- The Free plan gives 13,000 GB-s a day of Durable Objects, and each
  object counts as 128 MB: about 29 object hours. The default bound, 24
  instance hours a day, keeps within it.
- Tested with `wrangler dev` (2 instances, 150 s): the third visitor
  waited in the queue, got the place at the limit of the first two,
  and the storage of an instance (5 files) was empty after its limit.
- Caution: each visitor runs code with the network, and can read the
  vars and secrets of the Worker. Give the Worker no secret. Livebook
  makes a random `secret_key_base` in each VM. The VMs restore one
  snapshot, but their random bytes (`:crypto.strong_rand_bytes/1`,
  `:rand`) and their `secret_key_base` were all different in 3 instances
  (`wrangler dev`).
- On Cloudflare (2026-09-28): the first deploy of the Workers `livebook`
  (18.4 MB, 14.4 MB with gzip, on the Free plan) and `livebook-iframe`.
  A new instance ran all the cells of the notebook with no error, and
  the JS of a Kino output came through `/t/NAME/` (200, with
  `access-control-allow-origin: *`).

**Build and deploy at each push.** Workers Builds (the Git integration
of Workers) builds and deploys the Worker `livebook` from this
repository. There are two triggers:

- A push to `main` that changes `wasm/livebook/*` (the build watch
  path) starts a build with the last `beam.com` of `main`.
- A merge to `main` that changes `beam.com`: CI builds and tests it, the
  job `edge` publishes it as the prerelease `edge` (with its SHA-256),
  and then calls the Deploy Hook of the Worker (the secret
  `LIVEBOOK_DEPLOY_HOOK` of the repository).

`wasm/livebook/build.sh` downloads that `beam.com`, checks its SHA-256,
and runs `setup.sh`. `deploy.sh` deploys the iframe Worker and then the
Worker of Livebook with the token of Workers Builds. The limits of Workers Builds (2026-09-28): Ubuntu 24.04 on
x86_64, 20 minutes, 8 GB, 2 vCPU and 3,000 build minutes a month on the
Free plan, and no cache. A build from nothing took 1 min 27 s on 2 CPUs
of this computer. The dry runs of the three deploys passed.

The settings of the Worker `livebook` (Settings > Build):

| Setting | Value |
|---|---|
| Git repository and branch | `sntran/beam.com`, `main` |
| Root directory | `wasm/livebook` |
| Build command | `sh build.sh` |
| Deploy command | `sh deploy.sh` |
| Build watch paths | include `wasm/livebook/*` |
| Build variables | `SUBDOMAIN` (the workers.dev subdomain), `INSTANCES` (5), `RETIRE` (objects of an earlier mode) |

If the token of Workers Builds cannot deploy the Worker
`livebook-iframe`, give the build an API token with the permission
"Workers Scripts: Edit".

**Found on the way:**

- **The clock does not move while code runs** on Cloudflare (a
  protection against timing attacks). `:timer.tc/1` gives 0 ms there.
  It gives the time of the last I/O, and a timer is not I/O: a sleep of
  1 ms before and after the work moved the clock by 2 ms, not to the
  real time (10,000 processes "in 1.0 ms"). So `Edge.measure/1` of the
  notebook also gives the reductions of the work, which need no clock.
  With `wrangler dev` (no such rule), the time is correct: 55 ms for
  10,000 processes.
- Livebook needs `os_mon`, which beam.com does not have. `setup.sh`
  compiles its Erlang code from the source of the same OTP, and
  `livebook.patch` turns off its port programs.
- Livebook: the distribution at start, `:erlang.memory/0` with
  `-Mea min`, and ExUnit for the modules of a cell (docs/UPSTREAM.md
  L1 to L3).
- **A WebSocket during a deploy** can fail with "This script has been
  upgraded" (seen once).

## Erlang in a browser tab

`wasm/browser/index.html` loads the Worker variant of `wasm/erts` (kernel
and stdlib in the module) and runs `erl -eval` in the page. Chromium 141
has JSPI with no flag: "hello from wasm32-unknown-emscripten, OTP 29, 43
processes" in 436 ms.

## Use cases

- **Phoenix LiveView on Workers.** The runtime Worker (each isolate has
  its own VM) or a Durable Object runs the app: pages,
  LiveView sockets, PubSub and timers in one VM, near the users, with no
  server to manage. An idle VM costs no CPU time. The data can be the
  SQL storage of the Durable Object (SQLite), or Postgres through
  `connect()`.
- **Erlang and Elixir code at the edge**, as a function per request: an
  API, a webhook, a small service, in the runtime Worker (no binding to
  set up). The first request of an isolate boots the VM (0.6
  s); the next ones take 3 ms, and the VM costs nothing between them.
- **Stateful objects with the actor model:** a Durable Object for each
  room, game, document or user, with OTP processes inside it
  (`gen_server`, supervisors, ETS) and a WebSocket for each client.
- **Erlang in the browser:** a playground or a tutorial that runs real
  OTP; offline apps; the same Elixir code on the server and in the page
  (a LiveView that runs in the tab when there is no network is a
  question for later).
- **One runtime for many apps:** the runtime Worker has no application,
  and boots the release that it is pointed to. The `.beam`
  files are data for V8, not code, so the rule of Workers against code at
  run time does not apply to them: a release can come from another Worker,
  from R2 or from a URL.
- **A sandbox:** a WebAssembly VM has no access to files, processes or the
  network, other than what the host gives it (as `wasm_tcp`). Untrusted
  Erlang code (a plugin, an exercise) can run in a Worker or a tab.
- **Deno and Node.js:** a VM inside a JavaScript program (a CLI, an
  Electron app) with no native binary for each platform.

## How this fits `beam.com`

The WebAssembly runtime does not use APE or Cosmopolitan: it is ERTS
built with Emscripten, a second runtime next to the APE one. The Blink
spike (APE in an emulator) was the way to keep one binary, and it was 150
to 250 times slower. What it shares is the goal and the release: the same
`.beam` files and the same release run on the APE runtime and on the
WebAssembly runtime. So it is a build target of `beam.com` ("build once,
run on the operating systems and on WebAssembly hosts"), not a part of
the APE binary: `beam.com INPUT -o DIR --target wasm32` (see "Build the
Workers with `beam.com`").

Still open:

- **The runtime in CI:** done. The step `wasm_runtime` of `build.sh`
  installs emsdk (6.0.10) and builds the variant for Workers from a clone
  of the same OTP; `bundle` puts it in the zip (`beam.com` is 1.9 MB
  larger). `WASM_RUNTIME=none` leaves it out.
- **Upstream:** the changes of ERTS (`otp.patch`).

## Next

- **A smaller `release.bin`:** only the modules of the boot at first, and
  the others from the app Worker when the code server asks for them.
- **Data:** Postgres through `wasm_tcp` (Postgrex over `gen_tcp` and
  `ssl`, which work now). (SQLite on D1 and Durable Objects is done: see
  "Ecto SQLite".)
- **Cloudflare:** the first deploy is done (see "On Cloudflare: the
  first deploy", and "Tenants, a boot point, a spare VM, a smaller
  release"). Still to test there: R2 for the snapshots, a paid plan, and
  more load on one tenant.
- **Lazy modules:** a runtime built with `-sSUPPORT_LONGJMP=wasm` (no
  `invoke_*` frames) could load the modules that the boot does not load
  from the Worker with the release (docs/UPSTREAM.md EM4). It would also
  let a crash dump suspend.
- **More NIFs:** Rustler NIFs (Rust for `wasm32-unknown-emscripten`, one
  crate at a time).
- **WASI:** not now. ERTS needs threads: `wasi-threads` was withdrawn,
  and its successor (shared-everything-threads) is in no host yet;
  Workers have no threads, and their WASI is an experimental JavaScript
  shim. WASI 0.3 (2026-06) has async components, but not the stack
  switching of the green threads (JSPI here). Later, with stack switching
  in Wasmtime and other hosts, the same `beam.wasm` could run there.
- **More Durable Objects:** PubSub between objects (a
  `Phoenix.PubSub` adapter over Durable Object requests).
- **The snapshot:** see "What is still open" in "A snapshot of the
  booted VM".
- **UDP and DNS** through the host.
- **Incoming TCP:** the `connect()` handler of Workers (Spectrum, private
  beta; a paid product) when it is available; distributed Erlang over `wasm_tcp` (it needs
  a distribution module, as `inet_tcp_dist` over `wasm_tcp`).

## Limits of the way

- Threads switch only when one waits: a long NIF or BIF stops all the
  others (Erlang processes are still preempted by reductions).
- The CPU time of a request in Workers applies to all the threads.
- The runtime Worker keeps its VM while the isolate is in memory, and the
  VM runs only while a request is open; a Durable Object keeps its VM
  while it is in memory, and runs it all the time.
- TCP sockets of the runtime Worker close with the request that opened
  them (outgoing) or with their WebSocket (incoming).
- No incoming TCP on Workers other than through a WebSocket and a client
  proxy (for now); no UDP.
- No ports (no `fork()` or `exec()`), and no NIFs that are not linked into
  the runtime (the list: the file `nifs` of the runtime).
