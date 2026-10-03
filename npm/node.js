// The BEAM in Node.js (25 or later, for JSPI): a native app.com (beam.com
// INPUT -o app.com) with the WebAssembly runtime of this package.
//
//   import { boot } from 'beam.com/node';
//   const vm = await boot('app.com', { env: { PORT: '4000' } });
//   const response = await vm.fetch(new Request('http://localhost/'));
//
// worker.js of the runtime is the code of the Workers. It imports two
// modules that only Workers has: cloudflare:sockets (node/sockets.js
// here), and beam.wasm as a WebAssembly.Module. The hooks give them to
// the modules of runtime/ only.
import { registerHooks } from 'node:module';
import fs from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
// app-com.js and runtime-id.js import nothing: they load before the hooks.
import { appRelease } from './runtime/app-com.js';
import runtimeId from './runtime/runtime-id.js';

const runtimeUrl = new URL('./runtime/', import.meta.url);
const wasmUrl = new URL('beam.wasm', runtimeUrl);
const SOCKETS = new URL('./node/sockets.js', import.meta.url).href;
const WASM = 'beam-com:beam.wasm';

registerHooks({
  resolve(spec, ctx, next) {
    if (ctx.parentURL?.startsWith(runtimeUrl.href)) {
      if (spec === 'cloudflare:sockets') return { url: SOCKETS, shortCircuit: true };
      if (spec === './beam.wasm') return { url: WASM, shortCircuit: true };
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
export async function release(app) {
  const file = await fs.open(app);
  try {
    const { size } = await file.stat();
    const read = async (at, n) => {
      const b = new Uint8Array(n);
      const { bytesRead } = await file.read(b, 0, n, at);
      return b.subarray(0, bytesRead);
    };
    return await appRelease(read, size, { runtime: runtimeId });
  } finally {
    await file.close();
  }
}

// The VM of an app.com, when it is ready. env: the variables of the VM.
// There is no cache for snapshots in Node.js, so BEAM_SNAPSHOT is "off".
// The VM keeps its state between requests (plain: false), as in Deno.
export async function boot(app, { env = {} } = {}) {
  const bin = await release(app);
  const { Vm } = await import(new URL('worker.js', runtimeUrl).href);
  const vm = new Vm({ BEAM_SNAPSHOT: 'off', ...env }, { release: bin, plain: false });
  await vm.ready;
  return vm;
}
