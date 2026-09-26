# BEAM.com

BEAM.com is an experiment: the Erlang/OTP runtime system (ERTS) as one
[Actually Portable Executable](https://justine.lol/ape.html) (APE),
made with [Cosmopolitan Libc](https://github.com/jart/cosmopolitan).

It uses the "redbean style": the executable is also a zip file. You add
an Erlang release to the zip, and the one file runs your release on
Linux, macOS, Windows and the BSDs, on x86_64 and aarch64.

You do not need Erlang to make such a file. `beam.com` has the compiler:

```
$ sh ./beam.com build examples/hashsum.erl
beam.com: wrote hashsum.com (25304313 bytes)
  release: hashsum 0.1.0
  applications: beam_com_script kernel stdlib crypto
$ sh ./hashsum.com abc
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc
```

```
$ sh ./beam.com help
BEAM.com: Erlang/OTP 29.1.1 in one executable file, for Linux,
macOS, Windows and the BSDs, on x86_64 and aarch64.

usage: beam.com COMMAND [ARGUMENTS]

Commands:
  build INPUT [-o OUTPUT] [-a APP]...
                  make an executable from a .erl file with main/1, or
                  from an application directory
  version         show the versions, the emulator and the platform
  help [COMMAND]  show this text, or the help of a command
...
$ sh ./beam.com version
beam.com 0.1.0
  Erlang/OTP  : 29.1.1
  ERTS        : 17.1
  Emulator    : jit
  OS type     : unix/linux
  Architecture: x86_64-pc-linux-gnu
  Schedulers  : 4
  Applications: asn1-5.5.2 beam_com-0.1.0 ... stdlib-8.1 wasm-0.1.0
```

The default `beam.com` has no release: it runs these commands (`beam.com`
with no argument shows the help). When you add a release to a copy of
`beam.com`, the release runs instead. Erlang/OTP version: **29.1.1**.

`crypto` and `ssl` work: the `crypto` and `asn1` NIFs are linked into
`beam.com` with a static OpenSSL 4.0.2, and TLS connections verify the
server with the certificates of the OS (on Windows too).

## Build a program with `beam.com build`

```sh
beam.com build INPUT [-o OUTPUT] [-a APP]... [--pledge PROMISES]
               [--unveil "PERMISSIONS PATH"]... [--native TARGET]
```

`INPUT` is one of these:

- **One `.erl` file** that exports `main/1`, as for `escript`. The
  program gets the command line arguments, and halts with status 0 when
  `main/1` returns (127 on an exception).
- **An application directory**: `src/*.erl` (subdirectories too),
  `src/NAME.app.src` or `ebin/NAME.app`, and optionally `include/`,
  `priv/`, `config/sys.config`, `config/vm.args` (the rebar3 layout) and
  the `erl_opts` of `rebar.config`. Parsers (`src/*.yrl`, yecc),
  scanners (`src/*.xrl`, leex) and ASN.1 modules (`asn1/*.asn1` or
  `src/*.asn1`, `.asn` too; BER) are made into Erlang code first. The
  `deps` of `rebar.config` are Hex packages (see below).

The builder compiles the code, selects the OTP applications that the
program needs, makes an OTP release with `systools`, and writes a copy of
`beam.com` with the release in its zip (`OUTPUT`, by default the name of
`INPUT` with `.com`). The new file does not have the compiler or the
`build` command, only what the program needs.

The applications are the ones that the `.app` file names, the ones of
the modules that the code calls (from the imports of the compiled code),
and all the applications that these need. Use `-a APP` for an
application that the code only calls with `apply/3` or similar.

The zip of `beam.com` has `kernel`, `stdlib`, `sasl`, `compiler`,
`parsetools`, `crypto`, `asn1`, `public_key`, `ssl`, `inets`, `wasm` and
`esqlite`.

### Hex packages

The `deps` of `rebar.config` are fetched from [hex.pm](https://hex.pm)
and compiled into the program, as rebar3 does, without rebar3:

```erlang
{deps, [{cowboy, "~> 2.13"},       % a Hex requirement
        {jsx, "3.1.0"},            % this version only
        recon,                     % the highest version
        {mylib, "~> 1.0", {pkg, my_lib}}]}.  % another package name
```

- **Versions.** When `rebar.lock` has all the deps, its versions are
  used, and nothing is resolved. Otherwise `beam.com build` takes the
  highest version of each package that matches all the requirements (of
  `rebar.config` and of the packages), the locked version first when it
  matches, and writes `rebar.lock` (the format of rebar3). A conflict
  is an error that names both requirements; a version in `rebar.config`
  solves it. Pre-releases are used only when a requirement names one.
- **Checks.** Each tarball is checked with the outer checksum (SHA-256
  of the file: `pkg_hash_ext` of `rebar.lock`, or the checksum of the
  Hex API) and the inner checksum (`pkg_hash`, and the `CHECKSUM` file).
- **Cache.** The tarballs are kept in the cache of the user
  (`~/.cache/beam.com` on Linux; `BEAM_COM_CACHE` changes it). With
  `rebar.lock` and a full cache, a build does not use the network.
- **Network.** HTTPS with `httpc`, verified with the certificates of
  the OS. `HTTPS_PROXY` and `NO_PROXY` are used. `HEX_API_URL` (default
  `https://hex.pm/api`) and `HEX_MIRROR` (default `https://repo.hex.pm`)
  select other servers.
- **Build.** The packages are compiled in order (a package after the
  packages that it needs), with their `erl_opts` (without
  `warnings_as_errors`), and their warnings are not shown. A package
  can use the parse transforms and the headers (`include_lib`) of the
  packages that it needs.
- **Not supported:** git and other sources, Elixir packages (mix), NIFs
  (C code) and rebar3 plugins or hooks.

[`examples/hexweb`](examples/hexweb) uses cowboy (with cowlib and
ranch) and jsx: it starts a web server and gets JSON from it. CI builds
it on each platform, two times (with and without `rebar.lock`).

### A native file for one system (`--native`)

`--native TARGET` writes a file for one system instead of an APE file,
as Cosmopolitan's `assimilate` does. `TARGET` is `linux-x86_64`,
`linux-aarch64`, `freebsd-x86_64` or `macos-x86_64`:

```sh
beam.com build hello.erl --native linux-x86_64 -o hello
./hello
```

The kernel starts the native file directly: no shell script at the
start, no APE loader in `$TMPDIR` or `$HOME`, and on macOS a Mach-O file
that can be signed. The file is the APE file with the ELF or Mach-O
header of the target at its start (the shell script of the APE file
has these headers). The size and the zip do not change, and the file
still runs its release from `/zip`. The builder gives the same bytes as
`assimilate` (tested with the fat `beam.com`).

The file runs only on its target. Apple Silicon has no native form:
there, APE files run with the APE loader. On Windows, the APE file is
already a native PE file.

### WebAssembly

`beam.com` runs WebAssembly modules and WASI preview 1 programs with
[WAMR](https://github.com/bytecodealliance/wasm-micro-runtime) (the
interpreter, linked into `beam.com`). The `wasm` application is in the
zip, and `beam.com build` selects it when the code calls `wasm`:

```erlang
{ok, Mod} = wasm:load(Bytes),                    % the bytes of a .wasm file
{ok, Inst} = wasm:instantiate(Mod),
{ok, [42]} = wasm:call(Inst, "add", [40, 2]),    % i32/i64: integers, f32/f64: floats
{ok, Bin} = wasm:memory_read(Inst, Offset, Len),

%% A WASI program (from Rust, Go, Zig, C, ...): argv, env and directories.
{ok, ExitCode} = wasm:run(Bytes, ["prog", "arg"],
                          #{env => [{"KEY", "value"}], dirs => [{"/", "."}]}).
```

[`examples/wasm_check.erl`](examples/wasm_check.erl) tests calls, traps,
memory and a WASI program, and runs a `.wasm` file that you give it. CI
runs it on each platform with a Go program
([`examples/wasm/hello_go`](examples/wasm/hello_go), `GOOS=wasip1`).
WAMR adds about 0.6 MB (two CPUs). Build with `WASM=0` to leave it out.

Go resolves relative paths from `/`, so give the directory of a Go
program as `"/"` in `dirs`.

### JIT, and the interpreter (`beam-emu.com`)

`beam.com` runs Erlang code with BeamAsm, the JIT of OTP, in one fat
file: the x86 backend in the x86_64 half and the arm backend in the
aarch64 half ([`docs/JIT.md`](docs/JIT.md)). The programs that it builds
have the JIT too. No memory page of the JIT code is writable and
executable at the same time (W^X): the JIT writes the code through a
second mapping.

`beam-emu.com` is the same with the BEAM interpreter (`JIT=0
./build.sh`). It is 2.8 MB smaller and starts 40 to 90 ms faster, but
Erlang code is slower: 2 times on x86_64 and up to 11 times on aarch64
for function calls ([`docs/BENCHMARKS.md`](docs/BENCHMARKS.md)). Use it
to build small command-line programs, where the start time counts more.
Code in C (crypto, SQLite, WebAssembly) has the same speed in both.

### SQLite

`beam.com` has SQLite 3.53.4, with the
[esqlite](https://github.com/mmzeeman/esqlite) NIF. SQLite itself is
compiled from its amalgamation with `cosmocc`; esqlite is the small NIF
that gives Erlang code the SQLite API (`esqlite3:open/1`, `exec/2`,
`q/2`, ...). `beam.com build` selects the `esqlite` application when the
code calls `esqlite3`:

```sh
beam.com build examples/sqlite_check.erl
./sqlite_check.com my.db
```

SQLite adds about 1.8 MB (two CPUs) to `beam.com` and to each program
that it makes, also when the program does not use SQLite, because the
NIF is in the emulator. Build with `SQLITE=0` to leave it out.

### Sandbox: `--pledge` and `--unveil`

A program can give up what it does not need, with the `pledge()` and
`unveil()` of Cosmopolitan (as OpenBSD programs do):

```sh
beam.com build server.erl --pledge "inet dns" --unveil "r /etc/ssl" --unveil "rwc /var/lib/server"
```

- `--pledge PROMISES`: the groups of system calls that the program
  keeps, for example `inet` (sockets), `dns`, `wpath` and `cpath` (write
  and create files), `proc exec` (port programs). `stdio rpath` are
  always added: ERTS needs them to start. `beam.com` (the JIT)
  also adds `prot_exec`: without it, the JIT cannot allocate memory for
  its code and ERTS stops at the start ("Cannot allocate executable
  memory"). `beam-emu.com` does not need it.
  `beam.com help build` lists the promises.
- `--unveil "PERMISSIONS PATH"` (more than one): the files and
  directories that the program can see, with the permissions `r`, `w`,
  `x` and `c` (create). All other paths are hidden. BEAM.com adds its own
  file, `/dev/null`, `/dev/urandom` and the APE loader.

A forbidden system call returns an error: Erlang code gets `{error,
eperm}` (pledge) or `{error, eacces}` (unveil). Without `proc exec`,
port programs fail (`open_port/2` returns an error), and kernel uses its
own DNS client, because the native resolver is a port program.

| System | `--pledge` | `--unveil` |
|---|---|---|
| Linux | yes (seccomp) | yes (Landlock, Linux 5.13 and later) |
| OpenBSD | the kernel stops the program on a forbidden call | yes |
| macOS, Windows, FreeBSD, NetBSD | ignored | ignored |

The rules are applied when the program starts, before ERTS starts its
threads, so that they apply to all the threads of the VM (on Linux, a
rule applies to the thread that sets it and the threads that it starts
later). For the same reason there is no `pledge()` for Erlang code.
`BEAM_COM_PLEDGE` and `BEAM_COM_UNVEIL` (rules separated by `;`) add
rules at run time, to try a sandbox without a new build; they can only
take more away.

## Add your release

Make a normal OTP release **without ERTS**, for OTP 29, and add its
`releases` and `lib` directories to a copy of `beam.com`:

```sh
cd examples/greeter
rebar3 release                      # include_erts is false in rebar.config
cd _build/default/rel/greeter
cp /path/to/beam.com greeter.com
zip -r greeter.com releases lib
sh ./greeter.com                    # on Windows: rename to greeter.exe
```

Examples (CI builds each one with rebar3 and runs it on every platform,
and also builds each one with `beam.com build` on every platform):

- [`examples/hashsum.erl`](examples/hashsum.erl): a one-file program
  (only for `beam.com build`).
- [`examples/wasm_check.erl`](examples/wasm_check.erl): WebAssembly and
  WASI, in a one-file program.
- [`examples/sqlite_check.erl`](examples/sqlite_check.erl): a one-file
  program with SQLite (only for `beam.com build`).
- [`examples/greeter`](examples/greeter): an application, a supervisor
  and a `gen_server`.
- [`examples/calc`](examples/calc): a scanner (`.xrl`), a parser (`.yrl`)
  and an ASN.1 module (only for `beam.com build`).
- [`examples/crypto_check`](examples/crypto_check): hashes, HMAC,
  AES-GCM and random bytes with `crypto`.
- [`examples/tls_check`](examples/tls_check): port programs, a local
  TLS 1.3 handshake, and an HTTPS request with certificate verification.

When BEAM.com starts, it reads `/zip/releases/start_erl.data`
(`ERTS_VSN REL_VSN`, written by rebar3/relx and by `systools`), and boots
the release like its start script does:

| File in the zip | Use |
| --- | --- |
| `releases/REL_VSN/start.boot` | `-boot`. Its code paths must start with `$ROOT` (rebar3 does this). |
| `releases/REL_VSN/sys.config` | `-config`, if the file is there. |
| `releases/REL_VSN/vm.args` | More flags, if the file is there. `#` starts a comment. Quotes and `-args_file` are not supported. |
| `lib/APP-VSN/ebin/*` | The code of the applications, `kernel` and `stdlib` too. |
| `.args` | Optional. More arguments, one on each line (redbean style). |

Other rules:

- The command line arguments are plain arguments for the program
  (`init:get_plain_arguments/0`). If `.args` has a `...` line, the command
  line arguments go there instead, as flags.
- `ERL_FLAGS` adds flags, as with `erl`. An argument that starts with `+`
  is an emulator flag (`+S 2` becomes `-S 2` before the first `--`).
- Without `-noshell` in `vm.args`, the release starts with a shell
  (like `console`).
- Set `BEAM_COM_VERBOSE=1` to see the full emulator command line.
- When the zip has no release and no `.args`, `beam.com` is a plain
  `beam.smp`.

## How it works

### Nothing is extracted

BEAM.com runs the code where it is: in the zip of its own file. ERTS
reads the `.beam` files, the boot script and the configuration from
`/zip/...`, the zip file system of Cosmopolitan, as from a directory.
There is no install step and no cache directory.

Tools such as [Burrito](https://github.com/burrito-elixir/burrito) and
Bakeware work in a different way: they unpack ERTS and the release to a
directory on the first run (one for each version), and then run the
files from there.

| | BEAM.com | Burrito, Bakeware |
|---|---|---|
| First start | the same as the next ones | unpacks to disk first |
| Files left on disk | none (see below) | the unpacked release, until you remove it |
| One file for | all the platforms and CPUs | one platform and CPU |
| NIFs | only the static NIFs in `beam.com` | any NIF of the release |
| Files in `priv/` | read from the zip; executables in `priv/` cannot run | normal files |
| The zip | read-only at run time | normal files |

What BEAM.com writes, and removes:

- When you start an APE file with `sh`, its shell header writes the
  small APE loader to `$TMPDIR/.ape-1.10` on the first run (Linux,
  macOS and the BSDs, not Windows). It stays there, for all APE files
  of that version. A Linux system with the loader registered in
  `binfmt_misc` does not need this.
- On Windows, the resolver settings and the certificates of Windows go
  to two files in the temp directory at start, which are removed at
  exit (see "Crypto and TLS").

### One file, many programs

An OTP installation has more than one executable. ERTS starts
`erl_child_setup` when it boots (it forks the port programs), and on
Linux the kernel starts `inet_gethost` at boot to resolve the host name.
BEAM.com links these programs into the emulator. It is a multi-call
binary, like BusyBox (see [`cosmo/beam_com.c`](cosmo/beam_com.c)).

When ERTS must execute a program in `/zip/bin/`, it executes its own
file (`GetProgramExecutableName()`) again, with
`BEAM_COM_PROGRAM=<program name>` in the environment
(`beam_com_exec_helper()`). The new process removes the variable and
runs that program. The base name of `argv[0]` is only a fallback,
because Linux `binfmt_misc` does not keep `argv[0]`.

### Crypto and TLS

`build.sh` builds a static `libcrypto` (OpenSSL 4.0.2, no assembly, so
the same C code compiles for x86_64 and aarch64), and OTP is configured
with `--enable-static-nifs`. ERTS selects a static NIF by the name of the
module that loads it, so the `crypto.beam` of a normal release uses the
NIF inside `beam.com` (the release does not need its `crypto.so`).

`public_key:cacerts_get/0` reads the certificates of the OS on Linux,
macOS and the BSDs. On Windows, `public_key` only reads the Windows store
for `os:type()` `{win32, _}`, so BEAM.com exports the trusted roots of
Windows (with `crypt32`) to a PEM file at start and gives it to
`public_key` with `-public_key cacerts_path File`.

### The zip of the default beam.com

```
bin/start_clean.boot, bin/no_dot_erlang.boot
bin/windows.inetrc                 resolver settings, used on Windows
lib/kernel-11.0.4/{ebin,include}/...
lib/stdlib-8.1/{ebin,include}/...
lib/.../                           sasl, compiler, crypto, asn1,
                                   public_key, ssl, inets
lib/beam_com/ebin/...              the commands (apps/beam_com)
lib/beam_com_script-0.1.0/ebin/... runs one-file programs
lib/wasm-0.1.0/ebin/...
```

There is no `releases/` directory: a release that you add brings its own.

The code of `kernel` and `stdlib` is stored in the zip without
compression. The boot loads these modules first, and a stored entry is
read without inflating it: this makes the start about 50 ms (about 27%)
faster, for 2 MB more (measured on Linux x86_64). `beam.com build`
keeps these entries as they are, so the programs that it makes start
faster too.

BEAM.com does the work of `erlexec`. It gives ERTS
`-root /zip -bindir /zip/bin -progname beam.com -home $HOME`, then the
release arguments, `ERL_FLAGS`, `.args` and the command line.

When the zip has `lib/beam_com` and no release (the default
`beam.com`), BEAM.com boots `start_clean` and runs `beam_com:main/0`,
which runs the command. With a release, only `build` does this, and the
other arguments go to the release.

### How `beam.com build` writes the new file

PKZIP keeps its index (the central directory) at the end of the file,
and in an APE file the offsets count from the start of the file. The
emulator also has zip entries of its own inside its image (symbol
tables, time zones, `.cosmo`), which must stay where they are. The
builder ([`apps/beam_com/src/beam_com_zip.erl`](apps/beam_com/src/beam_com_zip.erl))
keeps the bytes up to the first entry that it removes, moves the entries
after that point that it keeps, adds the new entries, and writes a new
central directory with the new offsets.

## Debugging

- `BEAM_COM_VERBOSE=1` shows the arguments that BEAM.com gives ERTS.
- The Cosmopolitan runtime flags work before all other arguments, on
  every platform: `beam.com --strace version` logs each system call
  (also on Windows and macOS), and `--ftrace` logs each C function
  call. The log goes to standard error.
- Crash reports: when the emulator dies on a fatal signal (for
  example `SIGSEGV`, or `SIGABRT` from `erlang:halt(abort)`), the
  Cosmopolitan runtime prints the signal, the registers and a backtrace
  with function names (from the symbol tables in the zip) to standard
  error, and the exit status is 128 + the signal number.
  `BEAM_COM_CRASH_REPORTS=0` turns this off. Signals that ERTS handles
  itself (`SIGINT`, `SIGUSR1`, `SIGTERM`, ...) do not change.

## Build

You need Linux (x86_64), `git`, `make`, `perl`, `curl`, `zip` and
`unzip`. The script downloads cosmocc (4.0.2), OpenSSL (4.0.2) and the
OTP source, applies the patches, builds a small OTP and makes
`build/beam.com`:

```sh
./build.sh
```

The steps are `toolchain openssl otp configure sqlite wasm make release
multicall bundle test` (`sqlite` does nothing with `SQLITE=0`, and
`wasm` does nothing with `WASM=0`). You can run one step or more, for example `./build.sh bundle test`.
See the top of [`build.sh`](build.sh) for the environment variables.

The OTP build runs the APE tools that it builds. If Linux cannot run
APE files directly, register the APE loader with `binfmt_misc` (see
[the workflow](.github/workflows/build.yml)).

### Changes to OTP

The OTP changes are small. Most of the port is in the configure
arguments and in a header that the compiler includes in each file
([`cosmo/erts_cosmo.h`](cosmo/erts_cosmo.h)).

| Change | Why |
| --- | --- |
| `--enable-jit` | BeamAsm with both backends (`docs/JIT.md`). `JIT=0` gives `--disable-jit`: the BEAM interpreter (`beam-emu.com`). |
| `--disable-kernel-poll`, `ac_cv_header_poll_h=no` | The `select()` back-end is used. The `POLL*` values of Cosmopolitan are not compile-time constants, and epoll/kqueue are not on all systems. |
| `--disable-esock` | The `socket` NIF needs BSD types that Cosmopolitan does not have. `gen_tcp` and `gen_udp` use `inet_drv`. |
| `erts_cv_linux_thp=no` | The 2 MiB page alignment for Linux breaks the APE layout. |
| monotonic clock = `CLOCK_MONOTONIC` | `CLOCK_UPTIME` is in the headers, but only works on BSD. |
| `ac_cv_func_sendfile=no` | `inet_drv` only knows the Linux, BSD and Solaris `sendfile()`. |
| `-DZSTD_DISABLE_ASM` | cosmocc does not compile the zstd `.S` file for two CPUs. |
| `DEP_CC=cosmo/depcc` | cosmocc does not support `-MM` with many input files. |
| `DED_LD=cosmo/noshared` (at configure time) | There are no shared objects. NIF `.so` files become placeholders, and the NIF configure tests link normal programs, not `-shared` ones. |
| `--enable-static-nifs`, `--with-ssl`, `--disable-dynamic-ssl-lib` | The `crypto` and `asn1` NIFs and `libcrypto` are linked into the emulator. |
| No `ERTS_LOW_WRITE` section | The APE linker script does not know this section. It made the PE `.data` section end after the file data, and `apelink` stopped with "PE SizeOfRawData overlaps end of image". |
| No reserve-then-commit `mmap` | On Windows, `mmap(MAP_FIXED)` in a `PROT_NONE` reservation fails, and ERTS stopped at boot. |
| `FD_SETSIZE` when `sysconf(_SC_OPEN_MAX)` fails | It fails with `EINVAL` on Windows. |
| Native `cmsghdr` layout in `sys_uds.c` | Cosmopolitan does not convert control messages for BSD and XNU, so no port program could start on macOS and the BSDs. |
| No forker on Windows | Cosmopolitan cannot pass fds on Windows, so port programs fail with `enotsup` there. |
| [`patches/otp/0001-cosmopolitan.patch`](patches/otp/0001-cosmopolitan.patch) | The items above that need source changes, the multi-call hooks, the `_Float16` conversion, and `gethostbyname_r` in `erl_interface`. |

## Continuous integration

[The workflow](.github/workflows/build.yml):

1. Builds `beam.com` on Ubuntu with cosmocc.
2. Builds the examples with a normal Erlang/OTP 29.1.1 and rebar3, and
   adds each one to a copy of `beam.com` with `zip`.
3. Runs `beam.com` and the examples ([`tests/run.sh`](tests/run.sh),
   [`tests/run.ps1`](tests/run.ps1)) on each platform. On each platform,
   it also builds the examples with `beam.com build` and runs the results.

`beam.com`, the example executables and the APE loader are build
artifacts of each run.

### Platform status

| Platform | How to run | beam.com, greeter | crypto | TLS | Port programs |
| --- | --- | --- | --- | --- | --- |
| Linux x86_64 | `sh ./beam.com` (or `./beam.com` with the APE loader in binfmt_misc) | ✅ | ✅ | ✅ | ✅ |
| Linux aarch64 | `sh ./beam.com` | ✅ | ✅ | ✅ | ✅ |
| macOS arm64 | `sh ./beam.com` | ✅ | ✅ | ✅ | ✅ |
| macOS x86_64 | `sh ./beam.com` | ✅ | ✅ | ✅ | ✅ |
| FreeBSD | `sh ./beam.com` | ✅ | ✅ | ✅ | ✅ |
| NetBSD | `ape-x86_64.elf ./beam.com` (its `sh` cannot read APE files) | ✅ | ✅ | ✅ | ✅ |
| OpenBSD 7.3 | `ape-x86_64.elf ./beam.com` | ✅ | ✅ | ✅ | ✅ |
| OpenBSD 7.9 | Not supported by Cosmopolitan (7.3 or earlier only) | ❌ | ❌ | ❌ | ❌ |
| Windows x86_64 | `beam.exe` (a copy with an `.exe` name) | ✅ | ✅ | ✅ | ❌ |

`ape-x86_64.elf` is the APE loader from cosmocc (`bin/ape-x86_64.elf`).
On NetBSD and OpenBSD, also install it where Cosmopolitan's `execve()`
looks for it (`/usr/bin/ape` or `~/.ape-1.10`): BEAM.com starts its
helper programs by executing itself, and without a loader Cosmopolitan
falls back to `sh`.

On Windows, `os:type()` is `{unix, windows}`, and port programs do not
work: `open_port({spawn, ...})`, `os:cmd/1` and native name lookups
fail with `enotsup` (see C16 in [`docs/UPSTREAM.md`](docs/UPSTREAM.md)).
At start, BEAM.com therefore gives kernel an inetrc with the name servers
and the hosts file of Windows, so that names are resolved with Erlang's
own DNS client (`ERL_INETRC` points at it; set `ERL_INETRC` yourself to
use your own file), and it exports the trusted root certificates of
Windows to a PEM file that `public_key:cacerts_get/0` reads
(`-public_key cacerts_path File`; give that parameter yourself to use
your own file). Both files are in the temp directory of the user and
are removed when the node stops.

## Tests

Unit tests with coverage (`./build.sh unit`), behavior tests that run in
`beam.com` on each platform (`tests/run.sh`, `tests/run.ps1`), and how
to test without CI: see [`docs/TESTING.md`](docs/TESTING.md).

Benchmarks (size, start time, and the speed of typical work, for each
variant, such as the interpreter against the JIT): see
[`docs/BENCHMARKS.md`](docs/BENCHMARKS.md).

## Notes for upstream

[`docs/UPSTREAM.md`](docs/UPSTREAM.md) records what did not work with
Cosmopolitan and with the OTP build, with small reproducers, the
workaround in BEAM.com, and a possible upstream fix for each item.

## Known limits

- No `socket` NIF, no NIFs or drivers in shared objects
  (Cosmopolitan cannot make them). Only the static NIFs in `beam.com`
  work (`crypto`, `asn1`, `wasm` and `esqlite`).
- WebAssembly: interpreter only (no AOT or JIT), WASI preview 1 only, no
  SIMD, no threads, and no component model yet.
- No distribution: `epmd` is not included, so `-sname`/`-name` do not work.
- Windows: no port programs (no `os:cmd/1`, no `inet_gethost`; names
  are resolved with Erlang's DNS client, IPv4 name servers only).
- `run_erl` does not work (there is no `mkfifo()`).
- A release that you add with `zip` brings the applications that it
  needs, when they are not in the zip of `beam.com` (pure Erlang ones
  only).
- A release must be for the same OTP as `beam.com` (29.1.1). BEAM.com
  writes a warning when `start_erl.data` names another ERTS version.
- `beam.com build` takes only Hex packages (no git dependencies), and it
  does not compile Elixir.

## Roadmap

See [`docs/ROADMAP.md`](docs/ROADMAP.md): `beam.com build` (no Erlang
installation needed), SQLite, WebAssembly (WAMR, WASI) and a JIT
probe.
