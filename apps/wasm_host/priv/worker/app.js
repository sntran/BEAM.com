// A Worker that holds only a release (release.bin of beam_com_wasm), for a runtime
// Worker (worker.js with a service binding APP) to boot.
import release from './release.bin';

export default {
  fetch(request) {
    if (new URL(request.url).pathname !== '/release.bin') return new Response('not found', { status: 404 });
    return new Response(release, { headers: { 'content-type': 'application/octet-stream' } });
  },
};
