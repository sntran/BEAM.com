# Run and build programs

This file is the manual of `beam.com INPUT` (run a program) and
`beam.com INPUT -o OUTPUT` (make an executable of it). For Elixir and
Phoenix, see [`ELIXIR.md`](ELIXIR.md). For Cloudflare Workers, see
[`WORKERS.md`](WORKERS.md).

## The command line

```sh
beam.com [FLAGS] [INPUT] [-- ARGUMENTS]    # run INPUT (default: the project here)
beam.com [FLAGS] INPUT -o OUTPUT           # make the executable OUTPUT

FLAGS: [-a APP]... [--allow-read[=PATH,...]] [--allow-write[=PATH,...]]
       [--allow-net] [--allow-run[=PROGRAM,...]] [--allow-all]
       [--target TARGET] [--main MODULE] [--tool rebar|mix]
       [--extract-priv APP]... [--cacerts FILE]
```

There is one command line, as for `npm run`: the flags can come before
or after `INPUT`, and the arguments of the program come after `--`.
`beam.com app.erl -- one two` runs `app.erl` with the arguments `one`
and `two`; `beam.com app.erl -o app.com` makes `app.com`. A run makes
the same executable in the cache of BEAM.com (`BEAM_COM_CACHE`, else
`~/.cache/beam.com/run`), again only when a file of `INPUT` is newer,
and runs it: the program gets the terminal, and its exit status is the
exit status of `beam.com`. In a directory with `mix.exs`,
`rebar.config` or `src/`, `beam.com` alone runs that project.

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
  modules that other files name in `-behaviour` or as a
  `parse_transform` are compiled first, as rebar3 does. The `deps` of
  `rebar.config` are Hex packages (see below). An application can also
  have an entry, as an escript: see "Command line programs" below.
- **One Elixir file** (`.ex` or `.exs`) in which one module exports
  `main/1`, or **a Mix project** (`mix.exs`): see
  [`ELIXIR.md`](ELIXIR.md).
- **A release directory** without ERTS (from `mix release` or rebar3):
  see "One file, natively and at the edge" in [`WORKERS.md`](WORKERS.md).

The builder compiles the code, selects the OTP applications that the
program needs, makes an OTP release with `systools`, and writes a copy of
`beam.com` with the release in its zip (`OUTPUT`). The new file does
not have the compiler, only what the program needs.

The applications are the ones that the `.app` file names, the ones of
the modules that the code calls (from the imports of the compiled code),
and all the applications that these need. Use `-a APP` for an
application that the code only calls with `apply/3` or similar.

The zip of `beam.com` has these applications:

- OTP: `kernel`, `stdlib`, `sasl`, `compiler`, `parsetools`, `crypto`,
  `asn1`, `public_key`, `ssl`, `inets`, `xmerl` and `runtime_tools`.
- Elixir: `elixir`, `eex`, `ex_unit`, `iex`, `logger` and `mix`.
- BEAM.com: `wasm` (WebAssembly), `esqlite` (SQLite), `wasm_host` (for
  the WebAssembly runtime) and `beam_com_script` (for one-file programs).

