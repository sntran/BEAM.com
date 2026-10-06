#!/usr/bin/env node
// npx beam.com ARGS: beam.com of the version of this package, with ARGS
// (download.mjs). For example: npx beam.com app.erl -o app.com
//
// npx beam.com --snapshot APP.com [-o FILE] [--full] [--warm PATH]...
// [--env NAME=VALUE]... [--no-compress]: the snapshot of the build of
// APP.com for serve(app, { snapshot }) of a Worker (snapshot() of
// node.mjs), in FILE (default APP.snapshot), with its pages in gzip (not
// with --full: the global scope of a Worker cannot inflate). Give
// the BEAM_ERL_FLAGS of the Worker with --env, or in the vars of
// wrangler.jsonc of this directory: a Worker with other flags boots in
// place of the snapshot. It runs here, with no download of beam.com.
import { spawn } from 'node:child_process';
import { closeSync, openSync, readFileSync, readSync, statSync, writeFileSync } from 'node:fs';
import { constants } from 'node:os';
import { command, ensure } from './download.mjs';

if (process.argv[2] === '--snapshot') {
  try {
    await snapshotCommand(process.argv.slice(3));
    process.exit(0);
  } catch (e) {
    console.error(`beam.com: ${e.message}`);
    process.exit(1);
  }
}

async function snapshotCommand(args) {
  const opts = { env: {}, warm: [], kind: 'boot-point' };
  let app = null, out = null;
  while (args.length) {
    const a = args.shift();
    const value = () => {
      if (!args.length) throw new Error(`${a} needs a value`);
      return args.shift();
    };
    if (a === '-o') out = value();
    else if (a === '--full') opts.kind = 'full';
    else if (a === '--no-compress') opts.compress = false;
    else if (a === '--warm') opts.warm.push(value());
    else if (a === '--env') {
      const v = value(), at = v.indexOf('=');
      if (at < 1) throw new Error(`--env ${v}: not NAME=VALUE`);
      opts.env[v.slice(0, at)] = v.slice(at + 1);
    } else if (!a.startsWith('-') && !app) app = a;
    else throw new Error(`--snapshot: unknown argument ${a}`);
  }
  if (!app) throw new Error('usage: npx beam.com --snapshot APP.com [-o FILE] [--full] [--warm PATH]... [--env NAME=VALUE]... [--no-compress]');
  if (opts.warm.length && opts.kind !== 'full') throw new Error('--warm is for a full snapshot (--full)');
  out ??= app.replace(/\.com$/, '') + '.snapshot';
  // The flags of the Worker, when --env does not give them: the vars of
  // its wrangler.jsonc. A Worker with other flags boots in place of the
  // snapshot.
  let source = '--env';
  if (opts.env.BEAM_ERL_FLAGS === undefined) {
    const { wranglerVars } = await import('./wrangler.mjs');
    const w = wranglerVars('.');
    if (typeof w?.vars.BEAM_ERL_FLAGS === 'string') {
      opts.env.BEAM_ERL_FLAGS = w.vars.BEAM_ERL_FLAGS;
      source = w.file;
    }
  }
  const { snapshot } = await import('./node.mjs');
  const t0 = performance.now();
  const bytes = await snapshot(app, opts);
  writeFileSync(out, bytes);
  const flags = (opts.env.BEAM_ERL_FLAGS ?? '').split(/\s+/).filter(Boolean).join(' ');
  console.error(`beam.com: wrote ${out} (${(bytes.length / 1048576).toFixed(1)} MB, ${opts.kind}, `
    + `BEAM_ERL_FLAGS "${flags}"${flags ? ` of ${source}` : ''}, in ${Math.round(performance.now() - t0)} ms)`);
  if (!flags) console.error('beam.com: a Worker with BEAM_ERL_FLAGS boots in place of this snapshot: give its flags with --env BEAM_ERL_FLAGS=..., or in the vars of wrangler.jsonc');
  // A Worker can be at most 64 MiB, with all its modules (gzip does not
  // count): the app file and the snapshot are most of it.
  const total = statSync(app).size + bytes.length;
  if (total > 56 * 1048576) {
    // An APE file starts with "MZ"; a file of --target wasm32 is a zip.
    const head = Buffer.alloc(2), fd = openSync(app, 'r');
    try { readSync(fd, head, 0, 2, 0); } finally { closeSync(fd); }
    const native = head.toString() === 'MZ';
    console.error(`beam.com: warning: ${app} and ${out} are ${(total / 1048576).toFixed(1)} MiB, and a Worker can be at most 64 MiB`
      + (native ? `. Build the app with -o FILE.com --target wasm32: a file with no native program, about 25 MB smaller` : ''));
  }
}

let release = null;
try {
  release = JSON.parse(readFileSync(new URL('../runtime/release.json', import.meta.url), 'utf8'));
} catch {}

let file;
try {
  file = await ensure(release, { log: (text) => console.error(text) });
} catch (e) {
  console.error(e.message);
  process.exit(1);
}
const [program, args] = command(file, process.argv.slice(2));
const child = spawn(program, args, { stdio: 'inherit' });
// The terminal sends SIGINT to the process group, so beam.com gets it
// already: a second one would go to the break handler of the BEAM.
process.on('SIGINT', () => {});
process.on('SIGTERM', () => child.kill('SIGTERM'));
child.on('error', (e) => {
  console.error(`beam.com: ${file}: ${e.message}`);
  process.exit(1);
});
child.on('exit', (code, signal) => {
  process.exit(signal ? 128 + (constants.signals[signal] ?? 0) : (code ?? 1));
});
