// The bytes of the app.com of the project, when the entry gives them with
// use(app) of deno.js, in place of a path (the first argument of deno.js,
// or BEAM_APP). release-bin.js reads them at the first request.
export let app = null;

export function use(bytes) {
  app = bytes;
}
