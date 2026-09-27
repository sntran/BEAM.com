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
6. Build settings: `erl_crash_dump.c` without `-fexceptions`,
   `HAVE_MALLOPT` off in `config.h` (Emscripten does not declare it), no
   `-export-dynamic` (no dynamic NIFs; it made a JS wrapper for each
   symbol: 1 MB of JS in place of 124 KB).
7. Compiler flags: no security hardening flags (stack canaries, fortify
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
the seconds) runs from the WebAssembly ERTS: in Node.js, and in a Durable
Object of Cloudflare's `workerd`, with a real browser (Chromium, with
Playwright). Phoenix, LiveView and the `.beam` files of the app are not
changed.

```sh
npm install --prefix wasm                                # ws (the Node.js host), playwright-core (the tests)
BEAM_COM=.../beam.com wasm/phoenix/setup.sh              # mix phx.new, the LiveView, a release
BOOTSTRAP=... ELIXIR=... SERVE=1 wasm/phoenix/run.sh     # Node.js: http://localhost:4000/counter
EMSDK=... BOOTSTRAP=... ELIXIR=... wasm/phoenix/build-worker.sh
workerd serve wasm/phoenix/build/worker/worker.capnp     # workerd: http://localhost:8789/counter
node wasm/phoenix/browser-test.mjs http://localhost:8789/counter
```

### The parts

| Part | What |
|---|---|
| The risk check | libcrypto for WebAssembly; the release (`mix release`, no ERTS) boots as `bin/hello start` does; interactive mode |
| `wasm_host` | a static NIF: `recv/0` runs on a dirty I/O scheduler and suspends its green thread until the host has an event (the normal scheduler runs meanwhile); `send/1`. Events are a JSON header, a newline and the body |
| `wasm/phoenix/wasm_host/` | a Phoenix endpoint adapter (in place of `Bandit.PhoenixAdapter`): a pump process, a `Plug.Conn.Adapter`, and a loop for `WebSock` handlers (the LiveView socket) |
| `wasm/erts/host/server.mjs` | a Node.js host: `node:http` and WebSockets (`ws`) |
| `wasm/worker/worker.js` | a Durable Object: one VM for all requests and `WebSocketPair` sockets |
| `wasm_tcp` | TCP client sockets of the host (`node:net`, `connect()` of `cloudflare:sockets`) for `gen_tcp`; `ssl` runs over them |
| `wasm/worker/pack.erl` | packs a release into `release.bin` (in Erlang, so no toolchain); the Worker writes it into the file system of the VM before the boot |

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
`release.bin` of the app is 7.5 MB (6.9 MB with gzip; 1,367 files):
8.8 MB with gzip in all. The limit of a Worker is 10 MB with gzip (paid
plan). The modules that the boot and a render load are 2.9 MB (2.1 MB
with gzip) of the 7.5 MB, so there is room to leave out modules.

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
- **Dirty I/O schedulers:** `wasm_host:recv/0` holds one of them while it
  waits, and interactive mode reads the `.beam` files with dirty I/O
  NIFs: the release keeps the default number of dirty I/O schedulers (10
  green threads cost almost nothing).

## Erlang in a browser tab

`wasm/browser/index.html` loads the Worker variant of `wasm/erts` (kernel
and stdlib in the module) and runs `erl -eval` in the page. Chromium 141
has JSPI with no flag: "hello from wasm32-unknown-emscripten, OTP 29, 43
processes" in 436 ms.

## Use cases

- **Phoenix LiveView on Workers.** One Durable Object runs the app: pages,
  LiveView sockets, PubSub and timers in one VM, near the users, with no
  server to manage. An idle VM costs no CPU time. The data can be the
  SQL storage of the Durable Object (SQLite), or Postgres through
  `connect()`.
- **Erlang and Elixir code at the edge**, as a function per request: an
  API, a webhook, a small service. A stateless Worker boots a VM for each
  request (about 0.5 s for kernel and stdlib, more with an app), so a
  Durable Object that stays warm is better for most uses.
- **Stateful objects with the actor model:** a Durable Object for each
  room, game, document or user, with OTP processes inside it
  (`gen_server`, supervisors, ETS) and a WebSocket for each client.
- **Erlang in the browser:** a playground or a tutorial that runs real
  OTP; offline apps; the same Elixir code on the server and in the page
  (a LiveView that runs in the tab when there is no network is a
  question for later).
- **A sandbox:** a WebAssembly VM has no access to files, processes or the
  network, other than what the host gives it (as `wasm_tcp`). Untrusted
  Erlang code (a plugin, an exercise) can run in a Worker or a tab.
- **Deno and Node.js:** a VM inside a JavaScript program (a CLI, an
  Electron app) with no native binary for each platform.

## How this could fit `beam.com`

A proposal, not done:

- **`beam.com build --target worker APP`** (or `--target wasm32`): the
  native build of the release as now, then `pack.erl` (Erlang code that
  `beam.com` has) and the Worker files. The output is a directory for
  `wrangler deploy`: `worker.js`, `beam.mjs`, `beam.wasm`, `release.bin`
  and a `wrangler.toml` with the Durable Object. No Emscripten, no
  Node.js.
- **The runtime:** `beam.wasm` and `beam.mjs` (2 MB with gzip), built by
  the CI of BEAM.com with `wasm/erts/build.sh`, in the zip of `beam.com`
  or downloaded at the first `--target worker` build.
- **The host adapter as an application:** `wasm_host`, `wasm_tcp` and the
  Phoenix adapter would be one application (Erlang, with an Elixir part
  for Phoenix) that the build adds to the release, as `beam.com` adds its
  own applications now. The endpoint gets the adapter at run time (as
  `WASM_HOST=1` does in the demo), so the same release runs natively.
- **What must be decided:** whether BEAM.com carries the Emscripten
  toolchain in CI (the runtime changes only with OTP and ERTS), and
  whether the upstream points (`WebSockAdapter`, the changes of ERTS)
  go upstream first.

## Next

- **Leave out unused modules** in `release.bin` (a list of the modules
  that a boot and the tests load), for smaller Workers.
- **Data:** an Ecto adapter for the SQL storage of Durable Objects, or
  `exqlite` over it; Postgres through `wasm_tcp` (Postgrex over
  `gen_tcp` and `ssl`, which work now).
- **A deploy to Cloudflare** (this spike ran `workerd` locally): the CPU
  time and memory limits in production, and JSPI there.
- **More Durable Objects:** PubSub between objects (a
  `Phoenix.PubSub` adapter over Durable Object requests).
- **A snapshot of the booted VM** (the memory after the boot), to make
  the cold start shorter.
- **UDP and DNS** through the host; incoming TCP is not possible on
  Workers.

## Limits of the way

- Threads switch only when one waits: a long NIF or BIF stops all the
  others (Erlang processes are still preempted by reductions).
- The CPU time of a request in Workers applies to all the threads.
- A stateless Worker or Deno Deploy keeps no VM between requests; a
  Durable Object does, while it is in memory.
- No incoming TCP or UDP on Workers: the host gives HTTP and WebSockets.
- No ports (no `fork()` or `exec()`), and no NIFs that are not linked into
  the runtime.
