// The two formats of a snapshot (worker.js): BEAMSNP1, the pages as they
// are, and BEAMSNZ1, the pages in gzip (packSnapshot), with the same
// header. "node --test tests/host". The imports of the runtime are
// stand-ins, because these tests do not start a VM.
import { register } from 'node:module';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

register(`data:text/javascript,${encodeURIComponent(`
  const stub = { './beam.mjs': 'export default () => {};', './beam.wasm': 'export default null;' };
  export async function resolve(spec, ctx, next) {
    return spec in stub ? { url: 'data:text/javascript,' + encodeURIComponent(stub[spec]), shortCircuit: true }
                        : next(spec, ctx);
  }`)}`);
const { packSnapshot, parseSnapshot, inflateSnapshot, snapshotHeader, erlFlags, allocFlags, WAIT_FLAGS } =
  await import('../../priv/wasm_host/worker/worker.js');

const PAGE = 65536;

// A snapshot of BEAMSNP1 with the pages 0 and 2 of a VM, and one page of
// a NIF library: each page has its own pattern.
function snapshot(head = {}) {
  const h = new TextEncoder().encode(JSON.stringify({
    size: 4 * PAGE, pages: [0, 2], fs: { files: {}, streams: [] }, listeners: {}, boot_point: true,
    release: 'r1', flags: '-Mea min', nifs: { count: 1, libs: [{ pages: [5] }] }, ...head,
  }));
  const pages = new Uint8Array(3 * PAGE).map((_, i) => (i >> 16) * 7 + (i % 251));
  const out = new Uint8Array(12 + h.length + pages.length);
  out.set(new TextEncoder().encode('BEAMSNP1'));
  new DataView(out.buffer).setUint32(8, h.length);
  out.set(h, 12);
  out.set(pages, 12 + h.length);
  return { bytes: out, pages };
}

test('packSnapshot gives BEAMSNZ1 with the same header, and smaller', async () => {
  const { bytes } = snapshot();
  const packed = await packSnapshot(bytes);
  assert.equal(new TextDecoder().decode(packed.subarray(0, 8)), 'BEAMSNZ1');
  assert.ok(packed.length < bytes.length / 4, `${packed.length} of ${bytes.length}`);
  assert.deepEqual(snapshotHeader(packed), snapshotHeader(bytes));
  assert.equal(snapshotHeader(packed).flags, '-Mea min');
});

test('the pages of BEAMSNZ1 inflate to the pages of BEAMSNP1', async () => {
  const { bytes, pages } = snapshot();
  const snap = parseSnapshot(await packSnapshot(bytes));
  assert.equal(snap.pagesData, null);
  await inflateSnapshot(snap);
  assert.deepEqual(snap.pagesData, pages);
  assert.equal(snap.packed, null);
  // BEAMSNP1 has its pages at once.
  const plain = parseSnapshot(bytes);
  assert.deepEqual(plain.pagesData, pages);
  assert.equal(await inflateSnapshot(plain), plain);
});

test('packSnapshot of BEAMSNZ1 gives it as it is', async () => {
  const packed = await packSnapshot(snapshot().bytes);
  assert.deepEqual(await packSnapshot(packed), packed);
});

test('BEAMSNZ1 with pages that its header does not give is an error', async () => {
  for (const pages of [[0], [0, 2, 3]]) {
    const { bytes } = snapshot();
    const head = JSON.parse(JSON.stringify(snapshotHeader(bytes)));
    const snap = { ...parseSnapshot(await packSnapshot(bytes)), ...head, pages };
    await assert.rejects(inflateSnapshot(snap), /snapshot: (more|fewer) pages than its header gives/);
  }
});

test('a file that is not a snapshot', () => {
  assert.throws(() => parseSnapshot(new TextEncoder().encode('BEAMSNX1\0\0\0\0{}')), /not a snapshot/);
});

test('allocFlags: an 8 MB carrier threshold for binaries and heaps, except with -Mea', () => {
  assert.deepEqual(allocFlags([]), ['-MBsbct', '8192', '-MHsbct', '8192']);
  assert.deepEqual(allocFlags(['-MBsbct', '4096']), ['-MBsbct', '8192', '-MHsbct', '8192']);
  assert.deepEqual(allocFlags(['-Mea', 'min']), []);
});

test('WAIT_FLAGS: no busy wait of the schedulers', () => {
  assert.deepEqual(WAIT_FLAGS, ['-sbwt', 'none', '-sbwtdcpu', 'none', '-sbwtdio', 'none']);
});

// The VM that restores a snapshot keeps the flags of the VM that made it.
test('snapshot.mjs starts its VM with WAIT_FLAGS and allocFlags of worker.js', () => {
  const text = fs.readFileSync(new URL('../../wasm/snapshot/snapshot.mjs', import.meta.url), 'utf8');
  const start = text.indexOf("m.arguments.push('-S'");
  const push = text.slice(start, text.indexOf("'--'", start)).replace(/\s+/g, ' ');
  const flags = [...WAIT_FLAGS, ...allocFlags([])].map((x) => `'${x}'`).join(', ');
  assert.ok(start > 0 && push.includes(flags), push);
});

test('erlFlags: the flags as one text', () => {
  assert.equal(erlFlags({}), '');
  assert.equal(erlFlags({ BEAM_ERL_FLAGS: '  -Mea   min ' }), '-Mea min');
  assert.equal(erlFlags({ BEAM_ERL_FLAGS: '-Mea min\t+S 1' }), '-Mea min +S 1');
});
