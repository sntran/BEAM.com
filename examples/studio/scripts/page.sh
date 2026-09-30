#!/bin/sh
# Builds the studio as static files for a web page (for example a directory
# of GitHub Pages), with beam.com (https://github.com/sntran/BEAM.com):
#
#   BEAM_COM=/path/to/beam.com scripts/page.sh OUT
#
# OUT gets:
# - index.html, sw.js, vm.js, ws-shim.js: the page (see page/index.html);
# - beam.wasm, beam.mjs, worker.js, browser.js, browser/: the runtime. The
#   VM runs in a Web Worker, which has no import map, so this worker.js
#   imports the files of browser/;
# - release.bin: the release of the studio;
# - app/static.json: the static files that the site serves. It is empty:
#   the VM serves all the files of the studio and of the app.
# The page needs a browser with JSPI (Chrome or Edge 137 or later).
set -eu
: "${BEAM_COM:?set BEAM_COM to the path of beam.com}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: page.sh OUT}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

sh "$ROOT/scripts/release.sh"
cd "$ROOT"

# The build runs the release once on this computer, to find the modules of
# its boot.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/studio-page.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
STUDIO_ROOT="$TMP/root" PORT=0 "$BEAM_COM" _build/prod/rel/studio -o "$TMP/out" --target wasm32

mkdir -p "$OUT/browser" "$OUT/app"
cp "$ROOT"/page/index.html "$ROOT"/page/sw.js "$ROOT"/page/vm.js "$ROOT"/page/ws-shim.js "$OUT/"
cp "$TMP/out/beam.wasm" "$TMP/out/beam.mjs" "$TMP/out/browser.js" "$OUT/"
cp "$TMP"/out/browser/*.js "$OUT/browser/"
cp "$TMP/out/release/release.bin" "$OUT/release.bin"
rm -rf "$OUT/licenses"
cp -R "$TMP/out/licenses" "$OUT/licenses"
sed -e "s#from 'cloudflare:sockets'#from './browser/sockets.js'#" \
    -e "s#from './beam.wasm'#from './browser/beam-wasm.js'#" \
    -e "s#import('./release.bin')#import('./browser/none.js')#" \
    -e "s#import('./snapshot.bin')#import('./browser/none.js')#" \
    "$TMP/out/worker.js" > "$OUT/worker.js"
for spec in cloudflare:sockets ./beam.wasm ./release.bin ./snapshot.bin; do
    if grep -q "'$spec'" "$OUT/worker.js"; then
        echo "page.sh: worker.js still imports $spec" >&2
        exit 1
    fi
done
echo '[]' > "$OUT/app/static.json"
echo "page.sh: wrote $OUT"
