# JIT (BeamAsm): the design report

This is the design report of 2026-09-26, written before the work on the
JIT started. It is a record: some plans in it changed during the work.
For the result, see [`../JIT.md`](../JIT.md).

Design report, 2026-09-26, before step (a). Paths are relative to the built OTP 29.1.1 tree
(`build/otp`, "OTP") or the Cosmopolitan source
(the Cosmopolitan source at commit 3293fad0, "COSMO") unless absolute.

### Summary

- asmjit and the BeamAsm C++ sources compile with cosmoc++ today, for both
  CPUs, with no source change. Tested: all 46 asmjit files
  (core, support, x86 or arm) plus 8 to 11 `beam/jit` files per CPU
  (a compile test with `cosmoc++` and the per-CPU compilers).
- Two things needed fixing for the test: `c_src/cosmo/erts_cosmo.h` is not valid
  C++ (see 2.1), and the aarch64 half needs the ARM cache-instruction
  macros in `config.h` set to 1 (see 2.2).
- The build system is the main work: OTP picks one `JIT_ARCH` at configure
  time, and five generated files differ between x86 and arm. A fat build
  needs per-CPU wrapper files selected with `#if defined(__x86_64__)`.
- Executable memory: asmjit's POSIX path works under Cosmopolitan on every
  OS. (This research expected a small patch for dual mapping, because
  `SHM_ANON` is a macro but NULL at run time on non-FreeBSD; the
  measurement later showed that dual mapping works without it: see
  "W^X" above. macOS arm64 uses `MAP_JIT`.)
- Calling convention: Cosmopolitan never defines `WIN32`/`_WIN32`, so the
  System V code paths are used everywhere, including Windows. Correct.
- Recommendation: build with `--disable-native-stack`-equivalent
  (`NATIVE_ERLANG_STACK` off). It removes the sigaltstack dependency, the
  OpenBSD `MAP_STACK` problem and the Windows signal-emulation risk in one go.
  ARM already runs this way upstream.
- Size: about +1.0 MB text per CPU (asmjit + BeamAsm objects total 508 KB
  x86, 414 KB arm text in the sample, plus the parts not compiled in the
  sample), minus `beam_emu.o` (~0.3 MB). Expect `beam.com` to grow from
  36.7 MB to roughly 39-41 MB (JIT code is also generated at run time, so
  RSS grows more than the file).

### 1. How OTP selects the JIT backend

### configure

- `erts/configure.ac:3046-3108`: `JIT_ARCH=x86` for `ARCH=amd64`,
  `JIT_ARCH=arm` for `arm64`. `ARCH` comes from the host triple, so a
  cosmocc configure on x86_64 gives `amd64` (`erts/config.log:19984`).
- `erts/configure.ac:3195-3232`: `NATIVE_ERLANG_STACK` is `AC_DEFINE`d for
  x86 unless `host_os` is `openbsd*`; for arm it is always off. This is a
  `config.h` macro, so it is one value for both CPU halves of a fat build.
- `erts/configure.ac:3236-3247`: on `linux*`, `ERLANG_FRAME_POINTERS`
  (only if native stack) and `HAVE_LINUX_PERF_SUPPORT` are defined.
- `erts/configure.ac:3344-3356`: `JIT_ENABLED`, `JIT_ARCH`,
  `PRIMARY_FLAVOR` (jit or emu) are substituted into the Makefile.
- `erts/configure.ac:3112-3190`: JIT requires a C++17 `CXX`. Note: the
  current BEAM.com configure got `CXX='g++'` (host compiler,
  `erts/config.log:19999`). `build.sh` must pass `CXX=cosmoc++`.
