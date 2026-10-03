// The beam.com of this package: the file of the GitHub release of the same
// version, in the cache, with the SHA-256 that the package holds
// (bin/release.json, from scripts/npm.sh). The package does not hold the
// file: a host that only uses the runtime never downloads it.
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
export async function ensure(release, { env = process.env, platform = process.platform, fetch = globalThis.fetch, log = () => {} } = {}) {
  if (env.BEAM_COM) return env.BEAM_COM;
  if (!release?.version || !/^[0-9a-f]{64}$/.test(release?.sha256 ?? '')) {
    throw new Error('this package has no release of beam.com (bin/release.json): set BEAM_COM to the path of a beam.com');
  }
  const file = cachePath(release, env, platform);
  if (fs.existsSync(file)) return file;
  const url = downloadUrl(release, env);
  log(`beam.com: downloading ${url}`);
  const response = await fetch(url);
  if (!response.ok) throw new Error(`beam.com: ${url}: status ${response.status}`);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const part = `${file}.${process.pid}.part`;
  const out = fs.createWriteStream(part, { mode: 0o755 });
  const hash = createHash('sha256');
  try {
    for await (const chunk of response.body) {
      hash.update(chunk);
      if (!out.write(chunk)) await new Promise((r) => out.once('drain', r));
    }
    await new Promise((resolve, reject) => out.end((e) => (e ? reject(e) : resolve())));
    const got = hash.digest('hex');
    if (got !== release.sha256) {
      throw new Error(`beam.com: ${url}: the SHA-256 is ${got}, and this package expects ${release.sha256}`);
    }
    fs.chmodSync(part, 0o755);
    fs.renameSync(part, file);
  } finally {
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
