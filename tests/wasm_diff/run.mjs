// Runs one program in the Worker build of beam.wasm, in Node.js:
//
//   node run.mjs JOB.json
//
// JOB.json: {"runtime": DIR, "root": OTP_ROOT, "libs": [EBIN...],
//   "boot": BOOT_FILE, "pa": DIR, "eval": EXPR, "schedule": "node" | "plain",
//   "nifs": {FILE: MODULE_FILE} (optional)}
//
// The driver copies the boot file, each EBIN directory, and the files of
// "pa" into the memory file system, below the same names as on the disk.
// The VM writes its output to stdout and to stderr, and the exit status
// of the driver is the exit status of the VM.
//
// The schedule "plain" runs the timers of the threads as a plain Worker
// does: all the timers that are due run in one task, one after the other.
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const job = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
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

const exit = new Promise((resolve) => {
  createBeam({
    arguments: ['-S', '1', '-SDcpu', '1', '-SDio', '1', '-A', '0', '--',
      '-root', job.root, '-bindir', path.join(job.root, 'bin'), '-progname', 'erl', '--',
      '-home', '/', '-boot', job.boot.replace(/\.boot$/, ''), '-noshell',
      '-pa', job.pa, '-eval', job.eval],
    preRun: [(m) => {
      Object.assign(m.ENV, { BINDIR: path.join(job.root, 'bin'), ROOTDIR: job.root, EMU: 'beam', PROGNAME: 'erl', HOME: '/' });
      m.FS.mkdirTree(path.dirname(job.boot));
      m.FS.writeFile(job.boot, fs.readFileSync(job.boot));
      for (const dir of job.libs) copyTree(m.FS, dir);
      copyTree(m.FS, job.pa);
      if (job.work) m.FS.mkdirTree(job.work);
    }],
    print: (s) => process.stdout.write(s + '\n'),
    printErr: (s) => process.stderr.write(s + '\n'),
    instantiateWasm: (imports, done) => {
      WebAssembly.instantiate(wasm, imports).then((instance) => done(instance));
      return {};
    },
    jspiSchedule: job.schedule === 'plain' ? plainSchedule() : undefined,
    nifModule: (file) => nifs[file] ?? null,
    onExit: (code) => resolve(code),
  }).catch((e) => { process.stderr.write(`run.mjs: ${e}\n`); resolve(2); });
});
process.exitCode = await exit;
process.exit();
