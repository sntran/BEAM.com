// The reader of a native app.com (priv/wasm_host/worker/app-com.js):
// "node --test tests/host". The zip files of these tests come from
// zip.mjs, with the layout that beam.com writes: native code first, then
// the entries, and the edge part (.wasm/) at the end.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { gunzipSync, inflateRawSync } from 'node:zlib';
import { appFiles, appRelease, bytesReader, crc32, zipEntries } from '../../priv/wasm_host/worker/app-com.js';
import { zip } from './zip.mjs';

const enc = new TextEncoder();
const dec = new TextDecoder();
const bytes = (d) => (typeof d === 'string' ? enc.encode(d) : d);

// The files of release.bin: [[path, Uint8Array], ...] in their order.
function unpack(buffer) {
  const b = new Uint8Array(buffer);
  const v = new DataView(buffer);
  assert.equal(dec.decode(b.subarray(0, 8)), 'BEAMFS1\n');
  const out = [];
  for (let i = 8; i < b.length;) {
    const plen = v.getUint32(i); const p = dec.decode(b.subarray(i + 4, i + 4 + plen)); i += 4 + plen;
    const dlen = v.getUint32(i); out.push([p, b.subarray(i + 4, i + 4 + dlen)]); i += 4 + dlen;
  }
  return out;
}

const META = { name: 'app', vsn: '1.0.0', args: ['-boot', '/app/releases/1.0.0/start'], runtime: 'aa11', snapshot_key: 'k' };
const BEAM = 'FOR1\0\0\0\x10BEAMAtU8 the code of a module';

// An app.com with a native release and its edge part.
const app = () => zip([
  { name: 'bin/start_clean.boot', data: 'not of the release' },
  { name: 'lib/', data: '' },
  { name: 'lib/a-1.0/ebin/a.beam', data: BEAM, method: 8 },
  { name: 'lib/a-1.0/ebin/a.app', data: '{application, a, []}.', method: 8 },
  { name: 'lib/a-1.0/priv/x.txt', data: 'priv' },
  { name: 'licenses/NOTICE', data: 'between the entries of the release' },
  { name: 'releases/1.0.0/start.boot', data: 'the native boot' },
  { name: 'releases/1.0.0/vm.args', data: '-noshell\n-boot_var RELEASE_LIB /zip/lib\n' },
  { name: '.wasm/.release.json', data: JSON.stringify(META), method: 8 },
  { name: '.wasm/releases/1.0.0/start.boot', data: 'the boot with wasm_host', method: 8 },
  { name: '.wasm/releases/1.0.0/vm.args', data: '-noshell\n' },
  { name: '.wasm/lib/wasm_host-0.1.0/ebin/wasm_host.beam', data: BEAM, method: 8 },
]);

test('the release of an app.com: lib/ and releases/, with the edge part in its place', async () => {
  const { read, size } = bytesReader(await app());
  const files = unpack(await appRelease(read, size, { runtime: 'aa11' }));
  const get = (p) => files.find(([q]) => q === p)?.[1];
  assert.equal(files[0][0], '.release.json');
  assert.deepEqual(JSON.parse(dec.decode(files[0][1])), META);
  assert.deepEqual(files.map(([p]) => p).sort(), [
    '.release.json', 'lib/a-1.0/ebin/a.app', 'lib/a-1.0/ebin/a.beam', 'lib/a-1.0/priv/x.txt',
    'lib/wasm_host-0.1.0/ebin/wasm_host.beam', 'releases/1.0.0/start.boot', 'releases/1.0.0/vm.args',
  ]);
  assert.equal(dec.decode(get('releases/1.0.0/start.boot')), 'the boot with wasm_host');
  assert.equal(dec.decode(get('releases/1.0.0/vm.args')), '-noshell\n');
  assert.equal(dec.decode(get('lib/a-1.0/ebin/a.app')), '{application, a, []}.');
  assert.equal(dec.decode(get('lib/a-1.0/priv/x.txt')), 'priv');
  // A deflated .beam file: a gzip file with the same data.
  for (const p of ['lib/a-1.0/ebin/a.beam', 'lib/wasm_host-0.1.0/ebin/wasm_host.beam']) {
    assert.deepEqual([...get(p).subarray(0, 3)], [0x1f, 0x8b, 8]);
    assert.equal(dec.decode(gunzipSync(get(p))), BEAM);
  }
});

