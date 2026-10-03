#!/usr/bin/env node
// npx beam.com ARGS: beam.com of the version of this package, with ARGS
// (lib/download.js). For example: npx beam.com app.erl -o app.com
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { constants } from 'node:os';
import { command, ensure } from '../lib/download.js';

let release = null;
try {
  release = JSON.parse(readFileSync(new URL('./release.json', import.meta.url), 'utf8'));
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
