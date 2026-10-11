// The runtime Worker with the release and a snapshot of the build in it
// (release/release.bin, and release/snapshot.bin of wasm/snapshot/snapshot.mjs):
// the global scope of the Worker restores the VM before the first request.
// Cloudflare runs the global scope of a new isolate with its own limit
// (1 s). The first request then only starts the threads. The var
// BEAM_WARM (a path, as "/") also sends one GET request to the app there,
// so that V8 compiles the code of a request before the first request.
// That request must not use I/O of the host (SQL, sockets). Measured on
// Cloudflare: see docs/WORKERS.md.
//
//   node wasm/snapshot/snapshot.mjs DIR --warm 4000:/
//   (cd DIR && wrangler deploy -c wrangler.global.jsonc)
import { env } from 'cloudflare:workers';
import plain, { Vm } from './worker.js';
import release from './release/release.bin';
import snapshot from './release/snapshot.bin';

let vm = new Vm(env, { release, snapshot });
await vm.ready;
if (env.BEAM_WARM) await vm.warm(env.BEAM_WARM);
// A VM that stopped: the requests of this isolate then boot a VM of their
// own (the Worker of worker.js).
vm.onDead = () => { vm = null; };

export default {
  fetch(request, env, ctx) {
    return vm ? vm.fetch(request, ctx, env) : plain.fetch(request, env, ctx);
  },
};
