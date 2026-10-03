// A zip file as beam.com writes one, for the tests of app-com.js and of
// js/edge.mjs: native code first, then the entries, and the edge part
// (.wasm/) at the end.
import { crc32 } from '../../priv/wasm_host/worker/app-com.js';

const enc = new TextEncoder();
const bytes = (d) => (typeof d === 'string' ? enc.encode(d) : d);

async function deflate(b) {
  const s = new Blob([b]).stream().pipeThrough(new CompressionStream('deflate-raw'));
  return new Uint8Array(await new Response(s).arrayBuffer());
}

// A zip file: files is [{name, data, method (0 or 8), crc}], with prefix
// before the first entry (the native code) and a comment after the end
// record. zip64: the end record of a zip64 file.
export async function zip(files, { prefix = 'MZqFpD native code', comment = '', zip64 = false } = {}) {
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
