# The Erlang shell on the web

A Cowboy app (see [`src/worker.erl`](src/worker.erl)): `/` is a page with
the Erlang shell, `/ws` is the WebSocket of a session, and `/hello` is a
text with a count of the requests of its VM. It runs natively, on
Cloudflare Workers, on Deno Deploy and in a web page.

Caution: the shell runs the code of each visitor in the VM, with the
network of the host. Give the VM no secret.

## Deploy at each git push

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/sntran/BEAM.com/tree/main/examples/worker)
[![Deploy on Deno](https://deno.com/button)](https://console.deno.com/new?clone=https://github.com/sntran/BEAM.com&path=examples/worker)

A button copies this directory into a new repository of your account, and
the host builds and deploys it at each push. The buttons work after the
first release of the npm package `beam.com`.

The build step of the host runs `npm run build`, which makes `app.com`, one
native file. Then the engine of the npm package serves that file: the same
[`worker.js`](worker.js) runs on Cloudflare Workers
([`wrangler.jsonc`](wrangler.jsonc)) and on Deno Deploy
([`deno.json`](deno.json)).

The app is stateless: it has no Durable Object. Each isolate runs its own
VM, and each WebSocket is a session of the shell in the VM of its isolate.
See [`examples/phoenix_demo`](../phoenix_demo) for a stateful app.

On this computer:

```sh
npm install && npm run build
sh app.com                       # natively, on PORT (4000)
npx wrangler dev                 # Cloudflare Workers, in workerd
npx deno serve -A worker.js      # Deno
```

[`pages.sh`](pages.sh) makes the static site of the shell (the VM runs in
the page).
