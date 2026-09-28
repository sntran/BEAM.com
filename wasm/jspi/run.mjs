// Runs a WASI reactor whose pthreads are green threads on JSPI (jspi_pthread.c).
import { WASI } from 'node:wasi';
import { readFileSync } from 'node:fs';

const wasi = new WASI({ version: 'preview1', args: [], env: {}, returnOnExit: true });
const waiters = new Map();   // thread -> resolve function of its suspend
const early = new Set();     // resumed before it suspended
let threadEntry;

const jspi = {
  spawn(t) {
    setImmediate(() => threadEntry(t).catch(fail));
  },
  suspend: new WebAssembly.Suspending((t, ms) => new Promise(resolve => {
    if (early.delete(t)) return resolve(1);
    let timer = null;
    waiters.set(t, () => { if (timer) clearTimeout(timer); waiters.delete(t); resolve(1); });
    if (ms >= 0) timer = setTimeout(() => { waiters.delete(t); resolve(0); }, ms);
  })),
  resume(t) {
    const w = waiters.get(t);
    if (w) queueMicrotask(w); else early.add(t);
  },
  yield: new WebAssembly.Suspending(() => new Promise(r => setImmediate(r))),
};

function fail(e) { console.error(e); process.exit(2); }

const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]),
  { wasi_snapshot_preview1: wasi.wasiImport, jspi });
wasi.initialize(instance);
threadEntry = WebAssembly.promising(instance.exports.jspi_thread_entry);
let finished = false;
process.on('beforeExit', () => { if (!finished) { console.error('deadlock: all threads wait'); process.exit(3); } });
const code = await WebAssembly.promising(instance.exports.jspi_main)().catch(fail);
finished = true;
process.exit(code);
