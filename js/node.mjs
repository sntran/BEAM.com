// The BEAM in Node.js (25 or later, for JSPI): a native app.com (beam.com
// INPUT -o app.com) with the WebAssembly runtime of this package.
//
//   import { boot } from 'beam.com';
//   const vm = await boot('app.com', { env: { PORT: '4000' } });
//   const response = await vm.fetch(new Request('http://localhost/'));
//
// worker.js of the runtime is the code of the Workers. Its TCP sockets use
// node:net. It imports beam.wasm as a WebAssembly.Module, as in Workers,
// and Node.js imports a .wasm file as an instance: the hook gives the
// module to the files of runtime/ only.
import { registerHooks } from 'node:module';
import fs from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
// app-com.js and runtime-id.js import nothing: they load before the hooks.
import { appFiles, appRelease } from '../runtime/app-com.js';
import runtimeId from '../runtime/runtime-id.js';

const runtimeUrl = new URL('../runtime/', import.meta.url);
const wasmUrl = new URL('beam.wasm', runtimeUrl);
const WASM = 'beam-com:beam.wasm';

registerHooks({
  resolve(spec, ctx, next) {
    if (spec === './beam.wasm' && ctx.parentURL?.startsWith(runtimeUrl.href)) {
      return { url: WASM, shortCircuit: true };
    }
    return next(spec, ctx);
  },
  load(url, ctx, next) {
    if (url !== WASM) return next(url, ctx);
    return {
      format: 'module',
      shortCircuit: true,
      source: 'import fs from "node:fs";\n'
        + `export default await WebAssembly.compile(fs.readFileSync(${JSON.stringify(fileURLToPath(wasmUrl))}));\n`,
    };
  },
});

export { appRelease, runtimeId };

// The release of an app.com for this runtime (release.bin as an
// ArrayBuffer). The file must come from the beam.com of the version of
// this package: app-com.js refuses a file for another runtime.
export function release(app) {
  return readApp(app, appRelease);
}

// The release of app with get (appRelease, or appFiles: no copy).
async function readApp(app, get) {
  const file = await fs.open(app);
  try {
    const { size } = await file.stat();
    const read = async (at, n) => {
      const b = new Uint8Array(n);
      const { bytesRead } = await file.read(b, 0, n, at);
      return b.subarray(0, bytesRead);
    };
    return await get(read, size, { runtime: runtimeId });
  } finally {
    await file.close();
  }
}

// The VM of an app.com, when it is ready. env: the variables of the VM.
// There is no cache for snapshots in Node.js, so BEAM_SNAPSHOT is "off".
// The VM keeps its state between requests (plain: false), as in Deno.
export async function boot(app, { env = {} } = {}) {
  const bin = await readApp(app, appFiles);
  const { Vm } = await import(new URL('worker.js', runtimeUrl).href);
  const vm = new Vm({ BEAM_SNAPSHOT: 'off', ...env }, { release: bin, plain: false });
  await vm.ready;
  return vm;
}

// A snapshot of the build of an app.com, for serve(app, { snapshot }) of a
// Worker (npx beam.com --snapshot). kind:
// - 'boot-point' (the default): the VM loaded the modules of its boot, and
//   the program did not start. It holds no variable of the app: each VM
//   starts the program with the variables of its host.
// - 'full': the VM after its boot and the warm-up requests (warm, paths).
//   It holds the variables of env and the state of the program. A Phoenix
//   app must give SECRET_KEY_BASE and PHX_HOST, and an app with Ecto
//   SQLite cannot use it (its boot changes the database).
// Gives the bytes of the snapshot.
export async function snapshot(app, { env = {}, warm = [], kind = 'boot-point' } = {}) {
  if (kind !== 'boot-point' && kind !== 'full') throw new Error(`the kind of snapshot is boot-point or full, not ${kind}`);
  const bin = await readApp(app, appFiles);
  const { Vm, releaseMeta } = await import(new URL('worker.js', runtimeUrl).href);
  const meta = releaseMeta(bin);
  if (kind === 'full') {
    if (meta.sql) throw new Error(`${app}: the app has Ecto SQLite: use a snapshot at the boot point`);
    const missing = ['SECRET_KEY_BASE', 'PHX_HOST'].filter((k) => meta.env?.PHX_SERVER === 'true' && !env[k]);
    if (missing.length) throw new Error(`${app}: a full snapshot of a Phoenix app needs ${missing.join(' and ')}`);
  }
  const vm = new Vm({ BEAM_SNAPSHOT: 'off', ...env }, { release: bin, plain: false, capture: kind });
  let bytes;
  if (kind === 'boot-point') {
    // wasm_host says "ready", and then it stops at the boot point. A boot
    // that fails rejects ready.
    let timer;
    const late = new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(new Error(`${app}: the VM did not stop at the boot point in 120 s`)), 120000);
    });
    try {
      bytes = await Promise.race([vm.captured, vm.ready.then(() => vm.captured), late]);
    } finally {
      clearTimeout(timer);
    }
  } else {
    await vm.ready;
    await vm.listening(Number(env.PORT ?? meta.env?.PORT ?? 4000));
    for (const path of warm) {
      const r = await vm.fetch(new Request(new URL(path, 'http://localhost')));
      await r.arrayBuffer();
      if (r.status >= 500) throw new Error(`${app}: the warm-up request ${path} gave ${r.status}`);
    }
    bytes = await vm.snapshot(false);
  }
  if (!(bytes instanceof Uint8Array)) throw new Error(`${app}: no snapshot (${bytes}): the VM was not quiet`);
  return bytes;
}
