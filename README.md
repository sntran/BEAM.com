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
  <https://phoenix.one.deno.net> (Deno Deploy): a Phoenix LiveView
  app with `phx.gen.auth`, Ecto SQLite, PubSub and Presence, from one
  build ([`examples/phoenix_demo`](examples/phoenix_demo)).
- <https://livebook.fifo.workers.dev> (Cloudflare Workers, an instance
  for each visitor) and <https://livebook.one.deno.net> (Deno Deploy):
  Livebook, with the notebooks of beam.com
  ([`wasm/livebook`](wasm/livebook)).
- <https://phx.fifo.workers.dev> (Cloudflare Workers, an instance for
  each visitor) and <https://sntran.github.io/BEAM.com/phx/> (in the
  page): `mix phx.new` and a Phoenix app, with nothing to install
  ([`examples/studio`](examples/studio)).
- <https://beam.one.deno.net> (Deno Deploy): the Erlang shell, with the
  VM on the server and a restricted shell for all the visitors
  ([`examples/worker`](examples/worker)).

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

To check where the file comes from, use the
[GitHub CLI](https://cli.github.com/): CI signs each `beam.com` of a
release and of `edge`.

```sh
gh attestation verify beam.com --repo sntran/BEAM.com
```

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
  edge: 13 files (62171 bytes) for the WebAssembly runtime
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

One file runs natively and in the WebAssembly runtime. Each executable of
`-o` also has its edge part, of 40 to 180 KB (`--no-edge` leaves it out).
A release directory of `mix release` is an input too:

```sh
beam.com _build/prod/rel/my_app -o my_app.com     # a Phoenix app
PHX_SERVER=true ./my_app.com                     # natively
cd worker && BEAM_APP=../my_app.com deno serve -A deno.js   # the same file on Deno
```

The npm package `beam.com` has the runtime for Node.js, and `npx
beam.com` (see [npm](#npm)).

See "One file, natively and at the edge" in [`docs/WORKERS.md`](docs/WORKERS.md).

## Publish on GitHub Pages

An Erlang or Elixir app can run in the browser of each visitor, at
`https://USER.github.io/REPO/`. The code of the app does not change, and
you need no Erlang, Elixir or Node.js on your computer. Add this file to
the repository of the app:

```yaml
# .github/workflows/pages.yml
name: Pages
on:
  push:
    branches: [main]
  workflow_dispatch:
permissions:
  contents: read
  pages: write
  id-token: write
jobs:
  pages:
    uses: sntran/BEAM.com/.github/workflows/pages-app.yml@v0.1.0
```

Then turn on Pages one time: Settings, Pages, Source "GitHub Actions". The
`GITHUB_TOKEN` cannot do this step. Until the first release (`v0.1.0`),
use `@main` in place of `@v0.1.0`: the workflow then uses the `edge`
build of `beam.com`.

The workflow ([`pages-app.yml`](.github/workflows/pages-app.yml)) builds
the app with `beam.com --target wasm32`, and publishes the static site
`DIR/page/`. A Mix project with Phoenix becomes a release first
(`mix.com release`). Its inputs:

| Input | Default | What |
|---|---|---|
| `path` | `.` | The directory of the app. |
| `beam-com` | the tag of the workflow, else `edge` | The version of `beam.com`. |
| `deploy` | `true` | `false`: build the site, and do not publish it. |

The workflow that calls it must give `pages: write` and `id-token: write`,
also with `deploy: false`: else GitHub refuses the run when it starts.
When the workflow uses `edge` (a pin to a branch, such as `@main`), the
run shows a warning. A pin to a commit SHA uses the release of that
commit, and stops with an error when the commit has no release tag.
Before the build, the workflow checks the SHA-256 of `beam.com` and its
provenance (`gh attestation verify`). The check stops the build when
`build.yml` of BEAM.com did not make the file, or when the check cannot
reach GitHub or Sigstore. It needs no other
permission.

The app needs an HTTP listener on `PORT` (4000 by default), and only the
NIFs of the WebAssembly runtime. The limits:

- Each browser has its own copy of the app. Two visitors do not share
  data.
- The data stays in the memory of the VM. 30 s after the last tab of the
  site closes, the data goes, and the next visit starts from the snapshot
  of the boot.
- No outgoing TCP: a connection of Erlang gets `econnrefused`.
- The first visit downloads `beam.wasm` (about 6.5 MB) and `release.bin`
  (3.5 to 14 MB for a Phoenix app).
- The browser needs JSPI: Chrome and Edge 137 or later, or Firefox 153
  or later.

Caution: all the project sites of one GitHub account share one origin
(`USER.github.io`), also the user site. A page of another site of the
same account can read the data of the app in the browser: its secret,
the snapshot of its VM, and its frame. Give an app with private data its
own custom domain (Settings, Pages, Custom domain).

See "A static site for any app" in [`docs/WORKERS.md`](docs/WORKERS.md).

## npm

This repository is also the npm package `beam.com`, of the same version
as `beam.com`:

```sh
npx beam.com app.erl -o app.com
npx beam.com mix phx.server
```

The package does not hold `beam.com` (about 50 MB). At the first run,
`npx beam.com` downloads `beam.com` of the same version from the GitHub
release, and checks its SHA-256 against the value that the package
holds. Then the file stays in the cache (`~/.cache/beam.com/npm/`). A
host that only uses the runtime never downloads it.

- `BEAM_COM`: the path of a `beam.com` to use. Then nothing is
  downloaded.
- `BEAM_COM_DOWNLOAD`: the URL of a directory with the file `beam.com`,
  in place of the GitHub release.
- `BEAM_COM_CACHE`: the cache directory.

The package also has the WebAssembly runtime, for a native `app.com`.
In Node.js 25 or later (for JSPI):

```js
import { boot } from 'beam.com/node';

const vm = await boot('app.com', { env: { PORT: '4000' } });
const response = await vm.fetch(new Request('http://localhost/'));
```

The file must come from `beam.com` of the version of the package: a file
for another runtime is an error. `release(app)` gives the release of the
file, without a VM.

| Import | What |
|---|---|
| `beam.com/node` | `boot`, `release`, `appRelease` and `runtimeId`, for Node.js. |
| `beam.com/edge` | `edge(app, dir)`: the function of `npx beam.com app.com -o DIR --target wasm32`. |
| `beam.com/app-com` | The reader of an `app.com`, for any host: `appRelease(read, size, { runtime })`. |
| `beam.com/runtime-id` | The identity of this runtime, for `appRelease`. |
| `beam.com/worker` | The runtime (`worker.js` of Cloudflare Workers). |
| `beam.com/beam.wasm` | The VM: ERTS built for WebAssembly. |

For Cloudflare Workers, Deno Deploy and a web page, the same command as
`beam.com` writes the directory of these hosts from the file. With an
`app.com` as the input, `npx` downloads no `beam.com`: the runtime of the
package does the work.

```sh
npx beam.com app.com -o dist --target wasm32
(cd dist/release && npx wrangler deploy) && (cd dist && npx wrangler deploy)
```

`dist` is the same as the output of `beam.com app.com -o dist --target
wasm32` (see [`docs/WORKERS.md`](docs/WORKERS.md)): `deno.js` for Deno
Deploy, and `dist/page/` for a static site.

The release job of CI makes the generated part of the package
(`runtime/`, with `scripts/npm.sh`) and publishes it with each tag `v*`.

## Documentation

The site <https://sntran.github.io/BEAM.com/> is Livebook in your
browser, with these pages as notebooks that run (see
[`docs/NOTEBOOKS.md`](docs/NOTEBOOKS.md)). The same pages are at
[`docs/`](https://sntran.github.io/BEAM.com/docs/) as static pages, and
the Erlang shell in your browser is at
[`repl/`](https://sntran.github.io/BEAM.com/repl/).

| File | What |
|---|---|
| [`docs/PROGRAMS.md`](docs/PROGRAMS.md) | Run and build programs: the inputs, Hex packages, command line programs, native files (`--target`), distributed Erlang, a release in the zip, debugging. |
| [`docs/ELIXIR.md`](docs/ELIXIR.md) | Elixir programs, the tools (`mix`, `iex`, `elixir`), Phoenix from source, the file watcher. |
| [`docs/WORKERS.md`](docs/WORKERS.md) | Cloudflare Workers, Deno Deploy and web pages (`--target wasm32`): Durable Objects, Ecto SQLite, snapshots, tenants, limits. |
| [`docs/NOTEBOOKS.md`](docs/NOTEBOOKS.md) | The documentation as notebooks that run in your browser: a tour of beam.com, the WebAssembly VM, the anatomy of the file, WebAssembly programs, hosts and storage, networking, and building programs. |
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
