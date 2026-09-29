# PhoenixDemo

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## The demo on Cloudflare Workers

This is a standard Phoenix LiveView app from `mix phx.new --database sqlite3`
and `mix phx.gen.auth Accounts User users --live`. beam.com runs it on
Cloudflare Workers, at https://phoenix.fifo.workers.dev. One Durable Object
runs the release in BEAM (WebAssembly), and its SQLite storage keeps the
database.

The home page (`PhoenixDemoWeb.DemoLive`) shows what only a live BEAM process
on Cloudflare can show:

- The architecture of the VM: `wasm32-unknown-emscripten`.
- The Cloudflare data center of the request, from its `cf-ray` header.
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

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
