// Moves the static files of a Phoenix app (lib/APP-VSN/priv/static in
// DIR/release/release.bin, of beam.com --target wasm32) to DIR/static, the
// static assets of the Worker: Cloudflare serves them before the Worker
// runs, and they are not in the memory of the isolate. The .gz files are
// written unpacked (Cloudflare compresses). cache_manifest.json stays in the
// release too, because Phoenix reads it at start. The priv/static of
// phoenix, phoenix_html and phoenix_live_view (the sources of app.js) are
// removed. The configurations of wrangler get "assets".
//
//   node static.mjs DIR APP
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

const [dir, app] = process.argv.slice(2);
if (!dir || !app) throw new Error('usage: node static.mjs DIR APP');
const file = path.join(dir, 'release', 'release.bin');
const b = fs.readFileSync(file);
if (b.subarray(0, 8).toString() !== 'BEAMFS1\n') throw new Error(`${file}: not a release`);
const keep = [b.subarray(0, 8)];
const sources = new Set(['phoenix', 'phoenix_html', 'phoenix_live_view']);
let moved = 0, removed = 0;
for (let i = 8; i < b.length;) {
  const start = i;
  const plen = b.readUInt32BE(i); i += 4;
  const p = b.subarray(i, i + plen).toString(); i += plen;
  const dlen = b.readUInt32BE(i); i += 4;
  const data = b.subarray(i, i + dlen); i += dlen;
  const [lib, appDir, priv, stat, ...rest] = p.split('/');
  if (lib === 'lib' && priv === 'priv' && stat === 'static' && rest.length > 0) {
    const name = appDir.slice(0, appDir.lastIndexOf('-'));
    if (name === app) {
      let rel = rest.join('/');
      let bytes = data;
      if (rel.endsWith('.gz')) {
        rel = rel.slice(0, -3);
        bytes = zlib.gunzipSync(data);
      }
      const out = path.join(dir, 'static', rel);
      fs.mkdirSync(path.dirname(out), { recursive: true });
      // A file and its .gz: the file wins.
      if (!p.endsWith('.gz') || !fs.existsSync(out)) fs.writeFileSync(out, bytes);
      moved += bytes.length;
      if (rel !== 'cache_manifest.json' || p.endsWith('.gz')) continue;
    } else if (sources.has(name)) {
      removed += dlen;
      continue;
    }
  }
  keep.push(b.subarray(start, i));
}
fs.writeFileSync(file, Buffer.concat(keep));
for (const f of fs.readdirSync(dir).filter((f) => /^wrangler.*\.jsonc$/.test(f))) {
  const p = path.join(dir, f);
  const s = fs.readFileSync(p, 'utf8');
  if (s.includes('"assets"')) continue;
  fs.writeFileSync(p, s.replace(/\n}\s*$/, ',\n  "assets": { "directory": "static" }\n}\n'));
}
console.log(`${file}: ${fs.statSync(file).size >> 10} KB; static: ${moved >> 10} KB; removed: ${removed >> 10} KB`);
