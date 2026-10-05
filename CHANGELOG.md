# Changes

The release job of CI puts the section of a version at the start of the
notes of its release.

## Unreleased

Fixes from the check of the examples with 0.1.0-rc.1:

- The tools of Elixir (`mix`, `iex`, `elixir`, `elixirc`) put an
  `escript` in `PATH` when it has none, so Mix can run rebar3 for a
  dependency that is a rebar3 project. Before, the build of
  `examples/phoenix_demo` with `npx beam.com` (the Deploy buttons, Workers
  Builds and Deno Deploy) stopped at `idna`.
- `beam.com DIR` reads a `mix.lock` that Mix wrote (`"name": {...}`), with
  no warnings. Before, it stopped with `badarg`.
- `beam.com DIR` writes `mix.lock` for a package that rebar3 builds.
  Before, it stopped with `badarg` (`examples/notes` with no `mix.lock`).
- The Cloudflare host gives the app `x-forwarded-proto`, as the Deno host
  and the web page do. Before, `force_ssl` of Phoenix redirected each
  request.
- The help of `--cacerts` and `docs/WORKERS.md` say that `--cacerts` also
  works with `-o app.com` (the edge part of the file).
- Outgoing HTTP (port 80) and HTTPS (port 443, with `--cacerts`) go
  through `fetch()` of the host, and `connect()` is only for other
  protocols. So the VM also reaches a host behind Cloudflare
  (api.cloudflare.com, many webhooks), which `connect()` of Cloudflare
  cannot reach. The program and its configuration do not change. A
  WebSocket goes through a tunnel of `connect()`. `BEAM_FETCH` gives
  other hosts and ports. See "HTTP through fetch()" in `docs/WORKERS.md`,
  and `specs/FetchPath.tla`.
- `worker.capnp` gives workerd TLS for `fetch()` to `https://` URLs.
- `beam.com INPUT -o DIR --page` writes a static site that runs the app
  in the browser: `DIR/app.com`, the page and its runtime, with no CDN.
  The build does not run the release, so it needs no database and no
  secret. `pages-app.yml`, the Livebook page, the shell at `repl/` and
  the studio at `phx/` of the site of BEAM.com use it. Before, they used
  the full directory of `--target wasm32`. `start()` of the page takes
  `statics: false` for an app that serves `priv/static` at a path other
  than `/` (the studio). `BEAM_COM_BASE` names the APE file that a native
  (assimilated) `beam.com` copies for a build, so that it still makes APE
  files.
- `npx beam.com --snapshot app.com` writes the snapshot of the build of
  `app.com`, and `serve(app, { snapshot })` gives it to the VMs. A full
  snapshot (`--full`) replaces the boot: a stateless Worker restores its
  VM in the global scope, and the first request of a new isolate took 82
  to 107 ms of CPU on Cloudflare (213 to 483 ms with the snapshot of the
  store). A snapshot at the boot point (the default) holds no variable of
  the app: a VM restores it only when the store has no snapshot yet, so
  the first isolate of a deploy took 844 ms (1,695 ms with a boot). See
  "The snapshot of the build" in `docs/WORKERS.md`.
- `--target wasm32` is internal. The help, `README.md` and
  `docs/WORKERS.md` no longer show it: `app.com` with the npm package
  (`serve(app)`, `--snapshot`, `--nif-modules`) and `--page` do what it
  did. The option stays for the build of the npm package and for the
  scripts of the examples. "The runtime directory (internal)" in
  `docs/BUILDING.md` gives its files. This change removes
  `examples/phoenix_demo/scripts/wasm.sh`.
- `serve(app, { statics: false })` keeps the static files of a Phoenix
  app in the VM, for an app that serves them at another path
  (`Plug.Static` with `at:`). By default, the host serves them at the
  root of the site, before the VM. `boot()` of Node.js takes the same
  option. `examples/studio` is now a project of `app.com` with the npm
  package, with `worker.js` and `wrangler.jsonc`, in place of
  `scripts/wasm.sh` and `--target wasm32`.
