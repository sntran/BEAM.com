#!/bin/sh
# Livebook in a web page (page/index.html): the release of setup.sh, the
# runtime of beam.com and the files of page/, as static files for a site
# (the root of the site on GitHub Pages: docs/site.sh).
#
#   BEAM_COM=/path/to/beam.com wasm/livebook/page.sh DIR OUT
#
# DIR is the directory of setup.sh (with the release of Livebook). OUT gets:
# - index.html, sw.js, vm.js, ws-shim.js: the page (see index.html);
# - beam.wasm, beam.mjs, worker.js, browser.js, browser/: the runtime. The
#   VM runs in a Web Worker, which has no import map, so this worker.js
#   imports the files of browser/;
# - release.bin: the release, without its static files;
# - app/: the static files of Livebook, and app/static.json, their list;
# - config.json: the iframe page of Livebook (Kino draws its JS outputs
#   there): app/iframe/vN.html of this site, or IFRAME_URL. An iframe page
#   of another site cannot load the JS of Kino, because the service worker
#   does not take its requests.
# It needs Node.js 22 or later.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${BEAM_COM:?set BEAM_COM}"
DIR=${1:?usage: page.sh DIR OUT}
OUT=${2:?usage: page.sh DIR OUT}
NODE=${NODE:-node}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/livebook-page.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

"$BEAM_COM" "$DIR/livebook/_build/prod/rel/livebook" -o "$TMP/out" --target wasm32 \
    --cacerts "$DIR/cacert.pem"
"$NODE" "$HERE/../erts/host/static.mjs" "$TMP/out" livebook

mkdir -p "$OUT/browser"
cp "$HERE"/page/index.html "$HERE"/page/sw.js "$HERE"/page/vm.js "$HERE"/page/ws-shim.js "$OUT/"
cp "$TMP/out/beam.wasm" "$TMP/out/beam.mjs" "$TMP/out/browser.js" "$OUT/"
cp "$TMP"/out/browser/*.js "$OUT/browser/"
cp "$TMP/out/release/release.bin" "$OUT/release.bin"
rm -rf "$OUT/licenses" "$OUT/app"
cp -R "$TMP/out/licenses" "$OUT/licenses"
sed -e "s#from 'node:net'#from './browser/net.js'#" \
    -e "s#from './beam.wasm'#from './browser/beam-wasm.js'#" \
    -e "s#import('./release.bin')#import('./browser/none.js')#" \
    -e "s#import('./snapshot.bin')#import('./browser/none.js')#" \
    "$TMP/out/worker.js" > "$OUT/worker.js"
for spec in node:net ./beam.wasm ./release.bin ./snapshot.bin; do
    if grep -q "'$spec'" "$OUT/worker.js"; then
        echo "page.sh: worker.js still imports $spec" >&2
        exit 1
    fi
done
mv "$TMP/out/static" "$OUT/app"
"$NODE" -e '
const fs = require("fs"), path = require("path");
const [app, iframe] = process.argv.slice(1), files = [];
(function walk(d) {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) walk(p); else files.push("/" + path.relative(app, p).split(path.sep).join("/"));
  }
})(app);
fs.writeFileSync(path.join(app, "static.json"), JSON.stringify(files.sort()));
const pages = files.map((f) => /^\/iframe\/v(\d+)\.html$/.exec(f)).filter(Boolean).sort((a, b) => a[1] - b[1]);
if (!pages.length) throw new Error("page.sh: no iframe page in app/iframe");
const config = { iframe_page: `v${pages.at(-1)[1]}.html`, ...(iframe ? { iframe_url: iframe } : {}) };
fs.writeFileSync(path.join(app, "..", "config.json"), JSON.stringify(config));
console.log(`page.sh: ${files.length} static files`);' "$OUT/app" "${IFRAME_URL:-}"
echo "page.sh: wrote $OUT"
