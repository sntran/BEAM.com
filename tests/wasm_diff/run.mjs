// Runs one program in the Worker build of beam.wasm, in Node.js:
//
//   node run.mjs JOB.json
//
// JOB.json: {"runtime": DIR, "root": OTP_ROOT, "libs": [EBIN...],
//   "boot": BOOT_FILE, "pa": DIR, "eval": EXPR, "schedule": "node" | "plain",
//   "nifs": {FILE: MODULE_FILE} (optional), "snapshot": true (optional),
//   "out": {VM_FILE: FILE} (optional), "ports": {NAME: PROGRAM} (optional)}
//
// The driver copies the boot file, each EBIN directory, and the files of
// "pa" into the memory file system, below the same names as on the disk.
// The VM writes its output to stdout and to stderr, and the exit status
// of the driver is the exit status of the VM.
//
// The schedule "plain" runs the timers of the threads as a plain Worker
// does: all the timers that are due run in one task, one after the other.
//
// A port of the program of the VM (BINDIR/erl, a mark file in the memory
// file system) starts a second VM: an instance of the same module in
// this process (Module.beamHost.spawn), with pipes on its fd 0 and fd 1.
// So the peer module works.
//
// "snapshot": after the first line of the program, the driver asks all
// the threads of ERTS to return (erts_wasm_hibernate), keeps the memory,
// the open files and the NIF libraries in WebAssembly (Module.nifHost),
// and restores them in a new instance, where the program goes on. This is
// what worker.js does with a snapshot (capture() and restore()).
//
// "out": after the exit of the VM, the driver writes each VM_FILE of the
// memory file system to FILE on the disk (for example a crash dump).
//
// "ports": the ports to bindings of worker.js (openPort): the port
// /env/NAME runs the JavaScript program PROGRAM of portPrograms below, as
// a binding of env with a method port().
import fs from 'node:fs';
import { register } from 'node:module';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const job = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
// worker.js imports the runtime of its build directory: stand-ins here,
// because only openPort runs.
let openPort = null;
if (job.ports) {
  register(`data:text/javascript,${encodeURIComponent(`
    const stub = { './beam.mjs': 'export default () => {};', './beam.wasm': 'export default null;' };
    export async function resolve(spec, ctx, next) {
      return spec in stub ? { url: 'data:text/javascript,' + encodeURIComponent(stub[spec]), shortCircuit: true }
                          : next(spec, ctx);
    }`)}`);
  ({ openPort } = await import(new URL('../../priv/wasm_host/worker/worker.js', import.meta.url).href));
}
if (typeof WebAssembly.Suspending !== 'function') {
  console.error('run.mjs: this Node.js has no JSPI (WebAssembly.Suspending)');
  process.exit(3);
}
const { default: createBeam } = await import(pathToFileURL(path.join(job.runtime, 'beam.mjs')));
const wasm = await WebAssembly.compile(fs.readFileSync(path.join(job.runtime, 'beam.wasm')));
// "nifs": {FILE: MODULE_FILE}, the NIF libraries in WebAssembly as
// compiled modules, as nifs.js gives them to a Worker. Then nothing
// compiles WebAssembly at run time, as in a Worker.
const nifs = {};
for (const [file, mod] of Object.entries(job.nifs ?? {})) nifs[file] = await WebAssembly.compile(fs.readFileSync(mod));
if (job.nifs) {
  const { imports, exports, customSections } = WebAssembly.Module;
  WebAssembly.Module = function () { throw new WebAssembly.CompileError('Wasm code generation disallowed by embedder'); };
  Object.assign(WebAssembly.Module, { imports, exports, customSections });
}

function copyTree(FS, from) {
  FS.mkdirTree(from);
  for (const e of fs.readdirSync(from, { withFileTypes: true })) {
    const full = path.join(from, e.name);
    if (e.isDirectory()) copyTree(FS, full);
    else if (e.isFile()) FS.writeFile(full, fs.readFileSync(full));
  }
}

function plainSchedule() {
  const jobs = [];
  const timers = new Map();
  let next = 1, pending = null;
  const runJobs = () => { pending = null; while (jobs.length) jobs.shift()(); };
  const kick = () => { pending ??= setImmediate(runJobs); };
  // One shared clock: each tick runs all the timers that are due.
  const tick = () => {
    const now = performance.now();
    const due = [...timers].filter(([, t]) => t.at <= now).sort((a, b) => a[1].at - b[1].at);
    for (const [id, t] of due) { timers.delete(id); t.f(); }
    runJobs();
    if (timers.size) arm();
  };
  let clock = null;
  const arm = () => {
    if (clock) clearTimeout(clock);
    const at = Math.min(...[...timers.values()].map((t) => t.at));
    clock = setTimeout(() => { clock = null; tick(); }, Math.max(1, at - performance.now()));
  };
  return {
    later: (f) => { jobs.push(f); kick(); },
    timer: (f, ms) => { const id = next++; timers.set(id, { f, at: performance.now() + ms }); arm(); return id; },
    clear: (id) => { timers.delete(id); },
  };
}

