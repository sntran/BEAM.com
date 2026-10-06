// The beam.com of this package: the file of the GitHub release of the same
// version, in the cache, with the SHA-256 that the package holds
// (runtime/release.json, from scripts/npm.sh). The package does not hold
// the file: a host that only uses the runtime never downloads it.
//
// - BEAM_COM: the path of a beam.com to use. Then nothing is downloaded.
// - BEAM_COM_DOWNLOAD: the URL of the directory of the files, in place of
//   the GitHub release (a mirror, or a test).
// - BEAM_COM_CACHE: the cache directory, as for beam.com.
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const REPOSITORY = 'sntran/BEAM.com';

// The time with no bytes that stops a download (ms).
const IDLE = 60000;

// The cache directory of beam.com (beam_com:cache_dir/0).
export function cacheDir(env = process.env) {
  if (env.BEAM_COM_CACHE) return env.BEAM_COM_CACHE;
  if (env.XDG_CACHE_HOME) return path.join(env.XDG_CACHE_HOME, 'beam.com');
  if (env.LOCALAPPDATA) return path.join(env.LOCALAPPDATA, 'beam.com');
  return path.join(env.HOME ?? os.homedir(), '.cache', 'beam.com');
}

// The path of the file in the cache. The name stays beam.com, because
// beam.com selects a tool by its name (mix.com is mix). Windows runs an
// APE file as a PE executable only with an .exe name.
export function cachePath({ version, sha256 }, env = process.env, platform = process.platform) {
  const name = platform === 'win32' ? 'beam.exe' : 'beam.com';
  return path.join(cacheDir(env), 'npm', `${version}-${sha256.slice(0, 12)}`, name);
}

export function downloadUrl({ version }, env = process.env) {
  const base = env.BEAM_COM_DOWNLOAD || `https://github.com/${REPOSITORY}/releases/download/v${version}`;
  return `${base.replace(/\/$/, '')}/beam.com`;
}

// The path of a beam.com that runs. The file in the cache was checked when
// it was downloaded: a file is in the cache only after the check.
// idle: the download stops when no bytes come in this time (ms).
export async function ensure(release, { env = process.env, platform = process.platform, fetch = globalThis.fetch, log = () => {}, idle = IDLE } = {}) {
  if (env.BEAM_COM) return env.BEAM_COM;
  if (!release?.version || !/^[0-9a-f]{64}$/.test(release?.sha256 ?? '')) {
    throw new Error('this package has no release of beam.com (runtime/release.json): set BEAM_COM to the path of a beam.com');
  }
  const file = cachePath(release, env, platform);
  if (fs.existsSync(file)) return file;
  const url = downloadUrl(release, env);
  log(`beam.com: downloading ${url}`);
  const ac = new AbortController();
  let timer;
  const wait = () => {
    clearTimeout(timer);
    timer = setTimeout(() => ac.abort(new Error(`beam.com: ${url}: no bytes in ${idle / 1000} s`)), idle);
  };
  wait();
  let response;
  try {
    response = await fetch(url, { signal: ac.signal });
  } catch (e) {
    clearTimeout(timer);
    throw ac.signal.aborted ? ac.signal.reason : e;
  }
  if (!response.ok) {
    clearTimeout(timer);
    throw new Error(`beam.com: ${url}: status ${response.status}`);
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const part = `${file}.${process.pid}.part`;
  const out = fs.createWriteStream(part, { mode: 0o755 });
  // An error of the file (a full disk): no drain comes after it.
  const failed = new Promise((_, reject) => out.once('error', reject));
  failed.catch(() => {});
  const hash = createHash('sha256');
  try {
    for await (const chunk of response.body) {
      wait();
      hash.update(chunk);
      if (!out.write(chunk)) await Promise.race([new Promise((r) => out.once('drain', r)), failed]);
    }
    await new Promise((resolve, reject) => out.end((e) => (e ? reject(e) : resolve())));
    const got = hash.digest('hex');
    if (got !== release.sha256) {
      throw new Error(`beam.com: ${url}: the SHA-256 is ${got}, and this package expects ${release.sha256}`);
    }
    fs.chmodSync(part, 0o755);
    fs.renameSync(part, file);
  } catch (e) {
    throw ac.signal.aborted ? ac.signal.reason : e;
  } finally {
    clearTimeout(timer);
    out.destroy();
    fs.rmSync(part, { force: true });
  }
  return file;
}

// The command that starts the file: Windows runs it as a PE executable,
// and a Unix shell runs the shell script at the start of an APE file.
export function command(file, args, platform = process.platform) {
  return platform === 'win32' ? [file, args] : ['/bin/sh', [file, ...args]];
}
