# BEAM.com

BEAM.com is an experiment: the Erlang/OTP runtime system (ERTS) as one
[Actually Portable Executable](https://justine.lol/ape.html) (APE),
made with [Cosmopolitan Libc](https://github.com/jart/cosmopolitan).

It uses the "redbean style": the executable is also a zip file. You add
an Erlang release to the zip, and the one file runs your release on
Linux, macOS, Windows and the BSDs, on x86_64 and aarch64.

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

[`examples/greeter`](examples/greeter) is a complete example with an
application, a supervisor and a `gen_server`.

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

### The zip of the default beam.com

```
bin/start_clean.boot, bin/no_dot_erlang.boot
lib/kernel-11.0.4/ebin/...
lib/stdlib-8.1/ebin/...
lib/hello-0.1.0/ebin/...
releases/start_erl.data            "17.1 0.1.0"
releases/0.1.0/start.boot          made with systools (tools/make_boot.escript)
releases/0.1.0/sys.config
releases/0.1.0/vm.args
```

BEAM.com does the work of `erlexec`. It gives ERTS
`-root /zip -bindir /zip/bin -progname beam.com -home $HOME`, then the
release arguments, `ERL_FLAGS`, `.args` and the command line.

## Build

You need Linux (x86_64), `git`, `make`, `perl`, `curl`, `zip` and
`unzip`. The script downloads cosmocc (4.0.2) and the OTP source,
applies the patches, builds a small OTP and makes `build/beam.com`:

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
| `DEP_CC=cosmo/depcc` | cosmocc does not support `-MM` with many input files. |
| `DED_LD=cosmo/noshared` | There are no shared objects. NIF `.so` files become placeholders. |
| No `ERTS_LOW_WRITE` section | The APE linker script does not know this section. It made the PE `.data` section end after the file data, and `apelink` stopped with "PE SizeOfRawData overlaps end of image". |
| [`patches/otp/0001-cosmopolitan.patch`](patches/otp/0001-cosmopolitan.patch) | The items above that need source changes, the multi-call hooks, the `_Float16` conversion, and `gethostbyname_r` in `erl_interface`. |

## Continuous integration

[The workflow](.github/workflows/build.yml):

1. Builds `beam.com` on Ubuntu with cosmocc.
2. Builds `examples/greeter` with a normal Erlang/OTP 29.1.1 and rebar3,
   and adds it to a copy of `beam.com` with `zip` (`greeter.com`).
3. Runs both files ([`tests/run.sh`](tests/run.sh),
   [`tests/run.ps1`](tests/run.ps1)) on:
   Linux x86_64 and aarch64, macOS arm64 and x86_64, Windows x86_64,
   and FreeBSD, NetBSD and OpenBSD (in VMs).

`beam.com` and `greeter.com` are build artifacts of each run.

## Notes for upstream

[`docs/UPSTREAM.md`](docs/UPSTREAM.md) records what did not work with
Cosmopolitan and with the OTP build, with small reproducers, the
workaround in BEAM.com, and a possible upstream fix for each item.

## Known limits

- No JIT, no `socket` NIF, no crypto/ssl, no NIFs or drivers in shared
  objects (Cosmopolitan cannot make them).
- No distribution: `epmd` is not included, so `-sname`/`-name` do not work.
- `run_erl` does not work (there is no `mkfifo()`).
- Only kernel and stdlib are in the default zip. A release brings the
  other applications that it needs (pure Erlang ones only).
