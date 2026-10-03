// The release of a Worker that Wrangler bundles (cloudflare/worker.js and
// cloudflare/durable.js): the edge part of the app.com of the project, as
// release.bin gives it. serve(app) of index.js gives the file (use). It
// runs at the top level of the entry of the Worker, so each isolate has
// the file, also an isolate that runs only the Durable Object.
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
    throw new Error("beam.com: no app.com: call serve(app) in the entry of the Worker");
  }
  const { read, size } = bytesReader(app);
  return appRelease(read, size, { runtime });
}
