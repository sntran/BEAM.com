// The reader of a native app.com (priv/wasm_host/worker/app-com.js):
// "node --test tests/host". The zip files of these tests are made here,
// with the layout that beam.com writes: native code first, then the
// entries, and the edge part (.wasm/) at the end.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { gunzipSync } from 'node:zlib';
import { appRelease, bytesReader, crc32, zipEntries } from '../../priv/wasm_host/worker/app-com.js';

const enc = new TextEncoder();
const dec = new TextDecoder();
const bytes = (d) => (typeof d === 'string' ? enc.encode(d) : d);

async function deflate(b) {
  const s = new Blob([b]).stream().pipeThrough(new CompressionStream('deflate-raw'));
  return new Uint8Array(await new Response(s).arrayBuffer());
}

// A zip file: files is [{name, data, method (0 or 8), crc}], with prefix
// before the first entry (the native code) and a comment after the end
// record. zip64: the end record of a zip64 file.
async function zip(files, { prefix = 'MZqFpD native code', comment = '', zip64 = false } = {}) {
  const parts = [bytes(prefix)];
  let at = parts[0].length;
  const central = [];
  for (const f of files) {
    const data = bytes(f.data);
    const name = enc.encode(f.name);
    const method = f.method ?? 0;
    const body = method === 8 ? await deflate(data) : data;
    const crc = f.crc ?? crc32(data);
    const h = new DataView(new ArrayBuffer(30));
    h.setUint32(0, 0x04034b50, true); h.setUint16(4, 20, true); h.setUint16(8, method, true);
    h.setUint32(14, crc, true); h.setUint32(18, body.length, true); h.setUint32(22, data.length, true);
    h.setUint16(26, name.length, true);
    parts.push(new Uint8Array(h.buffer), name, body);
    central.push({ name, method, crc, csize: body.length, size: data.length, offset: at });
    at += 30 + name.length + body.length;
  }
  const cdAt = at;
  for (const e of central) {
    const c = new DataView(new ArrayBuffer(46));
    c.setUint32(0, 0x02014b50, true); c.setUint16(10, e.method, true); c.setUint32(16, e.crc, true);
    c.setUint32(20, e.csize, true); c.setUint32(24, e.size, true); c.setUint16(28, e.name.length, true);
    c.setUint32(42, e.offset, true);
    parts.push(new Uint8Array(c.buffer), e.name);
    at += 46 + e.name.length;
  }
  const note = bytes(comment);
  const end = new DataView(new ArrayBuffer(22));
  end.setUint32(0, 0x06054b50, true);
  end.setUint16(8, zip64 ? 0xffff : central.length, true); end.setUint16(10, zip64 ? 0xffff : central.length, true);
  end.setUint32(12, at - cdAt, true); end.setUint32(16, cdAt, true); end.setUint16(20, note.length, true);
  parts.push(new Uint8Array(end.buffer), note);
  const out = new Uint8Array(parts.reduce((s, p) => s + p.length, 0));
  let i = 0;
  for (const p of parts) { out.set(p, i); i += p.length; }
  return out;
}

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

test('crc32: the check value of CRC-32', () => {
  assert.equal(crc32(enc.encode('123456789')), 0xcbf43926);
  assert.equal(crc32(new Uint8Array()), 0);
});
