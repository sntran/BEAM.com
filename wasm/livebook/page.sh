#!/bin/sh
# Livebook in a web page (page/index.html): the release of setup.sh as
# one app.com, the runtime of beam.com and the files of page/, as static
# files for a site (the root of the site on GitHub Pages: docs/site.sh).
#
#   BEAM_COM=/path/to/beam.com wasm/livebook/page.sh DIR OUT
#
# DIR is the directory of setup.sh (with the release of Livebook). OUT is
# the site of "beam.com RELEASE -o OUT --page", with the page of Livebook
# in place of the page of beam.com:
# - index.html, sw.js, vm.js, ws-shim.js: the page (see index.html);
# - app.com: the release of Livebook;
# - beam.wasm, beam.mjs, worker.js, browser.js, browser/, app-com.js,
#   runtime-id.js: the runtime. The VM runs in a Web Worker, which has no
#   import map, so this worker.js imports the files of browser/;
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

rm -rf "$OUT/app" "$OUT/licenses"
"$BEAM_COM" "$DIR/livebook/_build/prod/rel/livebook" -o "$OUT" --page \
    --cacerts "$DIR/cacert.pem"
# The page of Livebook in place of the page of beam.com.
rm -f "$OUT/main.js" "$OUT/scope.js" "$OUT/404.html"
cp "$HERE"/page/index.html "$HERE"/page/sw.js "$HERE"/page/vm.js "$HERE"/page/ws-shim.js "$OUT/"
# config.json: the newest iframe page in app/static.json of --page.
"$NODE" -e '
const fs = require("fs"), path = require("path");
const [app, iframe] = process.argv.slice(1);
const files = JSON.parse(fs.readFileSync(path.join(app, "static.json"), "utf8"));
const pages = files.map((f) => /^\/iframe\/v(\d+)\.html$/.exec(f)).filter(Boolean).sort((a, b) => a[1] - b[1]);
if (!pages.length) throw new Error("page.sh: no iframe page in app/iframe");
const config = { iframe_page: `v${pages.at(-1)[1]}.html`, ...(iframe ? { iframe_url: iframe } : {}) };
fs.writeFileSync(path.join(app, "..", "config.json"), JSON.stringify(config));
console.log(`page.sh: ${files.length} static files`);' "$OUT/app" "${IFRAME_URL:-}"
echo "page.sh: wrote $OUT"
