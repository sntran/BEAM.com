// The arguments of "npx beam.com --snapshot" (js/beam.com.mjs): "node
// --test tests/host". A wrong argument stops the command before it reads
// the file, so these tests need no runtime.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const cli = fileURLToPath(new URL('../../js/beam.com.mjs', import.meta.url));
const run = (...args) => spawnSync(process.execPath, [cli, '--snapshot', ...args], { encoding: 'utf8' });

for (const [args, text] of [
  [[], 'usage: npx beam.com --snapshot APP.com'],
  [['app.com', '--warm', '/'], '--warm is for a full snapshot (--full)'],
  [['app.com', '--env', 'NOVALUE'], '--env NOVALUE: not NAME=VALUE'],
  [['app.com', '--env', '=x'], '--env =x: not NAME=VALUE'],
  [['app.com', '-o'], '-o needs a value'],
  [['app.com', '--other'], '--snapshot: unknown argument --other'],
  [['a.com', 'b.com'], '--snapshot: unknown argument b.com'],
]) {
  test(`--snapshot ${args.join(' ') || '(no app)'}: ${text}`, () => {
    const r = run(...args);
    assert.equal(r.status, 1);
    assert.match(r.stderr, new RegExp(text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  });
}
