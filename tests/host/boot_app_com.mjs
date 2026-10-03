// Boot a native app.com in Node.js with the WebAssembly runtime of DIR
// (beam.com INPUT -o DIR --target wasm32, of the same beam.com): the check
// that one file runs natively and in the runtime. It needs JSPI (Node.js 25
// or later).
//
//   node tests/host/boot_app_com.mjs DIR APP.com [--get PATH] [--expect TEXT]
//
// The release comes from APP.com through app-com.js of DIR, with the
// identity of the runtime of DIR (runtime-id.js). Before the boot, each
// .beam of the release must be a module after one gunzip at most: a
// deflated entry of a gzip file would give a gzip file in a gzip file,
// and the VM would not load that module. With --get, the check sends GET
// PATH to the app when it is ready: the status must be 200, and the body
// must have TEXT. Without --get, the output of the program must have TEXT
// (a program that stops, as a script). BOOT_ENV (JSON) gives more
// variables of the VM, for example SECRET_KEY_BASE. The check stops after
// 120 s.
import { registerHooks } from 'node:module';
import { gunzipSync } from 'node:zlib';
import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const args = process.argv.slice(2);
const option = (name) => { const i = args.indexOf(name); return i < 0 ? null : args.splice(i, 2)[1]; };
const get = option('--get');
const expect = option('--expect');
const [dir, app] = args;
if (!dir || !app) {
  console.error('usage: node tests/host/boot_app_com.mjs DIR APP.com [--get PATH] [--expect TEXT]');
  process.exit(2);
}
const runtimeDir = path.resolve(dir);
const done = (ok, text) => { console.log(`boot_app_com: ${ok ? 'ok' : 'FAIL'}: ${text}`); process.exit(ok ? 0 : 1); };
setTimeout(() => done(false, 'no result in 120 s'), 120000).unref();

// worker.js imports beam.wasm as a module, as in Workers: the module
// compiled here. Its TCP sockets use node:net of Node.js.
const wasmFile = path.join(runtimeDir, 'beam.wasm');
registerHooks({
  resolve(spec, ctx, next) {
    if (spec === './beam.wasm') return { url: 'beam-com:beam.wasm', shortCircuit: true };
    return next(spec, ctx);
  },
  load(url, ctx, next) {
    if (url !== 'beam-com:beam.wasm') return next(url, ctx);
    return {
      format: 'module', shortCircuit: true,
      source: `import fs from 'node:fs';\nexport default await WebAssembly.compile(fs.readFileSync(${JSON.stringify(wasmFile)}));`,
    };
  },
});

const t0 = performance.now();
const { default: runtime } = await import(pathToFileURL(path.join(runtimeDir, 'runtime-id.js')).href);
const { appRelease } = await import(pathToFileURL(path.join(runtimeDir, 'app-com.js')).href);
const file = await fs.open(app);
const { size } = await file.stat();
const read = async (at, n) => {
  const b = new Uint8Array(n);
  const { bytesRead } = await file.read(b, 0, n, at);
  return b.subarray(0, bytesRead);
};
let release;
try {
  release = await appRelease(read, size, { runtime });
} catch (e) {
  done(false, e.message);
}
console.log(`boot_app_com: the release of ${path.basename(app)}: ${(release.byteLength / 1048576).toFixed(2)} MB in ${Math.round(performance.now() - t0)} ms`);

// The files of release.bin: "BEAMFS1\n", then for each file a 32-bit
// big-endian length and the path, a 32-bit length and the data.
const bytes = new Uint8Array(release);
const view = new DataView(release);
const utf8 = new TextDecoder();
let beams = 0;
for (let at = 8; at < bytes.length;) {
  const n = view.getUint32(at);
  const name = utf8.decode(bytes.subarray(at + 4, at + 4 + n));
  const m = view.getUint32(at + 4 + n);
  let data = bytes.subarray(at + 8 + n, at + 8 + n + m);
  at += 8 + n + m;
  if (!name.endsWith('.beam')) continue;
  if (data[0] === 0x1f && data[1] === 0x8b) data = gunzipSync(data);
  if (utf8.decode(data.subarray(0, 4)) !== 'FOR1') done(false, `${name}: not a module after one gunzip`);
  beams++;
}
console.log(`boot_app_com: ${beams} modules, each one a module after one gunzip at most`);

// The output of the VM, for --expect without --get.
const native = console.log;
let seen = false;
console.log = (...a) => {
  native(...a);
  if (!get && expect && !seen && a.join(' ').includes(expect)) {
    seen = true;
    done(true, `the program wrote "${expect}"`);
  }
};

const { Vm } = await import(pathToFileURL(path.join(runtimeDir, 'worker.js')).href);
const env = { BEAM_SNAPSHOT: 'off', ...JSON.parse(process.env.BOOT_ENV ?? '{}') };
const vm = new Vm(env, { release, plain: false });
try {
  await vm.ready;
} catch (e) {
  if (!seen) done(false, e.message);
}
if (get) {
  const r = await vm.fetch(new Request(`http://localhost${get}`));
  const body = await r.text();
  if (r.status !== 200) done(false, `GET ${get}: status ${r.status}`);
  if (expect && !body.includes(expect)) done(false, `GET ${get}: no "${expect}" in ${body.length} bytes`);
  done(true, `GET ${get}: 200, ${body.length} bytes${expect ? `, with "${expect}"` : ''}`);
}
