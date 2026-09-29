# A Phoenix demo on Cloudflare Workers and Deno Deploy

Live: <https://phoenix.fifo.workers.dev> (Cloudflare Workers) and
<https://beam-phoenix.one.deno.net> (Deno Deploy).

This is a standard Phoenix LiveView app from `mix phx.new --database sqlite3`
and `mix phx.gen.auth Accounts User users --live`. beam.com makes one
directory from it that runs on both hosts. It holds the release and BEAM in
WebAssembly. On Cloudflare Workers, one Durable Object runs the release, and
its SQLite storage keeps the database. On Deno Deploy, each isolate runs the
release, with a database in memory: the data of one isolate is not in the
others, and a new deploy starts with no data.

The app uses Phoenix 1.9.0-dev and LiveView 1.3.0-dev, from the `main` branches
on GitHub, because no 1.9 pre-release is on Hex. The installer of the `main`
branch made the app, as `mix phx.new` of Phoenix 1.9 will make it: esbuild
makes an ES module, and the built-in `JSON` module replaces Jason.

The home page (`PhoenixDemoWeb.DemoLive`) shows what only a live BEAM process
can show. It names its host from `BEAM_HOST` (see docs/WORKERS.md of
beam.com):

- The architecture of the VM: `wasm32-unknown-emscripten`.
- The place of the server: the Cloudflare data center (from `/cdn-cgi/trace`)
  or the region of Deno Deploy (`BEAM_REGION`), and the country of the
  request (the `cf-ipcountry` header of Cloudflare).
- A server clock that the server pushes each second over the WebSocket.
- The round-trip time of the WebSocket, measured in the browser.
- The visitors online now (Phoenix.Presence): open a second tab.
- A counter that all visitors share (Phoenix.PubSub), in SQLite: a click in
  one tab changes it in all tabs.
- The uptime of the VM and its count of processes.

The other changes to the generated app:

- The demo sends no real email. The emails stay in memory (the local adapter
  of Swoosh), and the page `/mailbox` shows them to anybody. So anybody can
  log in as any user of the demo. Use no real email address.
- `bcrypt_elixir` is 3.3.2, the version of the NIF in beam.com, and the cost
  is 10 in production, not 12. A Worker has little CPU time.
- The default poller of `telemetry_poller` is off in production:
  `erlang:memory/0` is not supported with `-Mea min`.

Build, then deploy to Cloudflare Workers:

```sh
BEAM_COM=/path/to/beam.com SUBDOMAIN=NAME DENO_ORG=ORG DENO_APP=APP scripts/wasm.sh
cd _build/wasm
npx wrangler deploy -c wrangler.durable.jsonc --secrets-file FILE
```

`FILE` has one line, `SECRET_KEY_BASE=...`, from `mix phx.gen.secret`. Give it
at the first deploy only.

Deploy the same directory to Deno Deploy. `deno.env` has the variables of the
app (`DENO_ORG` and `DENO_APP` give its host name):

```sh
deno deploy create . --org ORG --app APP --source local \
  --runtime-mode dynamic --entrypoint deno.js
deno deploy env load deno.env --org ORG --app APP
deno deploy env add SECRET_KEY_BASE VALUE --secret --org ORG --app APP
deno deploy . --org ORG --app APP --prod
```

Mix runs the tests with the native VM of beam.com, and the tests of the
LiveView pages fail there: the NIF of `lazy_html` (a test dependency) needs
`dlopen()`, which that VM does not have. Run the tests with a standard
Erlang/OTP and Elixir.

Run it on this computer, with the tools of beam.com (see docs/ELIXIR.md):

```sh
mix.com setup
iex.com -S mix phx.server        # http://localhost:4000
```