- The ARM cache checks (`ethr_cv_arm_isb_sy_instr`,
  `..._dc_cvau_instr`, `..._ic_ivau_instr`, `erts/configure:14907-15053`)
  are compile tests run with the x86 compiler, so they are 0 in
  `erts/x86_64-pc-linux-gnu/config.h:173-198` and
  `erts/include/internal/x86_64-pc-linux-gnu/ethread_header_config.h:100-115`.
  `configure.ac:3086-3096` disables the ARM JIT when they are 0.

### Makefile (`erts/emulator/Makefile.in`)

- Lines 71-76: `OPCODE_TABLES += beam/jit/$(JIT_ARCH)/{ops,predicates,generators}.tab`.
- Lines 294-296: `-DBEAMASM=1` and alloc type var `beamasm`.
- Lines 650-663: `beam_makeops -jit yes` generates into `$(TTF_DIR)`:
  `beam_opcodes.c`, `beam_opcodes.h`, `beamasm_emit.h`, `beamasm_protos.h`
  (`utils/beam_makeops:811,816,855,1015`; `beam_hot/warm/cold.h` are only
  for the emulator flavor).
- Lines 666-669: `beam_asm_global.hpp` from `beam/jit/$(JIT_ARCH)/beam_asm_global.hpp.pl`.
- Lines 685-689: `make_tables -jit yes` (bif tables; same for both CPUs).
- Lines 783-796: asmjit sources: `core/*.cpp support/*.cpp $(JIT_ARCH)/*.cpp`.
- Line 885: `-Ibeam/jit -Ibeam/jit/$(JIT_ARCH)` (selects `beam_asm.hpp`).
- Lines 1015-1050: `ASMJIT_FLAGS`, and a precompiled header
  `$(TTF_DIR)/asmjit/core.h.gch` used through `-x c++-header -include`.
- Lines 1116-1158: `JIT_OBJS` (the same file names for both CPUs, from
  `beam/jit/$(JIT_ARCH)/`), lines 1098-1100: `beam_emu.o` is dropped.
- Lines 1361-1363: the JIT flavor links with `$(CXX)`.

### What differs between the x86 and arm backends

Source files with the same name in `beam/jit/x86/` and `beam/jit/arm/`:
`beam_asm.hpp`, `beam_asm_global.cpp`, `beam_asm_module.cpp`,
`process_main.cpp`, `instr_*.cpp` (13 files), `ops.tab`, `predicates.tab`,
`generators.tab`, `beam_asm_global.hpp.pl`. Shared: `beam/jit/*.cpp|.c|.h|.hpp`.

Generated outputs (both sets were generated for the comparison):

| file | x86 vs arm diff lines / total | included by |
|---|---|---|
| `beam_opcodes.h` | 1974 / 1660 | many C files (`beam_load.c`, ...) |
| `beam_opcodes.c` | 7984 / 13251 | compiled as C (loader transforms) |
| `beamasm_emit.h` | 245 / 1230 | `beam_jit_main.cpp` |
| `beamasm_protos.h` | 102 / 239 | `beam_asm.hpp` |
| `beam_asm_global.hpp` | 429 / 545 | `beam_asm.hpp` |

`erl_alloc_types.h`, `erl_bif_table.*` and friends depend only on the JIT
flavor, not on the CPU.

### Proposal: one source tree, two backends

cosmocc compiles every file twice, so every difference must be a
preprocessor decision:

1. Generate both sets: `$(TTF_DIR)/jit-x86/` and `$(TTF_DIR)/jit-arm/`
   (run `beam_makeops` and `beam_asm_global.hpp.pl` twice). Put wrapper
   files in `$(TTF_DIR)`, each of the form
   `#if defined(__x86_64__) #include "jit-x86/X" #elif defined(__aarch64__) #include "jit-arm/X" #endif`,
   for `beam_opcodes.h`, `beam_opcodes.c`, `beamasm_emit.h`,
   `beamasm_protos.h`, `beam_asm_global.hpp`.
