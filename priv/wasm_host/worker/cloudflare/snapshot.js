// The snapshot of the build of the app.com of the project (npx beam.com
// --snapshot), when the entry gives it to serve(app, { snapshot }): each
// new VM restores it in place of a boot. With none, the Worker makes its
// own snapshot (the Cache API, or the R2 bucket SNAPSHOTS).
let bytes = null;

export function useSnapshot(snapshot) {
  bytes = snapshot;
}

export { bytes as default };