A custom build can add more OTP applications: open an issue with the form
[A custom build of beam.com](https://github.com/sntran/BEAM.com/issues/new?template=custom_build.yml),
and CI builds the file for you (see "A custom build" in
[`BUILDING.md`](BUILDING.md)).

## Hex packages

The `deps` of `rebar.config` are fetched from [hex.pm](https://hex.pm)
and compiled into the program, as rebar3 does, without rebar3:

```erlang
{deps, [{cowboy, "~> 2.13"},       % a Hex requirement
        {jsx, "3.1.0"},            % this version only
        recon,                     % the highest version
        {mylib, "~> 1.0", {pkg, my_lib}}]}.  % another package name
```

- **Versions.** When `rebar.lock` has all the deps, its versions are
  used, and nothing is resolved. Otherwise the builder takes the
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
- **Not supported:** git and other sources, NIFs (C code) and rebar3
  plugins or hooks. Elixir packages (Mix) are supported: see
  [`ELIXIR.md`](ELIXIR.md).

[`examples/hexweb`](../examples/hexweb) uses cowboy (with cowlib and
ranch) and jsx: it starts a web server and gets JSON from it. CI builds
it on each platform, two times (with and without `rebar.lock`).

## Command line programs: `--main`, `priv` files and erl mode

An application directory can be a command line program, as an escript
made with `rebar3 escriptize` or `mix escript.build`. The builder takes
the module whose `main/1` runs:

- `--main MODULE`, or
- `rebar.config`: `-escript main MODULE` in `escript_emu_args`, else
  `escript_main_app` (the module with the name of the application), or
- `mix.exs`: `escript: [main_module: MODULE]`.

The release starts all the applications first; then `MODULE:main/1`
gets the command line arguments (as strings; as binaries for an Elixir
module), and the program halts with status 0 when `main/1` returns (127
on an exception), as for one `.erl` file. `vm.args` gets
`-s beam_com_script main MODULE`. A directory with both `rebar.config`
and `mix.exs` is built as a rebar3 project; `--tool mix` selects Mix.

**`priv` files as real files.** Code reads `priv` from the zip
(`code:priv_dir/1` is in `/zip`), which works for `file:read_file/1`,
but other programs (`sh`, a port program, a tool that gets a path)
cannot read `/zip`. When the `priv` directory of an application has an
executable file, or `--extract-priv APP` names the application, the
program copies that `priv` directory at its first start to
`CACHE/priv/HASH/APP-VSN/priv` (read-only files; the executables stay
executable), and `code:priv_dir(APP)` is then that directory. The code
stays in the zip. `HASH` is from the files, so a new build gets a new
directory, and the next starts use the copy. `CACHE` is
`$BEAM_COM_CACHE`, else the user cache directory
(`filename:basedir(user_cache, "beam.com")`: `~/Library/Caches/beam.com`
on macOS, `$XDG_CACHE_HOME/beam.com` or `~/.cache/beam.com` on the other
systems, Windows too).

**erl mode.** A program that starts a new Erlang VM (a peer node, a
worker in a sandbox) can start its own file: each program has
`-beam_com_exe PATH` (`init:get_argument(beam_com_exe)`), the path of
its file. When the file is started with `BEAM_COM_ERL=1` in the
environment, or through a link named `erl`, all the arguments are for
`erl`, and the VM starts with the `start_clean` boot and the
applications of the zip in the code path, not with the release:

```erlang
{ok, [[Exe]]} = init:get_argument(beam_com_exe),
Port = open_port({spawn_executable, Exe},
                 [{env, [{"BEAM_COM_ERL", "1"}]},
                  {args, ["-noinput", "-eval", "worker:start()"]}]).
```

(`{arg0, "erl"}` is not enough: when the kernel cannot start an APE
file, Cosmopolitan starts it with the APE loader, which gives the path
of the file as `argv[0]`.)

[`examples/toolbox`](../examples/toolbox) shows the three: its `main/1`
comes from `rebar.config`, it runs a shell script from `priv`, and it
starts itself again as `erl`.

## A native file for one system (`--target`)

`--target TARGET` writes a file for one system instead of an APE file,
as Cosmopolitan's `assimilate` does. `TARGET` is a target triple, as for
`deno compile --target` and Rust (or the shorter name of Zig):

| `TARGET` | Short name | System |
|---|---|---|
| `x86_64-unknown-linux-gnu` | `x86_64-linux` | Linux, x86_64 |
| `aarch64-unknown-linux-gnu` | `aarch64-linux` | Linux, aarch64 |
| `x86_64-unknown-freebsd` | `x86_64-freebsd` | FreeBSD, x86_64 |
| `x86_64-apple-darwin` | `x86_64-macos` | macOS, Intel |

```sh
beam.com hello.erl --target x86_64-linux -o hello
./hello
```

Without `--target`, the file is an APE file for all the systems.

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

The new file is a copy of the file that builds it. So build with the
APE file of `beam.com` (or a copy of it, such as `beam.exe`). A native
file, made with `--target` or with `--assimilate`, gives only native
files:

- Without `--target`, a build (`-o`) stops with an error: the program would
  run only on this system, and you did not ask for that. For example:
  `beam-elf.com: this is a native file (ELF, x86_64), not an APE file:
  a program built from it runs only on this system. Build with the APE
  file of beam.com, or give --target to make a native file`.
- With a `--target` of the same CPU and format (for example
  `x86_64-linux` from an assimilated file on Linux x86_64), the build
  writes a native file for that target.
- With another `--target`, the build stops with an error.

## Distributed Erlang and remote shells

Distributed Erlang works as with `erl`: the flags `-sname`, `-name` and
`-remsh` turn it on, and only then the file starts `epmd` (it is in the
file too, as `erlexec` starts it: `epmd -daemon`, unless `-start_epmd
false`). Without these flags, no `epmd` starts and no port is opened.

`beam.com` takes the flags of `erl`, so it is also the client:

```sh
beam.com -sname dev                              # a shell in a new node
beam.com -sname me -setcookie SECRET -remsh app  # a shell in the node app
beam.com epmd -names                             # the nodes on this computer
```

A program whose release has a node name (`-sname` or `-name` in
`config/vm.args`) has the `remote` command of the scripts of rebar3 and
`mix release`: a shell in the running node, with the cookie of the same
`vm.args`. There you can inspect the node and load new code into it (for
example `c:l(Module)`, or `code:load_binary/3`):

```sh
beam.com examples/counter -o counter.com   # config/vm.args: -sname counter
./counter.com &
./counter.com remote
(counter@host)1> counter:incr().
```

As in every remote shell, `halt()` there stops the node of the program;
leave the shell with Ctrl-G then `q`, or with Ctrl-C two times.

The graphical `observer` needs `wx`, which is not in `beam.com`; start
it in an Erlang installation and connect to the node, or use the shell.

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

CI builds `examples/greeter` in this way, with rebar3, and runs it on
each platform.

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

## Debugging

- `BEAM_COM_VERBOSE=1` shows the arguments that BEAM.com gives ERTS.
- The Cosmopolitan runtime flags work before all other arguments, on
  every platform: `beam.com --strace --version` logs each system call
  (also on Windows and macOS), and `--ftrace` logs each C function
  call. The log goes to standard error.
- Crash reports: when the emulator dies on a fatal signal (for
  example `SIGSEGV`, or `SIGABRT` from `erlang:halt(abort)`), the
  Cosmopolitan runtime prints the signal, the registers and a backtrace
  with function names (from the symbol tables in the zip) to standard
  error, and the exit status is 128 + the signal number.
  `BEAM_COM_CRASH_REPORTS=0` turns this off. Signals that ERTS handles
  itself (`SIGINT`, `SIGUSR1`, `SIGTERM`, ...) do not change.
