// The module "beam.com" of the npm package in a Worker (the condition
// "workerd" of its exports, which Wrangler uses): the engine that runs the
// app.com of the project, with the runtime of this package. The entry of
// the Worker:
//
//   import app from './app.com' with { type: 'bytes' };
//   import { serve } from 'beam.com';
//   export { Beam } from 'beam.com';   // stateful only
//
//   const beam = serve(app);
//
//   export default {
//     fetch(request, env, ctx) {
//       return beam.fetch(request, env, ctx);
//     },
//   };
//
// The app is stateful or stateless, as the Worker gives it:
// - stateful: with the export Beam and its binding (BEAM) in wrangler.jsonc,
//   each request goes to one Durable Object (durable.js): one VM for all
//   the requests, whose timers run between requests, and its SQLite
//   storage for Ecto SQLite;
// - stateless: with no binding, each isolate runs its own VM (worker.js).
//
// wrangler.jsonc gives app.com to the Worker as a Data module:
//   "rules": [{ "type": "Data", "globs": ["**/*.com"], "fallthrough": true }]
import { env as globalEnv } from 'cloudflare:workers';
import { release, use } from './release.js';
import { useSnapshot } from './snapshot.js';
import plain, { staticResponse, Vm } from './worker.js';
import front from './durable.js';

export { Beam } from './durable.js';

// options.binding: the binding of the Durable Object (BEAM). options.name:
// the name of the object, or a function of the request that gives it (a
// tenant, for example); the var BEAM_OBJECT, else "main", by default.
// options.nifs: the NIF libraries in WebAssembly of app.com, for an app
// that has them. A Worker cannot compile WebAssembly at run time, so
// "beam.com --nif-modules app.com ." writes nifs.js and nifs/, and the
// entry gives them:
//
//   import nifs from './nifs.js';
//   const beam = serve(app, { nifs });
//
// With the binding, the front of durable.js routes the requests: the
// tenants and the instances of its vars (BEAM_TENANTS, BEAM_INSTANCES),
// and the static assets of the binding ASSETS for path tenants. The
// instances also need scheduled() for their cron trigger (the sweep):
//
//   scheduled(controller, env, ctx) {
//     return beam.scheduled(controller, env, ctx);
//   },
//
// options.snapshot: the snapshot of the build of app.com (npx beam.com
// --snapshot app.com, imported as a Data module, as app.com). Each new VM
// restores it in place of a boot. A stateless Worker restores its VM in
// the global scope, before the first request; the entry waits for it:
//
//   import snapshot from './app.snapshot';
//   const beam = serve(app, { snapshot });
//   await beam.ready;
//
// With the var BEAM_WARM (a path, as "/"), the global scope also sends one
// GET request of that path to a full snapshot (see global.js).
export function serve(app, { binding = 'BEAM', name, nifs = null, snapshot = null } = {}) {
  use(app, nifs);
  useSnapshot(snapshot);
  // The VM of a stateless Worker, restored in the global scope.
  let vm = null;
  const ready = snapshot && !globalEnv[binding] ? (async () => {
    vm = new Vm(globalEnv, { release: await release(), snapshot });
    await vm.ready;
    if (globalEnv.BEAM_WARM) await vm.warm(globalEnv.BEAM_WARM);
  })() : Promise.resolve();
  // The env of the front: the binding as BEAM, the name of the object, and
  // the static files of app.com (the front serves them, with no request
  // to the object).
  const statics = async (request) => {
    const files = (await release()).statics;
    return files ? staticResponse(files, request) : null;
  };
  const frontEnv = (env) => ({
    ...env, BEAM: env[binding], BEAM_OBJECT: name ?? env.BEAM_OBJECT, BEAM_STATICS: statics,
  });
  return {
    ready,
    fetch(request, env, ctx) {
      const objects = env[binding];
      if (!objects && snapshot) {
        return ready.then(() => {
          vm.firstHost(new URL(request.url).hostname);
          return vm.fetch(request, ctx);
        });
      }
      if (!objects) return plain.fetch(request, env, ctx);
      if (typeof name === 'function') return objects.getByName(name(request)).fetch(request);
      return front.fetch(request, frontEnv(env), ctx);
    },
    scheduled(controller, env, ctx) {
      if (!env[binding]) return;
      return front.scheduled(controller, frontEnv(env), ctx);
    },
  };
}
