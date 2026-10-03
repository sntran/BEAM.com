// npx beam.com APP.com -o DIR --target wasm32 (js/edge.mjs): "node --test
// tests/host". A fake
// runtime/ of the package, and an app.com from zip.mjs with an edge part
// and the files of the hosts.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { edge, isAppCom, staticFiles, unpack, wasm32Command } from '../../js/edge.mjs';
import { zip } from './zip.mjs';

const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'edge-'));
const read = (dir, f) => fs.readFileSync(path.join(dir, f), 'utf8');

// runtime/ of the package: app-com.js of the repository, and stand-ins for
// the other files.
function runtime() {
  const dir = tmp();
  const files = {
    'runtime-id.js': "export default 'rid';\n",
    'worker.js': 'the worker',
    'beam.wasm': 'the VM',
    'deno.js': 'the host of Deno',
    'page/index.html': 'the page',
    'package.json': '{ "type": "module" }',
    'release.json': '{}',
  };
  for (const [f, d] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, f)), { recursive: true });
    fs.writeFileSync(path.join(dir, f), d);
  }
  fs.copyFileSync(new URL('../../priv/wasm_host/worker/app-com.js', import.meta.url), path.join(dir, 'app-com.js'));
  return dir;
}

async function app(dir, { runtime: id = 'rid', host = true } = {}) {
  const file = path.join(dir, 'my_app.com');
  const meta = { name: 'my_app', vsn: '1', args: [], env: {}, runtime: id };
  fs.writeFileSync(file, await zip([
    { name: 'lib/my_app-1/ebin/my_app.app', data: '{application, my_app, []}.' },
    { name: 'lib/my_app-1/priv/static/css/app.css', data: 'body {}', method: 8 },
    { name: 'lib/my_app-1/priv/static/css/app.css.gz', data: 'gzip' },
    { name: 'lib/my_app-1/priv/static/.well-known/x', data: 'hidden' },
    { name: 'lib/other-1/priv/static/y.css', data: 'not of the app' },
    { name: '.wasm/.release.json', data: JSON.stringify(meta), method: 8 },
    ...(host ? [
      { name: '.wasm/host/wrangler.jsonc', data: '{ "name": "my-app" }' },
      { name: '.wasm/host/worker.capnp', data: 'text = "@SECRET_KEY_BASE@"', method: 8 },
      { name: '.wasm/host/page/env.json', data: '{"name": "my_app"}' },
    ] : []),
  ]));
  return file;
}

test('DIR: the runtime, the files of the hosts, the release and the static files', async () => {
  const rt = runtime(), dir = tmp(), out = path.join(dir, 'out');
  const result = await edge(await app(dir), out, { runtime: rt, key: 'the key' });
  const size = fs.statSync(path.join(out, 'release', 'release.bin')).size;
  assert.deepEqual(result, { name: 'my_app', vsn: '1', files: 5, bytes: size, statics: 1 });
  // The runtime, but not the files of the package only.
  assert.equal(read(out, 'worker.js'), 'the worker');
  assert.equal(read(out, 'deno.js'), 'the host of Deno');
  assert.equal(read(out, 'page/index.html'), 'the page');
  assert.ok(!fs.existsSync(path.join(out, 'package.json')));
  assert.ok(!fs.existsSync(path.join(out, 'release.json')));
  // The files of the hosts, with the key in place of the mark.
  assert.equal(read(out, 'wrangler.jsonc'), '{ "name": "my-app" }');
  assert.equal(read(out, 'worker.capnp'), 'text = "the key"');
  assert.equal(read(out, 'page/env.json'), '{"name": "my_app"}');
  // The release, for the Workers and for the page, and the VM of the page.
  const bin = fs.readFileSync(path.join(out, 'release', 'release.bin'));
  assert.deepEqual(fs.readFileSync(path.join(out, 'page', 'release.bin')), bin);
  assert.deepEqual(unpack(bin.buffer.slice(bin.byteOffset, bin.byteOffset + bin.length)).map(([p]) => p), [
    '.release.json', 'lib/my_app-1/ebin/my_app.app', 'lib/my_app-1/priv/static/css/app.css',
    'lib/my_app-1/priv/static/css/app.css.gz', 'lib/my_app-1/priv/static/.well-known/x', 'lib/other-1/priv/static/y.css',
  ]);
  assert.equal(read(out, 'page/beam.wasm'), 'the VM');
  // The static files of the app only.
  assert.deepEqual(JSON.parse(read(out, 'page/app/static.json')), ['/css/app.css']);
  assert.equal(read(out, 'page/app/css/app.css'), 'body {}');
});

