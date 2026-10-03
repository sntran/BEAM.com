// The module "beam.com" of the npm package in a Worker (the condition
// "workerd" of its exports, which Wrangler uses): a Worker that runs the
// app.com of the project, with the runtime of this package (see release.js
// for the entry of the Worker). The default export sends each request to the Durable Object
// Beam (durable.js: one VM, and its SQLite storage for Ecto SQLite); plain
// is a Worker with one VM for each isolate (worker.js).
export { use } from './release.js';
export { Beam, default } from './durable.js';
export { default as plain } from './worker.js';
