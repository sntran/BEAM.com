# The studio: `mix phx.new` with nothing to install

The studio makes a Phoenix project, compiles it and runs it in one VM:
natively, in a web page, or on Cloudflare Workers. You change a file,
save it, and the app runs again.

- **New project**: the generator of phx_new (`mix phx.new NAME
  --database sqlite3 --no-mailer --no-dashboard --no-gettext`) runs in
  the VM. The release has the packages of such a project, so the studio
  runs no `mix deps.get`.
- **Build**: Mix reads `mix.exs` and the config files, and
  `Kernel.ParallelCompiler` compiles `lib/`. The app then starts in the
  same VM. A new project builds in about 2 s in WebAssembly.
- **Assets**: there is no esbuild and no Tailwind CLI. The browser loads
  the files of `assets/js` as ES modules, and the studio changes their
  imports as esbuild resolves them. The compiler of Tailwind 4 runs in the
  page of the app, with daisyUI and the heroicons of phx.new, from
  jsDelivr. The studio keeps the last CSS for the next load.
- **`$ mix`**: the generators of Phoenix and Ecto (`phx.gen.live`,
  `phx.gen.html`, `phx.gen.context`, `ecto.gen.migration` and others)
  write their files, then the studio builds, and `Ecto.Migrator` runs the
  new migrations.
- **IEx**: the IEx tab evaluates an expression in the VM of the app.
- **Download**: the project as a zip file, with no build files and no
  database. Run it with `mix setup` and `mix phx.server`.

## How the requests go

One plug (`Studio.Front`) takes each request of the VM:

| Path | Goes to |
|---|---|
| `/__studio/...` | The studio (a LiveView, `StudioWeb.Endpoint`) |
| `/assets/js/app.js`, `/assets/css/app.css` | The asset steps (`Studio.Assets`) |
| Any other path | The endpoint of the app of the project |

The app runs at `/` of the site, so its paths need no change. Under a
path (a path tenant `/t/NAME` of Workers, or the scope of the service
worker of the page), the studio puts that path in `script_name` and in
the `url` of both endpoints.

## Run it

Natively, with the `mix` of beam.com (`mix.com`, a link to beam.com):

```sh
cd examples/studio
mix.com deps.get
PORT=4000 mix.com run --no-halt
# open http://localhost:4000/__studio/
```

In a web page (Chrome or Edge 137 or later), as static files:

```sh
BEAM_COM=/path/to/beam.com scripts/page.sh OUT
```

On Cloudflare Workers, with an instance for each visitor: a Durable
Object with its own VM, at `/t/NAME/`. `npm run build` makes `app.com`
with the npm package `beam.com`, and [`worker.js`](worker.js) serves it.
The vars of [`wrangler.jsonc`](wrangler.jsonc) give the limits of the
instances. The studio serves its static files at `/__studio/static`, so
`worker.js` gives `serve(app, { statics: false })`.

```sh
npm install && npm run build
npx wrangler dev                 # test on this computer
npx wrangler deploy
```

Caution: an instance runs the code of its visitor, as a public instance
of Livebook does. The Durable Object of the instance is its sandbox.

## Limits

- The project stays in the memory of the VM. In the page, a new load of
  the page starts again: use Download to keep the project. On Workers,
  the files stay in the storage of the instance while it lives
  (30 minutes).
- The packages of a project are the packages of the release. A new
  dependency in `mix.exs` does not load.
- A save compiles all of `lib/` again, and the app starts again.
- The Tailwind step needs jsDelivr, and the editor needs esm.sh.
- In WebAssembly, SQLite has no WAL: a repo of the project uses the
  journal mode `delete`.

Caution: an instance on Workers runs the code of its visitor, as a public
instance of Livebook does. The Durable Object of the instance is its
sandbox.
