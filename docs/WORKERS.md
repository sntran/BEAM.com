# Cloudflare Workers, Deno Deploy and web pages

The `app.com` of `beam.com INPUT -o app.com` runs natively, and also on
Cloudflare Workers, on Deno Deploy, in a web page and in Node.js. The
program is not changed: its HTTP server (Bandit or Cowboy) listens with
`gen_tcp`, as on a computer, and all of OTP is there.

At the edge, a second runtime runs the file: ERTS of the same
Erlang/OTP, compiled to WebAssembly with Emscripten (`beam.wasm`). The
npm package `beam.com` holds that runtime, and `serve(app)` of the
package serves the file. The build needs no Emscripten and no other
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

Copy [`examples/worker`](../examples/worker) (stateless) or
[`examples/phoenix_demo`](../examples/phoenix_demo) (stateful, with a
Durable Object): their `package.json`, `worker.js`, `wrangler.jsonc` and
`deno.json` do not change from one app to another. Then:

```sh
npm install && npm run build    # npx beam.com makes app.com
npx wrangler dev                # test on this computer: Cloudflare Workers, in workerd
npx deno serve -A worker.js     # or Deno
npx wrangler deploy             # deploy to Cloudflare
```

The input of the build is what `beam.com -o` takes (a `.erl` or `.ex`
file, an application directory, a rebar3 or Mix project), or a release
directory without ERTS. For a Phoenix app, build a release with `mix
release` and `include_erts: false`, and give its directory: then
`runtime.exs` and the config providers run in the Worker. See
[`examples/phoenix_demo/scripts/app-com.sh`](../examples/phoenix_demo/scripts/app-com.sh).
See "Deploy at each git push" below.

## Stateless or stateful

**Stateless** (no Durable Object). Each isolate runs its own VM. The
first request of an isolate boots the VM (or restores a snapshot), and
the VM stays for the next requests to that isolate. The VM runs only
while a request is open: an idle VM costs no CPU time, and its timers
wait for the next request. Use it for a stateless service: an API, a
webhook, a site.

**Stateful** (the export `Beam` and its binding `BEAM` in
`wrangler.jsonc`). One Durable Object runs one VM for all the requests,
and the VM runs all the time while the object is in memory. Its SQLite
storage is the database of Ecto SQLite. Use it for a server whose state
must be in one place: LiveView with PubSub and Presence, a game, a chat
room. Cloudflare bills the duration of an object while it is in memory.

For the shortest cold start, see "The snapshot of the build".

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
`.wasm/` in their place (`app-com.js` of the npm package):

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
app-com.js beam.mjs beam.wasm worker.js`. The npm package has it as the
module `runtime-id.js`, and `.wasm/.release.json` of a native file holds
the identity of the runtime of the build. A host gives
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

The build of a native file does not run the program. So the VM loads
the modules one by one. `--no-edge` leaves the edge part out, and a `beam.com` with no
WebAssembly runtime writes none.

`--target wasm32` with `-o FILE.com` writes only the part of the file
that the WebAssembly runtime reads: a zip with `lib/`, `releases/`,
`.wasm/` and the licenses, with no native program before it. `serve(app)`, `deno.js` and
the web page run it as they run `app.com`, but it does not run natively.
It is about 25 MB smaller. A Worker keeps its modules in the memory of
its isolate, so the VM also gets about 25 MB more of the 128 MB:

```sh
npx beam.com _build/prod/rel/my_app -o edge.com --target wasm32
```

The build refuses it with `--no-edge` and `--allow-*`. An output that
does not end with `.com` is the runtime directory (see "The runtime
directory (internal)" in `docs/BUILDING.md`). A snapshot of the build (`npx beam.com --snapshot`) of
`edge.com` is the same as one of `app.com` of the same build: its key is
the release.

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
  Data module. A Worker can be at most 64 MiB, and gzip does not change
  this limit: for a large app with a snapshot of the build, deploy the
  file of `--target wasm32` with `-o FILE.com`. On Deno, `deno.js` of the package is
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

An app that serves these files at another path (`Plug.Static` with
`at:`) gives `serve(app, { statics: false })`. Then the VM keeps the
files, and the app serves them. `start()` of a web page takes the same
option. [`examples/studio`](../examples/studio) serves its files at
`/__studio/static`. Its `worker.js` has this line:

```js
const beam = serve(app, { statics: false });
```

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
- `serve(app, { nifs })`: the NIF libraries in WebAssembly of `app.com`
  (see [`NIFS.md`](NIFS.md)), for an app that has them. `beam.com
  --nif-modules app.com .` writes `nifs.js` and `nifs/`, and the entry
  imports them: `import nifs from './nifs.js';`. Run it again after each
  build of `app.com`.
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
package on a second origin (`check.mjs --cdn`). `beam.com INPUT -o DIR
--page` writes a site with its own copy of the runtime, so it needs no CDN
(see "A static site for any app").

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

## The program does not change

- The application `wasm_host` goes into the release, and the boot script
  starts it before the applications of the program. In the Worker, it
  makes `gen_tcp` use the sockets of the host (`wasm_tcp`). On a
  computer, it does nothing.
- The Worker gives each request to the listener of the program on
  `PORT` (default 4000) as an HTTP/1.1 connection, and gives the answer
  back. WebSockets work (LiveView). HTTP stays in Bandit or Cowboy.
- The connection to the app has no TLS. The Worker gives the scheme of
  the client in `x-forwarded-proto` (`https` on Cloudflare, `http` in
  `wrangler dev` on `http://localhost`), as Deno and the web page do. So
  `force_ssl: [rewrite_on: [:x_forwarded_proto]]` of Phoenix works.
