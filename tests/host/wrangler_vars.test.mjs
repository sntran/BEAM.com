// The vars of the Wrangler file of a project (js/wrangler.mjs), which
// npx beam.com --snapshot reads for BEAM_ERL_FLAGS. "node --test
// tests/host".
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { jsonc, wranglerVars } from '../../js/wrangler.mjs';

test('jsonc: comments, a comma before } and ], and strings as they are', () => {
  const text = `{
    // a comment
    "name": "app", /* a comment
    of two lines */
    "url": "https://example.com/a//b", "q": "a \\" /* not a comment */",
    "list": [1, 2,],
    "vars": { "BEAM_ERL_FLAGS": "-Mea min", },
  }`;
  assert.deepEqual(jsonc(text), {
    name: 'app', url: 'https://example.com/a//b', q: 'a " /* not a comment */', list: [1, 2],
    vars: { BEAM_ERL_FLAGS: '-Mea min' },
  });
});

test('wranglerVars: wrangler.jsonc, then wrangler.json, else null', () => {
  const dir = mkdtempSync(join(tmpdir(), 'wrangler-'));
  try {
    assert.equal(wranglerVars(dir), null);
    writeFileSync(join(dir, 'wrangler.json'), '{"vars": {"A": "1"}}');
    assert.deepEqual(wranglerVars(dir), { file: 'wrangler.json', vars: { A: '1' } });
    writeFileSync(join(dir, 'wrangler.jsonc'), '{\n  // no vars\n  "name": "x",\n}');
    assert.deepEqual(wranglerVars(dir), { file: 'wrangler.jsonc', vars: {} });
  } finally {
    rmSync(dir, { recursive: true });
  }
});
