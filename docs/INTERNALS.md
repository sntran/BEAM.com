# How BEAM.com works

This file explains how one file runs Erlang/OTP on each system. For
the WebAssembly runtime of the edge part of `app.com`, see "How it works" in
[`WORKERS.md`](WORKERS.md).

## Nothing is extracted

BEAM.com runs the code where it is: in the zip of its own file. ERTS
reads the `.beam` files, the boot script and the configuration from
`/zip/...`, the zip file system of Cosmopolitan, as from a directory.
There is no install step, and no cache directory for the code.

Tools such as [Burrito](https://github.com/burrito-elixir/burrito) and
Bakeware work in a different way: they unpack ERTS and the release to a
directory on the first run (one for each version), and then run the
files from there.

| | BEAM.com | Burrito, Bakeware |
|---|---|---|
| First start | the same as the next ones | unpacks to disk first |
| Files left on disk | none (see below) | the unpacked release, until you remove it |
| One file for | all the platforms and CPUs | one platform and CPU |
| NIFs | the static NIFs in `beam.com`, and NIF libraries in WebAssembly ([`NIFS.md`](NIFS.md)) | any NIF of the release |
| Files in `priv/` | read from the zip; copied to a cache directory only when they must be real files (see "Command line programs" in [`PROGRAMS.md`](PROGRAMS.md)) | normal files |
| The zip | read-only at run time; a new file in its place gives new code, and new files of `priv/` go to the cache ([`PROGRAMS.md`](PROGRAMS.md)) | normal files |

What BEAM.com writes, and removes:

- When you start an APE file with `sh`, its shell header writes the
  small APE loader to `$TMPDIR/.ape-1.10` on the first run (Linux,
  macOS and the BSDs, not Windows). It stays there, for all APE files
  of that version. A Linux system with the loader registered in
  `binfmt_misc` does not need this.
- A program of a project whose `priv` has an executable file (or with
  `--extract-priv`, also for a release) copies that `priv` directory to
  the user cache at its first start (see "Command line programs" in
  [`PROGRAMS.md`](PROGRAMS.md)). It stays there.
- A program of the zip (a file of `/zip` with an execute bit) that runs
  as a port program: on Linux from a memfd, with no file. On the other
  systems, in a sandbox, and when the memfd does not work, the first
  start writes its copy `CACHE/bin/SHA256/NAME` (mode 0500, in
  directories of mode 0700), and the next starts use it. It stays there,
  one copy for each content of the program. Remove `CACHE/bin` to
  remove the copies.
- On Windows, the resolver settings and the certificates of Windows go
  to two files in the temp directory at start, which are removed at
  exit (see "Crypto and TLS").

## One file, many programs

An OTP installation has more than one executable. ERTS starts
`erl_child_setup` when it boots (it forks the port programs), and on
Linux the kernel starts `inet_gethost` at boot to resolve the host name.
BEAM.com links these programs into the emulator. It is a multi-call
binary, like BusyBox (see [`c_src/cosmo/beam_com.c`](../c_src/cosmo/beam_com.c)).

When ERTS must execute a helper program `/zip/bin/NAME`, it executes
its own file (`GetProgramExecutableName()`) again, with
`BEAM_COM_PROGRAM=<program name>` in the environment
(`beam_com_exec_helper()`). The new process removes the variable and
runs that program. The base name of `argv[0]` is only a fallback,
because Linux `binfmt_misc` does not keep `argv[0]`. One function,
`beam_com_zip_helper()` of `c_src/cosmo/beam_com_zipexec.c`, decides
which paths are helpers. Each other program of the zip runs from a real
file: a memfd on Linux, else a copy in the cache (see "priv files as
real files" in [`PROGRAMS.md`](PROGRAMS.md)).

The helper programs (`beam_com_main()` in `beam_com.c` finds each one by
the start of its name):

| Program | Source | Use |
|---|---|---|
| `erl_child_setup` | `beam_com_child_setup.c` | ERTS starts it at boot; it forks the port programs. |
| `inet_gethost` | `beam_com_inet_gethost.c` | The resolver of host names of `inet`. |
| `epmd` | `beam_com_epmd*.c` | The port mapper of distributed Erlang. |
| `inotifywait`, `mac_listener` | `beam_com_watch.c` | The file watcher. |
| `ssh_agent_bridge` | `beam_com_agent.c` | The connection of the git client to an SSH agent on a named pipe of Windows. |
| `git_sha1dc` | `beam_com_sha1dc.c` | The SHA-1 check of the git client, with the library of `sha1dc/`. |

A new helper needs a name that does not start with the name of another
helper, and that no other helper name starts with.

On Linux, the APE loader runs an APE file (the shell script of the file
starts it, or binfmt_misc). Cosmopolitan's `execve()` of an APE file
tries the kernel first, and starts the loader only when the kernel
refuses the file. On WSL2 the kernel does not refuse it: the
`WSLInterop` entry of binfmt_misc gives it to Windows, and the helper
does not start (C31 in [`UPSTREAM.md`](UPSTREAM.md)). So when
`/proc/self/exe` is a loader and not the file, BEAM.com starts an APE
file with that loader itself (`ape - FILE ARGV0 ARGV1 ...`): the helper
programs, `epmd`, a port that starts an APE file (erl mode), and the
file watcher of the tools. A native file (`--assimilate`, `--target`)
is `/proc/self/exe`, and the kernel starts it.

## Windows on ARM64

Windows starts an APE file as a PE file, and the PE header names the
x86_64 half. Windows on ARM64 runs that half under its x64 emulation.
The aarch64 half of `beam.com` also runs on Windows (C58 in
[`UPSTREAM.md`](UPSTREAM.md)), so the file starts that half itself:

1. The x86_64 half starts first. `win_arm64_start()` of
   [`beam_com.c`](../c_src/cosmo/beam_com.c) asks Windows for the
   machine with `IsWow64Process2()`. On x86_64, the function returns,
   and nothing changes.
2. On ARM64, it reads the loader `/zip/bin/ape-arm64.exe` (7 KB) and
   writes it to the cache directory as `ape-arm64-HASH.exe`, when the
   file is not there with the same bytes. HASH is the FNV-1a hash of
   the loader. The cache directory is `BEAM_COM_CACHE`, else `beam.com`
   in `XDG_CACHE_HOME` or in `LOCALAPPDATA`.
3. It starts the loader with the path of its own file and its
   arguments (`execv()`). The loader `bin/ape-arm64.exe` of cosmocc
   ([`ape/ape-arm64.c`](https://github.com/sntran/cosmopolitan/blob/main/ape/ape-arm64.c)
   of sntran/cosmopolitan) maps the aarch64
   half of that file at its fixed addresses and starts it. The x86_64
   process waits and gives the exit status of the native process.
   The loader has no high-entropy ASLR (`/highentropyva:no`). Thus
   Windows puts the stacks and the heaps of its process below 4 GiB,
   and the fixed addresses of the aarch64 half (from 32 GiB) are free.
   With high entropy, these blocks went to random addresses up to some
   TiB, and about 1 start in 4000 failed with "cannot map the image".

When a step fails (no cache directory, a write error), the x86_64 half
runs, as before. `BEAM_COM_NATIVE=0` also keeps the x86_64 half.

The native process starts each helper program, each port program and
each other APE file with the same loader: `posix_spawn()` and `execve()`
of the patched libc put the loader of the current process before an APE
file that has an aarch64 half. Thus a program that `beam.com` builds,
and a second VM from the same file, are native too. An x86_64 program of
Windows (`cmd.exe`, `git.exe`) starts as it is.

## Crypto and TLS

The step `openssl` (`scripts/steps.sh`) builds a static `libcrypto` of
OpenSSL 4.0.3 two times: for x86_64 and for aarch64, each with the
assembly code of its CPU. The aarch64 archive goes to `lib/.aarch64/`,
where the fat linker of cosmocc finds it. One compile of the crypto NIF
makes the two halves, so a header that differs between the two builds
(`openssl/configuration.h`) has the text of each CPU under
`__aarch64__`. OTP is configured with `--enable-static-nifs`.

The assembly code must keep the rules of Cosmopolitan Libc, and
`check_openssl_asm` stops the build when it does not:

- aarch64: no instruction writes x28 (the thread pointer) or x18 (C73,
  SSL1). `patches/openssl/0002-aarch64-registers.patch` builds the C
  code of the modules that do.
- x86_64: no assembly object has the bytes of the TLS load that
  Cosmopolitan Libc changes at start on Windows and XNU
  (`libc/runtime/morph_tls.c`).

OpenSSL finds the features of the CPU when crypto starts
(`OPENSSL_init_crypto()`), not before `main()` (C74). On x86_64 it reads
`cpuid`. On aarch64 it runs a probe instruction for each feature and
catches SIGILL, because `getauxval()` of Cosmopolitan is not the path
that OpenSSL takes. The variables `OPENSSL_ia32cap` and `OPENSSL_armcap`
set the features by hand.

With the assembly code, on one Intel Xeon with AVX-512 and SHA-NI
(2.1 GHz, Linux):
AES-256-GCM goes from 121 MB/s to 8213 MB/s, SHA-256 from 314 MB/s to
1750 MB/s, RSA-2048 signs from 445 to 3166 each second, and P-256 signs
from 1163 to 39550 each second. ERTS selects a static NIF by the name of the
module that loads it, so the `crypto.beam` of a normal release uses the
NIF inside `beam.com` (the release does not need its `crypto.so`).

`public_key:cacerts_get/0` reads the certificates of the OS on Linux,
macOS and the BSDs. On Windows, `public_key` only reads the Windows store
for `os:type()` `{win32, _}`, so BEAM.com exports the trusted roots of
Windows (with `crypt32`) to a PEM file at start and gives it to
`public_key` with `-public_key cacerts_path File`.

`public_key` does not read `SSL_CERT_FILE`, but OpenSSL, curl, Python
and Go do. A sandbox or a proxy that terminates TLS often gives its CA
only in that file. So when `SSL_CERT_FILE` names a regular file that
BEAM.com can read, BEAM.com gives that file to `public_key` in the same
way, on each system. The file replaces the certificates of the OS, as it
does for OpenSSL. Your own `-public_key` argument wins. With `--allow-net`
(`-N`), the sandbox of BEAM.com also lets the program read the file.

## The zip of the default beam.com

```
bin/start_clean.boot, bin/no_dot_erlang.boot
bin/windows.inetrc                 resolver settings, used on Windows
bin/sandbox.inetrc                 resolver settings, used in the sandbox
bin/mix                            the script of mix (for the tools)
lib/kernel-11.0.4/{ebin,include}/...
lib/stdlib-8.1/{ebin,include}/...
lib/.../                           sasl, compiler, parsetools, crypto, asn1,
                                   public_key, ssl, inets, ssh, xmerl,
                                   runtime_tools, tools, syntax_tools
lib/elixir-1.20.5/ebin/...         and eex, ex_unit, iex, logger, mix
lib/esqlite-.../ebin/...           SQLite
lib/wasm-0.1.0/ebin/...            WebAssembly
lib/wasm_host-0.1.0/...            for the edge part, with the runtime
                                   (priv/runtime/beam.wasm) and the Workers
lib/beam_com/ebin/...              the commands (src/beam_com)
lib/beam_com_script-0.1.0/ebin/... runs one-file programs
licenses/                          LICENSE, NOTICE and the license texts
```

There is no `releases/` directory: a release that you add brings its own.

The code of `kernel` and `stdlib` is stored in the zip without
compression. The boot loads these modules first, and a stored entry is
read without inflating it: this makes the start about 50 ms (about 27%)
faster, for 2 MB more (measured on Linux x86_64). `beam.com INPUT -o OUTPUT`
keeps these entries as they are, so the programs that it makes start
faster too.

BEAM.com does the work of `erlexec`. It gives ERTS
`-root /zip -bindir /zip/bin -progname beam.com -home $HOME`, then the
release arguments, `ERL_FLAGS`, `.args` and the command line.

When the zip has `lib/beam_com` and no release (the default
`beam.com`), BEAM.com boots `start_clean` and runs `beam_com:main/0`,
which runs or builds the input. With a release, the arguments go to the
release. A run ends with `execv()` of the executable in the cache (at
exit, in `beam_com.c`): no port program, so it works on Windows too.

## How `beam.com INPUT -o OUTPUT` writes the new file

PKZIP keeps its index (the central directory) at the end of the file,
and in an APE file the offsets count from the start of the file. The
emulator also has zip entries of its own inside its image (symbol
tables, time zones, `.cosmo`), which must stay where they are. The
builder ([`src/beam_com/beam_com_zip.erl`](../src/beam_com/beam_com_zip.erl))
keeps the bytes up to the first entry that it removes, moves the entries
after that point that it keeps, adds the new entries, and writes a new
central directory with the new offsets.

In the zip of `beam.com`, the code of OTP 29 has no docs and no debug
information, and the code of Elixir has only its docs (for `h/1` in
`iex`). `step_bundle` of `scripts/steps.sh` strips them, about 16 MB. The
protocols of Elixir keep their debug information, because the
consolidation of Mix reads it. A custom build can keep the debug
information of OTP and Elixir (`DEBUG_INFO=1`, for `cover` and `rr/1`)
and the docs of OTP (`OTP_DOCS=1`, for `h/1` of OTP modules). A program
does not need them: the builder strips them from the beam files of the
program, as `mix release` does (`strip_beams`). It keeps the chunks that
the loader uses, the line numbers (for stack traces) and the
attributes. A program is about 7.7 MB smaller, and it starts as fast as
before ([`BENCHMARKS.md`](BENCHMARKS.md)).

The builder also strips the beams that it compiles, of the program and
of its deps. Their compile information and debug information have the
paths of the build, with a new temporary directory each time. Without
them, two builds of the same code almost always give the same bytes,
and the reload of a program that runs (`beam_com_reload`) reads only the
beams that changed. A file that a Mix step writes with a new time (for
example `cache_manifest.json` of `phx.digest`) is new at each build. The
Erlang compiler gets the option `deterministic`.
The Elixir compiler can give other bytes for some modules (for example
in the tables of a module that a macro makes).

## JIT, and the interpreter (`beam-emu.com`)

`beam.com` runs Erlang code with BeamAsm, the JIT of OTP, in one fat
file: the x86 backend in the x86_64 half and the arm backend in the
aarch64 half ([`JIT.md`](JIT.md)). The programs that it builds
have the JIT too. No memory page of the JIT code is writable and
executable at the same time (W^X): the JIT writes the code through a
second mapping.

`beam-emu.com` is the same with the BEAM interpreter (`make JIT=0
OUT=build/beam-emu.com`). It is 2.8 MB smaller and starts 40 to 90 ms faster, but
Erlang code is slower: 2 times on x86_64 and up to 11 times on aarch64
for function calls ([`BENCHMARKS.md`](BENCHMARKS.md)). Use it
to build small command-line programs, where the start time counts more.
Code in C (crypto, SQLite, WebAssembly) has the same speed in both.

## Changes to OTP

The OTP changes are small. Most of the port is in the configure
arguments and in a header that the compiler includes in each file
([`c_src/cosmo/erts_cosmo.h`](../c_src/cosmo/erts_cosmo.h)).

| Change | Why |
| --- | --- |
| `--enable-jit` | BeamAsm with both backends ([`JIT.md`](JIT.md)). `JIT=0` gives `--disable-jit`: the BEAM interpreter (`beam-emu.com`). |
| `--disable-kernel-poll`, `ac_cv_header_poll_h=no` | The `select()` back-end is used. The `POLL*` values of Cosmopolitan are not compile-time constants, and epoll/kqueue are not on all systems. |
| `--disable-esock` | The `socket` NIF needs BSD types that Cosmopolitan does not have. `gen_tcp` and `gen_udp` use `inet_drv`. To send a descriptor over a Unix socket (`SCM_RIGHTS`), `beam_com_fd` has its own static NIF (`c_src/fd/beam_com_fd.c`). |
| `erts_cv_linux_thp=no` | The 2 MiB page alignment for Linux breaks the APE layout. |
| monotonic clock = `CLOCK_MONOTONIC` | `CLOCK_UPTIME` is in the headers, but only works on BSD. |
| `ac_cv_func_sendfile=no` | `inet_drv` only knows the Linux, BSD and Solaris `sendfile()`. |
| `-DZSTD_DISABLE_ASM` | cosmocc does not compile the zstd `.S` file for two CPUs. |
| `DEP_CC=c_src/cosmo/depcc` | cosmocc does not support `-MM` with many input files. |
| `DED_LD=c_src/cosmo/noshared` (at configure time) | There are no shared objects. NIF `.so` files become placeholders, and the NIF configure tests link normal programs, not `-shared` ones. |
| `--enable-static-nifs`, `--with-ssl`, `--disable-dynamic-ssl-lib` | The `crypto` and `asn1` NIFs and `libcrypto` are linked into the emulator. |
| No `ERTS_LOW_WRITE` section | The APE linker script does not know this section. It made the PE `.data` section end after the file data, and `apelink` stopped with "PE SizeOfRawData overlaps end of image". |
| No reserve-then-commit `mmap` | On Windows, `mmap(MAP_FIXED)` in a `PROT_NONE` reservation fails, and ERTS stopped at boot. |
| `FD_SETSIZE` when `sysconf(_SC_OPEN_MAX)` fails | It fails with `EINVAL` on Windows. |
| Native `cmsghdr` layout in `sys_uds.c` | Cosmopolitan does not convert control messages for BSD and XNU, so no port program could start on macOS and the BSDs. |
| No forker on Windows | Cosmopolitan cannot pass fds on Windows. The spawn driver starts each port program itself with `posix_spawn()` (C16 of [`UPSTREAM.md`](UPSTREAM.md)). |
| [`patches/otp/0001-cosmopolitan.patch`](../patches/otp/0001-cosmopolitan.patch) | The items above that need source changes, the multi-call hooks, the `_Float16` conversion, and `gethostbyname_r` in `erl_interface`. |
| [`patches/otp/0002-jit.patch`](../patches/otp/0002-jit.patch) | The JIT with both backends in one fat file ([`JIT.md`](JIT.md)). |

The WebAssembly runtime has its own changes of ERTS:
[`wasm/erts/otp.patch`](../wasm/erts/otp.patch) (see
[`WORKERS.md`](WORKERS.md)). [`UPSTREAM.md`](UPSTREAM.md) records each
problem, with a possible fix upstream.
