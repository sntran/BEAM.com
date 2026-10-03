// The entry of the Worker "livebook" (wrangler.jsonc): the app.com of
// Livebook (setup.sh makes build/livebook.com), with the engine of the npm
// package beam.com. Each instance is a Durable Object (Beam), and the
// cron trigger sweeps the instances past their time limit.
import app from './build/livebook.com' with { type: 'bytes' };
import { serve } from 'beam.com';
export { Beam } from 'beam.com';

const beam = serve(app);

export default {
  fetch(request, env, ctx) {
    return beam.fetch(request, env, ctx);
  },
  scheduled(controller, env, ctx) {
    return beam.scheduled(controller, env, ctx);
  },
};
