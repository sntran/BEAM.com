// snapshot.bin of the build (optional), next to release.bin: an
// ArrayBuffer, else null.
let bytes = null;
for (const path of ['../snapshot.bin', '../release/snapshot.bin']) {
  try {
    const b = await Deno.readFile(new URL(path, import.meta.url));
    bytes = b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
    break;
  } catch {}
}
export default bytes;
