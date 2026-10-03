// release.bin as an ArrayBuffer, as the import of a Data module gives it in
// Workers: next to worker.js (one Worker), else in release/ (the Worker with
// the release). With a native app.com (the bytes of use(app) of deno.js,
// else the path in the first argument of deno.js, else BEAM_APP): the
// release of that file (its edge part, see app-com.js), for this runtime
// only.
import { app as given } from './app.js';

async function release() {
  if (given) {
    const [{ appRelease, bytesReader }, { default: runtime }] =
      await Promise.all([import('../app-com.js'), import('../runtime-id.js')]);
    const { read, size } = bytesReader(given);
    return appRelease(read, size, { runtime });
  }
  const app = Deno.args[0] ?? Deno.env.get('BEAM_APP');
  if (app) {
    const { appRelease } = await import('../app-com.js');
    const { default: runtime } = await import('../runtime-id.js');
    const f = await Deno.open(app);
    try {
      const read = async (at, n) => {
        const b = new Uint8Array(n);
        await f.seek(at, Deno.SeekMode.Start);
        for (let o = 0; o < n;) {
          const r = await f.read(b.subarray(o));
          if (r === null) break;
          o += r;
        }
        return b;
      };
      return await appRelease(read, (await f.stat()).size, { runtime });
    } finally {
      f.close();
    }
  }
  let b;
  try {
    b = await Deno.readFile(new URL('../release.bin', import.meta.url));
  } catch {
    b = await Deno.readFile(new URL('../release/release.bin', import.meta.url));
  }
  return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
}

export default await release();