- Outgoing HTTP and HTTPS (Req, Finch, Mint, Swoosh) go through `fetch()`
  of the host: see "HTTP through fetch()". The other outgoing TCP and TLS
  (`gen_tcp`, `ssl`: a database, SMTP, Redis) use `connect()` of Workers.
  A connection belongs to the request that opened it, and closes with it.
- On Cloudflare, `connect()` cannot reach a host behind Cloudflare.
  Cloudflare blocks "outbound TCP sockets to Cloudflare IP ranges", and a
  Worker cannot connect to itself. Protocols other than HTTP to such a
  host get `econnrefused`.
- `:httpc` does not work: it gives the family option `inet`, and then
  `gen_tcp` uses `inet_tcp` of the VM, not the sockets of the host. Its
  name lookup gets `nxdomain`. Use Req, Finch or Mint.
- The text `vars` of the Worker and its secrets are the environment of
  the VM. `PHX_SERVER=true` is set for a release with Phoenix.
- **The Origin of a WebSocket.** Phoenix compares the `Origin` of a
  WebSocket with the host of its config (`PHX_HOST`). When the `Origin`
  of a request is the origin of the request itself, the Worker gives the
  app the origin of `PHX_HOST`. So LiveView also connects on
  `localhost` (`wrangler dev`), a custom domain or a preview URL. The
  `Origin` of another site goes as it is, and the app refuses it.
- `beam.com --cacerts FILE` puts the root certificates of FILE (PEM)
  into the edge part of `app.com`, for TLS. The runtime has no certificates of its own, and the builder
  does not copy the store of the build computer. A native run of the file
  uses the store of the computer, not FILE.

### The sockets of the host and gen_tcp

The sockets of the host (`wasm_tcp`) give the program the results and
the messages of `gen_tcp` with its default backend (`inet_drv`) of the
same OTP. A test does the same steps on a socket of `gen_tcp` on
127.0.0.1 and on a socket of `wasm_tcp`, and compares the results and
the messages ([`tests/support/tcp_diff.ex`](../tests/support/tcp_diff.ex)).
For example:

- The options of inet, and their checks: a wrong option gives `{error,
  einval}`. `setopts/2` sets the options from the last one to the first
  one, and `{active, N}` adds N to the counter, with `{tcp_passive, S}`
  at 0.
- All the packet types of inet, with `packet_size`, `line_delimiter`, and
  `{http, S, Packet}` in an active mode.
- The end of the peer comes after the data. A passive socket then gives
  `{error, closed}` one time, and then `{error, enotconn}`. An active
  socket gets `{tcp_closed, S}` after the data, also when it becomes
  active after the end.
- One `recv` at a time: a second one gets `{error, ealready}`.
- `gen_tcp:shutdown(S, write)`: the peer gets the end of the data, and the
  socket still reads. A send after it gives `{error, closed}`.
- `controlling_process/2` gives the `tcp` and `tcp_closed` messages of the
  socket in the mailbox of the old owner to the new owner.

