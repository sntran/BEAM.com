// Unpacks a release.bin (of beam.com --target wasm32) into DIR, as the Worker
// does into /app, and prints a shell script that sets RELEASE_ARGS (the boot
// arguments, with DIR for /app) and RELEASE_ENV (the environment of the
// release, KEY=VALUE words):
//
//   eval "$(node unpack.mjs release.bin DIR)"
import fs from 'node:fs';
import path from 'node:path';

const [file, dir] = process.argv.slice(2);
const b = fs.readFileSync(file);
if (b.subarray(0, 8).toString() !== 'BEAMFS1\n') throw new Error(`${file}: not a release`);
let meta;
for (let i = 8; i < b.length;) {
  const plen = b.readUInt32BE(i); i += 4;
  const p = b.subarray(i, i + plen).toString(); i += plen;
  const dlen = b.readUInt32BE(i); i += 4;
  const data = b.subarray(i, i + dlen); i += dlen;
  if (p === '.release.json') { meta = JSON.parse(data); continue; }
  fs.mkdirSync(path.dirname(path.join(dir, p)), { recursive: true });
  fs.writeFileSync(path.join(dir, p), data);
}
const q = (s) => `'${String(s).replaceAll("'", "'\\''")}'`;
const args = meta.args.map((a) => a.startsWith('/app/') ? dir + a.slice(4) : a);
console.log(`RELEASE_NAME=${q(meta.name)} RELEASE_VSN=${q(meta.vsn)}`);
console.log(`RELEASE_ARGS=${q(args.join(' '))}`);
console.log(`RELEASE_ENV=${q(Object.entries(meta.env).map(([k, v]) => `${k}=${v}`).join(' '))}`);
