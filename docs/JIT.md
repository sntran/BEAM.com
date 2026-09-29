# JIT (BeamAsm) in BEAM.com

## Status: the default `beam.com`

Since all platforms were green with the fat JIT, and the benchmarks
(`docs/BENCHMARKS.md`) show that it is worth its cost, `beam.com` has
the JIT, and `beam-emu.com` has the interpreter (`JIT=0 ./build.sh`).

## One fat file with both backends (steps c and d)

`JIT=1 ./build.sh` (the default, with the normal, fat `cosmocc`) builds a
`beam.com` with both backends of BeamAsm: the x86 backend in the
x86_64 half and the arm backend in the aarch64 half. CI builds it and
tests it on every platform (see `tests/run.sh`).

What was needed, in addition to the x86_64 probe below:

- **`JIT_ARCH=fat`** (`patches/otp/0002-jit.patch`, when
  `BEAM_COM_FAT_JIT=yes`, which `build.sh` sets for `cosmocc`). The
  Makefile generates the opcode tables and `beam_asm_global.hpp` once for
  each backend, into `$(TTF_DIR)/jit-x86` and `jit-arm`. Small wrapper
  files select the backend of the compiler pass with
  `#if defined(__x86_64__)` / `#elif defined(__aarch64__)`:
  `beam/jit/fat/*.cpp` and `beam_asm.hpp` for the backend sources, and
  `beam/jit/fat/ttf/*` for the generated files. asmjit is compiled with
  both backends (`ASMJIT_NO_FOREIGN` empties the files of the other CPU).
- **Step c was done inside step d.** An aarch64-only build would need a
  real cross-compile of OTP: configure takes the backend from the host
  CPU, and the OTP build runs the tools that it builds. The fat build
  needs neither.
- **x28** (`docs/UPSTREAM.md` C22): Cosmopolitan keeps its thread
  pointer in x28 on aarch64. The arm backend keeps X3 in x28, so it uses
  its DEBUG register layout under Cosmopolitan (X3-X5 in x15-x17).
- **The ARM cache instructions** (O14): the configure checks for
  `isb sy`, `dc cvau` and `ic ivau` run only on an ARM host. With
  `BEAM_COM_FAT_JIT=yes` they are set to 1 (used only in ARM code).
- **macOS on Apple Silicon** (O13): cosmocc does not define `__APPLE__`,
  so the macOS code of asmjit and ERTS is replaced by run-time checks
  (`IsXnuSilicon()`): single-mapped memory with `MAP_JIT`, the
  per-thread write permission with Cosmopolitan's `__jit_begin()` and
  `__jit_end()`, and `__clear_cache()` (it calls
  `sys_icache_invalidate()` on macOS).
- **The dependency pass** (C23): cosmocc defines no CPU for `-MM`, so
  the wrapper files take the x86 files there.

Sizes (CI): the fat JIT is 40.0 MB, the fat interpreter 37.2 MB.

Tested locally: all behavior tests with the fat JIT on Linux x86_64,
and on the aarch64 half with qemu.

### W^X: no page is writable and executable

asmjit maps the JIT code two times (dual mapping): one executable view
and one writable view of the same shared memory object
(`shm_open()`; on Linux a deleted file in `/dev/shm`). No change was
needed. `tests/programs/jit_maps.erl` reads the memory map of the
program (`/proc/self/maps`, `procstat -v`, `vmmap`), and CI checks it:

| Platform | Pages that are writable and executable | Dual mapped |
|---|---|---|
| Linux x86_64 and aarch64 | 0 | yes |
| FreeBSD, NetBSD | 0 | yes |
| macOS x86_64 | 0 | (the probe cannot see it in `vmmap`) |
| macOS arm64 | 1 (`MAP_JIT`) | no: one mapping, with a write permission for each thread (`__jit_begin()`/`__jit_end()`), which the hardware enforces |
| OpenBSD | (no memory map for the program) | the kernel does not allow RWX pages at all, and the JIT runs |
| Windows | not measured | |

On Linux, `+JMsingle true` gives one RWX mapping, which the check sees
(so the check works).

## The x86_64 probe (steps a and b)

BeamAsm first worked in an x86_64-only `beam-jit.com`
(`JIT=1 CC=x86_64-unknown-cosmo-cc ./build.sh`), on Linux, macOS x86_64,
Windows, FreeBSD, NetBSD and OpenBSD 7.3.

What was needed:

- `--enable-jit` with `CXX` (the C++ compiler of `CC`).
- The native stack for Erlang code is off (`enable_native_stack=no`,
  patches/otp/0002-jit.patch): it needs all signal handlers on an
  alternate stack, and OpenBSD does not allow it. This is the upstream
  configuration for arm64 and for OpenBSD.
- asmjit is compiled without its precompiled header: `cosmocc` cannot make
  or use one `.gch` file for two CPUs (the same patch).
- `cosmo/erts_cosmo.h` has C linkage for C++ files.
- The compiler of one CPU writes an ELF file. `build.sh` makes the APE
  file with `apelink` (`objcopy -O binary` drops the zip of the ELF).

Sizes: the x86_64-only `beam-jit.com` was 28.7 MB, and the programs that
it makes about 20 MB. The x86_64 JIT emulator alone is 11.3 MB.

## The design

The design report that was written before the work started is in
[`history/JIT-DESIGN.md`](history/JIT-DESIGN.md). Some of its plans
changed during the work: this file gives the result.
