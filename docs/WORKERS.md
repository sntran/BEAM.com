# Cloudflare Workers (`--target wasm32`)

`beam.com INPUT -o DIR --target wasm32` makes Cloudflare Workers of a
program. The program is not changed: its HTTP server (Bandit or Cowboy)
listens with `gen_tcp`, as on a computer, and all of OTP is there.

The Workers run a second runtime: ERTS of the same Erlang/OTP, compiled
to WebAssembly with Emscripten (`beam.wasm`). It is in the zip of
`beam.com`, so the build needs no Emscripten, no Node.js and no other
toolchain.

Live demos, on the Free plan of Workers:

- <https://phoenix.fifo.workers.dev>: a Phoenix LiveView app with
  `phx.gen.auth` and Ecto SQLite, in one Durable Object
  ([`examples/phoenix_demo`](../examples/phoenix_demo)).
- <https://livebook.fifo.workers.dev>: Livebook, with an instance for each
  visitor ([`wasm/livebook`](../wasm/livebook)).

Other projects run the BEAM in WebAssembly in other ways: ERTS with the
threads of the browser (Popcorn 0.4, and a build of Anton Vasetenkov),
AtomVM, or BEAM code compiled to WebAssembly. See "Related work" in
[`history/WASM-LOG.md`](history/WASM-LOG.md).

## Quick start

```sh
beam.com examples/worker -o worker --target wasm32    # an application, a rebar3 or Mix project
beam.com _build/prod/rel/hello -o worker --target wasm32   # or a release directory (mix release)

cd worker
npx workerd serve worker.capnp                        # test on this computer: http://127.0.0.1:8789
(cd release && npx wrangler deploy) && npx wrangler deploy
```

The input is what `beam.com -o` takes (a `.erl` or `.ex` file, an
application directory, a rebar3 or Mix project), or a release directory
without ERTS. For a Phoenix app, build a release with `mix release` and
`include_erts: false`, and give its directory: then `runtime.exs` and the
config providers run in the Worker. See
[`examples/phoenix_demo/scripts/wasm.sh`](../examples/phoenix_demo/scripts/wasm.sh).

The same directory also runs on Deno and Deno Deploy, and in a web page:
see "Deno and Deno Deploy" and "In a web page" below.

## What the build writes

| File | What |
|---|---|
| `wrangler.jsonc`, `worker.js`, `beam.mjs`, `beam.wasm` | The runtime Worker (`NAME`): the VM, with no program. |
| `release/wrangler.jsonc`, `release/app.js`, `release/release.bin` | The Worker with the release (`NAME-release`, with no public URL). The runtime Worker gets `release.bin` from it at the first request of an isolate. |
| `durable.js`, `wrangler.durable.jsonc` | The same runtime in one Durable Object (`NAME-durable`): one VM for all the requests, with SQLite storage. |
| `global.js`, `wrangler.global.jsonc` | The runtime Worker with the release and a snapshot of the build in it. The global scope restores the VM before the first request. |
| `durable-global.js`, `wrangler.durable-global.jsonc` | The Durable Objects, with a spare VM that the global scope restores. |
| `worker.capnp` | Both Workers for `workerd`. |
| `tcp-proxy.mjs` | A local TCP port for a listener of the program (see "Incoming TCP"). |
| `licenses/` | The license texts of the software in `beam.wasm`. Wrangler uploads them with the runtime (about 80 KB). |
| `deno.js`, `deno.json`, `deno/` | The same runtime on Deno and Deno Deploy (see below). |
| `browser.js`, `browser/` | The same runtime in a web page (see below). |
| `page/` | A static site that runs the app in the browser of each visitor, for example on GitHub Pages (see "A static site for any app"). |

The build also runs the release one time on this computer, to find the
modules of its boot. The Worker then loads them in one batch, and the
first request is shorter. `BEAM_COM_WASM_NATIVE_RUN=0` turns this off,
for a program that must not start on the build computer.

## Three ways to run the VM