const PAGE = 65536;
// The module of the last instance (a snapshot makes a second one).
let vm = null;
const bindir = path.join(job.root, 'bin');
const program = path.join(bindir, 'erl');
const vmArgs = (extra) => ['-S', '1', '-SDcpu', '1', '-SDio', '1', '-A', '0',
  // No time correction for a snapshot: the monotonic time of a new
  // instance starts again at 0.
  ...(job.snapshot ? ['-c', 'false'] : []), '--',
  '-root', job.root, '-bindir', bindir, '-progname', 'erl', '--',
  '-home', '/', '-boot', job.boot.replace(/\.boot$/, ''), ...extra];
const args = vmArgs(['-noshell', '-pa', job.pa, '-eval', job.eval]);

// The files and the environment of a VM, and the mark file of the
// program of the VM, for os:find_executable/1 and open_port/2.
function prepare(m, env = {}) {
  Object.assign(m.ENV, { BINDIR: bindir, ROOTDIR: job.root, EMU: 'beam', PROGNAME: 'erl', HOME: '/', PATH: bindir }, env);
  m.FS.mkdirTree(path.dirname(job.boot));
  m.FS.writeFile(job.boot, fs.readFileSync(job.boot));
  for (const dir of job.libs) copyTree(m.FS, dir);
  copyTree(m.FS, job.pa);
  if (job.work) m.FS.mkdirTree(job.work);
  m.FS.writeFile(program, '');
  m.FS.chmod(program, 0o755);
  for (const name of Object.keys(job.ports ?? {})) {
    m.FS.mkdirTree('/env');
    m.FS.writeFile(`/env/${name}`, '');
    m.FS.chmod(`/env/${name}`, 0o755);
  }
}

// The host spawn: only the program of the VM. The bytes of the port go
// to fd 0 of the new VM, and its fd 1 goes to the port. Its output on
// stderr goes to stderr. Its exit code ends the port.
// The programs of "ports". Each one gets the bytes of the VM (stdin) and
// its arguments, and gives a stream of bytes for the VM.
// - echo: the bytes back.
// - sink RATE COUNT: reads COUNT bytes at RATE bytes for each second, and
//   gives one line: the count and the SHA-256.
// - source COUNT: gives COUNT bytes (0, 1, ..., 255, 0, ...) as fast as
//   the VM takes them, then one line: the ms that it took, and the count
//   of the times that the window of the VM was full (data() gave false).
const portPrograms = {
  echo: (stdin) => stdin,
  sink: (stdin, [rate, count]) => new ReadableStream({
    async start(c) {
      const { createHash } = await import('node:crypto');
      const hash = createHash('sha256');
      const t0 = performance.now();
      let n = 0;
      for await (const chunk of stdin) {
        hash.update(chunk);
        n += chunk.byteLength;
        const wait = t0 + (n / Number(rate)) * 1000 - performance.now();
        if (wait > 0) await new Promise((r) => setTimeout(r, wait));
        if (n >= Number(count)) break;
      }
      c.enqueue(new TextEncoder().encode(`${n} ${hash.digest('hex')}\n`));
      c.close();
    },
  }),
  source: (stdin, [count], stats) => {
    const t0 = performance.now();
    let n = 0;
    return new ReadableStream({
      pull(c) {
        if (n >= Number(count)) {
          c.enqueue(new TextEncoder().encode(`${Math.round(performance.now() - t0)} ms ${stats.full}\n`));
          c.close();
          return;
        }
        const part = new Uint8Array(Math.min(65536, Number(count) - n)).map((_, i) => (n + i) & 255);
        n += part.length;
        c.enqueue(part);
      },
    });
  },
};
// The stats of the port that starts: openPort calls port() before its
// first wait.
let starting = null;
const portEnv = Object.fromEntries(Object.entries(job.ports ?? {}).map(([name, prog]) =>
  [name, { port: (stdin, { argv }) => portPrograms[prog](stdin, argv, starting) }]));

function spawn({ path: file, argv, env }, events) {
  if (openPort && file.startsWith('/env/')) {
    const stats = { full: 0 };
    const data = (bytes) => {
      const free = events.data(bytes);
      if (free === false) stats.full++;
      return free;
    };
    starting = stats;
    try {
      return openPort(portEnv, { path: file, argv, env }, { ...events, data },
                      { log: (t) => process.stderr.write(t + '\n') });
    } finally {
      starting = null;
    }
  }
  if (file !== program) throw Object.assign(new Error(`not the program of the VM: ${file}`), { errno: 44 });
  const vars = Object.fromEntries(env.map((kv) => [kv.slice(0, kv.indexOf('=')), kv.slice(kv.indexOf('=') + 1)]));
  let stdio = null, ended = false;
  const queue = [];
  createBeam({
    arguments: vmArgs(argv.slice(1)),
    preRun: [(m) => {
      prepare(m, vars);
      m.beamKeepProcess = true;
      stdio = m.beamStdioPipes((bytes) => events.data(bytes));
      for (const bytes of queue.splice(0)) stdio.write(bytes);
      if (ended) stdio.end();
    }],
    print: (s) => process.stderr.write(s + '\n'),
    printErr: (s) => process.stderr.write(s + '\n'),
    instantiateWasm: (imports, done) => { WebAssembly.instantiate(wasm, imports).then(done); return {}; },
    jspiSchedule: job.schedule === 'plain' ? plainSchedule() : undefined,
    nifModule: (f) => nifs[f] ?? null,
    onExit: (code) => events.exit(code),
  }).catch((e) => { process.stderr.write(`run.mjs: spawn: ${e}\n`); events.exit(2); });
  return {
    write: (bytes) => (stdio ? stdio.write(bytes) : queue.push(bytes)),
    end: () => { if (ended) return; ended = true; stdio?.end(); },
  };
}

