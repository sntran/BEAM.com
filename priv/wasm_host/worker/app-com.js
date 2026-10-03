// The release of a native app.com for the WebAssembly runtime: the same
// file that runs natively runs in the VM of worker.js (Workers, Deno, a
// web page). "beam.com INPUT -o app.com" writes the edge part of the file
// into its zip, under .wasm/ (beam_com_wasm:overlay/4): .release.json
// (the boot of the VM, and the runtime of the build), the application
// wasm_host, the boot script with wasm_host, and the modules in the place
// of NIFs.
//
// appRelease(read, size, { runtime }) gives the release as release.bin
// gives it (an ArrayBuffer, see unpack in worker.js): the files of lib/
// and releases/ of the zip, with the files of .wasm/ in their place, and
// .release.json first.
// - read(at, n): n bytes (a Uint8Array) at the offset at of app.com: a
//   file, a range of a URL, or bytes in memory (bytesReader).
// - size: the size of app.com in bytes.
// - runtime: the identity of this runtime (the text of runtime-id.js of
//   DIR, beam_com_wasm:runtime_id/1). With it, a file for another runtime
//   is an error.
// It reads three parts: the end of the file, the central directory, and
// the span of the release (the edge part is at the end of it).
//
// A deflated .beam entry becomes a gzip file with the same data (the
// loader of ERTS reads it so), with no inflate: the release stays small
// in the memory of the host. The zip of beam.com stores a .beam file that
// is gzip data already (beam_com_zip). Each other entry is checked with
// its CRC-32.

const text = new TextDecoder();
const u16 = (b, i) => b[i] | (b[i + 1] << 8);
const u32 = (b, i) => (b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)) >>> 0;
const fail = (message) => { throw new Error(`app.com: ${message}`); };

const LOCAL = 0x04034b50, CENTRAL = 0x02014b50, END = 0x06054b50;
const STORED = 0, DEFLATED = 8;
// The end record (22 bytes) and a comment of at most 65535 bytes.
const TAIL = 22 + 0xffff;

const CRC = new Uint32Array(256).map((_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});