2. Wrapper `.cpp` files in a new `beam/jit/fat/` (or generated into
   `$(TTF_DIR)`): `beam_asm_global.cpp`, `beam_asm_module.cpp`,
   `process_main.cpp`, `instr_*.cpp`, each `#include`ing the x86 or arm
   file under `#if`. Same for `beam_asm.hpp` (replace
   `-Ibeam/jit/$(JIT_ARCH)` with `-Ibeam/jit/fat`).
3. asmjit: compile `core/*.cpp support/*.cpp x86/*.cpp arm/*.cpp`. asmjit
   already guards its backends with `ASMJIT_ARCH_X86`/`ASMJIT_ARCH_ARM`
   (derived from the compiler), and `ASMJIT_NO_FOREIGN=1` (Makefile.in:1021)
   makes the foreign-arch files compile to nothing. No wrappers needed.
4. Replace the `.gch` precompiled header with `-include asmjit/core.h`
   (Makefile.in:1023-1050). Tested: cosmoc++ rejects `-x c++-header`, and
   the per-CPU compilers try to link a `.gch` output. The plain `-include`
   works and is what the test script used.
5. `config.h` / `ethread_header_config.h`: force the six
   `ETHR_HAVE_GCC_ASM_ARM_*_INSTRUCTION` values to 1 for the aarch64 half.
   They only appear under `!x86` guards (`erts/include/internal/gcc/ethr_membar.h:127-146`,
   `beam/jit/beam_jit_main.cpp:83-88`), so the simplest way is to pass the
   configure cache variables `ethr_cv_arm_{isb_sy,dc_cvau,ic_ivau}_instr=yes`
   in `build.sh` (like the other `ac_cv_*` overrides) after checking that
   the x86 half ignores them. Verified: `beam_jit_main.cpp` compiles for
   aarch64 with those set to 1 and fails with them at 0 (`#error` at
   `beam_jit_main.cpp:503`).
6. `NATIVE_ERLANG_STACK`: leave it undefined (see section 4).
7. `JIT_ARCH` itself: set it to `fat` (or keep `x86` and ignore it) in
   configure when `CC` is cosmocc; use it only to pick the wrapper dir.

### 2. Does asmjit / BeamAsm compile with cosmoc++?

Yes. A compile test compiled them with
`-std=c++17 -O2 -g`, OTP's `ASMJIT_FLAGS`, `-DBEAMASM=1`, the JIT-flavor
generated headers, and `-include asmjit/core.h`. Results:

- x86_64 (`x86_64-unknown-cosmo-c++`): 53/53 objects OK (all asmjit
  core/support/x86 files; `beam_jit_main.cpp`, `beam_jit_common.cpp`,
  `beam_jit_metadata.cpp`, `beam_jit_bs.cpp`; x86 `beam_asm_global.cpp`,
  `beam_asm_module.cpp`, `process_main.cpp`, `instr_arith/bs/common/call.cpp`).
  Total text 508 KB.
- aarch64 (`aarch64-unknown-cosmo-c++`): 56/56 OK (all asmjit
  core/support/arm files; `beam_jit_common.cpp`, `beam_jit_bs.cpp`; arm
  `beam_asm_global/module.cpp`, `process_main.cpp`,
  `instr_arith/bs/common/call.cpp`; `beam_jit_main.cpp` with the fix in 2.2).
  Total text 414 KB.
- Fat `cosmoc++ -c` of `asmjit/core/jitallocator.cpp` produced the x86
  object and the `.aarch64/` twin as expected.

OTP builds asmjit and BeamAsm with exceptions and RTTI at the compiler
default (no `-fno-exceptions`; `CXXFLAGS` is `CFLAGS` minus C-only warnings,
Makefile.in:298). cosmoc++ ships libstdc++ (GCC 12.3, `__cplusplus 201703L`).
No warnings were seen from `virtmem.cpp`.

### 2.1 `erts_cosmo.h` is not C++-safe (required patch)

