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
import { env } from 'cloudflare:workers';
import { Vm } from './worker.js';
import front, { Beam as Base } from './durable.js';
import release from './release/release.bin';
import snapshot from './release/snapshot.bin';

let spare = new Vm(env, { release, snapshot });
await spare.ready;
if (env.BEAM_WARM) await spare.warm(env.BEAM_WARM);

// The tenants and the instances of durable.js; the first object of the
// isolate takes the spare VM. With BEAM_PERSIST, each object boots its own
// VM: the spare VM booted with no storage, so it has not loaded the
// persisted files of the object.
export class Beam extends Base {
  makeVm(vars, host) {
    const sql = this.ctx.storage.sql, id = this.ctx.id.toString();
    const take = spare && !this.env.BEAM_PERSIST;
    const vm = take ? spare.adopt({ sql, id, vars })
      : new Vm(this.env, { plain: false, sql, id, release, snapshot: null, vars, secrets: this.ctx.storage, host });
    if (take) spare = null;
    return vm;
  }
}

export default front;
