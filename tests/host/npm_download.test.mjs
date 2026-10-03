// The download of beam.com for npx beam.com (js/download.mjs): "node
// --test tests/host". A local HTTP server gives the files, in place of the
// GitHub release (BEAM_COM_DOWNLOAD).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { cacheDir, cachePath, command, downloadUrl, ensure } from '../../js/download.mjs';

const sha256 = (b) => createHash('sha256').update(b).digest('hex');
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'npm-download-'));

// A server with the files of files ({path: bytes}), and the paths that it
// got.
async function server(files) {
  const requests = [];
  const s = http.createServer((req, res) => {
    requests.push(req.url);
    const body = files[req.url];
    res.writeHead(body ? 200 : 404);
    res.end(body);
  });
  await new Promise((r) => s.listen(0, '127.0.0.1', r));
  const url = `http://127.0.0.1:${s.address().port}`;
  return { url, requests, close: () => new Promise((r) => s.close(r)) };
}

test('the cache directory of beam.com', () => {
  assert.equal(cacheDir({ BEAM_COM_CACHE: '/c', XDG_CACHE_HOME: '/x' }), '/c');
  assert.equal(cacheDir({ XDG_CACHE_HOME: '/x', LOCALAPPDATA: '/l' }), path.join('/x', 'beam.com'));
  assert.equal(cacheDir({ LOCALAPPDATA: '/l', HOME: '/h' }), path.join('/l', 'beam.com'));
  assert.equal(cacheDir({ HOME: '/h' }), path.join('/h', '.cache', 'beam.com'));
});

test('the file in the cache keeps the name beam.com, and beam.exe on Windows', () => {
  const release = { version: '1.2.3', sha256: 'ab'.repeat(32) };
  assert.equal(cachePath(release, { BEAM_COM_CACHE: '/c' }, 'linux'),
               path.join('/c', 'npm', '1.2.3-abababababab', 'beam.com'));
  assert.equal(path.basename(cachePath(release, { BEAM_COM_CACHE: '/c' }, 'win32')), 'beam.exe');
});

test('the URL: the GitHub release of the version, or BEAM_COM_DOWNLOAD', () => {
  assert.equal(downloadUrl({ version: '1.2.3' }, {}),
               'https://github.com/sntran/BEAM.com/releases/download/v1.2.3/beam.com');
  assert.equal(downloadUrl({ version: '1.2.3' }, { BEAM_COM_DOWNLOAD: 'http://m/d/' }), 'http://m/d/beam.com');
});

test('the command: sh on Unix, the file on Windows', () => {
  assert.deepEqual(command('/c/beam.com', ['-v'], 'linux'), ['/bin/sh', ['/c/beam.com', '-v']]);
  assert.deepEqual(command('C:\\c\\beam.exe', ['-v'], 'win32'), ['C:\\c\\beam.exe', ['-v']]);
});

test('a download: the file is in the cache after the check, and the next call reads the cache', async () => {
  const data = Buffer.from('#!/bin/sh\necho beam.com\n');
  const release = { version: '1.2.3', sha256: sha256(data) };
  const s = await server({ '/files/beam.com': data });
  const env = { BEAM_COM_CACHE: tmp(), BEAM_COM_DOWNLOAD: `${s.url}/files` };
  const logs = [];
  try {
    const file = await ensure(release, { env, platform: 'linux', log: (t) => logs.push(t) });
    assert.equal(file, cachePath(release, env, 'linux'));
    assert.deepEqual(fs.readFileSync(file), data);
    if (process.platform !== 'win32') assert.equal(fs.statSync(file).mode & 0o111, 0o111);
    assert.equal(await ensure(release, { env, platform: 'linux' }), file);
    assert.deepEqual(s.requests, ['/files/beam.com']);
    assert.deepEqual(logs, [`beam.com: downloading ${s.url}/files/beam.com`]);
    // Only the file is in its directory: no part file stays.
    assert.deepEqual(fs.readdirSync(path.dirname(file)), ['beam.com']);
  } finally {
    await s.close();
  }
});

test('a file with another SHA-256 is an error, and nothing stays in the cache', async () => {
  const release = { version: '1.2.3', sha256: sha256('the expected file') };
  const s = await server({ '/beam.com': Buffer.from('another file') });
  const env = { BEAM_COM_CACHE: tmp(), BEAM_COM_DOWNLOAD: s.url };
  try {
    await assert.rejects(ensure(release, { env, platform: 'linux' }),
                         { message: `beam.com: ${s.url}/beam.com: the SHA-256 is ${sha256('another file')}, `
                                    + `and this package expects ${release.sha256}` });
    assert.deepEqual(fs.readdirSync(path.dirname(cachePath(release, env, 'linux'))), []);
  } finally {
    await s.close();
  }
});

test('a status that is not 200 is an error', async () => {
  const s = await server({});
  const env = { BEAM_COM_CACHE: tmp(), BEAM_COM_DOWNLOAD: s.url };
  try {
    await assert.rejects(ensure({ version: '1.2.3', sha256: 'ab'.repeat(32) }, { env }),
                         { message: `beam.com: ${s.url}/beam.com: status 404` });
  } finally {
    await s.close();
  }
});

test('BEAM_COM: no download; and no release.json: an error that names BEAM_COM', async () => {
  assert.equal(await ensure(null, { env: { BEAM_COM: '/my/beam.com' } }), '/my/beam.com');
  for (const release of [null, { version: '1.2.3' }, { version: '1.2.3', sha256: 'not a hash' }]) {
    await assert.rejects(ensure(release, { env: {} }), /set BEAM_COM to the path of a beam.com/);
  }
});
