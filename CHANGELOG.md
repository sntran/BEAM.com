# Changes

The release job of CI puts the section of a version at the start of the
notes of its release.

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
  --nif-include` gives the headers. lazy_html (the HTML parser of
  Phoenix.LiveViewTest) passes its tests so. See `docs/NIFS.md`.
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
