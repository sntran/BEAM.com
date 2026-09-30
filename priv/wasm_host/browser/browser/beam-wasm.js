// The module import of beam.wasm in worker.js: the compiled runtime.
export default await WebAssembly.compileStreaming(fetch(new URL('../beam.wasm', import.meta.url)));