export function crc32(b) {
  let c = 0xffffffff;
  for (let i = 0; i < b.length; i++) c = CRC[(c ^ b[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

// A reader of bytes in memory (an ArrayBuffer or a typed array).
export function bytesReader(bytes) {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes.buffer ?? bytes, bytes.byteOffset ?? 0, bytes.byteLength);
  return { size: b.length, read: async (at, n) => b.subarray(at, at + n) };
}

// The central directory: {entries, cdAt}, where each entry is {name,
// method, crc, csize, size, offset}.
export async function zipEntries(read, size) {
  const n = Math.min(size, TAIL);
  const tail = await read(size - n, n);
  if (tail.length !== n) fail('a short read at the end of the file');
  // The last end record whose comment ends the file.
  let e = -1;
  for (let i = n - 22; i >= 0; i--) {
    if (u32(tail, i) === END && i + 22 + u16(tail, i + 20) === n) { e = i; break; }
  }
  if (e < 0) fail('not a zip file (no end of central directory)');
  const count = u16(tail, e + 10), cdSize = u32(tail, e + 12), cdAt = u32(tail, e + 16);
  if (count === 0xffff || cdAt === 0xffffffff || cdSize === 0xffffffff) fail('a zip64 file is not supported');
  if (cdAt + cdSize > size) fail('the central directory is outside the file');
  const cd = await read(cdAt, cdSize);
  const entries = [];
  for (let i = 0, k = 0; k < count; k++) {
    if (i + 46 > cd.length || u32(cd, i) !== CENTRAL) fail('a bad central directory');
    const nlen = u16(cd, i + 28), xlen = u16(cd, i + 30), clen = u16(cd, i + 32);
    entries.push({
      name: text.decode(cd.subarray(i + 46, i + 46 + nlen)), method: u16(cd, i + 10),
      crc: u32(cd, i + 16), csize: u32(cd, i + 20), size: u32(cd, i + 24), offset: u32(cd, i + 42),
    });
    i += 46 + nlen + xlen + clen;
  }
  return { entries, cdAt };
}

async function inflate(raw) {
  const s = new Blob([raw]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
  return new Uint8Array(await new Response(s).arrayBuffer());
}

// The same deflate data in a gzip file: a header of 10 bytes, the data,
// the CRC-32 and the size.
function gzipOf(raw, e) {
  const out = new Uint8Array(10 + raw.length + 8);
  out.set([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255]);
  out.set(raw, 10);
  const v = new DataView(out.buffer);
  v.setUint32(10 + raw.length, e.crc, true);
  v.setUint32(14 + raw.length, e.size, true);
  return out;
}

// The data of the entry e, in span (the bytes of the file from offset base).
async function entryData(span, base, e) {
  const h = e.offset - base;
  if (h < 0 || h + 30 > span.length || u32(span, h) !== LOCAL) fail(`${e.name}: no local header`);
  const start = h + 30 + u16(span, h + 26) + u16(span, h + 28);
  if (start + e.csize > span.length) fail(`${e.name}: the data is outside the file`);
  const raw = span.subarray(start, start + e.csize);
  if (e.method === DEFLATED && e.name.endsWith('.beam')) return gzipOf(raw, e);
  let d;
  if (e.method === STORED) d = raw;
  else if (e.method === DEFLATED) d = await inflate(raw);
  else fail(`${e.name}: the compression method ${e.method} is not supported`);
  if (d.length !== e.size || crc32(d) !== e.crc) fail(`${e.name}: the CRC-32 does not match`);
  return d;
}

const EDGE = '.wasm/';
// The files of the hosts that depend on the app (the configurations of
// Workers, the variables of the page): not in the release (appHost).
const HOST = '.wasm/host/';
const inRelease = (name) => !name.startsWith(HOST)
  && (name.startsWith('lib/') || name.startsWith('releases/') || name.startsWith(EDGE));

export async function appRelease(read, size, { runtime } = {}) {
  const { entries, cdAt } = await zipEntries(read, size);
  const want = entries.filter((e) => inRelease(e.name) && !e.name.endsWith('/'));
  const json = want.find((e) => e.name === `${EDGE}.release.json`);
  if (!json) fail('no edge part (.wasm/.release.json): build it with a beam.com that has the WebAssembly runtime, and without --no-edge');
  // One read: the entries of the release, up to the central directory.
  const lo = Math.min(...want.map((e) => e.offset));
  const span = await read(lo, cdAt - lo);
  if (span.length !== cdAt - lo) fail('a short read of the release');
  const meta = await entryData(span, lo, json);
  const release = JSON.parse(text.decode(meta));
  if (runtime && release.runtime !== runtime) {
    fail(`it was built for the runtime ${String(release.runtime).slice(0, 12)}, and this runtime is ${runtime.slice(0, 12)}: `
         + 'use the runtime of the beam.com that built it');
  }
  const files = new Map();
  for (const e of want) if (!e.name.startsWith(EDGE)) files.set(e.name, await entryData(span, lo, e));
  for (const e of want) if (e.name.startsWith(EDGE) && e !== json) files.set(e.name.slice(EDGE.length), await entryData(span, lo, e));
  return pack(meta, files);
}

// The files of the hosts in the edge part (.wasm/host/), as a Map of their
// paths in DIR to their data: wrangler.jsonc, worker.capnp, page/env.json
// and the others of beam_com_wasm:host_files/2. One read, after the
// central directory.
export async function appHost(read, size) {
  const { entries, cdAt } = await zipEntries(read, size);
  const want = entries.filter((e) => e.name.startsWith(HOST) && !e.name.endsWith('/'));
  const files = new Map();
  if (want.length === 0) return files;
  const lo = Math.min(...want.map((e) => e.offset));
  const span = await read(lo, cdAt - lo);
  for (const e of want) files.set(e.name.slice(HOST.length), await entryData(span, lo, e));
  return files;
}

// release.bin: "BEAMFS1\n", then (length, path, length, data) for each
// file, with .release.json first.
function pack(meta, files) {
  const enc = new TextEncoder();
  const parts = [['.release.json', meta], ...files].map(([p, d]) => [enc.encode(p), d]);
  const out = new Uint8Array(8 + parts.reduce((s, [p, d]) => s + 8 + p.length + d.length, 0));
  const v = new DataView(out.buffer);
  out.set(enc.encode('BEAMFS1\n'));
  let i = 8;
  for (const [p, d] of parts) {
    v.setUint32(i, p.length); out.set(p, i + 4); i += 4 + p.length;
    v.setUint32(i, d.length); out.set(d, i + 4); i += 4 + d.length;
  }
  return out.buffer;
}