These differences stay, because the host has no socket of the operating
system:

- `inet:sockname/1` gives `{{0,0,0,0}, 0}` for a connection, and the port
  of `listen/2` for a listener (also 0). `inet:peername/1` gives the
  address that the host gave, or `{0,0,0,0}` for a name.
- `getopts/2` gives the value that the program set, or the value of a
  socket of Linux. The options of the operating system (`buffer`,
  `recbuf`, `sndbuf`, `nodelay`, `keepalive`, `linger`, ...) do nothing.
  `buffer` is 65536 by default: as in `inet_drv`, a line of `{packet,
  line}` or of the HTTP packets is at most one buffer.
- A socket is a process, not a port. The owner gets no exit signal from
  it, as with the `socket` backend of `gen_tcp`. With `exit_on_close`, an
  error of a read gives `{tcp_error, S, Reason}` and `{tcp_closed, S}`,
  and the socket stops. The port of `inet_drv` also exits with that
  reason, and its owner gets the exit signal. `inet:monitor/1` and
  `inet:info/1` do not take a socket of the host.
- The end of the peer of a `connect()` socket closes the socket in the
  host in the two directions (`node:net` ends it). With `exit_on_close`
  false, a send after the end of the peer goes nowhere: the first one
  gives `ok`, and the next one `{error, closed}`, as after a reset.
- Only the Node.js host of the tests gives the reason `econnreset` of a
  reset. In Workers and Deno, a reset of the peer is an end
  (`show_econnreset` shows nothing).
- A connection of `/.tcp/PORT` is a WebSocket, which cannot end one
  direction: `gen_tcp:shutdown(S, write)` closes it.
- `send_timeout` counts the wait of a send for the window of the host
  (256 KB), not for the buffer of the operating system. As in `inet_drv`,
  the data of a send that timed out goes later.
- `{deliver, port}` sends `{S, {data, Data}}`, where `S` is the socket,
  not a port.

## HTTP through fetch()

The HTTP of the program goes through `fetch()` of the host, and
`connect()` is only for other protocols. `fetch()` is the HTTP client of
each host: on Cloudflare, it is a subrequest, and it also reaches a host
behind Cloudflare (api.cloudflare.com, a Worker on workers.dev, many
webhooks), which `connect()` cannot reach. The code and the
configuration of the program do not change:
`Req.get!("https://api.cloudflare.com/...")` works.

The host chooses the route of each connect of the program
(`specs/FetchPath.tla`):

| Connect | Route |
|---|---|
| Port 80 | `fetch()`. |
| Port 443, with a trust store (`--cacerts`) | `fetch()`. |
| Port 443, with no trust store | `connect()`. The program cannot trust the CA of the VM. |
| Another port | `connect()`. |
| `BEAM_FETCH` is set | `fetch()` for its hosts and ports, `connect()` for the others. |

For `fetch()`, the socket of the program goes to a server in the VM
(`wasm_host_fetch`), and each HTTP request on it is one `fetch()` call.

- **TLS.** The server in the VM ends the TLS of the program with a
  certificate for the SNI name, signed by a CA of the VM. The trust store
  of `:public_key.cacerts_get/0` holds that CA, so Req, Finch, Mint and
  Swoosh trust it. Caution: a program that gives its own CA file (for
  example `castore`, or `certifi` of hackney), or that pins a
  certificate, gets an unknown CA. Give it `:public_key.cacerts_get()`,
  or keep its host out of `BEAM_FETCH`.
- **The CA** is made at the boot, and again with the random bytes of the
  first request after a snapshot. Only this VM trusts it.
- **The URL** of `fetch()` is the host and the port of the connect,
  never the `Host` header or the SNI of the request. So `BEAM_CONNECT`
  still applies.
- **The body.** A request body is at most 32 MiB. The response comes in
  chunks, with chunked transfer coding. `fetch()` gives the body decoded,
  so the response has no `content-encoding`. A large HTTPS body costs CPU
  time: the TLS of each byte runs in WebAssembly.
- **No retry.** When the host does not answer in 5 minutes, the server
  closes the connection: the program does not know if the request ran.
- **WebSocket.** An upgrade does not go through `fetch()`. The server
  opens a tunnel: a `connect()` to the host of the connect, with TLS of
  its own, which checks the certificate of the host with the trust store
  of the build. Then the bytes go both ways. On Cloudflare, a tunnel to a
  host behind Cloudflare fails (502).
