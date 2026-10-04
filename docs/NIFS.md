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
    -o priv/my_nif.aarch64.aot priv/my_nif.wasm
```

> **Caution:** An AOT file is native code. It runs with all the rights
> of `beam.com`, as a native NIF does. Without `--bounds-checks=1`, an
> access outside the memory of the module can write the memory of
> `beam.com` (`beam.com` runs WebAssembly without guard pages). Without
> `--cpu`, `wamrc` uses the CPU of your computer, and the file can stop
> with an illegal instruction on another computer.

The AOT files are optional: without them, the `.wasm` file runs in the
interpreter. When an AOT file does not load (another WAMR version, or a
system that refuses memory that is both writable and executable), the
`.wasm` file runs.

On macOS with Apple silicon, `beam.com` uses the `.wasm` file: this
system runs new machine code only from memory with `MAP_JIT`, and the
AOT loader does not use it yet.

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

`beam.com` gives the module 151 `enif_*` functions: the terms (numbers,
atoms, strings, binaries, tuples, lists, maps and their iterators),
`enif_inspect_binary` and `enif_make_new_binary`, resources with
destructors, `enif_alloc_env` and `enif_send`, the pids and ports,
exceptions, `enif_schedule_nif`, the dirty NIF flags, the time
functions, `enif_term_to_binary` and `enif_binary_to_term`.

The limits:

- **One call at a time.** The calls into one library run one after the
  other: a WebAssembly module has one stack. Two libraries run at the
  same time. A long call (for example a dirty NIF) makes the other
  calls into the same library wait, also on a normal scheduler.
- **No threads.** `enif_thread_create` fails. The mutexes, the
  condition variables and the read-write locks do nothing, because the
  calls run one at a time.
- **Not supported:** monitors (`enif_monitor_process`), `enif_select`
  (it fails), `enif_snprintf`, `enif_fprintf`, the I/O queues
  (`enif_ioq_*`) and `enif_dynamic_resource_call`. The module can
  import them; a call to one of them stops the call with an exception.
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
- **Not at the edge yet.** The WebAssembly runtime of `--target wasm32`
  (Workers, Deno, a web page) does not load these files yet.

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
