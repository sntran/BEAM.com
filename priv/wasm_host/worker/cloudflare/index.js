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
import { use } from './release.js';
import plain from './worker.js';

export { Beam } from './durable.js';

// options.binding: the binding of the Durable Object (BEAM). options.name:
// the name of the object, or a function of the request that gives it (a
// tenant, for example); "main" by default.
export function serve(app, { binding = 'BEAM', name = 'main' } = {}) {
  use(app);
  return {
    fetch(request, env, ctx) {
      const objects = env[binding];
      if (!objects) return plain.fetch(request, env, ctx);
      return objects.getByName(typeof name === 'function' ? name(request) : name).fetch(request);
    },
  };
}