**The runtime Worker** (`wrangler.jsonc`). Each isolate has its own VM.
The first request of an isolate boots the VM (or restores a snapshot),
and the VM stays for the next requests to that isolate. The VM runs only
while a request is open: an idle VM costs no CPU time, and its timers
wait for the next request. Use it for a stateless service: an API, a
webhook, a site.

**A Durable Object** (`wrangler.durable.jsonc`). One VM serves all the
requests, and runs all the time while the object is in memory. Its
SQLite storage is the database of Ecto SQLite. Use it for a server whose
state must be in one place: LiveView with PubSub and Presence, a game, a
chat room. Cloudflare bills the duration of an object while it is in
memory.

**The global scope** (`wrangler.global.jsonc`,
`wrangler.durable-global.jsonc`). A snapshot of the build goes into the
Worker, and the global scope of each new isolate restores it before the
first request. This gives the shortest cold start. Make the snapshot
first, with Node.js 26:

```sh
node wasm/snapshot/snapshot.mjs worker --warm 4000:/        # writes worker/release/snapshot.bin
node wasm/snapshot/snapshot.mjs worker --boot-point         # with Ecto SQLite: at the boot point
npx wrangler deploy -c wrangler.global.jsonc
```

## The program does not change

- The application `wasm_host` goes into the release, and the boot script
  starts it before the applications of the program. In the Worker, it
  makes `gen_tcp` use the sockets of the host (`wasm_tcp`). On a
  computer, it does nothing.
- The Worker gives each request to the listener of the program on
  `PORT` (default 4000) as an HTTP/1.1 connection, and gives the answer
  back. WebSockets work (LiveView). HTTP stays in Bandit or Cowboy.
- Outgoing TCP and TLS work (`gen_tcp`, `ssl`, `:httpc`, Req) through
  `connect()` of Workers. A connection belongs to the request
  that opened it, and closes with it.
- The text `vars` of the Worker and its secrets are the environment of
  the VM. `PHX_SERVER=true` is set for a release with Phoenix.
- **The Origin of a WebSocket.** Phoenix compares the `Origin` of a
  WebSocket with the host of its config (`PHX_HOST`). When the `Origin`
  of a request is the origin of the request itself, the Worker gives the
  app the origin of `PHX_HOST`. So LiveView also connects on
  `localhost` (`wrangler dev`), a custom domain or a preview URL. The
  `Origin` of another site goes as it is, and the app refuses it.
- `beam.com --target wasm32 --cacerts FILE` puts the root certificates
  of FILE (PEM) into the release, for TLS. The runtime has no
  certificates of its own, and the builder does not copy the store of
  the build computer.

## Ecto SQLite: D1, Durable Objects and Deno KV

A release with `exqlite` (the driver of `ecto_sqlite3`) gets a module in
place of its NIF. That module sends each call to one of two places:

- The host runs the SQL. On Workers, in a Durable Object, the host sends
  each statement to the SQLite storage of the object (on the same
  machine). Else the host sends it to the D1 database of the binding
  `DB` (`BEAM_D1` names another binding). `wrangler.jsonc` has the
  binding: run `wrangler d1 create NAME`, then put its id there.
