# NIF libraries in WebAssembly

`beam.com` is one static file, so it cannot load a native NIF library
(a `.so` or `.dll` file): ERTS has no `dlopen()` in it. It can load a
NIF library that is compiled to WebAssembly. One `.wasm` file then
works on all the systems and CPUs of `beam.com`.

When `erlang:load_nif(PATH, Info)` finds no static NIF for the module,
it looks for these files, in this order:

1. `PATH.x86_64.aot` or `PATH.aarch64.aot` (the CPU of the computer): an
   AOT file, compiled to machine code. It runs at almost the speed of a
   native NIF.
2. `PATH.wasm`: the WebAssembly module. The interpreter of WAMR runs it.

The C code of the NIF does not change: the same `ERL_NIF_INIT`, the
same `enif_*` functions. `beam.com INPUT -o OUTPUT` copies the files in
`priv/` into the zip of OUTPUT, as for any `priv` file, and `load_nif`
reads them from the zip: nothing goes onto the disk.

How you make the `.wasm` file is your choice: any C compiler for
`wasm32-wasip1` works. This page shows Zig and wasi-sdk. For the speed
of native code, a custom build of `beam.com` can link the NIF as a
static NIF (see "Custom builds" in [`BUILDING.md`](BUILDING.md)).

## Speed

The bcrypt NIF of `bcrypt_elixir`, one hash with cost 12, on x86_64:

| Mode | Time |
|---|---|
| Native NIF | 255 ms |
| AOT file (`--bounds-checks=1`, generic CPU) | 318 ms |
| Interpreter (`.wasm`) | 2,400 ms |
| The WebAssembly runtime of `--target wasm32` (the engine of Node.js 26) | 339 ms |

`exqlite` (SQLite), 10,000 inserts in one transaction into a database
file: 195 ms with the AOT file, 543 ms with the interpreter.

## Make the `.wasm` file

1. Get the headers. `beam.com --nif-include` writes `erl_nif.h` and the
   files that it includes (with the C types of wasm32) to the cache of
   `beam.com`, and prints their directory.
2. Compile the C files for `wasm32-wasip1`, as a reactor (a module with
   no `main`), with these headers.