// The options of one instance of the runtime. on.exports: the exports of
// beam.wasm; on.line: each line of the standard output.
function options(on, resolve) {
  return {
    arguments: args,
    preRun: [(m) => {
      prepare(m);
      m.beamHost.spawn = spawn;
      on.module = m;
      vm = m;
    }],
    print: (s) => { process.stdout.write(s + '\n'); on.line?.(); },
    printErr: (s) => process.stderr.write(s + '\n'),
    instantiateWasm: (imports, done) => {
      WebAssembly.instantiate(wasm, imports).then((instance) => { on.exports = instance.exports; done(instance); });
      return {};
    },
    jspiSchedule: job.schedule === 'plain' ? plainSchedule() : undefined,
    nifModule: (file) => nifs[file] ?? null,
    onExit: (code) => resolve(code),
  };
}

// The memory, the open files and the NIF libraries of a VM whose threads
// all returned.
async function capture(m, x) {
  x.erts_wasm_hibernate();
  const start = performance.now();
  while (x.jspi_live_threads() > 0) {
    if (performance.now() - start > 5000) throw new Error('the threads of ERTS did not return');
    await new Promise((r) => setImmediate(r));
  }
  const heap = m.HEAPU8;
  const pages = new Map();
  for (let p = 0; p < heap.length / PAGE; p++) {
    const page = heap.subarray(p * PAGE, (p + 1) * PAGE);
    if (page.some((b) => b !== 0)) pages.set(p, page.slice());
  }
  const pipes = new Map();
  const streams = m.FS.streams.map((st, fd) => {
    if (!st || fd <= 2) return null;
    if (st.node?.pipe) {
      if (!pipes.has(st.node.pipe)) pipes.set(st.node.pipe, pipes.size);
      return { fd, pipe: pipes.get(st.node.pipe), flags: st.flags };
    }
    return { fd, path: st.path, flags: st.flags, position: st.position };
  }).filter(Boolean);
  return { size: heap.length, pages, streams, nifs: m.nifHost?.loaded() ? m.nifHost.save() : null };
}

function restore(m, x, snap) {
  for (let p = 0; p < m.HEAPU8.length / PAGE; p++) if (!snap.pages.has(p)) m.HEAPU8.fill(0, p * PAGE, (p + 1) * PAGE);
  if (!x.jspi_snapshot_grow(snap.size)) throw new Error('no memory');
  for (const [p, page] of snap.pages) m.HEAPU8.set(page, p * PAGE);
  if (snap.nifs) m.nifHost.restore(snap.nifs, (f) => m.FS.readFile(f));
  const made = new Set();
  for (const st of snap.streams) {
    if (st.pipe !== undefined) {
      if (!made.has(st.pipe)) { made.add(st.pipe); x.jspi_snapshot_pipe(); }
      const got = m.FS.getStream(st.fd);
      if (!got?.node?.pipe) throw new Error(`fd ${st.fd} is not a pipe`);
      got.flags = st.flags;
    } else {
      const got = m.FS.open(st.path, st.flags);
      if (got.fd !== st.fd) throw new Error(`fd ${st.fd} is ${got.fd}`);
      got.position = st.position;
    }
  }
  x.wasm_host_restore();
  x.erts_wasm_resume();
}

const exit = new Promise((resolve) => {
  const fail = (e) => { process.stderr.write(`run.mjs: ${e}\n`); resolve(2); };
  const on = {};
  if (job.snapshot) {
    on.line = () => {
      on.line = null;
      setTimeout(async () => {
        try {
          const snap = await capture(on.module, on.exports);
          const again = {};
          createBeam({
            ...options(again, resolve),
            noInitialRun: true,
            onRuntimeInitialized() {
              try { restore(again.module, again.exports, snap); } catch (e) { fail(e); }
            },
          }).catch(fail);
        } catch (e) {
          fail(e);
        }
      }, 300);
    };
  }
  createBeam(options(on, resolve)).catch(fail);
});
process.exitCode = await exit;
for (const [from, to] of Object.entries(job.out ?? {})) {
  try {
    fs.writeFileSync(to, vm.FS.readFile(from));
  } catch (e) {
    process.stderr.write(`run.mjs: ${from}: ${e}\n`);
  }
}
process.exit();