- The NIF of exqlite in the runtime (SQLite in the VM) runs the SQL, when
  the host does not. With the files of the host (Deno KV, see "Deno and
  Deno Deploy"), SQLite keeps the pages of its databases there. Else
  its databases are in the memory of the VM.

The app is not changed: [`examples/notes`](../examples/notes) runs on a
SQLite file on a computer, and on Workers with D1 or with a Durable
Object. Migrations run at the boot.

Caution: D1 and the storage of a Durable Object do not let SQL control a
transaction. `BEGIN`, `COMMIT` and `ROLLBACK` are accepted, but each
statement commits alone, and a rollback does not undo.

## Snapshots

At the first request of a new deploy, the Worker makes a snapshot of its
booted VM, and keeps it in the Cache API (or in the R2 bucket of the
binding `SNAPSHOTS`). The next isolates restore it and do not boot. This
is on by default; the var `BEAM_SNAPSHOT = "off"` turns it off.

- The key of a snapshot has the runtime, the release, the text bindings,
  the host and the version of the deploy. So a new deploy or a new
  secret gives a new snapshot.
- All isolates start from the same state. Values that the boot makes
  are the same in each isolate (for example the `endpoint_id` of
  Phoenix). After a restore, the Worker reseeds the random generator of
  OpenSSL, so random bytes differ.
- **The boot point.** A snapshot after the boot holds the state of the
  database that the boot used. So a Durable Object with Ecto SQLite (or
  with `BEAM_PERSIST`) makes its snapshot at the boot point: after the
  modules of the boot are loaded, before `runtime.exs` and the program.
  Each object then runs the program and its migrations on its own
  storage.

## Tenants and instances (Durable Objects)

With the var `BEAM_TENANTS`, each tenant has its own Durable Object: its
own VM, state and SQLite storage. The app gets the name of the tenant in
the request header `x-beam-tenant`.

| `BEAM_TENANTS` | The name of the tenant |
|---|---|
| `"cookie"` | `GET /.tenant/NAME` sets the cookie `beam_tenant`, and the cookie names the object (for a workers.dev URL). |
| `"host"` | The first label of the host (`NAME.example.com`). |
| `"path"` | `/t/NAME/...`. The Worker removes the prefix, and the VM gets `BEAM_TENANT` and `BEAM_TENANT_PATH` (the base path of its URLs). |

With `"path"` and `BEAM_INSTANCES`, each visitor can start an instance
(a button on the page of `/`), with a random name and a time limit. A
registry object limits the instances at one time, keeps a queue, and
deletes the storage of an instance at its limit. `wasm/livebook` uses
this.

With `BEAM_PERSIST` (a list of directories, for example `"/data"`), a
Durable Object keeps the files of these directories in its SQLite
storage, and a new VM gets them back. With `BEAM_PERSIST`, each object
boots its own VM, and does not take the spare VM of
`durable-global.js`.

Caution: with `"cookie"` and `"path"`, all the tenants share one origin
in the browser. A page of one tenant can run scripts on the pages of the
other tenants that the same browser opens, and can act for that
visitor there. When the tenants run code that you do not trust (as the
instances of `wasm/livebook`), use `"host"`: each tenant then has its
own origin. The Worker refuses a service worker under `/t/NAME/`, and a
fetch() of `/.instance`, so a tenant cannot take all the requests of the
origin, or read the instance of another visitor with fetch().

## Incoming TCP and distributed Erlang

Workers get HTTP requests, not TCP connections. So a WebSocket to
`/.tcp/PORT` of the runtime Worker is a connection to the listener of
the program on PORT. On the client, `tcp-proxy.mjs LOCAL_PORT
wss://HOST/.tcp/PORT` makes a local TCP port of it.

Caution: anyone who can reach the Worker can reach its listeners.
Protect the path (Cloudflare Access, a token) before you deploy a
listener.

`DIST_NAME` starts distributed Erlang over these sockets
(`-proto_dist wasm_tcp`, with no epmd: all nodes use the port
`DIST_PORT`, 4370). With `DIST_LISTEN=true`, a native node can connect
to the Worker, and a remote shell into the VM at the edge works.
`DIST_CONNECT` names a node that the Worker connects to.

## NIFs

The runtime has the NIFs of `crypto` and `asn1`, those of
`bcrypt_elixir` and `argon2_elixir` (for `phx.gen.auth`), and that of
`exqlite` (see "Ecto SQLite"). The file
`nifs` next to `beam.wasm` lists them. A release with another NIF (for
example `esqlite` or `wasm`) gets a warning, and that NIF does not load.

## Variables and bindings

| Name | Where | What |
|---|---|---|
| `APP` | runtime Worker | The service binding to the Worker with the release. |
| `RELEASE_URL` | runtime Worker | A URL of `release.bin`, when there is no `APP`. |
| `PORT` | both | The port of the HTTP listener of the program (4000). |
| `PHX_HOST` | both | The host of a Phoenix app, also for the Origin of a WebSocket. |
| `BEAM_ERL_FLAGS` | both | More emulator flags. `"-Mea min"` uses `malloc` for all memory: less memory, but no `erlang:memory/0`. |
| `BEAM_SNAPSHOT` | both | `"off"`: no snapshot. |
| `SNAPSHOTS` | both | An R2 bucket for the snapshots, in place of the Cache API. |
| `BEAM_VERSION` | both | The version metadata of the deploy (set by the build). |
| `BEAM_WARM` | global scope | The path of a warm-up request after a restore (`"/"`). |
| `DB`, `BEAM_D1` | runtime Worker | The D1 database of Ecto SQLite, and another name for its binding. |
| `BEAM_OBJECT` | Durable Object | The name of the object with no tenants (`"main"`). |
| `BEAM_TENANTS` | Durable Object | `"cookie"`, `"host"` or `"path"` (see above). |
| `BEAM_INSTANCES` | Durable Object | The instances at one time (then a queue). |
| `BEAM_INSTANCE_TTL` | Durable Object | The life of an instance in seconds (1800). |
| `BEAM_INSTANCE_HOURS` | Durable Object | The instance hours in each UTC day (24). |
| `BEAM_INSTANCES_PER_IP` | Durable Object | The instances at one time for one address (2). |
| `BEAM_INSTANCE_TITLE` | Durable Object | The title of the page of `/`. |
| `BEAM_RETIRE` | Durable Object | Objects of an earlier mode, whose storage the sweep deletes. |
| `BEAM_PERSIST` | Durable Object | Directories whose files stay in the storage of the object. |
| `DIST_NAME`, `DIST_COOKIE`, `DIST_PORT`, `DIST_LISTEN`, `DIST_CONNECT` | both | Distributed Erlang (see above). |
| `BEAM_CONNECT` | all hosts | The hosts that the VM can connect to, separated by commas: `host`, `host:port`, or `*.domain` (its subdomains). The host resolves the name, so the VM cannot reach another address. Other connections get `econnrefused`. With no `BEAM_CONNECT`, all hosts. The Node host of the tests (`wasm/erts/host/server.mjs`) does not check it. |
| `BEAM_SQLITE`, `BEAM_KV`, `BEAM_SQLITE_DEBUG` | Deno | The database of Ecto SQLite (see "Ecto SQLite on Deno KV"). |
| `BEAM_HOST`, `BEAM_REGION` | all hosts | Set by the runtime (see "The host"). |

## Measured

On Cloudflare (Free plan), with the times of `wrangler tail`:

| | CPU time |
|---|---|
| A full boot of a small Cowboy app | 435 to 553 ms |
| The first request of an isolate: a restore from the Cache API | 163 to 428 ms |
| The first request of an isolate: a restore in the global scope, with a warm-up | 8 to 21 ms (median 11) |
| A request to a warm VM | 2 to 10 ms |

In `workerd` on a computer, a Phoenix app answers its first request in
0.6 s with a boot, and in 0.2 s with a snapshot. The next requests take
3 to 5 ms, and a LiveView click takes about 50 to 70 ms.

- **Size:** `beam.wasm` is about 5 MB (2 MB with gzip). `release.bin`
  of a Phoenix app is 3.5 to 8.5 MB.
- **Memory:** a booted VM uses 40 to 58 MB. An isolate has 128 MB.
- **Speed:** Erlang code runs at 1.2 to 1.4 times the time of the native
  interpreter in Node.js. `workerd` is 25 to 30% slower than Node.js,
  because it checks the bounds of each memory access
  ([`UPSTREAM.md`](UPSTREAM.md) CF7).
- **The clock** does not move while code runs on Cloudflare (a
  protection against timing attacks). `:timer.tc/1` gives the time of
  the last I/O, not the CPU time.
- **The Free plan** gives 10 ms of CPU time for each request. In about
  150 requests, no request failed for its CPU time, also boots of 1.4 s.
  Cloudflare does not document how it applies the limit, so do not
  count on this. Password hashes with the default costs (bcrypt 0.6 s,
  argon2 1.5 s of CPU) need the paid plan.

## Deno and Deno Deploy

The output of `--target wasm32` also runs on Deno 2.9 and on Deno Deploy,
with the same `worker.js`. JSPI works in Deno with no flag. `deno.js`,
`deno.json` and `deno/` give the parts of the Workers runtime that
`worker.js` uses:

| Workers | Deno |
|---|---|
| `connect()` of `cloudflare:sockets` | `Deno.connect` (`deno/sockets.js`). TLS stays in `ssl` of OTP. |
| The imports of `beam.wasm`, `release.bin` and `snapshot.bin` | An import map (`deno.json`) and small modules that read the files. `release.bin` can be next to `worker.js` (one Worker) or in `release/`. |
| `WebSocketPair` | `Deno.upgradeWebSocket`, when `fetch()` returns the upgrade |
| `caches.default` | `caches.open('beam')` |
| The SQL storage of a Durable Object | SQLite in the VM, with its pages in Deno KV (see below) |
| The static assets (`static/`, from `wasm/erts/host/static.mjs`) | `deno.js` serves them before the VM |

Run it in the output directory:

```sh
deno serve --allow-net --allow-read --allow-env --allow-write=/tmp deno.js
```

For Deno Deploy, make an app with the entrypoint `deno.js`, and set the
variables of the release in the app. Then deploy the directory:

```sh
deno deploy create . --org ORG --app APP --source local \
  --runtime-mode dynamic --entrypoint deno.js
deno deploy env load FILE --org ORG --app APP    # a .env file of the variables
deno deploy . --org ORG --app APP --prod
```

The configurations of Workers upload none of the Deno files, and Deno
does not read the configurations of Workers. So one directory deploys to
both.

Differences from Workers:

- A Deno isolate keeps its VM between requests, as a Durable Object
  does. So the VM runs as in a Durable Object: its timers run between
  requests, and an app with Ecto SQLite makes its snapshot at the boot
  point.
- Each isolate has its own VM. Two requests can go to two isolates. So
  the state of the processes of one isolate is not in the other. The
  database is shared through Deno KV (see below).
- The environment of the release is the variables of the process,
  without those of Deno and of the host (`DENO_*`, `OTEL_*`, `K8S_*`,
  `CDN_LOOP`). Some of those change for each isolate, and the key of a
  snapshot holds the environment. `BEAM_ENV` = `NAME,NAME` gives the
  exact list of names.
- Deno Deploy gives the scheme of the client only in the URL. `deno.js`
  adds `x-forwarded-proto`, which `force_ssl` of Phoenix reads.
- The clock moves while code runs.

On Deno Deploy (September 2026), the Phoenix demo of
[`examples/phoenix_demo`](../examples/phoenix_demo) boots in 1.0 s
(release 12 MB) and makes a snapshot of 25 MB. On this computer, the
restore of that snapshot takes 0.15 s. The login flow, LiveView,
PubSub and Presence work.

### Ecto SQLite on Deno KV

On Deno, SQLite runs in the VM (the NIF of exqlite), and the host keeps
the pages of each database in Deno KV. All the isolates of an app use the
same KV, so they see the same data, and the data stays after a new
deploy. On Deno Deploy, assign a KV database to the app:

```sh
deno deploy database provision NAME --kind denokv --org ORG
deno deploy database assign NAME --org ORG --app APP
```

The variable `BEAM_SQLITE` selects the database:

| `BEAM_SQLITE` | The database |
|---|---|
| not set, or `kv` | SQLite in the VM, with its pages in Deno KV: `Deno.openKv(BEAM_KV)`. `BEAM_KV` is the path of a local KV file. On Deno Deploy, do not set it. With no KV, the host uses `memory`. |
| `memory` | `node:sqlite` in the isolate runs the SQL, with a database in memory for each isolate. |
| a file path | `node:sqlite` runs the SQL on that file. |
| `off` | SQLite in the VM, with its databases in the memory of the VM. |

The VM gets the mode that the host uses in `BEAM_SQLITE`: `kv`,
`memory`, `off` or the file path. With no KV, the host uses `memory`, and
the VM gets `memory`.

How the pages go to Deno KV:

- The host keeps each database as blocks of 4 KiB. Each block has a
  version, so a read sees the database as it was at its start, also when
  another isolate commits meanwhile.
- SQLite writes a transaction as one batch (`SQLITE_ENABLE_BATCH_ATOMIC_WRITE`).
  The host commits the batch in one atomic operation of KV, which checks
  that the database did not change after the read.
- A write takes a write lock in KV for 10 s, and its commit removes the
  lock. So a write transaction is three operations of KV: the read of the
  version, the lock, and the commit. When another isolate has the lock,
  or when the read is not of the last version, SQLite gets
  `SQLITE_BUSY`. Then its busy handler tries again from a new read (the
  `busy_timeout` of `ecto_sqlite3`, 2000 ms by default).
- A journal stays in the memory of the VM. The database in KV changes
  only in one commit, so a new VM needs no journal.
- There is no WAL. `journal_mode: :wal` of `ecto_sqlite3` keeps the mode
  `delete`. This is true for each database of the WebAssembly runtime:
  its SQLite has no WAL (`SQLITE_OMIT_WAL`).

`BEAM_SQLITE_DEBUG=1` logs each operation of the host on the files.

Test of the Phoenix demo with a local KV file (September 2026): two Deno
processes on one KV, four LiveView clients, 100 clicks at the same time.
The counter got all the 100 clicks, with no error, and it kept its value
after a restart.

On Deno Deploy (September 2026), the same demo with a KV database. The
times are from a client in the US, over one LiveView socket:

| | Database in memory | SQLite on Deno KV |
|---|---|---|
| First request of a new isolate (boot and migrations) | 8.2 s | 4.5 s |
| `GET /`, median | 46 ms | 36 to 48 ms |
| A LiveView event with no SQL, median | 16 ms | 15 to 16 ms |
| A click (one write transaction), median | 18 ms | 41 to 48 ms |

The first request has one measurement for each, and its time changes
with the work of the new isolate (a boot, or a restore of a snapshot).
A write transaction adds about 25 to 30 ms: three operations of KV (the
version, the lock, and the commit). With a separate unlock, a write was
six operations and added about 40 ms. Four clients sent 100 clicks at
the same time in 4.2 s, and the counter got all of them.

## In a web page

The output also runs in a browser tab with JSPI: Chrome and Edge 137 or
later, and Firefox 153 or later. Safari 27 also has JSPI, but nobody has
tested the pages of beam.com in Safari yet.
`browser.js` gives `worker.js` the parts of the Workers runtime that it
uses: a `WebSocketPair` of two ends in the page, and the Cache API of the
site for the snapshot. A page has no TCP connections (a connection of
Erlang gets `econnrefused`) and no SQL storage.

The page needs an import map before its first module, and then calls
`start()`:

```html
<script type="importmap">{ "imports": {
  "cloudflare:sockets": "./browser/sockets.js",
  "./beam.wasm": "./browser/beam-wasm.js",
  "./release.bin": "./browser/none.js",
  "./snapshot.bin": "./browser/none.js" } }</script>
<script type="module">
  import { start } from './browser.js';
  const beam = await start({ release: './release/release.bin' });
  const response = await beam.fetch('/');     // a Response of the app
  const socket = await beam.socket('/ws');    // a WebSocket of the app
</script>
```

The app runs in the page as in a Durable Object. The shell of
[`examples/worker`](../examples/worker) runs so at `repl/` of the site of
BEAM.com on GitHub Pages ([`pages.sh`](../examples/worker/pages.sh)). In Chromium, its VM is
ready in about 1.0 s at the first visit, and in 0.4 to 0.5 s at the next
visits (a restore of the snapshot).

### A static site for any app

`DIR/page/` is a static site that runs the app in the browser of each
visitor. Publish only this directory: it is the root of the site. Then
the app runs at `https://USER.github.io/REPO/`, and its code does not
change.

| File | What |
|---|---|
| `index.html` | The page. It starts the VM, then shows the app in the frame `app/`. |
| `vm.js` | The VM, in a module Web Worker. It keeps the cookies of the app. |
| `sw.js` | The service worker of `app/`: it gives each request of the frame to the VM. |
| `ws-shim.js` | The `WebSocket` of the pages of the app: a socket to the site goes to the VM. |
| `env.json` | The name of the app and the variables of its VM. |
| `worker.js` | `worker.js` with the imports of `browser/`, because a module Web Worker has no import map. |
| `browser.js`, `browser/`, `beam.mjs`, `beam.wasm` | The runtime. |
| `release.bin` | The release. |
| `app/static.json`, `app/...` | The files of `priv/static` of the app. The site serves them, not the VM. |
| `licenses/` | The license texts of the software in `beam.wasm`. |

`page/beam.wasm` and `page/release.bin` are hard links to `beam.wasm` and
`release/release.bin` of `DIR`, or copies when the file system has no hard
links.

The base path:

- The page finds its base path from its own URL. So the same files work
  at `/REPO/` of a project site, at `/` of a custom domain, and on
  `localhost`.
- The service worker gives the VM the path without the prefix of the
  frame (`/REPO/app`), as a proxy does.
- The VM gets the prefix in `BEAM_BASE_PATH`. The application `wasm_host`
  puts it in `url: [path: ...]` of each Phoenix endpoint (each module
  with the behaviour `Phoenix.Endpoint`). The other keys of `url` stay.
  This occurs after the config providers (`runtime.exs`), and before the
  applications of the program start. So the links and the forms of
  Phoenix (`~p`) stay in the frame.
- A link or a form with a path outside the frame, such as `href="/"` of
  the layout of `mix phx.new`, goes to the same path in the frame
  (`ws-shim.js`).

The variables of `env.json`:

| Variable | Value | When |
|---|---|---|
| `PORT`, `HOME` | `4000`, `/tmp` | always |
| `PHX_SERVER` | `true` | the release has Phoenix |
| `PHX_HOST` | `localhost`: the host that `vm.js` sends, so that `check_origin` takes the WebSocket | the release has Phoenix |
| `SECRET_KEY_BASE` | a random value for each browser, in `localStorage` | the release has Phoenix |
| `DATABASE_PATH` | `/tmp/NAME.db`, in the memory of the VM | the release has `exqlite` |

A GitHub workflow builds the site of an app and publishes it on GitHub
Pages: see "Publish on GitHub Pages" in the [README](../README.md#publish-on-github-pages).
The CI of BEAM.com calls this workflow
([`pages-app.yml`](../.github/workflows/pages-app.yml)) for
`examples/phoenix_demo` and `examples/worker`, and does not publish the
sites. Then [`tests/page/check.mjs`](../tests/page/check.mjs) serves each
site at `/repo/` (and the site of `examples/phoenix_demo` also at `/`),
and checks it in headless Chromium. For
`examples/phoenix_demo`, it checks the home page, a LiveView event, the
links, and the login form (a POST). On this computer,
[`tests/page/phoenix_demo.sh`](../tests/page/phoenix_demo.sh) builds the
site of `examples/phoenix_demo`. In headless
Chromium on a local server (October 2026), the app showed in 2.2 to
3.4 s at the first visit. The same page works in Firefox 157.

The limits:

- Each browser has its own copy of the app. Two visitors do not share
  data.
- The data stays in the memory of the VM. When the tab closes, the data
  goes. The next visit starts from the snapshot of the boot.
- One tab of the site runs the VM. Another tab of the site shows a
  message.
- No outgoing TCP: a connection of Erlang gets `econnrefused`.
- The first visit downloads `beam.wasm` (about 6.5 MB) and `release.bin`
  (3.5 to 14 MB for a Phoenix app).
- The app needs an HTTP listener on `PORT`, and only the NIFs of the
  runtime (see "NIFs").

### Livebook in a web page

Livebook runs so at the root of the same site
([`wasm/livebook/page.sh`](../wasm/livebook/page.sh)): Livebook,
Phoenix, Elixir and the code of a notebook run in the tab. Its Learn
section has the documentation of beam.com as notebooks
([`NOTEBOOKS.md`](NOTEBOOKS.md)). The notebook "The Erlang shell" runs
the same shell as `repl/` in the VM of Livebook, with a terminal in the
output of a cell. A web app with
pages and a LiveView socket needs more than `beam.fetch` in the page:

- The VM runs in a Web Worker (`vm.js`), so its work does not stop the
  page.
- A service worker (`sw.js`) takes each request of the Livebook frame
  (`app/`). A static file of Livebook comes from the site. Another request
  goes to the VM.
- A service worker cannot take a WebSocket. The pages of Livebook get
  `ws-shim.js`, whose `WebSocket` sends the socket of LiveView to the VM
  through the page.
- A page drops the `Set-Cookie` headers of a `Response`. So `vm.js` keeps
  the cookies of Livebook, and each request gets them.
- The iframe page of Kino (`app/iframe/vN.html`) is on the same site, so
  the service worker also takes its requests for the JS of Kino.

Caution: the JS outputs of Kino run on the origin of the site
(`sntran.github.io`), and not on a separate origin. A notebook from
another person can run JS there. Open only notebooks that you trust.

The notebooks stay in the memory of the tab, and a tab of the site runs
one VM. A notebook has no network: `Mix.install` works only for the
packages in the release (Kino). In headless Chromium (September 2026), on
a local server, the first visit showed Livebook in 1.9 s. The next
visits restored the VM from the snapshot in 0.25 s and showed Livebook
in 1.0 s. Livebook evaluated a cell in about 0.2 s, and 10,000 processes
started in 80 ms.

## The host

The runtime gives the app the variable `BEAM_HOST`: `cloudflare`,
`deno-deploy`, `deno` or `browser`. On Deno Deploy, `BEAM_REGION` is the
region of the isolate. It goes to the VM after the boot point, so it is
not in the key of the snapshot.

## Limits

- Threads switch only when one waits: a long NIF or BIF stops the other
  threads. Erlang processes are still preempted by reductions.
- The CPU time of a request counts all the threads of the VM.
- No port programs (no `fork()` or `exec()`), and only the NIFs of the
  runtime.
- No UDP. Incoming TCP only through a WebSocket (see above).
- An isolate can close at any time, and a deploy resets the Durable
  Objects. The next request boots or restores a new VM.
- Argon2 with its default costs (64 MiB) can go over the 128 MB of an
  isolate. Use lower costs, or bcrypt.
- On Deno KV, one transaction of SQLite writes at most 160 blocks of 4 KiB
  (640 KiB), because an atomic operation of KV has limits. A larger
  transaction gets `SQLITE_FULL`, and it changes nothing. Each read of a
  block that is not in the cache of the isolate is a read of KV.

## How it works

ERTS needs threads: the schedulers, the dirty schedulers and the helper
threads. Workers give one thread, and no shared memory. So the runtime
has green threads on JSPI (JavaScript Promise Integration, a standard
WebAssembly feature):

- Each thread of ERTS is one call of a `promising` export, with its own
  engine stack. All of them run on one host thread, in one linear
  memory.
- A thread that must wait (a mutex, a condition variable, a join, a
  sleep, `poll()`) calls a `Suspending` import. Its promise resolves when
  another thread signals it, or at a timeout. The event loop of the host
  runs the other threads meanwhile.
- Each thread has its own shadow stack, and puts its own stack pointer
  back after each wait.

The runtime is built from the source of the same OTP by
[`wasm/erts/build.sh`](../wasm/erts/build.sh) (the step `wasm_runtime`
of the Makefile). [`wasm/erts/otp.patch`](../wasm/erts/otp.patch) has the
changes of ERTS. For example, `process_main()` returns at the end of each
time slice: V8 then uses its optimized code for the loop of the
interpreter, which made Erlang code about 4 times faster.

**A snapshot** is a copy of the memory of the VM. A suspended JSPI stack
cannot be saved, so each thread of ERTS returns to the host when it is
idle, and no stack is left. The host copies the memory, the files, the
pipes and the listeners. In a new instance, it copies them back, and
each thread starts again in the function where it stopped. The VM of a
snapshot runs with `-c false` (no time correction), so its monotonic time
jumps forward after a restore, and the timers that are due fire.

The full record of how the runtime was made, with all the measurements,
is in [`history/WASM-LOG.md`](history/WASM-LOG.md). The problems that
were found in Emscripten, `workerd` and other projects are in
[`UPSTREAM.md`](UPSTREAM.md).
