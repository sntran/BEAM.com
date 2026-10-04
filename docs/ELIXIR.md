# Elixir, its tools, and Phoenix

`beam.com` has Elixir 1.20.4. It builds Elixir programs, and it is
also an Elixir installation in one file: `mix`, `iex`, `elixir`,
`elixirc` and `escript`.

## Elixir programs

Elixir is compiled with the Erlang/OTP 29.1.1 of `beam.com`, and its beam
files have no debug information: 2.8 MB in the zip, with the docs for
`h/1` in `iex`. So `beam.com INPUT -o OUTPUT` compiles Elixir code
without an Elixir installation:

```sh
beam.com hello.ex -o hello.com         # one file; a module exports main/1
beam.com my_project -o my_project.com  # a Mix project (mix.exs)
beam.com hello.ex -- Alice             # or run it
```

- **One file** (`.ex` or `.exs`): the modules of the file, and the one
  that exports `main/1` runs; it gets the arguments as binaries (as
  `System.argv/0`). An exception is printed in the format of Elixir, and
  the status is 127.
- **A Mix project**: `mix.exs` is read with Mix, in the `:prod`
  environment (the Mix tool is not used): `:app`, `:version`, `:deps`,
  `:elixirc_paths` (`lib`) and `:erlc_paths` (`src`) of `project/0`,
  and `:mod`, `:extra_applications`, `:applications`, `:env` and
  `:registered` of `application/0`. The Erlang files are compiled
  first, then the Elixir files. `config/config.exs` becomes the
  `sys.config` of the release (with `Config.Reader`, env `:prod`).
- **Deps** are Hex packages, in Erlang (rebar3, make) or in Elixir (Mix),
  as for rebar3 projects (see "Hex packages" in
  [`PROGRAMS.md`](PROGRAMS.md)), with `mix.lock` (in the
  format of Mix) in place of `rebar.lock`. Deps `only: :dev` or
  `:test` and `optional: true` are left out; `runtime: false` deps are
  compiled, but they are not in the applications of the program.
- A program gets only the Elixir applications that it uses: `elixir`,
  with `compiler` (which Elixir needs at run time), makes a program
  1.9 MB larger than the same program in Erlang, and its start about
  40 ms slower ([`BENCHMARKS.md`](BENCHMARKS.md)).
- **Not supported:** umbrella projects, `config/runtime.exs`, protocol
  consolidation (protocols work, but their dispatch is not optimized),
  and Mix tasks or aliases.

[`examples/greeter_ex`](../examples/greeter_ex) is a Mix project with jason
(a Hex package in Elixir) and `config/config.exs`;
[`tests/programs/elixir_check.ex`](../tests/programs/elixir_check.ex) is a
one-file program. CI builds and runs both on each platform.

## The tools: `mix`, `iex`, `elixir`, `elixirc` and `escript`

`beam.com` is also an Elixir installation in one file. Give the file
the name of a tool, and it is that tool. The names `mix.com`, `iex.com`,
`elixir.com` and `elixirc.com` are the same file as `beam.com`:

```sh
cp beam.com mix.com                 # or a link: ln beam.com mix.com
./mix.com new hello && cd hello
../mix.com test
../iex.com -S mix                   # iex.com: another copy or link
../elixir.com -e 'IO.puts(1 + 2)'
../elixirc.com lib/hello.ex -o ebin
```

The name can also be without `.com` (`mix`), or with `.exe` on Windows
(`mix.exe`). The tool can also be the first argument of `beam.com`:
`beam.com mix test`, `beam.com iex -S mix`.

- They run as the scripts of Elixir run them (`-s elixir start_cli`,
  `+iex`, `+elixirc`), with the applications of the zip: `elixir`,
  `eex`, `ex_unit`, `iex`, `logger` and `mix`, with their docs (`h/1` in
  `iex`). `iex -S mix` and `elixir -S mix` use the `mix` script of the
  zip.
- `escript FILE` runs an escript, as the `escript` program of OTP, with
  the flags of its `%%!` line. Escripts from `mix escript.build` run
  with it.