Every C++ file failed with
`erts_cosmo.h:46: conflicting declaration of 'long int beam_com_gethostid()' with 'C' linkage`.
The forced-include header defines `static inline` functions and declares
`beam_com_main`, `beam_com_exec_helper` without `extern "C"`. Fix: wrap
the declarations in `#ifdef __cplusplus extern "C" { #endif` (the test used
such a copy, `jit-design/erts_cosmo_cxx.h`). Trivial, no risk.

### 2.2 ARM cache-instruction macros (required for aarch64)

See item 5 in section 1. Without it, `beam_jit_main.cpp:503` hits
`#error "Platform lacks implementation for clearing instruction cache"`
on aarch64, because `BEAMASM_MANUAL_ICACHE_FLUSHING` needs
`ETHR_HAVE_GCC_ASM_ARM_{IC_IVAU,DC_CVAU}_INSTRUCTION` and
`ERTS_THR_INSTRUCTION_BARRIER` (`beam_jit_main.cpp:83-88`,
`erl_threads.h:276`, `ethr_membar.h:146`). The `dc cvau / ic ivau / isb sy`
instructions are valid user-space instructions on every aarch64 OS we
target. Cosmopolitan's own `__clear_cache` does the same
(`COSMO/third_party/compiler_rt/clear_cache.c:20-42`).

### 3. Executable memory

### How ERTS allocates JIT memory

ERTS does not use `erl_mmap.c` for code. It uses asmjit's `JitAllocator`
(`beam/jit/beam_jit_main.cpp:155-235`): try dual mapping
(`kUseDualMapping`, block size 32 MB), fall back to single mapping (RWX),
and fail if `+JMsingle`/`+JPperf` demanded single mapping but got dual.
Per-OS selection happens inside asmjit `core/virtmem.cpp`:

- `virtmem.cpp:14-110`: `_WIN32` -> VirtualAlloc/CreateFileMapping
  (lines 158-350); `__APPLE__` -> `mach_vm_remap` on x86, `MAP_JIT` +
  `pthread_jit_write_protect_np` on arm64 (`ASMJIT_NO_DUAL_MAPPING`);
  `__NetBSD__` -> `MAP_REMAPDUP`; otherwise `ASMJIT_ANONYMOUS_MEMORY_USE_FD`:
  an fd from `memfd_create` (`__linux__ && __NR_memfd_create`, line 587),
  else `shm_open(SHM_ANON)` (line 616, `#if defined(SHM_ANON)`), else a
  random-named file in `/dev/shm` or `$TMPDIR` (lines 628-660) with a
  run-time noexec check (lines 700-745). Both views are `mmap(MAP_SHARED, fd)`.
- `has_hardened_runtime()` (lines 753-780) tests one RWX `mmap`; if it
  fails, `jitallocator.cpp:538-546` forces dual mapping.
- Icache: `virtmem.cpp:1150-1170` and `beam_jit_main.cpp:450-505`.
- `beam/jit/beam_jit_metadata.cpp:346` mmaps the perf jitdump file
  `PROT_READ|PROT_EXEC` only when `+JPperf` is on.

### What cosmocc/Cosmopolitan gives

cosmocc predefines `__linux__`, `__COSMOPOLITAN__`, `__COSMOCC__` and never
`_WIN32`/`__APPLE__`/`__OpenBSD__` (checked with `-dM -E`). So asmjit takes
the `__linux__` + `USE_FD` path on every OS, and OS differences are decided
at run time inside libc:

- `__NR_memfd_create` is `extern const int` (`COSMO/libc/sysv/consts/nr.h:315`),
  not a macro, so asmjit's memfd branch is compiled out. `SHM_ANON` *is* a
  macro (`libc/sysv/consts/shm.h:4`) but its value is NULL except on FreeBSD
  (`consts.sh:1025`). Result today: `shm_open(NULL)` fails on Linux, macOS,
  NetBSD, OpenBSD, Windows, and asmjit returns an error instead of trying
  the tmp-file path. Dual mapping then fails and ERTS silently falls back
  to RWX. Patch (asmjit, ~20 lines under `__COSMOPOLITAN__`):
  `if (IsLinux()) fd = syscall(__NR_memfd_create, "vmem", MFD_CLOEXEC);`
  (`libc/stdio/syscall.c:32` exists), `else if (IsFreebsd()) shm_open(SHM_ANON)`,
  else fall through to the tmp-file loop.
