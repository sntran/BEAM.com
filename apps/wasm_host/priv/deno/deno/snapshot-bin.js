// snapshot.bin of the build (optional): an ArrayBuffer, else null.
let bytes = null;
try {
  const b = await Deno.readFile(new URL('../release/snapshot.bin', import.meta.url));
  bytes = b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
} catch {}
export default bytes;
