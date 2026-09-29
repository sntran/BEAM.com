// release.bin as an ArrayBuffer, as the import of a Data module gives it in
// Workers.
const b = await Deno.readFile(new URL('../release/release.bin', import.meta.url));
export default b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
