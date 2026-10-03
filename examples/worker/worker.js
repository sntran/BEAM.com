// The entry of the shell on Cloudflare Workers and on Deno Deploy: app.com
// (npm run build) with the engine of the npm package beam.com. Stateless:
// with no Durable Object, each isolate runs its own VM, and each
// WebSocket is a session of the shell in the VM of its isolate.
import app from './app.com' with { type: 'bytes' };
import { serve } from 'beam.com';

const beam = serve(app);

export default {
  fetch(request, env, ctx) {
    return beam.fetch(request, env, ctx);
  },
};