- On macOS arm64, the VM starts `erl_child_setup` with `posix_spawn()`
  of libSystem, through the APE loader. Before, it used `fork()`, and the
  child could hang in `_objc_atfork_child`: a process stayed after the VM
  stopped. See C32 in `docs/UPSTREAM.md`.

## 0.1.0-rc.1

The first release candidate of 0.1.0. It is a pre-release on GitHub, and
on npm it has the dist-tag `next` (`npm install beam.com@next`).

- Erlang/OTP 29.1.1 and Elixir 1.20.4 in one executable file for Linux,
  macOS, Windows, FreeBSD, NetBSD and OpenBSD, on x86_64 and aarch64,
  with the JIT (BeamAsm) for both CPUs. `beam-emu.com` has the
  interpreter.
- `beam.com INPUT` runs and `beam.com INPUT -o OUTPUT` builds `.erl` and
  `.ex` files, applications, and rebar3 and Mix projects, with Hex
  packages, and with no Erlang installation. `mix`, `iex`, `elixir`,
  `elixirc` and `escript` are in the file.
- Static NIFs: `crypto` (OpenSSL 4.0.2), SQLite 3.53.4 (esqlite and
  exqlite), WebAssembly and WASI (WAMR 2.4.5), bcrypt_elixir and
  argon2_elixir.
- NIF libraries in WebAssembly: when a NIF has no native library,
  `load_nif/2` loads `PATH.wasm`, or its AOT file `PATH.x86_64.aot` or
  `PATH.aarch64.aot`, through WAMR, also from the zip of a program. One
  `.wasm` file works on all the systems, and in the WebAssembly runtime
  of `--target wasm32`, where the engine of the host runs it. `beam.com
  --nif-include` gives the headers. A snapshot of the edge holds these
  libraries too, and `beam.com --nif-modules` gives them to a Worker
  that runs an `app.com` (`serve(app, { nifs })`). lazy_html (the HTML
  parser of Phoenix.LiveViewTest) passes its tests so. See
  `docs/NIFS.md`. `beam.com` has lazy_html 0.1.13 in WebAssembly: a Mix
  project with it needs no C++ compiler.
- The OTP application `tools`, for `mix test --cover`.
- A sandbox with the permission flags of Deno (`--allow-read`,
  `--allow-write`, `--allow-net`, `--allow-run`), on Linux and OpenBSD.
- `--target wasm32`: a second runtime, ERTS on WebAssembly with green
  threads on JSPI. One output runs on Cloudflare Workers (Durable
  Objects, D1, snapshots, tenants), on Deno Deploy (SQLite with its
  pages in Deno KV), and in a web page. Phoenix LiveView and Livebook
  run on it.
- Each native `app.com` holds an edge part: the same app runs on
  Cloudflare Workers, on Deno Deploy, and in a web page, with no second
  build.
- The npm package `beam.com`: `npx beam.com` downloads the `beam.com` of
  the release and checks its SHA-256. `import { serve } from 'beam.com'`
  gives a `fetch` handler for an `app.com`, on Cloudflare Workers and on
  Deno. The `exports` map of the package selects the file for each
  runtime.
- `serve(app)` is stateless by default: one VM for each isolate. With
  the binding `BEAM` and `export { Beam } from 'beam.com'`, it is
  stateful: one Durable Object holds the VM and its SQLite storage.
- A Phoenix app gets `SECRET_KEY_BASE` and `PHX_HOST` automatically. The
  key stays in the storage of the Durable Object or in Deno KV.
- A static site for a native `app.com`: the page comes from a CDN (for
  example jsDelivr), and it reads `app.com` with range requests.
- Two templates with Deploy buttons for Cloudflare and Deno Deploy:
  `examples/phoenix_demo` (stateful) and `examples/worker` (stateless).
  Each host builds the app at each git push.
- The documentation is a set of Livebook notebooks that run in the
  browser: <https://sntran.github.io/BEAM.com/>.

See [`docs/PLATFORMS.md`](docs/PLATFORMS.md) for the known limits.