test('three reads: the end of the file, the central directory, the span of the release', async () => {
  const file = await app();
  const reads = [];
  const read = async (at, n) => { reads.push([at, n]); return file.subarray(at, at + n); };
  await appRelease(read, file.length);
  assert.equal(reads.length, 3);
  const { entries, cdAt } = await zipEntries(read, file.length);
  const first = Math.min(...entries.filter((e) => e.name.startsWith('lib/a')).map((e) => e.offset));
  assert.deepEqual(reads[2], [first, cdAt - first]);
});

test('a file for another runtime', async () => {
  const { read, size } = bytesReader(await app());
  await assert.rejects(appRelease(read, size, { runtime: 'bb22' }),
                       /app.com: it was built for the runtime aa11, and this runtime is bb22/);
});

test('a native file with no edge part (--no-edge)', async () => {
  const { read, size } = bytesReader(await zip([{ name: 'lib/a-1.0/ebin/a.app', data: 'x' }]));
  await assert.rejects(appRelease(read, size), /app.com: no edge part \(.wasm\/.release.json\)/);
});

test('a bad CRC-32', async () => {
  const file = await zip([
    { name: 'lib/a-1.0/ebin/a.app', data: 'x', crc: 1234 },
    { name: '.wasm/.release.json', data: JSON.stringify(META) },
  ]);
  const { read, size } = bytesReader(file);
  await assert.rejects(appRelease(read, size), /app.com: lib\/a-1.0\/ebin\/a.app: the CRC-32 does not match/);
});

test('a compression method other than stored and deflated', async () => {
  const file = await zip([
    { name: 'lib/a-1.0/ebin/a.app', data: 'x', method: 12 },
    { name: '.wasm/.release.json', data: JSON.stringify(META) },
  ]);
  const { read, size } = bytesReader(file);
  await assert.rejects(appRelease(read, size), /the compression method 12 is not supported/);
});

test('not a zip file, and a zip64 file', async () => {
  const junk = bytesReader(enc.encode('MZ only native code, and no zip at all'));
  await assert.rejects(appRelease(junk.read, junk.size), /app.com: not a zip file/);
  const big = bytesReader(await zip([{ name: 'a', data: 'x' }], { zip64: true }));
  await assert.rejects(appRelease(big.read, big.size), /a zip64 file is not supported/);
});

test('an end record in the comment of the file does not count', async () => {
  // The comment has the bytes of an end record, but it does not end the file there.
  const fake = 'PK\x05\x06' + '\0'.repeat(18);
  const { read, size } = bytesReader(await zip([
    { name: 'lib/a-1.0/ebin/a.app', data: 'x' },
    { name: '.wasm/.release.json', data: JSON.stringify(META) },
  ], { comment: `${fake} and more text` }));
  const files = unpack(await appRelease(read, size));
  assert.deepEqual(files.map(([p]) => p), ['.release.json', 'lib/a-1.0/ebin/a.app']);
});

test('bytesReader: an ArrayBuffer, and a view into a larger buffer', async () => {
  const file = await app();
  const big = new Uint8Array(file.length + 10);
  big.set(file, 5);
  for (const r of [bytesReader(file.buffer), bytesReader(big.subarray(5, 5 + file.length))]) {
    assert.equal(r.size, file.length);
    assert.equal(unpack(await appRelease(r.read, r.size))[0][0], '.release.json');
  }
});

