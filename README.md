# BEAM.com

Erlang/OTP 29 and Elixir 1.20 in one executable file. The same file runs
on Linux, macOS, Windows, FreeBSD, NetBSD and OpenBSD, on x86_64 and
aarch64.

`beam.com` is the Erlang runtime system (ERTS, with the JIT) as one
[Actually Portable Executable](https://justine.lol/ape.html), made with
[Cosmopolitan Libc](https://github.com/jart/cosmopolitan). The file is
also a zip file: the OTP applications, Elixir and your program are in
it, and they run from there. Nothing is installed, and nothing is
extracted.

With `beam.com` you can:

- **Run and build programs** with no Erlang or Elixir on the computer: a
  `.erl` or `.ex` file, or a rebar3 or Mix project with Hex packages.
  `beam.com INPUT -o OUTPUT` makes one executable that runs on all these
  systems.
- **Use Elixir and its tools** from one file: `mix.com`, `iex.com`,
  `elixir.com`. A Phoenix app with SQLite and `phx.gen.auth` runs from
  its source, with no C compiler.
- **Deploy to Cloudflare Workers, Deno Deploy or a web page**:
  `beam.com INPUT -o DIR --target wasm32` makes one directory that runs
  the same program on all three, with a second runtime: ERTS compiled to
  WebAssembly.

The file has the compiler, `crypto` and `ssl` (with OpenSSL), SQLite, and
a WebAssembly runtime (WAMR). It is about 50 MB.

## Live demos

These run from the WebAssembly runtime of `beam.com`, on the free plans:

- <https://phoenix.fifo.workers.dev> (Cloudflare Workers) and
  <https://beam-phoenix.one.deno.net> (Deno Deploy): a Phoenix LiveView
  app with `phx.gen.auth`, Ecto SQLite, PubSub and Presence, from one
  build ([`examples/phoenix_demo`](examples/phoenix_demo)).
- <https://livebook.fifo.workers.dev>: Livebook, with an instance for
  each visitor ([`wasm/livebook`](wasm/livebook)).

## Download

```sh
curl -fLO https://github.com/sntran/BEAM.com/releases/latest/download/beam.com
sh ./beam.com --version
```

On Windows, save the file as `beam.exe`. Each release has `beam.com`
(with the JIT), `beam-emu.com` (the interpreter: a smaller file that
starts faster) and `SHA256SUMS`. The prerelease
[`edge`](https://github.com/sntran/BEAM.com/releases/tag/edge) has the
`beam.com` of the last merge to `main`.

On NetBSD and OpenBSD, start the file with the APE loader
(`ape-x86_64.elf ./beam.com`): see [`docs/PLATFORMS.md`](docs/PLATFORMS.md).

### A custom build

Do you need more OTP applications (for example `ssh` or `mnesia`), Hex and
rebar3 in the file, or a file without Elixir, SQLite or WebAssembly? Open
an issue with the form
[A custom build of beam.com](https://github.com/sntran/BEAM.com/issues/new?template=custom_build.yml).
CI builds and tests the file with your choices, and puts it on the issue.
You need no toolchain. See "A custom build" in
[`docs/BUILDING.md`](docs/BUILDING.md).

## Quick start

Run a program, and make an executable of it:

```
$ sh ./beam.com examples/hashsum.erl -- abc
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc
$ sh ./beam.com examples/hashsum.erl -o hashsum.com
beam.com: wrote hashsum.com (25304313 bytes)
  release: hashsum 0.1.0
  applications: beam_com_script kernel stdlib crypto
$ sh ./hashsum.com abc
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc
```

The same for a project: an application directory, a rebar3 project, or a
Mix project. `beam.com` alone runs the project of the directory.

```sh
beam.com examples/hexweb -o hexweb.com          # rebar3, with cowboy and jsx from hex.pm
beam.com examples/greeter_ex -o greeter_ex.com  # Mix, with jason
beam.com hello.ex -- Alice                      # one Elixir file
```

Use it as an Elixir installation. A copy or a link of the file with the
name of a tool is that tool:

```sh
ln -s beam.com mix.com && ln -s beam.com iex.com
./mix.com local.hex --force && ./mix.com archive.install hex phx_new --force
./mix.com phx.new hello --database sqlite3
cd hello && ../mix.com deps.get && ../mix.com ecto.migrate
../iex.com -S mix phx.server                     # http://localhost:4000
```

Make Cloudflare Workers of a program. The same directory runs on Deno:

```sh
beam.com examples/worker -o worker --target wasm32
cd worker
npx workerd serve worker.capnp                   # test on this computer (Workers)
deno serve -A deno.js                            # or on Deno
```

## Documentation

The site <https://sntran.github.io/BEAM.com/> has these pages, and the
Erlang shell in your browser at
[`repl/`](https://sntran.github.io/BEAM.com/repl/).

| File | What |
|---|---|
| [`docs/PROGRAMS.md`](docs/PROGRAMS.md) | Run and build programs: the inputs, Hex packages, command line programs, native files (`--target`), distributed Erlang, a release in the zip, debugging. |
| [`docs/ELIXIR.md`](docs/ELIXIR.md) | Elixir programs, the tools (`mix`, `iex`, `elixir`), Phoenix from source, the file watcher. |
| [`docs/WORKERS.md`](docs/WORKERS.md) | Cloudflare Workers, Deno Deploy and web pages (`--target wasm32`): Durable Objects, Ecto SQLite, snapshots, tenants, limits. |
| [`docs/LIBRARIES.md`](docs/LIBRARIES.md) | Crypto and TLS, SQLite, and WebAssembly in Erlang code. |
| [`docs/SANDBOX.md`](docs/SANDBOX.md) | `--allow-read`, `--allow-write`, `--allow-net`, `--allow-run`: a program that gives up what it does not need. |
| [`docs/PLATFORMS.md`](docs/PLATFORMS.md) | The status of each system, and the known limits. |
| [`docs/INTERNALS.md`](docs/INTERNALS.md) | How one file runs everywhere, and the changes to OTP. |
| [`docs/JIT.md`](docs/JIT.md), [`docs/BENCHMARKS.md`](docs/BENCHMARKS.md) | The JIT in one file for two CPUs, and what each part costs. |
| [`docs/BUILDING.md`](docs/BUILDING.md), [`docs/TESTING.md`](docs/TESTING.md) | Build BEAM.com, a custom build, CI and the tests. |
| [`docs/UPSTREAM.md`](docs/UPSTREAM.md) | The problems found in Cosmopolitan, OTP, Emscripten and other projects, with reproducers and fixes. |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | What comes next. |

## Examples

| Example | What it shows |
|---|---|
| [`examples/hashsum.erl`](examples/hashsum.erl) | A program in one `.erl` file. |
| [`examples/greeter`](examples/greeter) | An application with a supervisor, as a rebar3 release in the zip of `beam.com`. |
| [`examples/hexweb`](examples/hexweb) | A web server with Hex packages (cowboy, jsx). |
| [`examples/greeter_ex`](examples/greeter_ex) | A Mix project with a Hex package in Elixir. |
| [`examples/toolbox`](examples/toolbox) | A command line program: its entry, `priv` files, and a second VM from its own file. |
| [`examples/counter`](examples/counter) | Distributed Erlang: a remote shell into a running program. |
| [`examples/worker`](examples/worker) | The Erlang shell (`shell` of stdlib) on the web, with Cowboy: natively, on Workers, on Deno, and in a web page ([`pages.sh`](examples/worker/pages.sh)). |
| [`examples/notes`](examples/notes) | Ecto SQLite on a computer, and on Workers with D1 or a Durable Object. |
| [`examples/phoenix_demo`](examples/phoenix_demo) | Phoenix LiveView with `phx.gen.auth` in a Durable Object. |

## Platforms

| System | Status |
|---|---|
| Linux x86_64 and aarch64, WSL2 | ✅ |
| macOS arm64 and x86_64 | ✅ |
| Windows x86_64 | ✅ (no port programs) |
| FreeBSD, NetBSD, OpenBSD 7.3 | ✅ |
| OpenBSD 7.4 and later | ❌ (not supported by Cosmopolitan) |

CI runs the tests on each system. See
[`docs/PLATFORMS.md`](docs/PLATFORMS.md) for the details and the known
limits. The main limits: only the NIFs that are linked into `beam.com`
work, and Hex packages are the only dependencies of a build (no git
dependencies).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Report a security problem in
private: see [`SECURITY.md`](SECURITY.md).

## License

BEAM.com is licensed under the [Apache License 2.0](LICENSE). The file
`beam.com` contains Erlang/OTP, Elixir, Cosmopolitan Libc, OpenSSL,
SQLite, WAMR and other software, under their own licenses:
[`NOTICE`](NOTICE) names them, and the license texts are in
[`licenses/`](licenses) and in the zip of each file.
