# Changes

The release job of CI puts the section of a version at the start of the
notes of its release.

## Unreleased

- A VM that stops (`erlang:halt/1`, or a trap such as an allocation that
  failed) no longer holds its requests. Each open request gets 503 with
  `retry-after: 1`, each WebSocket closes with the code 1011, and the next
  request gets a new VM: a stateless Worker or Deno starts one, and a
  Durable Object resets. Before, the open requests and all later requests
  of that VM waited with no answer. In a plain Worker, the stop now runs
  in an open request, because the thread that stopped can run in the
  context of a request that ended.
- `BEAM_REQUEST_TIMEOUT` (60 s by default, `"0"` turns it off): a request
  gets 504 when the app does not listen, or does not send the head of its
  response, in this time.
- `BEAM_MAX_REQUESTS` and `BEAM_MAX_WEBSOCKETS`: above these counts, a new
  request or WebSocket gets 503 with `retry-after: 1` before the app reads
  its body. There is no limit by default.
- The host writes `beam: memory N MB (a new peak of this VM)` when the
  memory of the VM grew by 8 MB or more, and the memory of the VM when it
  stops.
- A process that computes no longer holds a Durable Object or Deno. The
  scheduler gives the host a turn after each 20000 reductions, so that
  new requests, timers and sockets run. In a Durable Object, one turn for
  each `BEAM_YIELD_REDS` reductions (1000000 by default) waits for a
  timer, and a request then waits about 150 ms in place of the whole
  work. Long work is about 6% slower. A stateless Worker has no such
  turns yet.
- A request body goes to the app in parts, as the client sends it, with
  flow control: the host sends a part only while less than 256 KB is
  unread in the VM (the new event `tcp_read` of `wasm_tcp`). Before, the
  host read the whole body first, and the VM held several copies of it:
  an upload of 32 MB made the memory of the VM grow to 208 MB (a Worker
  has 128 MB). Now it stays at about 40 MB. A body with no
  `content-length` goes as `transfer-encoding: chunked`.
- `BEAM_MAX_BODY`: a request body above this count of bytes gets 413. For
  a request with a body, `BEAM_REQUEST_TIMEOUT` starts at the end of the
  body.
- In a plain Worker, a line of the VM (stdout and stderr) that the host
  cannot write in the context of its thread goes to an open request.
  Before, `console.log` could throw there, and stop the thread of the VM.
- `beam.com INPUT -o edge.com --target wasm32` (an output that ends with
  `.com`) writes only the part that the WebAssembly runtime reads: a zip
  with the release and the edge part, with no native program. Another
  output of `--target wasm32` is still the runtime directory. It is about 25 MB smaller, so a Worker with a
  snapshot of the build stays below the 64 MiB of a Worker, and the VM
  gets about 25 MB more of the memory of the isolate.
- `npx beam.com --snapshot` writes the pages of the snapshot in gzip (about
  a quarter of the size; `--no-compress` writes them as they are). The
  host inflates them before the restore, in about 150 ms. A full snapshot
  (`--full`) has no gzip: a stateless Worker restores it in the global
  scope, which cannot inflate. A full snapshot in gzip restores in the
  first request.
- A response of the app goes to the client as the pieces come, with no
  new copy of the whole buffer for each piece. Before, the host joined
  each piece to the buffer, and copied an incomplete chunk again with
  each piece of it. The data of a large chunk now goes to the client
  before the end of the chunk. A bad chunked body stops the response.
- `npx beam.com --snapshot` reads `BEAM_ERL_FLAGS` from the `vars` of
  `wrangler.jsonc` when `--env` does not give it, and warns when the app
  file and the snapshot are near the 64 MiB of a Worker.
- `docs/WORKERS.md` has "Memory and capacity": the costs of an isolate,
  the limit that `wrangler dev` does not apply, one acceptor for Bandit,
  and the capacity of one Durable Object.
- The header of a snapshot keeps `BEAM_ERL_FLAGS`, and a Worker with other
  flags boots in place of the snapshot of the build. Give the flags of the
  Worker to `npx beam.com --snapshot --env BEAM_ERL_FLAGS=...`. Before, a
  snapshot made with no flags gave a Worker with `-Mea min` the
  allocators of ERTS, and 30 MB more memory.
- The bridge of the host is more robust:
  - A response of the app with a bad head (a status outside 100 to 599,
    a head above 1 MiB) gets 502, and the VM goes on. Before, an
    exception there stopped the thread of the VM.
  - The host skips a `1xx` head of the app (`100 Continue`, `103 Early
    Hints`) and waits for the final head. It removes `expect` from the
    request, because the host already has the body.
  - The head of a request and of a response is Latin-1, as in HTTP/1.1.
    Before, a header with bytes above 127 changed.
  - A client that cancels its request closes the connection of the app.
  - A request that waits for the listener of the app, or for a snapshot,
    stops when the VM stops, and leaves no wait behind.
  - An exception of the host on a message of the VM goes to the log, and
    does not stop the VM.
- `wasm_tcp` forgets each connection of a listener when its process
  stops. Before, the map of the listener grew with each connection.
- `BEAM_PERSIST`: a VM that stops saves the files that it wrote after the
  last save. Before, a stop lost up to 1 s of writes.
- The fetch path stops the `fetch()` of a request when the app closes its
  connection, and the cache of names holds at most 1024 names.
- A Durable Object that the host cannot reset (`ctx.abort` throws) starts
  a new VM at the next request. Before, it gave 503 to each request.
- A Worker whose snapshot does not restore in the global scope boots a VM
  in each request, and writes the cause to the log.
- `npx beam.com` stops the download of `beam.com` when no bytes come in
  60 s, and gives an error when the file cannot be written.
- A re-run of the release job after npm has the version keeps the
  `beam.com` that the npm package names (its SHA-256), and puts the
  tarball of npm on the release. A re-run with another `beam.com` stops
  with an error. Before, a re-run could replace the file of the release,
  and `npx beam.com` then refused the download.
- Flow control in the two directions. A send of the app waits while
  256 KB or more of its socket waits for the peer (the new event
  `tcp_sent` of `wasm_tcp`), so a client that reads slowly slows the app.
  In Node.js, a download of 64 MiB to a slow client held 64 MB in the
  host, and now 3 MB. The messages of a WebSocket client, a `connect()`
  socket, and the body of a `fetch()` of the fetch path go to the VM
  while less than 256 KB is unread there. A WebSocket whose app reads
  too slowly closes with the code 1008 above 16 MiB that wait.
- `gen_tcp:send/2` on a socket that the peer closed gives
  `{error, closed}`. Before, it gave `ok`.

## 0.1.0-rc.2

The second release candidate of 0.1.0. As 0.1.0-rc.1, it is a
pre-release on GitHub, and on npm it has the dist-tag `next`. It has the
fixes from the check of the examples with 0.1.0-rc.1, and these changes:

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
- The GitHub release holds the tarball of the npm package
  (`beam.com-VERSION.tgz`), with its attestation and its line in
  `SHA256SUMS`. It is the file that the release job publishes on npm, so
  `npm install URL` of the release installs the package with no
  registry.
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
