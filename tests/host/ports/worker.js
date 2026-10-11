// The host of tests/programs/ports_check.erl in workerd (wrangler dev):
// the bindings ECHO, SINK and SOURCE are Durable Objects, and each one
// runs a port program of programs.js. With wrangler.jsonc, the VM runs in
// the Durable Object Beam; with wrangler.plain.jsonc, in the Worker.
import { DurableObject } from 'cloudflare:workers';
import app from './app.com' with { type: 'bytes' };
import { serve } from 'beam.com';
import { echo, sink, source } from './programs.js';

export { Beam } from 'beam.com';

export class Echo extends DurableObject {
  port(stdin, opts) { return echo(stdin, opts); }
}

export class Sink extends DurableObject {
  port(stdin, opts) { return sink(stdin, opts); }
}

export class Source extends DurableObject {
  port(stdin, opts) { return source(stdin, opts); }
}

const beam = serve(app);

export default {
  fetch(request, env, ctx) {
    return beam.fetch(request, env, ctx);
  },
};
