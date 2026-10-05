// The entry of the studio on Cloudflare Workers: app.com (npm run build)
// with the engine of the npm package beam.com. Each visitor starts an
// instance: a Durable Object with its own VM, at /t/NAME/ (a path tenant,
// see the vars of wrangler.jsonc).
import app from './app.com' with { type: 'bytes' };
import { serve } from 'beam.com';

export { Beam } from 'beam.com';

// statics: false: the studio serves its static files at /__studio/static
// (Plug.Static with at:), so the VM keeps them. By default, serve(app)
// serves priv/static at the root of the site, before the VM.
const beam = serve(app, { statics: false });

export default {
  fetch(request, env, ctx) {
    return beam.fetch(request, env, ctx);
  },
  // The sweep of the old instances (the cron trigger of wrangler.jsonc).
  scheduled(controller, env, ctx) {
    return beam.scheduled(controller, env, ctx);
  },
};