- Packages: `mix local.hex` installs Hex, and `mix deps.get` then
  fetches from hex.pm. For Erlang packages, `mix local.rebar` installs
  rebar3, which Mix runs as an escript: put a link named `escript` in
  `PATH`. On NetBSD, where `sh` stops at the first NUL byte of an APE
  file, make `escript` a small script instead:
  `exec /path/to/ape-x86_64.elf /path/to/beam.com escript "$@"`.
  `beam.com INPUT -o OUTPUT` does not need Hex or rebar3.
- A custom build can have Hex and rebar3 in the file, so `mix deps.get`
  needs no `mix local.hex` or `mix local.rebar`. Open an issue with the
  form
  [A custom build of beam.com](https://github.com/sntran/BEAM.com/issues/new?template=custom_build.yml),
  and CI builds the file for you (see [`BUILDING.md`](BUILDING.md)).
- `ELIXIR_ERL_OPTIONS` and `ERL_FLAGS` give flags to the VM.
- To build an Elixir project into one file, use `beam.com INPUT -o OUTPUT` (see
  "Elixir programs" above), not a Mix task.
- `mix release` works with `include_erts: false`. Use its directory with
  `--target wasm32`, or add it to a copy of `beam.com` (see "Add your
  release" in [`PROGRAMS.md`](PROGRAMS.md)). With `include_erts: true`
  (the default), it stops: it copies ERTS from the disk, and there is
  none.
- **Not supported:** the options of
  the Elixir scripts that change the `erl` command (`--erl`, `--sname`,
  `--name`, `--cookie`, `--pipe-to`; give the flags of `erl` in
  `ELIXIR_ERL_OPTIONS` instead, for example `-sname dev`). On
  Windows, there are no port programs: Mix tasks that start other
  programs (rebar3, git) do not work.

### Make your own tools

You make the tool files yourself from `beam.com`, and only the tools
that you need. A tool file is `beam.com` under the name of the tool, so
a copy, a hard link or a symbolic link is enough:

```sh
# Only mix and iex, in ~/bin:
cp beam.com ~/bin/mix.com
ln ~/bin/mix.com ~/bin/iex.com      # a hard link: no second copy on disk

# All the tools, as with an installation (Linux, macOS and the BSDs):
for tool in mix iex elixir elixirc escript; do ln -s beam.com ~/bin/$tool; done
mix test
```

On Windows, copy `beam.com` to `mix.exe`, `iex.exe`, `elixir.exe` or
`elixirc.exe`, or make hard links with `mklink /H mix.exe beam.com`.

## Phoenix from source

With the tools, a Phoenix project runs from its source, as with an
Elixir installation, but without Erlang, Elixir or a C compiler on the
computer. This includes SQLite and `phx.gen.auth`:

```sh
mix.com local.hex --force
mix.com archive.install hex phx_new
mix.com phx.new hello --database sqlite3
cd hello
mix.com deps.get
mix.com phx.gen.auth Accounts User users
mix.com deps.get
mix.com ecto.migrate             # or ecto.setup
iex.com -S mix phx.server        # http://localhost:4000
```

- `beam.com` has the OTP applications that a new Phoenix app needs
  beyond Elixir: `xmerl` (for `swoosh`) and `runtime_tools`. It also
  has `tools`, for `mix test --cover`.
- The NIFs of `exqlite` 0.41.0 (for `ecto_sqlite3`), `bcrypt_elixir`
  3.3.2 (for `phx.gen.auth`) and `argon2_elixir` 4.1.3 (for
  `phx.gen.auth --hashing-lib argon2`) are linked into `beam.com`, as
  static NIFs (see "SQLite" in [`LIBRARIES.md`](LIBRARIES.md)). The packages from hex.pm work unchanged: ERTS finds a
  static NIF by the name of its module, before it opens the file in
  `priv`, so the NIF files are not needed.
- These packages compile with `elixir_make`, which runs `make`. The
  tools set `MAKE` (when it is not set) to a program `make` in the cache
  of BEAM.com: a link to the file (on macOS, a script that runs it).
  This `make` does nothing for `exqlite`, `bcrypt_elixir` and
  `argon2_elixir`, and runs
  the `make` of `PATH` for other packages with C code (an error when
  there is none). The tools also set `EXQLITE_USE_SYSTEM=1`, so that
  `exqlite` uses the SQLite of `beam.com` and does not download a
  compiled NIF.
- The version of these packages must be the version of their NIF in
  `beam.com` ("Linked NIFs" in `beam.com --version`): `beam.com` always
  uses its NIF. With another version, `mix compile` stops with an error
  that tells what to put in the deps of `mix.exs` (for example
  `{:exqlite, "0.41.0"}`).
- The esbuild and tailwind watchers download their programs and run
  them as ports, as they do with Elixir (not on Windows, which has no
  port programs here).
- Live reload works without `inotify-tools`: the tools set
  `FILESYSTEM_FSINOTIFY_EXECUTABLE_FILE` (read by `file_system`) to the
  file watcher of the file (see "The file watcher"), on Linux and the
  BSDs. On macOS, they set `FILESYSTEM_FSMAC_EXECUTABLE_FILE`, so that
  `file_system` does not compile its own watcher (which needs the
  command line tools of Xcode).
- PostgreSQL (`--database postgres`, the default) uses Postgrex, which
  is Elixir only. Other databases with a NIF, and other packages with C
  code, need `make` and a C compiler, and a NIF that `beam.com` can load:
  a static NIF of a custom build, or a NIF library in WebAssembly
  (`priv/NAME.wasm`, see [`NIFS.md`](NIFS.md)).
- Not on Windows (no port programs, so `elixir_make` cannot run) and
  not on NetBSD (its kernel does not start an APE file by a link; set
  `MAKE` to a script that starts `beam.com` with the APE loader and
  `BEAM_COM_PROGRAM=make`).

CI runs these steps on Linux: `phx.new --database sqlite3`,
`phx.gen.auth`, `deps.get`, `ecto.migrate`, an account with a password
(bcrypt) through `mix run`, and `iex.com -S mix phx.server`, which must
serve the start page and make a new account (a POST of the registration
form). With the network, the check of the tools also compiles `exqlite`,
`bcrypt_elixir` and `argon2_elixir` in a small project (on all the
platforms but NetBSD and Windows), checks that no NIF file was built or downloaded, and uses
esqlite and exqlite in one VM.

## The file watcher

The file has a file watcher with the command line and the output of
`inotifywait` (of inotify-tools), for the programs that use it, such as
`file_system` and so `phoenix_live_reload`:

```sh
beam.com inotifywait -m -r -e create -e modify -e delete --format '%w %e %f' lib
```

- On Linux it uses inotify. On the BSDs it compares the files (a move is
  then `DELETE` and `CREATE`): at once when kqueue sees a change in a
  watched directory or file, and every half second. When there are too
  many files for the descriptors (half of the open file limit, at most
  4096), the directories are watched first, and the interval finds the
  other changes. When kqueue fails, only the interval is used.
- On macOS, `file_system` uses `mac_listener` (with FSEvents) in place of
  `inotifywait`. The file is also `mac_listener`, with the same command
  line and output, and it compares the files as on the BSDs (with
  kqueue, and every `--latency` seconds, at most 5):
  `beam.com mac_listener --latency=0.5 -F /absolute/dir`.
- The tools of Elixir set `FILESYSTEM_FSINOTIFY_EXECUTABLE_FILE` to a link
  named `inotifywait` to the file (on macOS,
  `FILESYSTEM_FSMAC_EXECUTABLE_FILE` to a script `mac_listener` that runs
  the file), in the cache of BEAM.com (`BEAM_COM_CACHE`, else the user
  cache), unless you set it. On Linux, when the APE loader runs the file,
  `inotifywait` is a script that runs the file with that loader (for
  WSL2, see "One file, many programs" in [`INTERNALS.md`](INTERNALS.md)).
  There is no watcher for Windows
  yet.
- The options are those that `file_system` uses: `-m`, `-r`, `-q`, `-e`
  (`modify`, `close_write`, `moved_to`, `moved_from`, `create`,
  `delete`, `attrib`) and `--format` (`%w`, `%e`, `%f`).

## Phoenix on Cloudflare Workers

A Phoenix release also runs on Cloudflare Workers, with LiveView, Ecto
SQLite and `phx.gen.auth`: see [`WORKERS.md`](WORKERS.md) and
[`examples/phoenix_demo`](../examples/phoenix_demo).
