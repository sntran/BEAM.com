#!/bin/sh
# Builds the studio as static files for a web page (for example a directory
# of GitHub Pages), with beam.com (https://github.com/sntran/BEAM.com):
#
#   BEAM_COM=/path/to/beam.com scripts/page.sh OUT
#
# OUT is the site of "beam.com RELEASE -o OUT --page", with the page of
# the studio in place of the page of beam.com:
# - index.html, sw.js, vm.js, ws-shim.js: the page (see page/index.html);
# - app.com: the release of the studio;
# - beam.wasm, beam.mjs, worker.js, browser.js, browser/, app-com.js,
#   runtime-id.js: the runtime. The VM runs in a Web Worker, which has no
#   import map, so this worker.js imports the files of browser/;
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

rm -rf "$OUT/app" "$OUT/licenses"
"$BEAM_COM" _build/prod/rel/studio -o "$OUT" --page
# The page of the studio in place of the page of beam.com, and no static
# files on the site.
rm -rf "$OUT/main.js" "$OUT/scope.js" "$OUT/404.html" "$OUT/app"
cp "$ROOT"/page/index.html "$ROOT"/page/sw.js "$ROOT"/page/vm.js "$ROOT"/page/ws-shim.js "$OUT/"
mkdir -p "$OUT/app"
echo '[]' > "$OUT/app/static.json"
echo "page.sh: wrote $OUT"
