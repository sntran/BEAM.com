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

## One file, natively and at the edge

`beam.com INPUT -o app.com` writes the edge part of the program into the
zip of `app.com`, under `.wasm/`. Then the same file runs natively and in
the WebAssembly runtime. The native run never reads `.wasm/`.

| Entry | What |
|---|---|
| `.wasm/.release.json` | The boot of the VM, the snapshot key, and the identity of the runtime of the build. |
| `.wasm/lib/wasm_host-VSN/` | The application `wasm_host`. |
| `.wasm/releases/VSN/start.boot` | The boot script, with `wasm_host`. |
| The other entries | The modules in the place of NIFs (exqlite, wasm), `etc/cacerts.pem` of `--cacerts`, and the files of a Mix release that the native file changes. |

The runtime reads `lib/` and `releases/` of the zip, with the files of
`.wasm/` in their place (`app-com.js`, which `--target wasm32` writes
into DIR):

- It reads three parts of the file: the end, the central directory, and
  the span of the release. The edge part is at the end of that span. So a
  host can read the file from a URL with ranges, but only when the server
  sends the bytes of the file as they are (see below).
- A deflated `.beam` entry becomes a gzip file, with no inflate: the
  loader of ERTS reads it so. The release stays small in the memory of
  the host. The other entries are checked with their CRC-32.
- A file for another runtime is an error. Use the runtime of the
  `beam.com` that built the file.

Caution: a deflated `.beam` entry must hold a module, not a gzip file.
Else the loader makes a gzip file in a gzip file, and the VM cannot load
that module. In interactive mode, the error comes only at the first call
to the module. The zip writer of `beam.com` stores a `.beam` file that is
gzip data already. But the zip of `beam.com` itself comes from Info-ZIP,
and 13 modules of `elixir` in it are gzip files in deflated entries. They
do not get into an app.com today, because the build puts copies with no
docs in their place. The Node.js check of CI
([`tests/host/boot_app_com.mjs`](../tests/host/boot_app_com.mjs)) makes
sure that each `.beam` of the release is a module after one gunzip at
most.

The identity of a runtime is the SHA-256 of the output of `sha256sum
app-com.js beam.mjs beam.wasm worker.js`. `--target wasm32` writes it
into DIR as the module `runtime-id.js`, and `.wasm/.release.json` of a
native file holds the identity of the runtime of the build. A host gives
the identity of its runtime to the loader, and does not calculate a hash
at the start: a Worker cannot, because it gets `beam.wasm` as a module.
So a file that passes the check also has the correct snapshot key for
the runtime that boots it.

Caution: a server that compresses a response to a range request breaks
the reads, and a script in a web page cannot stop it, because it cannot
set `Accept-Encoding`. Then the loader stops with "not a zip file" or
with an error of the CRC-32, so the failure is clear. A test of GitHub
Pages in October 2026 found:

- GitHub Pages does not compress `.com` (`application/x-msdownload`) or
  `.zip`, also for a range.
- It compresses `.wasm` and `.bin`, also for a range.

So a file that a web page reads with ranges must keep the name `.com`.

The build of a native file does not run the program (`--target wasm32`
does, to find the modules of the boot). So the VM loads the modules one
by one. `--no-edge` leaves the edge part out, and a `beam.com` with no
WebAssembly runtime writes none.

A release directory (`_build/prod/rel/NAME` of `mix release`, or of
rebar3) is an input of `-o` too. The file has the applications of the
release, and the applications of the zip of `beam.com` that the release
names. A Mix release has no start script in the file: its boot script
sets `RELEASE_ROOT`, `RELEASE_SYS_CONFIG` and the other variables of the
start script, and its `vm.args` gives `-noshell` and `-boot_var
RELEASE_LIB`. Run it as `bin/NAME start`, with the same variables
(`PHX_SERVER=true` for a Phoenix server).

These parts of the start script of a Mix release are not in the file:

- `releases/VSN/env.sh` does not run. The build gives a warning when
  `env.sh` has a line that is not a comment. Set its variables when you
  start the file.
- The release starts no distribution: `RELEASE_DISTRIBUTION` and
  `RELEASE_COOKIE` do nothing.
