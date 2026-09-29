// release.bin as an ArrayBuffer, as the import of a Data module gives it in
// Workers: next to worker.js (one Worker), else in release/ (the Worker with
// the release).
let b;
try {
  b = await Deno.readFile(new URL('../release.bin', import.meta.url));
} catch {
  b = await Deno.readFile(new URL('../release/release.bin', import.meta.url));
}
export default b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
