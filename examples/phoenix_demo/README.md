# A Phoenix demo on Cloudflare Workers

Live: <https://phoenix.fifo.workers.dev>

This is a standard Phoenix LiveView app from `mix phx.new --database sqlite3`
and `mix phx.gen.auth Accounts User users --live`. beam.com runs it on
Cloudflare Workers, at https://phoenix.fifo.workers.dev. One Durable Object
runs the release in BEAM (WebAssembly), and its SQLite storage keeps the
database.

The app uses Phoenix 1.9.0-dev and LiveView 1.3.0-dev, from the `main` branches
on GitHub, because no 1.9 pre-release is on Hex. The installer of the `main`
branch made the app, as `mix phx.new` of Phoenix 1.9 will make it: esbuild
makes an ES module, and the built-in `JSON` module replaces Jason.

The home page (`PhoenixDemoWeb.DemoLive`) shows what only a live BEAM process
on Cloudflare can show:

- The architecture of the VM: `wasm32-unknown-emscripten`.
- The Cloudflare data center (from `/cdn-cgi/trace`) and the country of the
  request (the `cf-ipcountry` header).
- A server clock that the server pushes each second over the WebSocket.
- The round-trip time of the WebSocket, measured in the browser.
- The visitors online now (Phoenix.Presence): open a second tab.
- A counter that all visitors share (Phoenix.PubSub), in SQLite in the
  Durable Object: a click in one tab changes it in all tabs.
- The uptime of the VM and its count of processes.

The other changes to the generated app:

- The demo sends no real email. The emails stay in memory (the local adapter
  of Swoosh), and the page `/mailbox` shows them to anybody. So anybody can
  log in as any user of the demo. Use no real email address.
- `bcrypt_elixir` is 3.3.2, the version of the NIF in beam.com, and the cost
  is 10 in production, not 12. A Worker has little CPU time.
- The default poller of `telemetry_poller` is off in production:
  `erlang:memory/0` is not supported with `-Mea min`.

Build and deploy:

```sh
BEAM_COM=/path/to/beam.com SUBDOMAIN=NAME scripts/cloudflare.sh
cd _build/cloudflare
npx wrangler deploy -c wrangler.durable.jsonc --secrets-file FILE
```

`FILE` has one line, `SECRET_KEY_BASE=...`, from `mix phx.gen.secret`. Give it
at the first deploy only.

Mix runs the tests with the native VM of beam.com, and the tests of the
LiveView pages fail there: the NIF of `lazy_html` (a test dependency) needs
`dlopen()`, which that VM does not have. Run the tests with a standard
Erlang/OTP and Elixir.

Run it on this computer, with the tools of beam.com (see docs/ELIXIR.md):

```sh
mix.com setup
iex.com -S mix phx.server        # http://localhost:4000
```