- There are no `eval`, `rpc` or `remote` commands. So `bin/migrate` of
  `mix phx.gen.release` (`bin/NAME eval "App.Release.migrate"`) has no
  equivalent in the file.

The hosts of `app.com`, in the npm package `beam.com` (["npm" in
README.md](../README.md#npm)), of the same version as the `beam.com` that
made the file:

- Cloudflare Workers and Deno: `serve(app)` of the module `beam.com`
  (its condition `workerd`, which Wrangler uses, or `deno`), with the
  bytes of the file. One entry runs on both hosts (see "Deploy at each
  git push"). On Workers, Wrangler bundles the file into the Worker as a
  Data module (a Worker has 64 MiB). On Deno, `deno.js` of the package is
  the module `beam.com`. It also runs as it is, with the path of `app.com`
  as its first argument (or `BEAM_APP`):
  `deno serve -A node_modules/beam.com/runtime/deno.js app.com`. It needs
  no import map: `deno/worker.js` is a copy of `worker.js` with the
  imports of `deno/`.
- A web page: `main.js` of the package, with the option `app` (see
  "A static site of app.com").
- Node.js: `const vm = await boot('app.com')` of the module `beam.com`. The
  check of CI ("Run one file natively and at the edge") also uses
  [`tests/host/boot_app_com.mjs`](../tests/host/boot_app_com.mjs).

The host makes no copy of the release. The files of the VM are views of
the bytes of `app.com` (`appFiles` of `app-com.js`): the zip stores each
`.beam` file as a gzip file, which ERTS loads. A Worker holds the file as
a Data module, and it counts in the 128 MB of an isolate. The native
part of the file (about 25 MB for ERTS of x86_64 and aarch64) stays in
that memory too.

The static files of a Phoenix app (`PHX_SERVER` in the release, and
`lib/NAME-VSN/priv/static` of the application with the name of the
release) do not go into the VM. The host serves them from `app.com`
before the VM, as Plug.Static does: at the root of the site, with an
ETag, a cache of one year for a request with `vsn`, and `PATH.gz` for a
missing `PATH`. On Workers, the front Worker serves them, also for a
path tenant after its prefix, so they need no request to the Durable
Object. `cache_manifest.json` stays in the VM, because Phoenix reads it
at its start.

A Mix release evaluates its `runtime.exs` in the VM at the boot, so the
host gives its variables. For Ecto SQLite, `.release.json` gives
`DATABASE_PATH` (`/tmp/NAME.db`) when the host does not. A Phoenix app
(`PHX_SERVER` in `.release.json`) also gets these when the host does not
give them:

- `SECRET_KEY_BASE`: a random key that the VM makes one time and keeps
  in the storage of the Durable Object, or in Deno KV. All the VMs of
  the app share it. With no store (a plain Worker, or Deno with no KV),
  each VM makes its own key, and a session stays in that VM only.
- `PHX_HOST`: the host name of the first request.

### Deploy at each git push

A project deploys to Cloudflare Workers (Workers Builds) and to Deno
Deploy at each git push, with these small files, which do not change
from one app to another:

| File | What |
|---|---|
| `package.json` | The dev dependencies `beam.com` and `wrangler`, the script `build` (it makes `app.com`), and the script `deploy` (`wrangler deploy`). |
| `worker.js` | The entry, the same on both hosts: `serve(app)` and the `fetch` handler. |
| `wrangler.jsonc` | The name of the Worker, the flag `no_handle_cross_request_promise_resolution`, the Data rule for `*.com`, and for a stateful app the Durable Object. |
| `deno.json` | `"unstable": ["kv", "raw-imports"]`, and the `deploy` key of Deno Deploy: `npm install`, `npm run build`, and the entrypoint `worker.js`. |

The entry:

```js
import app from './app.com' with { type: 'bytes' };
import { serve } from 'beam.com';
export { Beam } from 'beam.com';   // stateful only

const beam = serve(app);

export default {
  fetch(request, env, ctx) {
    return beam.fetch(request, env, ctx);
  },
};
```

- The app is stateful or stateless, as the project chooses:
  - Stateful: the export `Beam` and its binding `BEAM` in
    `wrangler.jsonc` (with a migration `new_sqlite_classes`). Each
    request goes to one Durable Object: one VM for all the requests,
    whose timers run between requests, and its SQLite storage for Ecto
    SQLite. A Phoenix app with LiveView needs it. Cloudflare reads the
    class by the name of its export, so the export line stays in the
    entry. Example: [`examples/phoenix_demo`](../examples/phoenix_demo).
  - Stateless: no export and no binding. Each isolate runs its own VM,
    which serves the requests of that isolate. It is for an app with no
    state between requests and no work between requests. Example:
    [`examples/worker`](../examples/worker).
- `serve(app, { binding, name })`: `binding` is the binding of the
  Durable Object (`BEAM`), and `name` is the name of the object, or a
  function of the request that gives it, for one object for each tenant
  (the var `BEAM_OBJECT`, else `main`, by default). With no function,
  the vars of the tenants and the instances (`BEAM_TENANTS`,
  `BEAM_INSTANCES`, see below) route the requests.
- `beam.scheduled(controller, env, ctx)`: the sweep of the instances, for
  the cron trigger of a Worker with `BEAM_INSTANCES`.
- On Deno, an isolate keeps its VM between requests, as a Durable
  Object does. The second argument of `fetch` is the info of
  `deno serve`, and `Beam` is not used. Deno KV keeps the database and
  the key.
- Wrangler gives a Data module only to an import of a file path, so the
  import of `app.com` is in the entry. The rule is necessary: without
  it, Wrangler puts the bytes of the file into the JavaScript.

The other handlers of a Worker (`scheduled`, `email`, `queue`) are the
code of the project. A handler can make a request to the app:

```js
export default {
  fetch(request, env, ctx) {
    return beam.fetch(request, env, ctx);
  },
  scheduled(event, env, ctx) {
    ctx.waitUntil(beam.fetch(new Request('http://app/cron', { method: 'POST' }), env, ctx));
  },
};
```

Caution: a visitor can also send a request to such a path. Refuse the
path in `fetch`, or check a secret header that only the handler sends.

Both hosts have a button that clones such a repository (or one directory
of it) into the account of the user, and deploys it at each push:

```md
[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=REPO)
[![Deploy on Deno](https://deno.com/button)](https://console.deno.com/new?clone=REPO)
```

The limits:

- `npx beam.com` downloads `beam.com` of the GitHub release of the
  version of the package. So a build works after the release of that
  version on npm.
- The Cloudflare button needs a public repository.
- The Deno button does not make a database. For data that all the
  isolates share and that a new deploy keeps, assign a Deno KV database
  to the app (`deno deploy database provision`, then `assign`). With no
  KV, SQLite runs in the memory of each isolate.
- The build of Deno Deploy has 5 minutes by default, 2 CPUs and 3 GB of
  memory. Its build command runs in a small shell: `&&` works, but a
  quoted `sh -c "..."` does not. So the command is `npm run build`.
- `deno deploy create` of the Deno CLI 0.0.9908 made apps with an empty
  build configuration, and their builds failed at "building". A `deploy`
  key in `deno.json` gives the configuration.

### A static site of app.com

GitHub Pages can serve a static site from a directory of a branch, with
no GitHub Actions ("Deploy from a branch"). The site needs these files
on its own origin, with the code of the page from the npm package on a
CDN (for example jsDelivr, at the version of the package):

| File | What |
|---|---|
| `app.com` | The app. The page reads its release with range requests. GitHub Pages does not compress a `.com` file, also for a range. |
| `index.html`, `404.html` | The page of the package. `index.html` imports `main.js` of the CDN and starts it with `{ app: './app.com' }`. |
| `sw.js`, `vm.js` | One line each, which imports `page/sw.js` or `page/vm.js` of the CDN: a service worker and a SharedWorker must come from the origin of the site. |
| `.nojekyll` | GitHub Pages runs no Jekyll. |

[`tests/page/app-site.mjs`](../tests/page/app-site.mjs) writes these
files, and CI checks the site of `phoenix_demo.com` in Chrome, with the
package on a second origin (`check.mjs --cdn`). Not yet: `beam.com INPUT
-o DIR --target wasm32` writes this small site in place of the full
directory.

The npm package `beam.com` has the runtime (`beam.wasm`, `worker.js`,
`app-com.js` and `runtime-id.js`), the Node.js host, and `npx beam.com`.
The package does not hold `beam.com`: `npx beam.com` downloads the file
of the GitHub release of the same version at its first run, and checks
its SHA-256. `package.json` is at the root of this repository.
`scripts/npm.sh` writes the generated part (`runtime/`), and the release
job of CI publishes the package with each tag `v*`.

Measured with the `edge` build of October 2026 and this change, in
Node.js 26 on Linux x86_64:

| File | Size | Edge part | Release in memory | VM ready | VM memory |
|---|---|---|---|---|---|
| `hashsum.com` (`examples/hashsum.erl`) | 29.0 MB | 13 files, 62 KB | 3.7 MB | 283 ms | 32 MB |
| `worker.com` (`examples/worker`) | 31.0 MB | 13 files, 71 KB | 5.7 MB | 331 ms | 32 MB |
| `phoenix_demo.com` (its Mix release) | 37.3 MB | 16 files, 177 KB | 12.9 MB | 440 ms | 40 MB |

For `examples/phoenix_demo`, `release.bin` of `--target wasm32` has
13.5 MB, and its VM uses 56 MB: it loads the modules of the boot in one
batch.

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

A NIF library in WebAssembly (`priv/NAME.wasm`, see
[`NIFS.md`](NIFS.md)) loads in the runtime too: the engine of the host
runs it. `beam.com --target wasm32` gives it to Wrangler as a module
(`nifs.js`), because a Worker cannot compile WebAssembly at run time. A
VM with such a library makes no snapshot.

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
| `node:net` (`nodejs_compat`, the default from the compatibility date 2026-08-04) | `node:net` of Deno. TLS stays in `ssl` of OTP. |
| The imports of `beam.wasm`, `release.bin` and `snapshot.bin` | Small modules in `deno/` that read the files, with `deno/worker.js`, a copy of `worker.js` with their imports (no import map). `release.bin` can be next to `worker.js` (one Worker) or in `release/`. |
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
  "node:net": "./browser/net.js",
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
| `vm.js` | The VM, in a module SharedWorker for all the tabs of the site. It keeps the cookies of the app. |
| `sw.js` | The service worker of `app/`: it gives each request of the frame to the VM. |
| `ws-shim.js` | The `WebSocket` of the pages of the app: a socket to the site goes to the VM. It also tells the page the path of the frame. |
| `404.html` | The page of GitHub Pages for a path with no file. It sends a link to a page of the app to `index.html`. |
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
  (`ws-shim.js`). A redirect of the app to such a path does the same
  (`sw.js`). So a link to another site of the same origin (`/OTHER-REPO/`)
  also goes into the frame: the page cannot see the difference from a
  path of the app.
- Each request to the VM has the host `localhost` and the header
  `x-forwarded-proto: https`, as behind a proxy.

The path of the frame:

- The URL of the page keeps the path of the frame in its fragment, for
  example `https://USER.github.io/REPO/#/users/log-in`. Each navigation
  of the frame changes the fragment (`ws-shim.js`), also a LiveView
  navigation. The page replaces its history entry, so the back button of
  the browser goes back in the frame, not in the page.
- A reload, a bookmark, or a link with such a fragment opens the frame at
  that path. The page accepts only a path that starts with one `/`. Another
  fragment, such as `#//example.com` or `#javascript:x`, opens the home
  page of the app.
- A link to `BASE/app/PATH` (for example a link in an email) opens
  `BASE/#/PATH`. When the service worker is on, it sends the browser to
  the page (`sw.js`). At the first visit, GitHub Pages has no file at that
  path and gives `404.html`. That page finds the base path of the site
  with `env.json`, and goes to `BASE/#/PATH`. Another missing path shows
  a 404 text.

One VM for all the tabs of the site:

- `vm.js` runs in a module SharedWorker. So all the tabs of the site use
  one VM, and one jar of cookies: a login in one tab is a login in all
  the tabs. One VM also uses less memory than one VM for each tab (a
  booted VM uses 40 to 58 MB).
- A service worker cannot open a SharedWorker. So `sw.js` gives a request
  to the frame that sent it, and `ws-shim.js` of that frame gives it to
  its tab, which gives it to the VM. When the service worker does not know
  the frame (a new page of the frame), it gives the request to a tab of
  `index.html`, a visible one first.
- The VM stops 30 s after the last tab of the site closes, so a reload
  keeps the VM and its data. A tab tells the VM when it leaves (`pagehide`)
  and when it comes back from the back/forward cache (`pageshow`).
  `extendedLifetime` (Chrome 148 or later) keeps the SharedWorker alive for
  these 30 s. An older browser stops the SharedWorker with its last tab, so
  there a reload restores the snapshot. The next visit after the stop
  restores the snapshot.
- There is no heartbeat: a browser slows the timers of a hidden tab, so a
  heartbeat would stop the VM of a tab that is open in the background. A
  tab that crashes does not tell the VM that it left. Then the VM lives as
  long as the browser keeps the SharedWorker.
- When the boot of the VM fails in the SharedWorker, the page starts it
  one more time on the same port: an error that occurs one time (for
  example a network error on `release.bin`) does not make two VMs for one
  site.
- When the browser has no `SharedWorker`, or the VM does not start in it
  after the second start, the VM runs in a module Web Worker of one tab.
  Then another tab of the site shows a message.

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
site at `/repo/` (and the site of `examples/phoenix_demo` also at `/` and
at `/app/`, a repository with the name `app`),
and checks it in headless Chromium. For
`examples/phoenix_demo`, it checks the home page, a LiveView event, the
links, the login form (a POST), and the path of the frame in the fragment
(a reload, a LiveView navigation, a link to `BASE/app/PATH` with and
without the service worker, and a fragment that is not a path). With `--tabs` (at `/repo/`), it also
checks two tabs: the shared counter (`Phoenix.PubSub`) of one tab shows in
the other tab, a tab still works when the first tab closes, a reload of
the only tab keeps the VM (Chrome 148 or later), a visit 35 s after all
the tabs close restores the snapshot, a boot that fails one time gets one
more start, a SharedWorker that always fails gives the VM in the tab, and
the fallback with no `SharedWorker`. On this computer,
[`tests/page/phoenix_demo.sh`](../tests/page/phoenix_demo.sh) builds the
site of `examples/phoenix_demo`. In headless Chromium on a local server
(October 2026), the app showed in 1.6 to 3.4 s at the first visit. The
same page works in Firefox 157, with one VM for two tabs: the second tab
was ready in 10 ms.

Not tested yet: Safari, and Chrome for Android. Chrome 148 for Android
has SharedWorker again, but nobody has checked what occurs to the VM when
Android puts the tab in the background.

The limits:

- Each browser has its own copy of the app. Two visitors do not share
  data.
- The data stays in the memory of the VM. 30 s after the last tab of the
  site closes, the data goes. The next visit starts from the snapshot of
  the boot.
- No outgoing TCP: a connection of Erlang gets `econnrefused`.
- The first visit downloads `beam.wasm` (about 6.5 MB) and `release.bin`
  (3.5 to 14 MB for a Phoenix app).
- The app needs an HTTP listener on `PORT`, and only the NIFs of the
  runtime or NIF libraries in WebAssembly (see "NIFs").
- An app with `force_ssl` must have `rewrite_on: [:x_forwarded_proto]`
  (as `mix phx.new` writes it), or exclude the host `localhost`. Else it
  redirects each request to `https://localhost/`.

Caution: all the project sites of one GitHub account share one origin
(`USER.github.io`). A page of another site of the same account can read
the secret in `localStorage`, the snapshot in the Cache API (all the
memory of the VM), and the frame of the app. The site of BEAM.com runs
Livebook with notebooks of other people on `sntran.github.io` (see the
caution about Kino below). The user site (`USER.github.io` itself) has
the same origin. Give an app with private data its own custom domain
(Settings, Pages, Custom domain): then the site has its own origin.

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
  runtime or NIF libraries in WebAssembly.
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
