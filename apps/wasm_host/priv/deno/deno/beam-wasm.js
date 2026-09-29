// The runtime as a WebAssembly.Module, as the import of a .wasm file gives
// it in Workers.
export default await WebAssembly.compile(await Deno.readFile(new URL('../beam.wasm', import.meta.url)));