With [Zig](https://ziglang.org/):

```sh
zig cc -target wasm32-wasi -O2 -s -mexec-model=reactor \
    -I"$(beam.com --nif-include)" -o priv/my_nif.wasm c_src/my_nif.c
```

With [wasi-sdk](https://github.com/WebAssembly/wasi-sdk) (or a clang
with a WASI sysroot):

```sh
$WASI_SDK/bin/clang --target=wasm32-wasip1 -O2 -s -mexec-model=reactor \
    -I"$(beam.com --nif-include)" -o priv/my_nif.wasm c_src/my_nif.c
```

The headers make the module a NIF library: `ERL_NIF_INIT` exports
`nif_init`, an allocator and `chdir`, and each `enif_*` function is an
import of the module `env`. So the link needs no other flag.

The file name is the name that the NIF gives to `load_nif/2`, with
`.wasm`: for `erlang:load_nif(filename:join(PrivDir, "my_nif"), 0)`,
the file is `priv/my_nif.wasm`.

A library that uses other C libraries must compile them for
`wasm32-wasip1` too. WASI preview 1 has no threads, no `dlopen()` and
no signals. For SQLite, for example, give `-DSQLITE_THREADSAFE=0
-DSQLITE_OMIT_LOAD_EXTENSION=1 -DSQLITE_OMIT_WAL=1`, and the emulated
parts of wasi-libc (`-D_WASI_EMULATED_MMAN -lwasi-emulated-mman`, and
the same for `SIGNAL` and `PROCESS_CLOCKS`).

## Make the AOT files

An AOT file holds machine code: compile it with `wamrc`, the AOT
compiler of [WAMR](https://github.com/bytecodealliance/wasm-micro-runtime),
of the WAMR version of `beam.com` (2.4.5; see `WAMR_VERSION` in
`scripts/steps.sh`). Give these options:

```sh
wamrc --target=x86_64 --cpu=x86-64 --bounds-checks=1 \
    -o priv/my_nif.x86_64.aot priv/my_nif.wasm
wamrc --target=aarch64 --cpu=generic --bounds-checks=1 \
    --cpu-features=+reserve-x18,+reserve-x28 \
    -o priv/my_nif.aarch64.aot priv/my_nif.wasm
```

> **Caution:** An AOT file is native code. It runs with all the rights
> of `beam.com`, as a native NIF does. Without `--bounds-checks=1`, an
> access outside the memory of the module can write the memory of
> `beam.com` (`beam.com` runs WebAssembly without guard pages). Without
> `--cpu`, `wamrc` uses the CPU of your computer, and the file can stop
> with an illegal instruction on another computer. On aarch64, without
> `+reserve-x28`, the code can change the register that holds the thread
> pointer of `beam.com`, and the VM crashes; macOS can change x18 at
> any time, so the code must not use it either.

The AOT files are optional: without them, the `.wasm` file runs in the
interpreter. When an AOT file does not load (another WAMR version, or a
system that refuses memory that is both writable and executable), the
`.wasm` file runs.

On macOS with Apple silicon, the AOT code runs from memory with
`MAP_JIT`, as the JIT of the VM does.

## C++ (lazy_html)

[lazy_html](https://hex.pm/packages/lazy_html) 0.1.13 (the HTML parser
of `Phoenix.LiveViewTest`, a C++ NIF with fine and lexbor) works as a
NIF library in WebAssembly: its 93 tests pass with the `.wasm` file and
with the AOT file, also `render_component/3` and `live_isolated/2` of
LiveViewTest.

wasm32-wasi links no C++ exceptions, so fine and lazy_html need a small
change, which a flag turns on:
[`patches/fine/0001-no-exceptions.patch`](../patches/fine/0001-no-exceptions.patch)
(in `deps/fine`) and
[`patches/lazy_html/0001-no-exceptions.patch`](../patches/lazy_html/0001-no-exceptions.patch)
(in the package). Then, with lexbor at the commit of the `Makefile` of
lazy_html:

```sh
# lexbor: each .c file of source/lexbor, but ports/windows_nt
zig cc -target wasm32-wasi -O2 -std=c99 -DLEXBOR_STATIC \
    -D_POSIX_C_SOURCE=199309L -I"$LEXBOR/source" -c FILE.c -o FILE.o
zig ar rcs liblexbor.a *.o
zig c++ -target wasm32-wasi -mexec-model=reactor -O3 -std=c++17 \
    -fno-exceptions -DFINE_NO_EXCEPTIONS -DLEXBOR_STATIC -fvisibility=hidden \
    -I"$(beam.com --nif-include)" -Ideps/fine/c_include -I"$LEXBOR/source" \
    c_src/lazy_html.cpp liblexbor.a -s -o priv/liblazy_html.wasm
```

A document of 553 KB, the median of 15 calls:

| Step | Native NIF | AOT file | Interpreter |
|---|---|---|---|
| `from_document` | 16.7 ms | 29.9 ms | 233 ms |
| `query` | 1.1 ms | 1.5 ms | 12.8 ms |
| `to_html` | 3.7 ms | 6.0 ms | 46.5 ms |
| `to_tree` | 11.9 ms | 40.3 ms | 122.6 ms |

16 processes that use the library at the same time (the concurrent test
of lazy_html, 21,000 calls): 0.5 s with the AOT file, 110 ms with the
native NIF. The calls into one library run one at a time.

## Rust (rustler)

rustler 0.38 finds the `enif_*` functions with `dlsym()` at run time,
so it does not compile for `wasm32-wasip1`. A small change to rustler
makes a rustler NIF work:
[`patches/rustler/0001-wasm32-imports.patch`](../patches/rustler/0001-wasm32-imports.patch)
declares the `enif_*` functions as imports of `env` on `target_family =
"wasm"`. A test NIF with integers, strings, lists, binaries, atoms and a
resource passed with it. That change is not in rustler yet. With it:

```sh
cargo build --release --target wasm32-wasip1
cp target/wasm32-wasip1/release/my_nif.wasm priv/
```

## What a NIF library in WebAssembly can do

`beam.com` gives the module 170 `enif_*` functions: the terms (numbers,
atoms, strings, binaries, tuples, lists, maps and their iterators),
`enif_inspect_binary` and `enif_make_new_binary`, resources with
destructors and down callbacks, the monitors, `enif_alloc_env` and
`enif_send`, the pids and ports, exceptions, `enif_schedule_nif`, the
dirty NIF flags, the time functions, `enif_term_to_binary` and
`enif_binary_to_term`, `enif_snprintf` (with `%T`), the I/O queues
(`enif_ioq_*`) and `enif_inspect_iovec`.

The limits:

- **One call at a time.** The calls into one library run one after the
  other: a WebAssembly module has one stack. Two libraries run at the
  same time. A long call (for example a dirty NIF) makes the other
  calls into the same library wait, also on a normal scheduler.
- **Memory.** The memory of a module grows with no copy on Linux,
  macOS, FreeBSD and NetBSD (it has its maximum size in virtual memory,
  4 GB). On Windows and OpenBSD, each growth copies the memory: a
  library that grows its memory in many small steps is slow there.
- **No threads.** `enif_thread_create` fails. The mutexes, the
  condition variables and the read-write locks do nothing, because the
  calls run one at a time.
- **Not supported:** `enif_select` (it fails: the module has no file
  descriptors of the host), `enif_dynamic_resource_call`, and the
  options of `enif_set_option` (it fails). The module can import an
  unsupported function; a call to one of them stops the call with an
  exception.
- **Output.** `enif_fprintf` writes to the standard error of the VM,
  whatever its `FILE`. `%Lf` (a `long double`, 128 bits in wasm32)
  gives `?`.
- **Copies in I/O queues.** `enif_ioq_enq_binary`, `enif_ioq_enqv` and
  `enif_inspect_iovec` copy the bytes into the memory of the module.
- **No upgrade.** `load_nif/2` of new code, while the old code of the
  module has the library, fails with `upgrade`.
- **Files.** The module can open files, as a native NIF can: WASI gets
  `/`, and the module starts in the work directory of the VM. The
  sandbox of `beam.com` ([`SANDBOX.md`](SANDBOX.md)) limits these files
  too. A later change of the work directory of the VM does not change
  the work directory of the module. When the system does not open `/`
  for WASI, the module runs with no files (`BEAM_COM_NIF_DEBUG` tells).
- **Copies.** `enif_inspect_binary` copies the binary into the memory of
  the module.
- **Errors.** A trap of the module (for example an access out of its
  memory) raises `error:{wasm_trap, Message}` in the calling process.
  The module stays loaded.
- **At the edge.** See the next section.

## At the edge (`--target wasm32`)

The WebAssembly runtime of `--target wasm32` (Cloudflare Workers, Deno,
Node.js, a web page) loads the same `.wasm` file. ERTS itself runs in
WebAssembly there, and the engine of the host (V8) compiles and runs the
module, at about the speed of an AOT file (see "Speed"). The AOT files
are not used, and `beam.com --target wasm32` leaves them out of
`release.bin`.

- **Workers.** A Worker cannot compile WebAssembly at run time. So
  `beam.com --target wasm32` writes each NIF library of the release
  into the runtime Worker (`nifs/`, and `nifs.js`), and Wrangler
  compiles them. For a Worker that runs an `app.com` (`serve(app)` of
  the npm package), `beam.com --nif-modules app.com .` writes the same
  files next to the entry, and the entry gives them to `serve`:

  ```js
  import app from './app.com' with { type: 'bytes' };
  import nifs from './nifs.js';
  import { serve } from 'beam.com';

  const beam = serve(app, { nifs });
  ```

  Deno, Node.js and a web page compile the files at run time, and need
  no `nifs.js`.
- **Calls.** A call into the library costs about 5 µs more than in the
  native `beam.com`. A trap stops only that call, with
  `error:{wasm_trap, Message}`.
- **No files.** WASI has no directories there: the standard output and
  error, the clocks and random bytes work. Other functions of WASI fail
  or stop the call with an exception.
- **Snapshots.** A snapshot of a VM (`docs/WORKERS.md`) also holds the
  memory of each NIF library in WebAssembly, and the table slots of its
  functions. The restore makes each library again from its file, with
  the same memory, before the threads of ERTS start.
- The loader adds about 95 KB to `beam.wasm` (26 KB with gzip).

`tests/wasm_diff_test.exs` runs `nif_check` in the runtime, also with
the compiled module of a Worker, and after a snapshot and its restore.

## Debug

- `BEAM_COM_NIF_DEBUG=1`: `beam.com` writes the file that it loads, the
  error of an AOT file that did not load, and the `enif_*` functions
  that the module imports but `beam.com` does not give.
- `BEAM_COM_NIF_AOT=0`: `beam.com` does not use the AOT files.

## The test

[`tests/programs/nif_check`](../tests/programs/nif_check) is an
application with a NIF in C (`c_src/nif_check.c`), its `.wasm` and AOT
files in `priv/`, and `build.sh`, which makes them. `tests/run.sh`
builds it with `-o` and runs its checks on each system, with the AOT
file and with the interpreter.

## How it works

- `patches/otp/0003-wasm-nif.patch`: `erts_load_nif` calls the hook
  `erts_wasm_nif_open` before it opens a dynamic library. The headers of
  `--nif-include` (`erl_nif.h` for `__wasm__`) are from the same patch.
- `c_src/wasm/nif_wasm.c`: the hook loads the module in WAMR, reads the
  `ErlNifEntry` of the module, and gives ERTS an entry with a native
  function for each NIF. Each `enif_*` import changes the 32-bit
  handles of the module into terms, and back. The comment at the start
  of the file gives the rules.
- The WebAssembly runtime: `wasm/erts/build.sh` applies the same patch,
  and links the same file with `c_src/wasm/nif_wasm_host.c` in place of
  WAMR (the step `nif_edge` of `scripts/steps.sh`). That file gives the
  functions of WAMR on the engine of the host
  (`c_src/wasm/nif_wasm_host.js`): the module imports each `enif_*`
  function as an export of ERTS, the bridge reads and writes the memory
  of the module through copies, and each call into the module runs on
  its own JSPI stack. The comment at the start of
  `nif_wasm_host.c` gives the rules.