- HTTP/1.1 only (ALPN `http/1.1`): no HTTP/2.
- **The fallback.** Off the route of `fetch()` (for example port 443 with
  no trust store, or a host out of `BEAM_FETCH`), `connect()` to port 443
  or 80 can fail on Cloudflare. Then the host resolves the name (DNS over
  HTTPS) and compares the addresses with the IP ranges of Cloudflare. A
  host of Cloudflare goes to the server in the VM. A host that is down
  gets `econnrefused`, as before. Deno and a web page do not use the
  fallback.
- Caution: a Worker that fetches another Worker on the same zone (for
  example another one on your workers.dev subdomain) gets the error
  1042 of Cloudflare. Use a service binding for that Worker.
- `BEAM_FETCH` gives the hosts and ports of `fetch()`, with the rules of
  `BEAM_CONNECT`. For example, `*:80,*:443,api.local:8080` adds a port to
  the default. An empty `BEAM_FETCH` turns `fetch()` off: then only the
  fallback uses it.

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

### The snapshot of the build

`npx beam.com --snapshot app.com` writes `app.snapshot`, a snapshot of
the VM of `app.com`, at build time. The entry gives it to `serve`:

```js
import app from './app.com' with { type: 'bytes' };
import snapshot from './app.snapshot' with { type: 'bytes' };
import { serve } from 'beam.com';

const beam = serve(app, { snapshot });
await beam.ready;
```

`wrangler.jsonc` gives the file as a Data module, as `app.com`:
`"globs": ["**/*.com", "**/*.snapshot"]`. Run the command after the
build of `app.com` (`npm run build`), with the npm package of the same
version: a snapshot of another release does not restore, and the VM
boots in its place.

Give the command the `BEAM_ERL_FLAGS` of the Worker, for example
`--env "BEAM_ERL_FLAGS=-Mea min"`. Without `--env BEAM_ERL_FLAGS`, the
command reads it from the `vars` of `wrangler.jsonc` (or `wrangler.json`)
of the directory where it runs. It warns when the app file and the
snapshot are above 56 MiB, because a Worker can be at most 64 MiB. The header of the snapshot keeps the
flags of the emulator. A Worker with other flags boots in place of the
snapshot, and writes `beam: the snapshot of the build has the flags
...: a boot in its place`. Before, such a Worker restored a VM with the
allocators of ERTS: with `-Mea min`, a Phoenix app used 72 MB in place
of 42 MB.

The pages of a snapshot at the boot point are in gzip (the format
`BEAMSNZ1`), and the host inflates them before the restore.
`--no-compress` writes them as they are (`BEAMSNP1`). A full snapshot
has no gzip, because a stateless Worker restores it in the global scope,
and the global scope cannot inflate. A full snapshot in gzip restores in
the first request. Measured with a small app in `wrangler dev`
(October 2026):

| | Snapshot | Before the restore |
|---|---|---|
| gzip (default) | 5.1 MB | 170 to 610 ms |
| `--no-compress` | 18.2 MB | 26 to 32 ms |

The module of the snapshot stays in the memory of the isolate, so the
gzip pages give the VM about 13 MB more. A snapshot of a Phoenix app is
about 21 MB, and 5 MB in gzip. The snapshots that a Worker makes itself
(the Cache API, or the R2 bucket `SNAPSHOTS`) have no gzip.

The kinds of snapshot:

| Kind | Command | What a new VM does with it |
|---|---|---|
| Full | `npx beam.com --snapshot app.com --full [--warm /] --env NAME=VALUE...` | It restores it in place of a boot. A stateless Worker restores its VM in the global scope of each new isolate, before the first request. Cloudflare runs the global scope with its own limit (1 s). |
| The boot point (default) | `npx beam.com --snapshot app.com` | It restores it only when the store of snapshots (the Cache API, or the R2 bucket `SNAPSHOTS`) has none: the first VM of a deploy, in each data center. That VM then makes its snapshot for the store, as with no snapshot of the build. |

- A full snapshot is the VM after its boot and the warm-up requests. It
  holds the variables of `--env` and the state of the program, so all
  the VMs have the same `SECRET_KEY_BASE` and `PHX_HOST` of the build. A
  Phoenix app must give both. An app with Ecto SQLite cannot use it,
  because its boot changes the database. A Durable Object with tenants,
  `BEAM_PERSIST` or Ecto SQLite does not restore it: it needs a snapshot
  at the boot point.
