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
$ sh ./beam.com hello world
Hello, World! from BEAM.com
  OTP release : 29
  ERTS version: 17.1
  OS type     : unix/linux
  Architecture: x86_64-pc-linux-gnu
  Schedulers  : 2
  Release     : "/zip/releases/0.1.0/start"
  Arguments   : ["hello","world"]
```

The default `beam.com` holds a small `hello` release
([`hello/`](hello)). Erlang/OTP version: **29.1.1**.

`crypto` and `ssl` work: the `crypto` and `asn1` NIFs are linked into
`beam.com` with a static OpenSSL 3.5.8, and TLS connections verify the
server with the certificates of the OS (on Windows too).

## Build a program with `beam.com build`

```sh
beam.com build INPUT [-o OUTPUT] [-a APP]...
```

`INPUT` is one of these:

- **One `.erl` file** that exports `main/1`, as for `escript`. The
  program gets the command line arguments, and halts with status 0 when
  `main/1` returns (127 on an exception).
- **An application directory**: `src/*.erl` (subdirectories too),
  `src/NAME.app.src` or `ebin/NAME.app`, and optionally `include/`,
  `priv/`, `config/sys.config`, `config/vm.args` (the rebar3 layout) and
  the `erl_opts` of `rebar.config`. Dependencies are not fetched yet.

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
`crypto`, `asn1`, `public_key`, `ssl` and `inets`.

### SQLite (probe)

Build with `SQLITE=1 ./build.sh` to link SQLite 3.50.4 (the
[esqlite](https://github.com/mmzeeman/esqlite) NIF) into `beam.com` and
to put the `esqlite` application in its zip. CI makes this variant as
`beam-sqlite.com`. It adds about 1.8 MB to each program.

```sh
beam-sqlite.com build examples/sqlite_check.erl
./sqlite_check.com my.db
```

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
- [`examples/sqlite_check.erl`](examples/sqlite_check.erl): a one-file
  program with SQLite (for `beam-sqlite.com build`).
- [`examples/greeter`](examples/greeter): an application, a supervisor
  and a `gen_server`.
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

`build.sh` builds a static `libcrypto` (OpenSSL 3.5.8, no assembly, so
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
lib/beam_com/ebin/...              the "build" command (apps/beam_com)
lib/beam_com_script-0.1.0/ebin/... runs one-file programs
lib/hello-0.1.0/ebin/...
releases/start_erl.data            "17.1 0.1.0"
releases/0.1.0/start.boot          made with systools (tools/make_boot.escript)
releases/0.1.0/sys.config
releases/0.1.0/vm.args
```

BEAM.com does the work of `erlexec`. It gives ERTS
`-root /zip -bindir /zip/bin -progname beam.com -home $HOME`, then the
release arguments, `ERL_FLAGS`, `.args` and the command line.

When the first argument is `build` and the zip has `lib/beam_com`,
BEAM.com boots `start_clean` and runs `beam_com:main/0` instead of the
release.

### How `beam.com build` writes the new file

PKZIP keeps its index (the central directory) at the end of the file,
and in an APE file the offsets count from the start of the file. The
emulator also has zip entries of its own inside its image (symbol
tables, time zones, `.cosmo`), which must stay where they are. The
builder ([`apps/beam_com/src/beam_com_zip.erl`](apps/beam_com/src/beam_com_zip.erl))
keeps the bytes up to the first entry that it removes, moves the entries
after that point that it keeps, adds the new entries, and writes a new
central directory with the new offsets.

## Build

You need Linux (x86_64), `git`, `make`, `perl`, `curl`, `zip` and
`unzip`. The script downloads cosmocc (4.0.2), OpenSSL (3.5.8) and the
OTP source, applies the patches, builds a small OTP and makes
`build/beam.com`:

```sh
./build.sh
```

The steps are `toolchain openssl otp configure sqlite make release
multicall bundle test` (`sqlite` does nothing without `SQLITE=1`). You can run one step or more, for example `./build.sh bundle test`.
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
| `--disable-jit` | The BEAM interpreter is used. The JIT is a possible next step. |
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

## Notes for upstream

[`docs/UPSTREAM.md`](docs/UPSTREAM.md) records what did not work with
Cosmopolitan and with the OTP build, with small reproducers, the
workaround in BEAM.com, and a possible upstream fix for each item.

## Known limits

- No JIT, no `socket` NIF, no NIFs or drivers in shared objects
  (Cosmopolitan cannot make them). Only the static NIFs in `beam.com`
  work (`crypto`, `asn1`).
- No distribution: `epmd` is not included, so `-sname`/`-name` do not work.
- Windows: no port programs (no `os:cmd/1`, no `inet_gethost`; names
  are resolved with Erlang's DNS client, IPv4 name servers only).
- `run_erl` does not work (there is no `mkfifo()`).
- A release that you add with `zip` brings the applications that it
  needs, when they are not in the zip of `beam.com` (pure Erlang ones
  only).
- A release must be for the same OTP as `beam.com` (29.1.1). BEAM.com
  writes a warning when `start_erl.data` names another ERTS version.
- `beam.com build` does not fetch dependencies (Hex packages) yet, and
  it does not compile Elixir, `.yrl`/`.xrl` or `.asn1` files.

## Roadmap

See [`docs/ROADMAP.md`](docs/ROADMAP.md): `beam.com build` (no Erlang
installation needed), a SQLite probe, WebAssembly (WAMR, WASI) and a
JIT probe.