// A Phoenix app (PHX_SERVER): its static files, stored and deflated, and a
// gzip .beam file, which the zip of beam.com stores.
const PHX = { ...META, name: 'web', env: { PHX_SERVER: 'true' } };
const GZ_BEAM = new Uint8Array([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3, 1, 2, 3]);
const phoenix = () => zip([
  { name: 'lib/web-1.0/ebin/web.beam', data: GZ_BEAM },
  { name: 'lib/web-1.0/priv/static/app.js', data: 'console.log(1)', method: 8 },
  { name: 'lib/web-1.0/priv/static/images/logo.png', data: 'PNG' },
  { name: 'lib/web-1.0/priv/static/cache_manifest.json', data: '{}' },
  { name: 'lib/web-1.0/priv/other.txt', data: 'not static' },
  { name: 'lib/dep-2.0/priv/static/dep.js', data: 'of a dependency' },
  { name: '.wasm/.release.json', data: JSON.stringify(PHX) },
]);

test('appFiles: the files with no copy, and the static files of a Phoenix app', async () => {
  const file = await phoenix();
  const { read, size } = bytesReader(file);
  const r = await appFiles(read, size);
  const paths = r.files.map(([p]) => p).sort();
  assert.deepEqual(paths, [
    'lib/dep-2.0/priv/static/dep.js', 'lib/web-1.0/ebin/web.beam', 'lib/web-1.0/priv/other.txt',
    'lib/web-1.0/priv/static/cache_manifest.json',
  ]);
  assert.deepEqual(JSON.parse(dec.decode(r.meta)), PHX);
  // A stored entry is a view of the file: the .beam file too.
  const beam = r.files.find(([p]) => p === 'lib/web-1.0/ebin/web.beam')[1];
  assert.equal(beam.buffer, file.buffer);
  assert.deepEqual([...beam], [...GZ_BEAM]);
  assert.ok(r.buffers.has(file.buffer));
  assert.equal(r.byteLength, r.meta.length + r.files.reduce((n, [, d]) => n + d.length, 0));
  // The static files, at their paths on the site.
  assert.deepEqual([...r.statics.keys()].sort(), ['/app.js', '/images/logo.png']);
  const logo = r.statics.get('/images/logo.png');
  assert.equal(logo.data.buffer, file.buffer);
  assert.deepEqual({ size: logo.size, deflated: logo.deflated }, { size: 3, deflated: false });
  const js = r.statics.get('/app.js');
  assert.equal(js.deflated, true);
  assert.equal(js.crc, crc32(enc.encode('console.log(1)')));
  // appRelease keeps the static files in the release.
  const all = unpack(await appRelease(read, size)).map(([p]) => p);
  assert.ok(all.includes('lib/web-1.0/priv/static/app.js'));
});

test('appFiles: the inflate of the option for each deflated entry (a Worker in its global scope)', async () => {
  const { read, size } = bytesReader(await phoenix());
  const seen = [];
  const inflate = async (raw) => {
    seen.push(raw.length);
    return new Uint8Array(inflateRawSync(raw));
  };
  const r = await appFiles(read, size, { inflate, statics: false });
  // app.js is the one deflated entry that is not a .beam file.
  assert.equal(seen.length, 1);
  const js = r.files.find(([p]) => p === 'lib/web-1.0/priv/static/app.js')[1];
  assert.equal(dec.decode(js), 'console.log(1)');
});

test('appFiles: no static files for an app that is not a Phoenix app', async () => {
  const { read, size } = bytesReader(await zip([
    { name: 'lib/app-1.0/priv/static/app.js', data: 'x' },
    { name: '.wasm/.release.json', data: JSON.stringify({ ...META, name: 'app' }) },
  ]));
  const r = await appFiles(read, size);
  assert.equal(r.statics.size, 0);
  assert.deepEqual(r.files.map(([p]) => p), ['lib/app-1.0/priv/static/app.js']);
});

test('crc32: the check value of CRC-32', () => {
  assert.equal(crc32(enc.encode('123456789')), 0xcbf43926);
  assert.equal(crc32(new Uint8Array()), 0);
});
