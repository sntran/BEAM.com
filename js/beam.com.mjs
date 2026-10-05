#!/usr/bin/env node
// npx beam.com ARGS: beam.com of the version of this package, with ARGS
// (download.mjs). For example: npx beam.com app.erl -o app.com
//
// npx beam.com --snapshot APP.com [-o FILE] [--full] [--warm PATH]...
// [--env NAME=VALUE]...: the snapshot of the build of APP.com for
// serve(app, { snapshot }) of a Worker (snapshot() of node.mjs), in FILE
// (default APP.snapshot). It runs here, with no download of beam.com.
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
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
    else if (a === '--warm') opts.warm.push(value());
    else if (a === '--env') {
      const v = value(), at = v.indexOf('=');
      if (at < 1) throw new Error(`--env ${v}: not NAME=VALUE`);
      opts.env[v.slice(0, at)] = v.slice(at + 1);
    } else if (!a.startsWith('-') && !app) app = a;
    else throw new Error(`--snapshot: unknown argument ${a}`);
  }
  if (!app) throw new Error('usage: npx beam.com --snapshot APP.com [-o FILE] [--full] [--warm PATH]... [--env NAME=VALUE]...');
  if (opts.warm.length && opts.kind !== 'full') throw new Error('--warm is for a full snapshot (--full)');
  out ??= app.replace(/\.com$/, '') + '.snapshot';
  const { snapshot } = await import('./node.mjs');
  const t0 = performance.now();
  const bytes = await snapshot(app, opts);
  writeFileSync(out, bytes);
  console.error(`beam.com: wrote ${out} (${(bytes.length / 1048576).toFixed(1)} MB, ${opts.kind}, in ${Math.round(performance.now() - t0)} ms)`);
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
