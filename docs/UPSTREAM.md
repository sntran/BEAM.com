# Notes for upstream contributions

This file records what did not work when we built Erlang/OTP with
Cosmopolitan, how BEAM.com works around it, and what a fix upstream
could be. Keep it up to date when a new problem or workaround comes.

Status words:

- **3.3.2**: seen with cosmocc 3.3.2 (an older local toolchain).
- **4.0.2**: seen in CI with cosmocc 4.0.2 (the newest release).
- **HEAD**: checked in the Cosmopolitan source, commit `3293fad0`
  (2026-07-19), which is still version 4.0.2.

The reproducers are small C files. Compile them with `cosmocc` (the fat
x86_64 + aarch64 compiler) unless the text says something else.

---

## Cosmopolitan

### C1. Writable data in a named section breaks `apelink`

**Status:** 3.3.2, 4.0.2. The linker script in HEAD has the same layout.

**Symptom.** The link stops with:

```
/tmp/fatcosmocc.XXXX.com.dbg: PE SizeOfRawData overlaps end of image
```

**Reproducer.**

```c
#include <stdio.h>
__attribute__((section("MY_DATA"))) int counter = 1;
char big[4000] = {1};
int main(void) { printf("%d %d\n", counter, big[0]); return 0; }
```

Without the `section` attribute, the link is correct.

**Cause.** `ape/ape.lds` puts `.data` in an output section that ends on a
page boundary, and the PE header gives `.data` a `SizeOfRawData` of
that size. `ld` puts the orphan section `MY_DATA` after `.data`, so the
last file byte of the data segment is no longer page-aligned. In
`apelink.c`, `ValidatePeImage()` uses the end of the last `PT_LOAD`
segment in the file as the image size, and the rounded-up raw data of
`.data` goes past it. In ERTS, the orphan section is `ERTS_LOW_WRITE`
(0x538 bytes, from `ERTS_WRITE_UNLIKELY()` in `erts/emulator/beam/sys.h`).

To find the cause, compare `readelf -SW x.com.dbg` (look for a section
between `.data` and `.bss`) with the PE section table at the `MZqFpD`
header of the `.com.dbg` file.

**Workaround in BEAM.com.** Do not use the section for Cosmopolitan (in
[`patches/otp/0001-cosmopolitan.patch`](../patches/otp/0001-cosmopolitan.patch)).

**Possible upstream fix.**

1. In `ape/ape.lds`, collect writable orphan sections into `.data`, or
   add `. = ALIGN(...)` after the orphans so that the file data ends on
   the boundary that the PE header uses. The script already lists
   `.PyRuntime` (Python) and `.subrs` (Emacs) by name for the same
   reason.
2. At minimum, make the error message name the section and the ELF
   section that makes the problem, for example: "orphan section
   MY_DATA after .data; put it in .data".

This is the most useful contribution: any program with a
`section("...")` variable fails with a message that does not help.

### C2. `cosmocc -MM` with more than one input file

**Status:** 3.3.2. The same check is in `tool/cosmocc/bin/cosmocc` in HEAD.

**Reproducer.**

```sh
printf 'int a;\n' > a.c; printf 'int b;\n' > b.c
cosmocc -MM a.c b.c
# cosmocc: fatal error: cannot specify '-o' with '-c', or '-E' with multiple files
```

