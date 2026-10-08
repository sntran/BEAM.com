# The patches of BEAM.com

BEAM.com builds other projects with these changes. Each change has an
item in [`docs/UPSTREAM.md`](../docs/UPSTREAM.md): the problem, a
reproducer when there is one, the workaround, and a possible fix
upstream. No patch has been sent upstream yet.

When you add or change a patch:

1. Add or change its item in `docs/UPSTREAM.md`.
2. Add or change its row here, with the ids of its items.
3. Keep one purpose in each patch file, and start the file with a short
   text that tells what it does (`git apply` skips that text).

## Erlang/OTP (`patches/otp/`)

`step_otp` of `scripts/steps.sh` applies them to the clone of OTP, in
order, with `git apply`.

| Patch | File | What it does | Items |
|---|---|---|---|
| `0001-cosmopolitan.patch` | `erts/emulator/Makefile.in` | One run of the recipe makes all the static NIF libraries (`make -j`). | O11 |
| | `erts/emulator/beam/erl_bits.c` | `FP16_FROM_FP64` with no compiler helper. | O1, C9 |
| | `erts/emulator/beam/erl_init.c` | On Windows, the exit status itself, not a wait status. | C21 |
| | `erts/emulator/beam/sys.h` | No `ERTS_LOW_WRITE` section with Cosmopolitan. | C1, O3 |
| | `erts/emulator/sys/common/erl_mmap.h` | No `MAP_FIXED` over a reservation (Windows). | C12 |
| | `erts/emulator/sys/common/erl_poll.c` | `FD_SETSIZE` when `sysconf(_SC_OPEN_MAX)` fails. | C15 |
| | `erts/emulator/sys/unix/erl_main.c`, `erl_child_setup.c` | The helper programs are linked into the file, and an APE file starts with the APE loader. `erl_child_setup`: the `fork()` of libSystem on macOS arm64, and the loop over `/dev/fd` when `closefrom()` fails. | O9, C11, C31, C36, C37 |
| | `erts/emulator/sys/unix/sys.c` | Stop when `/dev/null` does not open. | O15 |
| | `erts/emulator/sys/unix/sys_drivers.c` | The linked helper programs; no `erl_child_setup` on Windows or when `fork()` fails; the child closes the end of the emulator; `posix_spawn()` of libSystem for `erl_child_setup` on macOS arm64. | O9, O12, O16, C16, C32 |
| | `erts/emulator/sys/unix/sys_uds.c` | The `struct cmsghdr` of BSD and XNU. | C17 |
| | `erts/emulator/zstd/zstd.mk` | No x86_64 assembly file in the aarch64 half. | O2 |
| | `lib/erl_interface/src/connect/ei_resolve.c` | The `gethostbyname_r` of Cosmopolitan. | O7 |
| `0002-jit.patch` | `erts/configure*`, `make/autoconf/otp.m4`, `erts/emulator/Makefile.in`, `asmjit`, `beam/jit/` | A fat JIT: both backends, selected at compile time for each CPU half and at run time for macOS. | O13, O14, C22 |
| `0003-wasm-nif.patch` | `erts/emulator/beam/erl_nif.c`, `erl_nif.h` | The hook for NIF libraries in WebAssembly, and `erl_nif.h` for `__wasm__` (not Emscripten). `wasm/erts/build.sh` applies it too. | O24 |

## Elixir (`patches/elixir/`)

The step `elixir` of the build applies them.

| Patch | File | What it does | Items |
|---|---|---|---|
| `0001-mix-lock-port-file.patch` | `lib/mix/lib/mix/sync/lock.ex` | The build lock of Mix does not wait for its own process. | EX1 |
| `0002-mix-consolidate-elixir-protocols-in-otp-lib.patch` | `lib/mix/lib/mix/compilers/protocol.ex` | Mix consolidates the protocols of Elixir when Elixir is in the lib directory of OTP. | EX2 |

## rustler (`patches/rustler/`)

The build of BEAM.com does not use it. It is for users who build a
rustler NIF for WebAssembly ([`docs/NIFS.md`](../docs/NIFS.md)), and for
a report to rustler.

| Patch | File | What it does | Items |
|---|---|---|---|
| `0001-wasm32-imports.patch` | `rustler/Cargo.toml`, `rustler/build.rs`, `rustler/src/sys/` | The `enif_*` functions as imports of `env` on `target_family = "wasm"`. | R1 |

## fine and lazy_html (`patches/fine/`, `patches/lazy_html/`)

The build of BEAM.com does not use them. They are for users who build
lazy_html as a NIF library in WebAssembly ([`docs/NIFS.md`](../docs/NIFS.md),
"C++"), and for a report to fine.

| Patch | File | What it does | Items |
|---|---|---|---|
| `fine/0001-no-exceptions.patch` | `c_include/fine.hpp` | With `FINE_NO_EXCEPTIONS`, fine raises a pending error when the NIF function returns, with no C++ exception. | F1 |
| `fine/0002-quiet-variant.patch` | `c_include/fine.hpp` | A variant does not format the term for the error of a type that it tries before the last one. | F2 |
| `lazy_html/0001-no-exceptions.patch` | `c_src/lazy_html.cpp` | Each `throw` returns the pending error of fine. | F1 |

## WAMR (`patches/wamr/`)

`step_wasm` of `scripts/steps.sh` applies them to the clone of WAMR, in
order, with `git apply`.

| Patch | File | What it does | Items |
|---|---|---|---|
| `0001-cosmopolitan-aarch64-jit.patch` | `core/shared/platform/common/posix/posix_memmap.c`, `posix_thread.c` | `MAP_JIT` and the write protection of macOS on Apple silicon at run time, and the cache flush on aarch64. | W5, W6 |
| `0002-reserve-linear-memory.patch` | `core/iwasm/common/wasm_memory.c` | A linear memory of wasm32 has its maximum size in virtual memory from the start, so a growth copies nothing. On Windows and OpenBSD, its mapping has room for twice its pages, so the copies take linear time. | W10 |

## Changes that are not patch files

Some changes are compiler flags or small edits in `scripts/steps.sh`.
Their items are in `docs/UPSTREAM.md` too:

- WAMR: the flags of `step_wasm`, and `c_src/wasm/wamr_target.h` and
  `c_src/wasm/aot_reloc.c` (W1 to W4, W7, W8), and the options of
  `wamrc` in `docs/NIFS.md` (W7, W9).
- exqlite and elixir_make: the flags and the `sed` edit of
  `build_hex_nif` (E1 to E4).
- The builder and the tools of beam.com (`src/beam_com/`): O17 to O19.
- Emscripten and the WebAssembly runtime of `--target wasm32`:
  `wasm/erts/build.sh` (the EM items).