- `mmap`: `libc/intrin/mmap.c:1121-1128` documents `PROT_EXEC`, OpenBSD W^X
  and `MAP_JIT`. Windows path `sys_mmap_nt` (lines 416-510): anonymous
  private -> `VirtualAlloc` with the requested protection (RWX allowed);
  file-backed shared -> `CreateFileMapping` with execute page flags, then
  `VirtualProtect` to the requested protection. Two views of one fd work.
  Caveat (lines 447-450, 485-505, and `libc/calls/open-nt.c:126-137`): a
  file created with `O_CREAT` gets execute access only if it already existed,
  so a fresh tmp file cannot be mapped `PROT_EXEC`; the dual-mapping attempt
  fails and asmjit falls back to single RWX `VirtualAlloc`. That is fine
  for a first version (upstream OTP on Windows also tolerates RWX).
- `mprotect` (`libc/intrin/mprotect.c:43-47`) maps to `VirtualProtect` on
  Windows. `MAP_JIT` is `0x800` on XNU, 0 elsewhere (`consts.sh:47`).
- macOS arm64: `mmap` goes through Apple's libSystem (`mmap.c:518-521`);
  cosmo has `__jit_begin()/__jit_end()` calling
  `pthread_jit_write_protect_np` (`libc/runtime/jit.c`,
  `libc/runtime/runtime.h:113-114`). asmjit's `MAP_JIT` code is under
  `__APPLE__`, so it is compiled out.
- sigaltstack: implemented for all OSes including the Windows signal
  emulation (`libc/calls/sigaltstack.c`, `libc/intrin/sig.c:301-309,590,814`
  honor `SA_ONSTACK` and the per-thread alt stack).
- OpenBSD: kernel refuses `PROT_WRITE|PROT_EXEC`; dual mapping through a
  file works if the tmp filesystem is not `noexec`. There is no
  `wxallowed` handling in cosmo (grep of `ape`, `libc`: none), so RWX
  single mapping is never available there.

### Proposed run-time selection (patch in asmjit `virtmem.cpp`, guarded by `__COSMOPOLITAN__`)

