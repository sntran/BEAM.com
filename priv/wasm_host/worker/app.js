// A Worker that holds only a release (release.bin of beam_com_wasm), for a runtime
// Worker (worker.js with a service binding APP) to boot; and, if there is
// one, a snapshot of the booted VM (snapshot.bin).
import release from './release.bin';

async function snapshot() {
  try { return (await import('./snapshot.bin')).default; } catch { return null; }
}

export default {
  async fetch(request) {
    const path = new URL(request.url).pathname;
    const data = path === '/release.bin' ? release : path === '/snapshot.bin' ? await snapshot() : null;
    if (!data) return new Response('not found', { status: 404 });
    return new Response(data, { headers: { 'content-type': 'application/octet-stream' } });
  },
};
