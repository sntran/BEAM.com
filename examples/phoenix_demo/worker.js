// The entry of the demo on Cloudflare Workers and on Deno Deploy: app.com
// (npm run build) with the engine of the npm package beam.com.
import app from './app.com' with { type: 'bytes' };
import { serve } from 'beam.com';

// Stateful: the Durable Object Beam (the binding BEAM of wrangler.jsonc)
// runs one VM for all the requests, and keeps the database in its SQLite
// storage. A stateless app leaves out this line and the binding: then each
// isolate runs its own VM.
export { Beam } from 'beam.com';

const beam = serve(app);

export default {
  fetch(request, env, ctx) {
    return beam.fetch(request, env, ctx);
  },
};