- A snapshot at the boot point is the VM after the modules of the boot
  loaded, before `runtime.exs` and the program. It holds no variable and
  no secret of the app: each VM starts the program with the variables of
  its host.
- Deno ignores the option, and boots.

Caution: a full snapshot puts its variables, also `SECRET_KEY_BASE`, into
the bundle of the Worker. Use the boot point for an app with secrets, or
keep the build and the bundle private.

Measured on Cloudflare (October 2026, `examples/worker`, stateless), the
CPU time of the first request of a new isolate:

| Snapshot of the build | First isolate of a deploy | The next isolates |
|---|---|---|
| None | 1,695 ms (a boot) | 213 to 483 ms (the snapshot of the store) |
| The boot point | 844 ms | 218 to 449 ms (the snapshot of the store) |
| Full | 82 to 107 ms (in the global scope) | 82 to 107 ms |

In `wrangler dev`, the first request of `examples/phoenix_demo` (a Durable
Object with Ecto SQLite) took 2.7 to 2.9 s with no snapshot of the
build, and 1.4 to 1.6 s with one at the boot point.

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
boots its own VM, or restores a snapshot at the boot point.

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
`/.tcp/PORT` of the Worker is a connection to the listener of
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
runs it. A Worker cannot compile WebAssembly at run time, so
`beam.com --nif-modules app.com .` writes `nifs.js` and `nifs/`, and the
entry gives them to Wrangler as modules (see `serve(app, { nifs })`
below). A snapshot holds the memory of the library too.

## Limits, and a VM that stops

The host protects its requests with these limits (see the table below):

- `BEAM_REQUEST_TIMEOUT` (60 s): when the app does not listen, or does
  not send the head of its response, in this time, the request gets 504.
  For a request with a body, the time starts at the end of the body. The
  app then gets the end of the connection. `"0"` turns the limit off. The
  limit does not apply to the body of a response that streams, or to a
  WebSocket.
- `BEAM_MAX_REQUESTS`: above this count of open requests, a new request
  gets 503 with `retry-after: 1`, before the app reads its body.
- `BEAM_MAX_WEBSOCKETS`: above this count of open WebSockets, a new
  upgrade gets 503.
- `BEAM_MAX_BODY`: a request body above this count of bytes gets 413.
  With a `content-length` above it, the app does not see the request.
  Else the app gets the end of the connection when the body passes it.

A request body goes to the app in parts of 32 KB or more (or the rest of
the body), as the client sends it. The head of the request goes with the
first bytes of the body, so a small body is one event. A body with no
`content-length` goes as `transfer-encoding: chunked`. The host sends a
part only while less than 256 KB of the body is unread in the VM: so a
large upload does not fill the memory of the VM, and an app that reads
slowly slows the client. While the app waits for more bytes than the VM
holds (a `recv` of a length, as Bandit reads a body), these bytes count
as read, so a body of any size reaches a `recv` of its length. The
socket also tells the host how many bytes that `recv` still waits for,
and the host then sends parts of up to 1 MiB: the app holds these bytes
anyway, and each part costs a turn of the VM.

The host starts the VM with `-MBsbct 8192 -MHsbct 8192`: a binary or a
process heap goes into a carrier of its own only above 8 MB, in place of
512 KB. In WebAssembly, these carriers made the memory of the VM grow far
above the memory that Erlang used: 16 clients that sent bodies of 2.7 MiB
at one time grew the memory of the VM to more than 1 GB. With the new threshold, the peak
was about 200 MB, and with `-Mea min` about 100 MB. Erlang itself used 14
MB in each case. With `-Mea min` in `BEAM_ERL_FLAGS`, the host leaves out
its flags.

When the app answers before it reads the whole body (a 413 of its own,
for example), the host reads the rest of the body and drops it, and then
the response goes. workerd cannot read a request body after the response
has gone, and it closes the connection with the bytes that it did not
read: `wrangler dev` uses that connection again, and its next request
gets 500. The host reads 64 MiB at most, and stops when no bytes come for
5 s, or after 60 s. The front Worker of a Durable Object pipes the body to
the object itself, with a handler for a read that fails, in place of the
pipe of workerd.

The other directions have the same flow control:

