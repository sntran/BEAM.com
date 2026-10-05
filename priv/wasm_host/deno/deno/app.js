// The bytes of the app.com of the project, when the entry gives them with
// serve(app) of deno.js, in place of a path (the first argument of
// deno.js, or BEAM_APP). release-bin.js reads them at the first request.
export let app = null;
// false: the static files of a Phoenix app stay in the release of the VM
// (the option statics of serve(app)).
export let statics = true;

export function use(bytes, split = true) {
  app = bytes;
  statics = split;
}