| OS (predicate) | strategy |
|---|---|
| Linux (`IsLinux()`) | memfd via `syscall(__NR_memfd_create)`, dual RX/RW; fallback RWX |
| FreeBSD | `shm_open(SHM_ANON)`, dual; fallback RWX |
| NetBSD, OpenBSD | tmp file in `$TMPDIR`, dual (asmjit's noexec probe already exists); OpenBSD has no RWX fallback, so a failure is fatal with a clear message |
| macOS x86_64 (`IsXnu() && !IsXnuSilicon()`) | tmp file dual; fallback RWX. Upstream disabled the JIT by default here because of Sonoma popups with `mach_vm_remap`; we do not use that API, so this must be tested on a real Mac |
| macOS arm64 (`IsXnuSilicon()`) | first try tmp-file dual mapping; if the RX view is refused, single mapping with `MAP_JIT` and `__jit_begin/__jit_end` around writes (`protect_jit_memory` hook, `virtmem.cpp:1218-1224`) |
| Windows (`IsWindows()`) | single RWX (`VirtualAlloc`); later: request exec access for the tmp file to get dual mapping |

ERTS side: leave `pick_allocator()` as is; it already tries dual then
single. Only `erts_jit_single_map` forcing for `__APPLE__ && __aarch64__`
(`beam_jit_main.cpp:188-195`) should become `if (IsXnuSilicon())`.

### 4. Calling convention, stack, signals

- `beam/jit/x86/beam_asm.hpp:64-69`: `ERTS_JIT_ABI_WIN32` only when
  `WIN32` is defined; otherwise `ERTS_JIT_ABI_SYSV`. cosmocc defines neither
  `WIN32` nor `_WIN32`, and Cosmopolitan runs System V ABI on Windows, so the
  SysV registers (`ARG1=rdi` ...) are right on every OS. The other `WIN32`
  uses (`x86/beam_asm_global.cpp:65,138`, `x86/instr_bs.cpp:1624,2102`,
  `x86/process_main.cpp:172`, `x86/instr_common.cpp:3273,3289`,
  `arm/instr_common.cpp:3132`, `beam_jit_common.cpp:371`) select the Unix
  ethread atomic layout (`state.counter`) and `perf_counter`; both are the
  Unix ones under cosmo. The x86 files compiled cleanly, which confirms the
  struct members exist.
- Native stack: with `NATIVE_ERLANG_STACK` the x86 JIT runs Erlang code on
  the process stack area and requires every signal handler to run on an
  alternate stack (`sys/unix/sys.c:444-452`,
  `sys/unix/sys_signal_stack.c:85-140`). Under Cosmopolitan this would rely
  on the Windows signal emulation honoring `SA_ONSTACK` (it does, see
  above) and would be forbidden on OpenBSD (`configure.ac:3200-3208`,
  `MAP_STACK` check), which is one of our target OSes at run time.
  Recommendation: do not define `NATIVE_ERLANG_STACK` (nor
  `ERLANG_FRAME_POINTERS`) for the cosmo build. This is exactly the arm
  configuration and the OpenBSD x86 configuration upstream, so it is a
  tested code path (`x86/beam_asm.hpp:107,218,263`, `beam_common.c:547`).
  Cost: slightly slower calls/returns on x86 and no `perf` frame pointers.
  Patch: in `configure.ac:3195-3232` set `enable_native_stack=no` when
  `$CC` is cosmocc (or pass a new `--disable-native-stack`).
- Stack overflow detection does not use signals (Erlang stacks are checked
  explicitly), so no SIGSEGV handling is needed.
- Breakpoints/tracing: `beam_bp.c` uses code patching through the RW view
  and `erts_debug_require_code_barrier`; nothing OS-specific.
- `HAVE_LINUX_PERF_SUPPORT` (`configure.ac:3241`) is set because the host
  is `linux`; it only adds `+JP*` options that write `/tmp/perf-PID.map`
  when asked. Harmless on other OSes. `HAVE_GDB_SUPPORT`
  (`beam_jit_metadata.cpp:30-33`) registers with `__jit_debug_descriptor`;
  harmless.

### 5. `#ifdef BEAMASM` + OS macros elsewhere in erts

Grep of `beam/*.c|h` and `sys/` (34 files use `BEAMASM`) found no
`BEAMASM` block combined with `WIN32`/`__APPLE__`/`__linux__`. The
OS-dependent ones are all in `beam/jit/` (listed in section 4) plus:

- `sys/unix/sys.c:444` and `sys/unix/sys_signal_stack.c:30`: only with
  `NATIVE_ERLANG_STACK` (off in our plan).
- `beam/code_ix.c:39`: `CODE_IX_ISSUE_INSTRUCTION_BARRIERS` needs
  `ERTS_THR_INSTRUCTION_BARRIER`; defined on x86 (`i386/ethr_membar.h:37`)
  and on aarch64 once the ISB macro is 1 (section 2.2).
- `beam/erl_vm.h:35-43`: `VALGRIND`/`CODE_MODEL_SMALL` undefine the stack
  macros; unaffected.
- `beam/jit/beam_asm.h:35-36` includes `<libkern/OSCacheControl.h>` under
  `__APPLE__` only; not hit.
- `erl_mmap.h` patch in `patches/otp/0001-cosmopolitan.patch:44-56`
  (no physical memory reservation under cosmo) is unrelated to JIT memory.
- `build.sh:345-355` (`step_multicall`) hard-codes `FLAVOR=emu` and
  `obj/$t/opt/emu`; a JIT build uses `FLAVOR=jit`, `obj/$t/opt/jit` and
  `bin/$t/beam.jit`, so `build.sh:345-431` needs a `FLAVOR` variable.

### 6. Staged plan

Each step is one PR, validated in CI on Linux, macOS, Windows, FreeBSD,
NetBSD, OpenBSD (x86_64), plus the aarch64 runners we have. `+JMsingle`
and `erlang:system_info(emu_flavor)` are the smoke checks.

| step | what | patches | risk |
|---|---|---|---|
| 0 | Prep, no behavior change: `extern "C"` in `c_src/cosmo/erts_cosmo.h`; `CXX=cosmoc++` in `build.sh` configure; `FLAVOR` variable in `build.sh`; replace the asmjit `.gch` PCH rule with `-include asmjit/core.h` (Makefile.in:1023-1050) | 3 small hunks | low |
| a | x86_64-only JIT on Linux: `CC=x86_64-unknown-cosmo-cc CXX=x86_64-unknown-cosmo-c++ --enable-jit`, `enable_native_stack=no` for cosmo (configure.ac:3195). asmjit `virtmem.cpp` cosmo patch for memfd/`SHM_ANON`. Run the test suite subset we use | configure.ac, virtmem.cpp (~30 lines), build.sh | medium: first real run of generated code inside an APE process; dual mapping on Linux |
| b | Same x86_64 binary on the other OSes (it already is an APE): FreeBSD, NetBSD, OpenBSD (dual mapping via tmp file; no RWX), Windows (RWX `VirtualAlloc`), macOS x86_64 (tmp-file dual; watch for the Sonoma popup). Add the per-OS table from section 3 to `virtmem.cpp` | virtmem.cpp only | medium-high: OpenBSD and macOS are the unknowns; Windows probably works first time |
| c | aarch64 half alone: `aarch64-unknown-cosmo-c++`, `ethr_cv_arm_*=yes`, `BEAMASM_MANUAL_ICACHE_FLUSHING`, macOS arm64 `MAP_JIT`/`__jit_begin` fallback. Test on Linux aarch64 and Apple Silicon | configure cache vars; `beam_jit_main.cpp:188` `IsXnuSilicon()`; virtmem.cpp MAP_JIT branch | medium-high: Apple Silicon executable memory is the biggest single risk |
| d | Fat build: generate both table sets, wrapper `.cpp`/`.h` files (section 1 proposal), `JIT_ARCH=fat`, build with plain `cosmocc/cosmoc++`, `apelink` | Makefile.in (~60 lines), new `beam/jit/fat/*.cpp` wrappers (17 two-line files), configure.ac | low-medium: mechanical, but the largest diff to keep rebased (document in `docs/UPSTREAM.md`) |
| e | Fallback/packaging: if any OS fails in b/c, ship `beam.com` (JIT) and `beam-emu.com` (interpreter). The emu flavor builds from the same tree (`make FLAVOR=emu`), so this is only a `build.sh` release step and a launcher check (`+emu_flavor emu` already exists: Makefile.in:934) | build.sh | low |

Size: the JIT-only objects sampled here total ~0.9 MB text for both CPUs;
the full set (all 13 `instr_*.cpp` per CPU) is roughly 2-3x that, so about
+3 MB in the fat file, minus `beam_emu.o` (299 KB x86, 276 KB aarch64).
Estimate: 36.7 MB -> 39-41 MB. A separate `beam-emu.com` would add another
~35 MB to the release, which argues for making the fat JIT build work
rather than shipping two files.

