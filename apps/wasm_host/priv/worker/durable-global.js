// durable.js with the release and a snapshot of the build in the Worker
// (release/release.bin, and release/snapshot.bin of wasm/snapshot/snapshot.mjs):
// the global scope of the isolate restores a spare VM, and the first
// Durable Object of the isolate takes it (Vm.adopt), so its first request
// only starts the threads. With BEAM_WARM (a path), a GET request of that
// path runs in the global scope first (see global.js). Another object in
// the same isolate restores the snapshot of the Cache API, or boots.
//
// Ecto SQLite: make the snapshot at the boot point
// (snapshot.mjs --boot-point), before the program and its migrations; the
// first request of each object then starts the program on its own storage.
//
//   node wasm/snapshot/snapshot.mjs DIR --warm 4000:/      (or --boot-point)
//   (cd DIR && wrangler deploy -c wrangler.durable-global.jsonc)
import { DurableObject, env } from 'cloudflare:workers';
import { Vm } from './worker.js';
import front from './durable.js';
import release from './release/release.bin';
import snapshot from './release/snapshot.bin';

let spare = new Vm(env, { release, snapshot });
await spare.ready;
if (env.BEAM_WARM) await spare.warm(env.BEAM_WARM);

export class Beam extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    const sql = ctx.storage.sql, id = ctx.id.toString();
    this.vm = spare ? spare.adopt({ sql, id }) : new Vm(env, { plain: false, sql, id, release, snapshot: null });
    spare = null;
  }

  fetch(request) {
    return this.vm.fetch(request);
  }
}

export default front;
