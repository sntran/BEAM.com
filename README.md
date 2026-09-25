# BEAM.com

BEAM.com is the Erlang/OTP runtime system (ERTS) as one
[Actually Portable Executable](https://justine.lol/ape.html) (APE),
made with [Cosmopolitan Libc](https://github.com/jart/cosmopolitan).

It uses the "redbean style": the executable is also a zip file. The
OTP libraries, the boot script, your `.beam` files and an `.args` file
are in the zip. At run time, ERTS reads them from `/zip/...`. You
copy one file to a computer, and it runs.

This first version runs a small hello world module
([`hello/hello.erl`](hello/hello.erl)).

```
$ sh ./beam.com one two
Hello, World! from BEAM.com
  OTP release : 28
  ERTS version: 16.4
  OS type     : {unix,linux}
  Architecture: x86_64-pc-linux-gnu
  Schedulers  : 4
  Arguments   : ["one","two"]
```

## How it works

### One file, many programs

An OTP installation has more than one executable. ERTS starts
`erl_child_setup` when it boots (it forks the port programs), and the
kernel starts `inet_gethost` for name resolution. BEAM.com links these
programs into the emulator. It is a multi-call binary, like BusyBox:
the base name of `argv[0]` selects the program
(see [`cosmo/beam_com.c`](cosmo/beam_com.c)).

When ERTS must execute a program in `/zip/bin/`, it executes its own
file (`GetProgramExecutableName()`) with that program name as `argv[0]`
(see `beam_com_exec_path()` in [`cosmo/erts_cosmo.h`](cosmo/erts_cosmo.h)).

### The zip

```
/zip/.args                         arguments, one on each line
/zip/bin/start.boot                boot scripts from "Install -minimal"
/zip/bin/start_clean.boot
/zip/bin/no_dot_erlang.boot
/zip/lib/kernel-*/ebin/*.beam
/zip/lib/stdlib-*/ebin/*.beam
/zip/lib/hello-1.0/ebin/hello.beam
```

BEAM.com does the work of `erlexec`. It gives ERTS
`-root /zip -bindir /zip/bin -progname beam.com -home $HOME`, and then
the lines of `/zip/.args`:

- Each line is one argument. Empty lines and lines that start with `#`
  are ignored.
- A `...` line is replaced by the command line arguments. If there is
  no `...` line, the command line arguments go at the end.
- An argument that starts with `+` is an emulator flag, as with `erl`
  (`+S 2` becomes `-S 2` before the first `--`).
- Set `BEAM_COM_VERBOSE=1` to see the full command line.

If the executable has no `/zip/.args`, it is a plain `beam.smp`.

To change the program, change the zip. For example, with Info-ZIP:

```sh
mkdir -p lib/myapp-1.0/ebin
erlc -o lib/myapp-1.0/ebin myapp.erl
printf -- '-noshell\n-s\nmyapp\nmain\n' > .args
zip beam.com .args lib/myapp-1.0/ebin/myapp.beam
```

## Build

You need Linux (x86_64), `git`, `make`, `perl`, `curl`, `zip` and
`unzip`. The script downloads cosmocc and the OTP source, applies the
patches, builds a small OTP and makes `build/beam.com`:

```sh
./build.sh
```

The steps are `toolchain otp configure make release multicall bundle
test`. You can run one step or more, for example `./build.sh bundle test`.
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
| `ERTS_SKIP_DEPEND=true` | cosmocc does not support `-MM` with many input files. |
| [`patches/otp/0001-cosmopolitan.patch`](patches/otp/0001-cosmopolitan.patch) | Multi-call hooks, the `_Float16` conversion, zstd, `gethostbyname_r`. |

## Continuous integration

[The workflow](.github/workflows/build.yml) builds `beam.com` on
Ubuntu, and then runs the same file on:

- Linux x86_64 and aarch64
- macOS arm64 and x86_64
- Windows x86_64
- FreeBSD, NetBSD and OpenBSD (in VMs)

Each run must print `Hello, World!`. The `beam.com` file is a build
artifact of each run.

## Known limits

- No JIT, no `socket` NIF, no crypto/ssl, no dynamic NIFs or drivers.
- No distribution: `epmd` is not included.
- Only kernel and stdlib are in the zip.
