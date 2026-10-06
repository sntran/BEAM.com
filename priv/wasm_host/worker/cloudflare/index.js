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
import plain, { parseSnapshot, staticResponse, Vm } from './worker.js';
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
// options.statics: true (the default) serves the static files of a
// Phoenix app (priv/static of the application of the release) at the root
// of the site, before the VM: the VM does not get them. An app that serves
// them at another path (Plug.Static with at:) gives false: then the VM
// keeps them and serves them.
//
// options.snapshot: the snapshot of the build of app.com (npx beam.com
// --snapshot app.com, imported as a Data module, as app.com):
// - a full one (--full): each new VM restores it in place of a boot. A
//   stateless Worker restores its VM in the global scope, before the
//   first request. The global scope cannot inflate the pages of a
//   snapshot in gzip (BEAMSNZ1), so such a snapshot restores in the first
//   request;
// - one at the boot point: a new VM restores it only when the store of
//   snapshots has none (the first VM of a deploy), and then the VM makes
//   its snapshot for the store, as with no snapshot of the build.
// The entry waits for the VM of the global scope:
//
//   import snapshot from './app.snapshot';
//   const beam = serve(app, { snapshot });
//   await beam.ready;
//
// With the var BEAM_WARM (a path, as "/"), the global scope also sends one
// GET request of that path to the VM of a full snapshot (see global.js).
export function serve(app, { binding = 'BEAM', name, nifs = null, snapshot = null, statics: split = true } = {}) {
  use(app, nifs, split);
  useSnapshot(snapshot);
  // The VM of a stateless Worker, restored from a full snapshot in the
  // global scope.
  let vm = null;
  const parsed = snapshot && parseSnapshot(snapshot);
  const full = !!parsed && !parsed.boot_point && !parsed.packed;
  const ready = full && !globalEnv[binding] ? (async () => {
    vm = new Vm(globalEnv, { release: await release(), snapshot });
    // A VM that stopped: the requests then go to the Worker of worker.js,
    // which boots a VM of its own.
    vm.onDead = () => { vm = null; };
    await vm.ready;
    if (globalEnv.BEAM_WARM) await vm.warm(globalEnv.BEAM_WARM);
  })().catch((e) => {
    // A VM that did not restore: the same, and the entry still loads
    // (await beam.ready).
    console.log(`beam: the snapshot of the build did not restore in the global scope (${e?.message ?? e}): each request boots a VM`);
    vm = null;
  }) : Promise.resolve();
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
      if (!objects && vm) return vm.fetch(request, ctx);
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