test('a new key for each DIR', async () => {
  const rt = runtime(), dir = tmp();
  const file = await app(dir);
  await edge(file, path.join(dir, 'a'), { runtime: rt });
  await edge(file, path.join(dir, 'b'), { runtime: rt });
  const a = read(path.join(dir, 'a'), 'worker.capnp'), b = read(path.join(dir, 'b'), 'worker.capnp');
  assert.match(a, /^text = "[A-Za-z0-9+/]{64}"$/);
  assert.notEqual(a, b);
});

test('errors: another runtime, no files of the hosts, a file as DIR', async () => {
  const rt = runtime(), dir = tmp();
  await assert.rejects(edge(await app(dir, { runtime: 'other' }), path.join(dir, 'o'), { runtime: rt }),
                       /it was built for the runtime other, and this runtime is rid/);
  await assert.rejects(edge(await app(dir, { host: false }), path.join(dir, 'o'), { runtime: rt }),
                       /no files of the hosts \(\.wasm\/host\/\): build it with a newer beam\.com/);
  fs.writeFileSync(path.join(dir, 'file'), '');
  await assert.rejects(edge(await app(dir), path.join(dir, 'file'), { runtime: rt }), /a file; DIR is a directory/);
});

test('staticFiles: priv/static of the app, sorted, with no compressed copy and no dot name', () => {
  const d = new Uint8Array(0);
  assert.deepEqual(staticFiles('a', [
    ['lib/a-1/priv/static/z.js', d], ['lib/a-1/priv/static/b/c.css', d], ['lib/a-1/priv/static/z.js.br', d],
    ['lib/a-1/priv/other/x', d], ['lib/a-1/priv/static/.x', d], ['lib/ab-1/priv/static/y', d],
    ['lib/a-1/priv/static', d],
  ]).map(([p]) => p), ['/b/c.css', '/z.js']);
});

test('unpack: not a release.bin', () => {
  assert.throws(() => unpack(new TextEncoder().encode('NOTBEAM!').buffer), /not a release\.bin/);
});

test('wasm32Command: only "INPUT -o DIR --target wasm32", in any order', () => {
  assert.deepEqual(wasm32Command(['a.com', '-o', 'd', '--target', 'wasm32']), { input: 'a.com', out: 'd' });
  assert.deepEqual(wasm32Command(['--target', 'wasm32-unknown-emscripten', '-o', 'd', 'a.com']), { input: 'a.com', out: 'd' });
  for (const args of [['a.com', '-o', 'd'], ['a.com', '-o', 'd', '--target', 'x86_64-linux'],
                      ['a.com', '-o', 'd', '--target', 'wasm32', '--cacerts', 'c.pem'],
                      ['a.com', 'b.com', '-o', 'd', '--target', 'wasm32'], ['-o', 'd', '--target', 'wasm32'],
                      ['a.com', '--target', 'wasm32', '-o'], []]) {
    assert.equal(wasm32Command(args), null, args.join(' '));
  }
});

test('isAppCom: a file with a zip, not a source file or a directory', async () => {
  const dir = tmp();
  fs.writeFileSync(path.join(dir, 'app.erl'), '-module(app).\n');
  assert.equal(isAppCom(await app(dir)), true);
  assert.equal(isAppCom(path.join(dir, 'app.erl')), false);
  assert.equal(isAppCom(dir), false);
  assert.equal(isAppCom(path.join(dir, 'none')), false);
});
