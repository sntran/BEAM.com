// The release of a Worker that Wrangler bundles (cloudflare/worker.js and
// cloudflare/durable.js): the edge part of the app.com of the project, as
// release.bin gives it. The entry of the Worker gives the file with use(),
// as a Data module (an ArrayBuffer):
//
//   import app from './app.com';
//   import { use } from 'beam.com/cloudflare';
//   use(app);
//   export { default, Beam } from 'beam.com/cloudflare';
//
// with this rule in wrangler.jsonc:
//
//   "rules": [{ "type": "Data", "globs": ["**/*.com"] }]
//
// The file must come from the beam.com of the version of this package:
// app-com.js refuses a file for another runtime. worker.js reads the
// release at the first request of an isolate, not in the global scope.
import { appRelease, bytesReader } from '../app-com.js';
import runtime from '../runtime-id.js';

let app = null;

export function use(bytes) {
  app = bytes;
}

export function release() {
  if (!app) {
    throw new Error("beam.com/cloudflare: no app.com: call use(app) in the entry of the Worker");
  }
  const { read, size } = bytesReader(app);
  return appRelease(read, size, { runtime });
}
