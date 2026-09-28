// The VM in one Durable Object, in place of one VM for each isolate: one
// instance for all the requests (a server whose state must be in one
// place), which runs all the time while it is in memory, and whose SQLite
// storage is the database of Ecto SQLite. All the requests go to the object
// "main" (BEAM_OBJECT names another one).
//
//   wrangler deploy -c wrangler.durable.jsonc
import { DurableObject } from 'cloudflare:workers';
import { Vm } from './worker.js';

export class Beam extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.vm = new Vm(env, { plain: false, sql: ctx.storage.sql });
  }

  fetch(request) {
    return this.vm.fetch(request);
  }
}

export default {
  fetch(request, env) {
    return env.BEAM.get(env.BEAM.idFromName(env.BEAM_OBJECT ?? 'main')).fetch(request);
  },
};