- A response of the app: a send of the app (`gen_tcp:send/2`) waits while
  256 KB or more of the sends of its socket wait for the client. So a
  client that reads slowly slows the app, and the host holds little of
  the response. Before, a download of 64 MiB to a slow client held up to
  64 MiB in the isolate.
- The messages of a WebSocket client, and the data of a `connect()`
  socket and of a `fetch()` of the fetch path: the host gives them to the
  VM while less than 256 KB is unread there. A `connect()` socket pauses.
  The messages of a WebSocket wait in the host; above 16 MiB that wait,
  the WebSocket closes with the code 1008.
- A WebSocket of the app to the client has no flow control: a WebSocket
  of Workers does not tell the host how much waits.

When the VM stops (`erlang:halt/1`, or a trap such as an allocation that
failed), the host writes `beam: the VM stopped (REASON)` with the memory
of the VM. Each open request then gets 503 with `retry-after: 1`, and each
WebSocket closes with the code 1011. The next request gets a new VM: a
stateless Worker starts one, and a Durable Object resets (its requests get
503 until then). The host also writes `beam: memory N MB (a new peak of
this VM)` when the memory of the VM grew by 8 MB or more. The memory of a
VM does not shrink, and an isolate of a Worker has 128 MB.

A process that computes with no wait does not hold the host in a Durable
Object or in Deno. The scheduler gives the host a turn: in Deno after each
20000 reductions, and in a Durable Object with a timer after each
`BEAM_YIELD_REDS` reductions (1000000 by default, about 50 ms of work).
Then the new requests, the time limit, and the I/O of the app run. A
smaller value answers sooner, but each timer costs about 3 ms of time.

Caution: a stateless Worker gets no such turns. A process that computes
holds its isolate, and the host cannot answer until it stops. Use a
Durable Object for an app that computes for a long time.

### Memory and capacity

An isolate of a Worker has 128 MB for the VM, the modules of the Worker
and JavaScript. Plan for these costs:

- The idle VM of a Phoenix app takes about 32 MB. The VM grows, but it
  does not shrink: the peak of the VM is what counts.
- The modules stay in the memory of the isolate for its life: `app.com`
  and the snapshot of the build. A file of `--target wasm32` with
  `-o FILE.com` is about 25 MB smaller, and a snapshot in gzip about 13
  MB smaller.
- Each open WebSocket and each process that waits keeps its heap. A
  Phoenix app with 75 LiveViews went over the 128 MB on Cloudflare.

Caution: `wrangler dev` does not apply the limit of 128 MB. A test that
passes in `wrangler dev` can reset the object on Cloudflare. Test the
memory on Cloudflare, and read the lines `beam: memory N MB (a new peak
of this VM)` of `wrangler tail`.

The bridge of the host has one listener for each port, so the app needs
one acceptor. In a Phoenix app, give Bandit `thousand_island_options:
[num_acceptors: 1]` in the `http` options of the endpoint: else each of
its 100 acceptors is a process that takes memory with no work.

One Durable Object served about 120 to 190 small requests each second on
Cloudflare (mkfifo.com, October 2026), and fewer for requests that use
the CPU. Use `BEAM_MAX_REQUESTS` so that the host answers 503 before
Cloudflare stops the requests with "Durable Object is overloaded".

## Variables and bindings