GCC accepts this, and many build systems (OTP's `depend` targets) use
it. There is no `-o` on the command line: the fat wrapper adds its own
output file.

**Workaround in BEAM.com.** [`cosmo/depcc`](../cosmo/depcc) runs the
compiler once for each source file (`DEP_CC`).

**Possible upstream fix.** For `-M`/`-MM` without `-MD`/`-MMD` and
without `-o`, run only the x86_64 pass and write to stdout. Dependency
output is the same for the two architectures in almost all cases.

### C3. `POLL*` values are not compile-time constants

**Status:** 3.3.2. HEAD still declares them as `extern const int16_t`
(`libc/sysv/consts/poll.h`).

**Reproducer.**

```c
#include <poll.h>
#include <limits.h>
unsigned ev = (unsigned)(unsigned short)(UINT_MAX & ~(POLLIN|POLLOUT|POLLNVAL|POLLERR|POLLHUP));
int main(void) { return ev; }
/* error: unable to substitute constant */
```

A plain `static short ev = POLLIN;` compiles, but an expression with
more than one of these values does not. ERTS uses the values in
static initializers and in `switch` statements (`erl_poll.h`,
`erl_check_io.c`).

**Workaround in BEAM.com.** Use the `select()` back-end of ERTS
(`ac_cv_header_poll_h=no`), which has its own event bits.

**Possible upstream fix.** The `POLL*` values are the same on Linux,
the BSDs and XNU (1, 4, 8, 0x10, 0x20, 0x40...). If the Windows
emulation can use the same numbers, they can become normal `#define`
constants. Or the compiler's constant substitution can support
expressions with more than one magic constant.

### C4. `CLOCK_UPTIME` is defined but fails on Linux

**Status:** 3.3.2.

**Reproducer.**

```c
#include <stdio.h>
#include <time.h>
int main(void) {
    struct timespec ts;
    printf("rc=%d\n", clock_gettime(CLOCK_UPTIME, &ts));  /* rc=-1 on Linux */
    return 0;
}
```

**Effect.** A configure script that tests "is this clock id defined"
selects `CLOCK_UPTIME` (FreeBSD's name), and then ERTS aborts at boot
on Linux with `clock_gettime(CLOCK_UPTIME, _) failed: Invalid argument`.

**Workaround in BEAM.com.** Set the OTP configure cache variables to
`CLOCK_MONOTONIC`.

**Possible upstream fix.** Map `CLOCK_UPTIME` to `CLOCK_MONOTONIC` on
Linux (FreeBSD documents them as the same), or `#undef` the names that
only one OS supports. The comments in `libc/sysv/consts.sh` already
show this mapping.

### C5. `AF_LINK` without `struct sockaddr_dl`

**Status:** 3.3.2. HEAD defines `AF_LINK` in `libc/sysv/consts/af.h`,
and there is no `net/if_dl.h`.

**Effect.** Code that uses `#ifdef AF_LINK` to select BSD link-layer
addresses (ERTS `inet_drv.c`, the `socket` NIF) does not compile.

**Workaround in BEAM.com.** `#undef AF_LINK` in
[`cosmo/erts_cosmo.h`](../cosmo/erts_cosmo.h), and `--disable-esock`.

**Possible upstream fix.** Add `<net/if_dl.h>` with `struct sockaddr_dl`
(BSD/XNU layout), or do not define `AF_LINK`.

### C6. Declared but not defined: `gethostid()`

**Status:** 3.3.2 (declared in `libc/runtime/runtime.h`). Not found in
HEAD, so it can be already removed; check again.

**Reproducer.** `#include <unistd.h>` and call `gethostid()`: the link
fails with `undefined reference to 'gethostid'`.

**Workaround in BEAM.com.** A stub that returns 0 (used only by
`erl_interface`).

**Possible upstream fix.** Implement it (for example from
`/etc/hostid`, or a hash of the host name, as glibc does), or remove
the declaration.

### C7. No `mkfifo()`

**Status:** 3.3.2, HEAD (only `sys_mkfifo` in an internal header).

**Reproducer.** `#include <sys/stat.h>` and call `mkfifo("x", 0600)`:
`undefined reference to 'mkfifo'`. On 3.3.2 the prototype is also
missing, so `-Werror=implicit-function-declaration` stops the compile.

**Workaround in BEAM.com.** A stub that returns -1 (only `run_erl` uses
it, and BEAM.com does not include `run_erl`).

**Possible upstream fix.** Add `mkfifo()`/`mkfifoat()` for the Unix
systems (the system call numbers are already in `nr.h`), and `ENOTSUP`
on Windows.

### C8. `-fstack-protector` fails to link on aarch64

**Status:** 3.3.2. HEAD has no `__stack_chk_guard` in `libc/`.

**Reproducer.**

```c
#include <string.h>
int f(const char *s) { char b[64]; strcpy(b, s); return b[1]; }
int main(int c, char **v) { return f(v[0]); }
```

```
cosmocc -fstack-protector-strong -o sp.com sp.c
cosmocc: x86_64 succeeded but aarch64 failed to link executable
... undefined reference to `__stack_chk_guard'
```

**Effect.** OTP 28/29 adds hardening flags by default, so configure
tests fail in a way that looks like a compiler bug ("This gcc
miscompiles the Erlang runtime system").

**Workaround in BEAM.com.** `--disable-security-hardening-flags`.

**Possible upstream fix.** Define `__stack_chk_guard` for aarch64 (and
set it at startup, as x86_64 does with the TLS canary), or make
cosmocc drop `-fstack-protector*` on aarch64 with a warning.

### C9. `__truncxfhf2` missing

**Status:** 3.3.2 only. HEAD has it in `libc/intrin/float16.c`, so it
is fixed in newer releases.

**Effect.** A conversion from `long` to `_Float16` on x86_64 calls
`__truncxfhf2`, and the link fails.

**Workaround in BEAM.com.** Convert through `double` in `erl_bits.c`
(this change is also correct for OTP, see O1).

### C10. `-shared` is not supported

**Status:** known limit of Cosmopolitan.

**Effect.** OTP builds NIFs as shared objects (`asn1`, `crypto`,
`runtime_tools`...).

**Workaround in BEAM.com.** [`cosmo/noshared`](../cosmo/noshared)
writes placeholder files, so the OTP build continues. Such NIFs cannot
load.

**Possible direction.** Not a Cosmopolitan bug. For BEAM.com, static
NIFs (`--enable-static-nifs`) are the better way.

### C11. `argv[0]` is lost when Linux runs an APE file through `binfmt_misc`

**Status:** 4.0.2 in CI (GitHub `ubuntu-latest`, APE loader registered
with the command from the Cosmopolitan README: `:APE:M::MZqFpD::/usr/bin/ape:`).

**Effect.** The kernel starts `/usr/bin/ape /path/to/prog.com args...`
and the program gets the file path as `argv[0]`, not the `argv[0]` of
the `execve()` call. A multi-call program that selects its mode by
`argv[0]` (as BusyBox does) then runs the wrong mode. For BEAM.com this
was a loop: each "erl_child_setup" was a new emulator that started one
more "erl_child_setup". Through `sh ./prog.com`, `argv[0]` is kept, so
the problem shows only with `binfmt_misc`.

**Workaround in BEAM.com.** Select the helper program with an
environment variable (`BEAM_COM_PROGRAM`), and use `argv[0]` only as a
fallback.

**Possible upstream fix.** Register with the `P` (preserve-argv0) flag
and teach the APE loader the extra argument that the kernel then gives
(`/usr/bin/ape /path/to/prog.com ORIGINAL_ARGV0 args...`). At minimum,
document that `argv[0]` is not kept with `binfmt_misc`.

### C12. Windows: `mmap(MAP_FIXED)` in a `PROT_NONE` reservation fails

**Status:** 4.0.2 in CI (`windows-latest`). The cause is our best
explanation from the ERTS code; a small reproducer is still to do.

**Effect.** ERTS (64-bit) reserves a large address range with
`mmap(NULL, size, PROT_NONE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE)`
and later commits parts of it with
`mmap(addr, n, PROT_READ|PROT_WRITE, ...|MAP_FIXED)`. On Windows the
second call fails, and ERTS stops at boot with
`erts_mmap: Failed to reserve physical memory for descriptors`. The same
file works on Linux, macOS and FreeBSD.

**Workaround in BEAM.com.** Do not define
`ERTS_HAVE_OS_PHYSICAL_MEMORY_RESERVATION` for Cosmopolitan (in
`erts/emulator/sys/common/erl_mmap.h`), so ERTS does not use this
reserve-then-commit method.

**Possible upstream fix.** On Windows, implement `MAP_FIXED` inside a
range that was reserved with `PROT_NONE` as `VirtualAlloc(MEM_COMMIT)`
(reserve with `MEM_RESERVE` first). This is a common pattern in
language runtimes (garbage collectors, JITs).

### C13. NetBSD and OpenBSD: `sh ./prog.com` stops at NUL bytes

**Status:** 4.0.2 in CI (vmactions NetBSD and OpenBSD 7.9 VMs).

**Effect.** `sh ./beam.com` prints `nul ('\0') in shell input`
(NetBSD) or `syntax error: NUL byte unexpected` (OpenBSD ksh). FreeBSD's
`sh` runs the same file correctly. So the "run it with sh" instruction
does not work on these two systems.

**Workaround in BEAM.com.** Run the file through the APE loader
(`ape-x86_64.elf ./beam.com`). CI tests this.

**Possible upstream fix.** Document this in the APE instructions. If
possible, move the first NUL byte after the part of the shell script
that these shells read before they stop.

### C14. OpenBSD 7.9: the APE loader aborts

**Status:** 4.0.2 in CI (vmactions OpenBSD 7.9 VM): `ape-x86_64.elf
./beam.com` gives `Abort trap (core dumped)` before the program starts.

**Note.** This is expected: the Cosmopolitan README supports "OpenBSD 7.3
or earlier". Newer OpenBSD versions only allow system calls from the
system libc (pinsyscalls, 7.5 and later), and statically linked programs
that make their own system calls stop. CI tests OpenBSD 7.3.

**Possible upstream work.** OpenBSD support after 7.4 would need the
system calls to go through `libc.so` on OpenBSD (as Go does since 1.22).
That is a large change.

### C15. Windows: `sysconf(_SC_OPEN_MAX)` fails with `EINVAL`

**Status:** 4.0.2 in CI (`windows-latest`).

**Effect.** ERTS stops at boot with
`erts_poll_init(): Failed to get max number of files: einval`.

**Workaround in BEAM.com.** In `erl_poll.c`, use `FD_SETSIZE` when
`sysconf()` fails (the `select()` back-end has this limit anyway).

**Possible upstream fix.** Return a fixed limit on Windows (for example
the size of the Cosmopolitan fd table), as POSIX requires a value or -1
without an error for "no limit".

### C16. Windows: no `SCM_RIGHTS` (fd passing) over `AF_UNIX` socket pairs

**Status:** HEAD source (found by reading the code; the CI symptom fits).

**Effect.** ERTS starts `erl_child_setup` (the "forker") with
`socketpair(AF_UNIX)` + `fork()` + `execve()`, and passes the pipe fds of
each port program to it with `sendmsg(SCM_RIGHTS)`. On Windows,
`libc/sock/sendmsg.c` and `recvmsg.c` return `EINVAL` for any
`msg_control`, and `socketpair(AF_UNIX)` is a named pipe
(`libc/sock/socketpair-nt.c`). So the forker cannot work. In CI, the
forker child also kept the stdout/stderr pipes of `beam.exe` open, so the
test hung after the program ended.

**Workaround in BEAM.com.** On Windows (run-time test of `__hostos`), do
not start the forker, and make `open_port({spawn, ...})` fail with
`enotsup`. So `os:cmd/1` and native name lookups (`inet_gethost`) do not
work on Windows yet.

**Possible upstream fix.** Implement fd passing between Cosmopolitan
processes (the fd table is already serialized for `execve()` in
`_COSMO_FDS_V2`, and `DuplicateHandle()` can copy handles into a known
peer process). At minimum return `ENOTSUP`, not `EINVAL`.

Related notes from the same code reading (not yet seen in CI):

- `fork()` on Windows copies every private mapping of the parent with
  `WriteProcessMemory` (`libc/proc/fork-nt.c`), also large untouched
  anonymous mappings. For a runtime like ERTS (about 1 GiB of reserved
  literal area) this is slow and doubles the memory. A fast path for
  fork-then-exec (or a documented `posix_spawn()` recommendation) would
  help.
- `poll()` on Windows checks pipes every 200 ms (`POLL_INTERVAL_MS`), can
  report a pipe readable when `PeekNamedPipe` succeeds with 0 bytes, and
  never reports `POLLOUT` for an `O_RDWR` pipe polled with `POLLIN`
  (`libc/calls/poll-nt.c`).
- `uname()` gives sysname `"Windows"`, so `os:type()` is
  `{unix, windows}` in ERTS.
- `sched_getaffinity()` on Windows wants `size == sizeof(cpu_set_t)`
  exactly (`libc/proc/sched_getaffinity.c`); Linux accepts a larger size.

### C17. BSD and XNU: `sendmsg`/`recvmsg` do not convert `struct cmsghdr`

**Status:** 4.0.2 in CI (macOS arm64 and x86_64, FreeBSD, NetBSD, OpenBSD
7.3). HEAD source: `libc/sock/sendmsg.c` and `recvmsg.c` give the
`msghdr` to the kernel unchanged (only `msg_name` is converted).

**Effect.** Cosmopolitan's `struct cmsghdr` has the Linux layout (64-bit
`cmsg_len`, data at offset 16). The BSD and XNU kernels use a 32-bit
`cmsg_len`, so they read the high half of `cmsg_len` as the level, and
`sendmsg(SCM_RIGHTS)` fails with `EINVAL`. The data offset is also
different (12 on XNU, 16 on the BSDs). For `recvmsg`, the kernel writes
`msg_flags` at offset 44, which is the upper half of the 64-bit
`msg_controllen`, so `MSG_CTRUNC` is lost. In ERTS every port program
(`os:cmd/1`, `inet_gethost`) failed with
`Failed to write to erl_child_setup: 22` on macOS and the BSDs. It works
on Linux, where the layouts are the same.

**Workaround in BEAM.com.** `sys_uds.c` writes and reads the control
message in the native layout when `__hostos` is a BSD or XNU.

**Possible upstream fix.** In `sendmsg()`/`recvmsg()` on BSD and XNU,
convert each `cmsghdr` (length, level, type and data offset) and
`msg_flags`, in the same way as `msg_name` is already converted.

### C18. Windows: no public API for the name servers, no `crypt32` imports

**Status:** 4.0.2 (headers in the cosmocc package). Not a bug; notes for
programs that bring their own resolver or TLS stack.

**Name servers.** On Windows there is no `/etc/resolv.conf`.
Cosmopolitan's resolver reads the name servers from the registry in
`__get_resolv_conf_nt()` (`third_party/musl/resolvconf.c`), which is
reached through `__get_resolv_conf()`. The function is exported from
`libcosmo.a`, but its header (`third_party/musl/lookup.internal.h`) is
internal, it returns IPv4 servers only (at most `MAXNS`, 3) and no
`search` list (both are `TODO(jart)` in the source). The same is true
of `GetHostsTxtPath()` (`libc/calls/sysdir.internal.h`), which gives
`C:\Windows\System32\drivers\etc\hosts`. A program with its own
resolver (ERTS: `inet_res`) has no public way to get this information.
`GetAdaptersAddresses()` (iphlpapi) is imported and declared, so a
program can also read the servers itself.

**Certificates.** `libc/nt/` has no import stubs for `crypt32.dll`
(`CertOpenSystemStoreW`, `CertEnumCertificatesInStore`,
`CertCloseStore`). A program that wants the trusted roots of Windows
loads the DLL with `LoadLibrary()` and calls the functions through
`GetProcAddress()` pointers declared with `__attribute__((__ms_abi__))`
(the pattern of `libc/dlopen/dlopen.c`). This works.

**Workaround in BEAM.com.** `windows_setup()` in `cosmo/beam_com.c`
uses `__get_resolv_conf()` and `GetHostsTxtPath()` for an inetrc file,
and `crypt32` through `LoadLibrary()` for a PEM file.

**Possible upstream fix.** Move the two declarations to a public header
(for example `libc/calls/calls.h` or a new `libc/dns.h`), or add a
public function that returns the name servers, and consider `crypt32`
stubs in `libc/nt/`.

---

### C19. `cosmocc` does not take assembler files

**Status:** 3.3.2; HEAD (`tool/cosmocc/bin/cosmocc` stops with
"assembler input files not supported" for `.s` and `.S`).

**Symptom.** `cosmocc -c trampoline.S` fails, so a project cannot use
the per-CPU assembly files that many runtimes have (WAMR has one for
each CPU), even when the file selects the CPU with `#if`.

**Workaround in BEAM.com.** Compile the file with
`x86_64-unknown-cosmo-cc` and `aarch64-unknown-cosmo-cc`, and put the
aarch64 object in `.aarch64/` next to the x86_64 object (the layout that
`cosmocc` and `cosmoar` use).

**Possible upstream fix.** For `.S`, run the preprocessor and the
assembler of each CPU, as for C files. A `.s` file cannot be for both
CPUs, but `.S` with `#if defined(__aarch64__)` can.

### C20. No `mremap()`

**Status:** 3.3.2 (link error), HEAD (only `cosmo_mremap()` in
`libc/runtime/runtime.h`).

**Symptom.** Code that uses `mremap()` when `_GNU_SOURCE` is defined
does not link: `undefined reference to 'mremap'`. A configure test that
runs on the build machine (with the host compiler) finds `mremap()`.

**Workaround in BEAM.com.** WAMR is compiled with `WASM_HAVE_MREMAP=0`,
and it uses its own implementation.

**Possible upstream fix.** Export `mremap()` with the Linux signature
(`cosmo_mremap()` already exists), or document the name.

## WAMR (WebAssembly Micro Runtime)

Seen with WAMR 2.4.5 and its `cosmopolitan` platform, in a fat (x86_64 +
aarch64) build with `cosmocc`.

### W1. The `cosmopolitan` platform must not write the GS base

**Symptom.** The first call into WebAssembly works, and the next call to
`printf()` crashes in `pthread_mutex_lock()` (Cosmopolitan's TLS).

**Cause.** On x86_64, WAMR writes the GS base register (`wrgsbase`,
`os_writegsbase()`, unless `WASM_DISABLE_WRITE_GS_BASE=1`). Cosmopolitan
keeps its thread-local storage pointer in `%gs` (`libc/thread/tls.h`).

**Workaround in BEAM.com.** `-DWASM_DISABLE_WRITE_GS_BASE=1`.

**Possible upstream fix.** Set `WASM_DISABLE_WRITE_GS_BASE=1` in the
`cosmopolitan` platform (`platform_internal.h` or
`shared_platform.cmake`).

### W2. `invokeNative_general.c` only works on 32-bit targets

**Symptom.** A WASI call (`fd_write`) crashes in
`wasm_runtime_get_wasi_ctx()` with `WAMR_BUILD_INVOKE_NATIVE_GENERAL=1`
on x86_64.

**Cause.** The generic trampoline passes the arguments as 32-bit words,
so the 64-bit `exec_env` pointer becomes two arguments.

**Workaround in BEAM.com.** The assembly trampolines
(`invokeNative_em64.s`, `invokeNative_aarch64.s`), selected with `#if`
as in `invokeNative_osx_universal.s`.

**Possible upstream fix.** Refuse `WAMR_BUILD_INVOKE_NATIVE_GENERAL` on
64-bit targets in CMake, or make the C version pass `uint64` words there.

### W3. A fat build needs the target to follow the compiler

**Symptom.** With `WAMR_BUILD_TARGET=X86_64`, CMake adds x86-only flags
(`-mindirect-branch-register`), which the aarch64 compiler of `cosmocc`
refuses, and `BUILD_TARGET_X86_64` is also defined for the aarch64 half.

**Workaround in BEAM.com.** BEAM.com compiles the WAMR sources with its
own flags, and a forced-include header defines `BUILD_TARGET_X86_64` or
`BUILD_TARGET_AARCH64` from `__x86_64__` and `__aarch64__`.

**Possible upstream fix.** A "universal" target for the `cosmopolitan`
platform, as for macOS universal binaries.

## Erlang/OTP

These are small, general changes. They help any unusual libc or
toolchain, not only Cosmopolitan.

### O1. `FP16_FROM_FP64` depends on a compiler helper

`erts/emulator/beam/erl_bits.c` casts a signed integer directly to
`_Float16`. On x86_64 GCC does this through `long double` and calls
`__truncxfhf2`, which some runtime libraries do not have.
`((_Float16) (double) (x))` gives the same result for these values.

### O2. `zstd.mk` always compiles the x86_64 assembly file

`erts/emulator/zstd/zstd.mk` adds `huf_decompress_amd64.S` on all
targets except win32. zstd already supports `-DZSTD_DISABLE_ASM`, but
the makefile ignores it. Fix: do not add the file when `CFLAGS` has
`ZSTD_DISABLE_ASM`, or add a configure option.

### O3. `ERTS_LOW_WRITE` should be optional

`ERTS_WRITE_UNLIKELY()` in `sys.h` puts variables in a custom section.
Some linkers and linker scripts do not handle custom sections (see C1).
A configure option or a `#ifndef ERTS_NO_LOW_WRITE_SECTION` guard would
help.

### O4. Configure selects clock ids that only compile

`make/autoconf/otp.m4` tests clock ids (`CLOCK_HIGHRES CLOCK_UPTIME
CLOCK_MONOTONIC`...) with a compile/link test. When not cross
compiling, an `AC_RUN_IFELSE` test that calls `clock_gettime()` would
not select an id that fails at run time (see C4).

### O5. Kernel poll: kqueue is selected when only the header is there

With Cosmopolitan, `sys/event.h` exists, so configure selects kqueue.
It works only on BSD and macOS. A run test (when not cross compiling)
would select the correct back-end.

### O6. `inet_drv.c` stops with `#error` for an unknown `sendfile()`

When configure finds `sendfile()` but the OS macros are not Linux, BSD
or Solaris, `inet_drv.c` stops with `#error "Unsupported sendfile
syscall"`. It could use the fallback without `sendfile()` (the same as
when `HAVE_SENDFILE` is not defined).

### O7. `ei_resolve.c` selects the `gethostbyname_r` variant by OS macros

`lib/erl_interface/src/connect/ei_resolve.c` uses `__GLIBC__`,
`__linux__` and FreeBSD macros to select the glibc-style
`gethostbyname_r` (6 arguments). A configure test of the signature
would work with musl, Cosmopolitan and other libcs.

### O8. A sub-configure failure does not stop the top-level configure

With `--disable-parallel-configure`, `erts/configure` failed (`exit 1`
in `erts/config.log`), but the top-level `./configure` exited with 0
and printed only the "APPLICATIONS DISABLED" table. The next `make`
then used an old `config.status`. [`build.sh`](../build.sh) checks
`erts/config.log` for this reason. The top-level configure should stop
when the ERTS configure fails.

### O9. Link the helper programs into one binary (idea)

BEAM.com links `erl_child_setup` and `inet_gethost` into the emulator
and selects the program by `argv[0]`. A small ERTS hook for "the path
of the helper programs" (instead of `BINDIR/name`) would make
single-file runtimes possible without patches to `sys_drivers.c` and
`erl_child_setup.c`.

### O10. `inet_db` discards added name servers when `/etc/resolv.conf` is missing

**Status:** OTP 29.1.1, `lib/kernel/src/inet_db.erl` and
`inet_config.erl`. Seen in BEAM.com on Windows (`os:type()` is
`{unix, windows}` and there is no `/etc/resolv.conf`), but the code is
the same on any Unix without that file.

**Reproducer** (any Unix, as root: `mv /etc/resolv.conf /tmp/`):

```erlang
inet_db:set_lookup([dns]),
inet_db:add_ns({8,8,8,8}),
inet_db:res_option(nameservers),            % [{{8,8,8,8},53}]
inet_res:resolve("www.erlang.org", in, a),  % {error,nxdomain}, nothing is sent
inet_db:res_option(nameservers).            % []
```

**Cause.** `inet_config:init/0` sets `resolv_conf_name` to
`/etc/resolv.conf` for every `{unix, _}`. `inet_res` calls
`inet_db:res_update_conf/0` before each lookup (in `make_options/1`,
before it reads `nameservers`). In `inet_db:handle_update_file/7`, when
`erl_prim_loader:read_file_info(File)` fails, the code takes the
"No file - clear content" branch and parses an empty binary, which
sends `{replace_ns, []}` and `{replace_search, []}`: the servers added
with `inet_db:add_ns/1` (or `{nameserver, IP}` in an inetrc) are gone,
and `inet_res:res_query/5` answers `{error, nxdomain}` for an empty
`nameservers` list without a query. This repeats every
`?RES_FILE_UPDATE_TM` (5 s).

**Workaround in BEAM.com.** `{resolv_conf, ""}.` in the inetrc, before
the `{nameserver, _}` entries. An empty file name deletes the monitor
(`handle_set_file/7`), and `inet_config` then does not set the default
name because `inet_db:res_option(resolv_conf)` is no longer `undefined`.

**Possible upstream fix.** In `handle_update_file/7`, when the file
does not exist and never existed (`Finfo =:= undefined`), keep the
current content instead of replacing it with the parse of `<<>>`; or
only clear when a file that was read earlier disappears. Documenting
`{resolv_conf, ""}` as the way to turn the monitor off would also help.

### O11. The static NIF libraries are made two times at the same time with `make -j`

**Status:** OTP 29.1.1, `erts/emulator/Makefile.in`. Seen in CI with
`--enable-static-nifs` (crypto and asn1) and `make -j4`. It does not
occur on each build.

**Symptom.**

```
 CC	../priv/obj/x86_64-pc-linux-gnu/aead_static.o
 CC	../priv/obj/x86_64-pc-linux-gnu/aead_static.o
...
../priv/obj/x86_64-pc-linux-gnu/algorithms_static.o: open failed with No such file or directory
make[8]: *** [x86_64-pc-linux-gnu/Makefile:235: ...algorithms_static.o] Error 1
```

**Cause.** The rule `$(STATIC_NIF_LIBS) $(STATIC_DRIVER_LIBS):` has
more than one target and no prerequisites. For make, this is one rule
for each target, so with `-j` it runs the recipe (`make -C lib
static_lib`, which makes all the libraries) once for each library at
the same time. The two runs write the same object files.

**Fix in BEAM.com.** A grouped target (`&:`, GNU make 4.3 and later):
the recipe runs once and makes all the targets.

**Possible upstream fix.** The same grouped target, or one stamp file
as the target of the recipe, with the libraries depending on it (this
also works with older make).
