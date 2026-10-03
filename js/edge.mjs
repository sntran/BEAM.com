#!/usr/bin/env node
// npx beam-edge APP.com -o DIR: the directory of "beam.com INPUT -o DIR
// --target wasm32" from a native app.com and the runtime of this package,
// with no beam.com. The same DIR deploys to Cloudflare Workers (wrangler
// deploy), Deno Deploy (deno.js) and a static site (DIR/page/).
//
// - The runtime: the files of runtime/ (scripts/npm.sh), the same for
//   each app.
// - The files that depend on the app: the edge part of APP.com
//   (.wasm/host/, beam_com_wasm:host_files/2), with a new SECRET_KEY_BASE
//   in worker.capnp.
// - The release: release/release.bin, from the edge part (app-com.js),
//   and page/app/, the files of priv/static of the app.
//
// The file must come from the beam.com of the version of this package:
// app-com.js refuses a file for another runtime. The boot loads the
// modules one by one: the native build does not run the app (--target
// wasm32 does, to find the modules of the boot).
import { randomBytes } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const KEY_MARK = '@SECRET_KEY_BASE@';
// The files of runtime/ that are not files of DIR.
const PACKAGE_ONLY = new Set(['package.json', 'release.json']);

// The files of a release.bin (ArrayBuffer): [[path, Uint8Array]].
export function unpack(bin) {
  const bytes = new Uint8Array(bin);
  const view = new DataView(bin);
  const utf8 = new TextDecoder();
  if (utf8.decode(bytes.subarray(0, 8)) !== 'BEAMFS1\n') throw new Error('not a release.bin');
  const files = [];
  for (let at = 8; at < bytes.length;) {
    const n = view.getUint32(at);
    const name = utf8.decode(bytes.subarray(at + 4, at + 4 + n));
    const m = view.getUint32(at + 4 + n);
    files.push([name, bytes.subarray(at + 8 + n, at + 8 + n + m)]);
    at += 8 + n + m;
  }
  return files;
}

// The files of priv/static of the app NAME, as the page serves them
// (beam_com_wasm:static_files/2): [["/PATH", data]], with no copy that the
// app compresses (.gz, .br), and no name that starts with ".".
export function staticFiles(name, files) {
  const prefix = `lib/${name}-`;
  const out = [];
  for (const [p, d] of files) {
    if (!p.startsWith(prefix)) continue;
    const [, priv, stat, ...parts] = p.slice(prefix.length).split('/');
    if (priv !== 'priv' || stat !== 'static' || parts.length === 0) continue;
    if (/\.(gz|br)$/.test(p) || parts.some((x) => x.startsWith('.'))) continue;
    out.push([`/${parts.join('/')}`, d]);
  }
  return out.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
}

// The files of a directory, as paths relative to it.
function tree(dir, base = dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = path.join(dir, e.name);
    return e.isDirectory() ? tree(p, base) : [path.relative(base, p)];
  });
}

function write(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, data);
}

// Writes DIR. runtime: the directory of the runtime (runtime/ of this
// package). Gives the name of the app and the number of files.
export async function edge(app, out, { runtime = fileURLToPath(new URL('../runtime/', import.meta.url)), key } = {}) {
  const { appHost, appRelease } = await import(pathToFileURL(path.join(runtime, 'app-com.js')).href);
  const { default: runtimeId } = await import(pathToFileURL(path.join(runtime, 'runtime-id.js')).href);
  const file = await fs.promises.open(app);
  let bin, host;
  try {
    const { size } = await file.stat();
    const read = async (at, n) => {
      const b = new Uint8Array(n);
      const { bytesRead } = await file.read(b, 0, n, at);
      return b.subarray(0, bytesRead);
    };
    bin = await appRelease(read, size, { runtime: runtimeId });
    host = await appHost(read, size);
  } finally {
    await file.close();
  }
  if (host.size === 0) throw new Error(`${app}: no files of the hosts (.wasm/host/): build it with a newer beam.com`);
  if (fs.existsSync(out) && !fs.statSync(out).isDirectory()) throw new Error(`${out}: a file; DIR is a directory`);
  for (const f of tree(runtime)) {
    if (!PACKAGE_ONLY.has(f)) write(path.join(out, f), fs.readFileSync(path.join(runtime, f)));
  }
  const secret = key ?? randomBytes(48).toString('base64');
  for (const [f, d] of host) {
    const data = f === 'worker.capnp' ? new TextDecoder().decode(d).replaceAll(KEY_MARK, secret) : d;
    write(path.join(out, f), data);
  }
  const release = new Uint8Array(bin);
  write(path.join(out, 'release', 'release.bin'), release);
  write(path.join(out, 'page', 'release.bin'), release);
  write(path.join(out, 'page', 'beam.wasm'), fs.readFileSync(path.join(runtime, 'beam.wasm')));
  const files = unpack(bin);
  const { name } = JSON.parse(new TextDecoder().decode(files[0][1]));
  const statics = staticFiles(name, files);
  write(path.join(out, 'page', 'app', 'static.json'), JSON.stringify(statics.map(([p]) => p)));
  for (const [p, d] of statics) write(path.join(out, 'page', 'app', p), d);
  return { name, files: files.length, statics: statics.length };
}

const main = process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
if (main) {
  const args = process.argv.slice(2);
  const o = args.indexOf('-o');
  const out = o < 0 ? null : args.splice(o, 2)[1];
  if (args.length !== 1 || !out) {
    console.error('usage: beam-edge APP.com -o DIR');
    process.exit(2);
  }
  try {
    const { name, files, statics } = await edge(args[0], out);
    console.log(`beam-edge: wrote ${out} (${name}: ${files} files in the release, ${statics} static files)\n`
      + `  Workers: (cd ${out}/release && wrangler deploy) && (cd ${out} && wrangler deploy)\n`
      + `  Deno: cd ${out} && deno serve -A deno.js\n`
      + `  web page: ${out}/page (a static site)`);
  } catch (e) {
    console.error(`beam-edge: ${e.message}`);
    process.exit(1);
  }
}
