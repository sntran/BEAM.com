// The host of tests/programs/ports_check.erl in Deno (deno serve): the
// bindings ECHO, SINK and SOURCE are the objects of the option env of
// serve(), in the isolate of the VM.
import app from './app.com' with { type: 'bytes' };
import { serve } from 'beam.com';
import { echo, sink, source } from './programs.js';

const beam = serve(app, { env: { ECHO: { port: echo }, SINK: { port: sink }, SOURCE: { port: source } } });

export default {
  fetch(request, info) {
    return beam.fetch(request, info);
  },
};
