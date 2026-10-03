#!/usr/bin/env node
// npx beam.com ARGS: beam.com of the version of this package, with ARGS
// (download.mjs). For example: npx beam.com app.erl -o app.com
//
// "npx beam.com APP.com -o DIR --target wasm32", with APP.com a native
// file, needs no beam.com: the runtime of this package makes DIR
// (edge.mjs), with the same result as beam.com.
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { constants } from 'node:os';
import { command, ensure } from './download.mjs';
import { edge, isAppCom, wasm32Command } from './edge.mjs';

const wasm32 = wasm32Command(process.argv.slice(2));
if (wasm32 && isAppCom(wasm32.input)) {
  const { input, out } = wasm32;
  try {
    const { name, vsn, files, bytes } = await edge(input, out);
    const worker = name.toLowerCase().replace(/[^a-z0-9-]/g, '-');
    console.log(`beam.com: wrote ${out} from ${input} (the Workers ${worker} and ${worker}-release)\n`
      + `  release: ${name} ${vsn}, ${files} files, ${(bytes / 1048576).toFixed(1)} MB\n`
      + `  deploy: (cd ${out}/release && wrangler deploy) && (cd ${out} && wrangler deploy)\n`
      + '  (or one Durable Object: wrangler deploy -c wrangler.durable.jsonc)\n'
      + `  Deno: cd ${out} && deno serve -A deno.js\n`
      + `  web page: ${out}/page (a static site)`);
    process.exit(0);
  } catch (e) {
    console.error(`beam.com: ${e.message}`);
    process.exit(1);
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
