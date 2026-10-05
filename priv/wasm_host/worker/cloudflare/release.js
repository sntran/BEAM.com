// The release of a Worker that Wrangler bundles (cloudflare/worker.js and
// cloudflare/durable.js): the edge part of the app.com of the project, as
// appFiles gives it (views of the file, no copy). serve(app) of index.js
// gives the file (use). It
// runs at the top level of the entry of the Worker, so each isolate has
// the file, also an isolate that runs only the Durable Object.
//
// The file must come from the beam.com of the version of this package:
// app-com.js refuses a file for another runtime. worker.js reads the
// release at the first request of an isolate, not in the global scope.
import { inflateRawSync } from 'node:zlib';
import { appFiles, bytesReader } from '../app-com.js';
import runtime from '../runtime-id.js';

// The global scope of a Worker cannot use DecompressionStream (a VM that
// serve(app, { snapshot }) restores there reads the release first).
const inflate = async (raw) => new Uint8Array(inflateRawSync(raw));

let app = null;
let modules = null;
let split = true;

// nifModules: the NIF libraries in WebAssembly of app.com, compiled by
// Wrangler (nifs.js of "beam.com --nif-modules"), or null. statics: false
// keeps the static files of a Phoenix app in the release of the VM (see
// serve(app) of index.js).
export function use(bytes, nifModules = null, statics = true) {
  app = bytes;
  modules = nifModules;
  split = statics;
}

// For worker.js: the path of each NIF library in /app, and its module.
export function nifs() {
  return modules;
}

// One read of the file for each isolate: the front Worker and its VMs
// share the files (they are views of app.com).
let files = null;

export function release() {
  if (!app) {
    throw new Error("beam.com: no app.com: call serve(app) in the entry of the Worker");
  }
  if (!files) {
    const { read, size } = bytesReader(app);
    files = appFiles(read, size, { runtime, inflate, statics: split });
  }
  return files;
}