| Name | Where | What |
|---|---|---|
| `PORT` | Worker, Durable Object | The port of the HTTP listener of the program (4000). |
| `PHX_HOST` | Worker, Durable Object | The host of a Phoenix app, also for the Origin of a WebSocket. |
| `BEAM_ERL_FLAGS` | Worker, Durable Object | More emulator flags, after the flags of the host (`-MBsbct 8192 -MHsbct 8192`, see below), so a flag here wins. `"-Mea min"` uses `malloc` for all memory: less memory, but no `erlang:memory/0`. |
| `BEAM_SNAPSHOT` | Worker, Durable Object | `"off"`: no snapshot. |
| `SNAPSHOTS` | Worker, Durable Object | An R2 bucket for the snapshots, in place of the Cache API. |
| `BEAM_VERSION` | Worker, Durable Object | The version metadata of the deploy (set by the build). |
| `BEAM_WARM` | global scope | The path of a warm-up request after a restore (`"/"`). |
| `DB`, `BEAM_D1` | Worker | The D1 database of Ecto SQLite, and another name for its binding. |
| `BEAM_OBJECT` | Durable Object | The name of the object with no tenants (`"main"`). |
| `BEAM_TENANTS` | Durable Object | `"cookie"`, `"host"` or `"path"` (see above). |
| `BEAM_INSTANCES` | Durable Object | The instances at one time (then a queue). |
| `BEAM_INSTANCE_TTL` | Durable Object | The life of an instance in seconds (1800). |
| `BEAM_INSTANCE_HOURS` | Durable Object | The instance hours in each UTC day (24). |
| `BEAM_INSTANCES_PER_IP` | Durable Object | The instances at one time for one address (2). |
| `BEAM_INSTANCE_TITLE` | Durable Object | The title of the page of `/`. |
| `BEAM_RETIRE` | Durable Object | Objects of an earlier mode, whose storage the sweep deletes. |
| `BEAM_PERSIST` | Durable Object | Directories whose files stay in the storage of the object. |
| `BEAM_REQUEST_TIMEOUT` | Worker, Durable Object, Deno | Seconds for the head of a response after the request body (60), then 504. `"0"`: no limit. |
| `BEAM_MAX_REQUESTS` | Worker, Durable Object, Deno | The open requests of a VM, then 503. No limit by default. |
| `BEAM_MAX_WEBSOCKETS` | Worker, Durable Object, Deno | The open WebSockets of a VM, then 503. No limit by default. |
| `BEAM_MAX_BODY` | Worker, Durable Object, Deno | The bytes of a request body, then 413. No limit by default. |
| `BEAM_YIELD_REDS` | Durable Object | The reductions of work between two turns of the event loop (1000000). `"0"`: no turns. |
| `DIST_NAME`, `DIST_COOKIE`, `DIST_PORT`, `DIST_LISTEN`, `DIST_CONNECT` | Worker, Durable Object | Distributed Erlang (see above). |
| `BEAM_CONNECT` | all hosts | The hosts that the VM can connect to, separated by commas: `host`, `host:port`, `*.domain` (its subdomains), or `*` (all hosts, as in `*:443`). The host resolves the name, so the VM cannot reach another address. Other connections get `econnrefused`. With no `BEAM_CONNECT`, all hosts. The Node host of the tests (`wasm/erts/host/server.mjs`) does not check it. |
| `BEAM_FETCH` | port 80, and port 443 with `--cacerts` | The hosts and ports whose connect goes through `fetch()`, with the rules of `BEAM_CONNECT` (see "HTTP through fetch()"). The others use `connect()`. Empty: no host. |
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

- **Size:** `beam.wasm` is about 5 MB (2 MB with gzip). The release
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

`serve(app)` of the npm package also runs on Deno 2.9 and on Deno Deploy,
with the same `worker.js`. JSPI works in Deno with no flag. The
condition `deno` of the package gives the parts of the Workers runtime
that the VM uses:

| Workers | Deno |
|---|---|
| `node:net` (`nodejs_compat`, the default from the compatibility date 2026-08-04) | `node:net` of Deno. TLS stays in `ssl` of OTP. |
| The Data module of `app.com` | The import of `app.com` with `{ type: 'bytes' }` (the flag `raw-imports` of `deno.json`) |
| `WebSocketPair` | `Deno.upgradeWebSocket`, when `fetch()` returns the upgrade |
| `caches.default` | `caches.open('beam')` |
| The SQL storage of a Durable Object | SQLite in the VM, with its pages in Deno KV (see below) |
| The static assets (`priv/static` of the app) | `serve(app)` serves them before the VM |

Run the project of the quick start with Deno:

```sh
npx deno serve -A worker.js
```

For Deno Deploy, make an app from the repository of the project. The
`deploy` key of `deno.json` gives the build and the entrypoint. Set the
variables of the release in the app. With the Deno CLI:

```sh
deno deploy create . --org ORG --app APP
deno deploy env load FILE --org ORG --app APP    # a .env file of the variables
deno deploy . --org ORG --app APP --prod
```

Deno does not read the configuration of Workers, and Workers do not read
`deno.json`. So one project deploys to both.

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
`start()` with `app`, the URL of a native `app.com`. The page reads the
release of the file with range requests:

```html
<script type="importmap">{ "imports": {
  "node:net": "./browser/net.js",
  "./beam.wasm": "./browser/beam-wasm.js",
  "./release.bin": "./browser/none.js",
  "./snapshot.bin": "./browser/none.js" } }</script>
<script type="module">
  import { start } from './browser.js';
  const beam = await start({ app: './app.com' });
  const response = await beam.fetch('/');     // a Response of the app
  const socket = await beam.socket('/ws');    // a WebSocket of the app
</script>
```

`beam.com --page` writes this page and the files that it needs (see
"A static site for any app"). The page serves the files of `priv/static`
of a Phoenix app at the root of the site, and the VM does not get them.
For an app that serves them at another path (`Plug.Static` with `at:`),
give `statics: false`: then the VM keeps them, as with `serve(app)`. The
studio at `phx/` of the site of BEAM.com does so.

The app runs in the page as in a Durable Object. The shell of
[`examples/worker`](../examples/worker) runs so at `repl/` of the site of
BEAM.com on GitHub Pages ([`pages.sh`](../examples/worker/pages.sh)). In Chromium, its VM is
ready in about 1.0 s at the first visit, and in 0.4 to 0.5 s at the next
visits (a restore of the snapshot).

### A static site for any app

`beam.com INPUT -o DIR --page` writes a static site that runs the app in
the browser of each visitor. `DIR` is the root of the site. Then the app
runs at `https://USER.github.io/REPO/`, and its code does not change:

```sh
beam.com _build/prod/rel/my_app -o site --page
```

The build does not run the release, so it needs no database and no
secret. The site has its own copy of the runtime, so it needs no CDN.

| File | What |
|---|---|
| `app.com` | The app: the same native file as `-o app.com`. The page reads its release with range requests. A visitor can also download it and run it. |
| `index.html` | The page. It starts the VM with `{ app: './app.com' }`, then shows the app in the frame `app/`. |
| `main.js` | The start of the page. |
| `vm.js` | The VM, in a module SharedWorker for all the tabs of the site. It keeps the cookies of the app. |
| `sw.js` | The service worker of `app/`: it gives each request of the frame to the VM. |
| `ws-shim.js` | The `WebSocket` of the pages of the app: a socket to the site goes to the VM. It also tells the page the path of the frame. |
| `404.html` | The page of GitHub Pages for a path with no file. It sends a link to a page of the app to `index.html`. |
| `worker.js` | `worker.js` with the imports of `browser/`, because a module Web Worker has no import map. |
| `browser.js`, `browser/`, `beam.mjs`, `beam.wasm`, `app-com.js`, `runtime-id.js` | The runtime, and the reader of `app.com`. |
| `app/static.json`, `app/...` | The files of `priv/static` of the app. The site serves them, not the VM. A file that the release has only as `PATH.gz` becomes `PATH`. |
| `licenses/` | The license texts of the software in `beam.wasm`. |
| `.nojekyll` | GitHub Pages runs no Jekyll ("Deploy from a branch"). |

The build refuses `--page` with `--no-edge`: the page runs the edge part
of `app.com`.

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
  (the directory with `sw.js`), and goes to `BASE/#/PATH`. Another missing
  path shows a 404 text.

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
  example a network error on `app.com`) does not make two VMs for one
  site.
- When the browser has no `SharedWorker`, or the VM does not start in it
  after the second start, the VM runs in a module Web Worker of one tab.
  Then another tab of the site shows a message.

The variables of the VM:

| Variable | Value | From |
|---|---|---|
| `PORT`, `HOME` | `4000`, `/tmp` | the page |
| `PHX_HOST` | `localhost`: the host that `vm.js` sends, so that `check_origin` takes the WebSocket | the page |
| `SECRET_KEY_BASE` | a random value for each browser, in `localStorage` | the page |
| `PHX_SERVER` | `true`, when the release has Phoenix | `app.com` |
| `DATABASE_PATH` | `/tmp/NAME.db` in the memory of the VM, when the release has `exqlite` | `app.com` |

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
(October 2026, with `--page`), the app showed in 2.4 to 4.2 s at the first
visit. The
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
- The first visit downloads `beam.wasm` (about 6.5 MB) and the parts of
  `app.com` that the release needs (about 13 MB for
  `examples/phoenix_demo`).
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
- A scheduler with work does not wait. So after each 20000 reductions,
  it gives the host a turn, and the host runs its timers and its I/O (see
  "Limits, and a VM that stops").

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
