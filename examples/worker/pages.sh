#!/bin/sh
# The shell as a static site: the VM runs in the page. docs/site.sh puts
# it at repl/ of the site of BEAM.com (GitHub Pages). It
# builds this example with --target wasm32, and writes into OUT the page
# (priv/index.html in its page mode), browser.js, worker.js, the runtime
# and the release.
#
#   sh examples/worker/pages.sh BEAM_COM OUT
#
# Test it with a local server, for example: python3 -m http.server -d OUT
# The page needs a browser with JSPI (Chrome 137 or later).
set -eu
BEAM_COM=$1
# OUT as an absolute path: the copies below run in another directory.
mkdir -p "$2"
OUT=$(cd "$2" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
sh "$BEAM_COM" "$HERE" -o "$BUILD/worker" --target wasm32
rm -f "$HERE/rebar.lock"
mkdir -p "$OUT"
cd "$BUILD/worker"
cp -R browser browser.js worker.js beam.mjs beam.wasm licenses "$OUT/"
cp release/release.bin "$OUT/release.bin"
sed 's/^<html lang="en">$/<html lang="en" data-beam="page">/' "$HERE/priv/index.html" > "$OUT/index.html"
grep -q '^<html lang="en" data-beam="page">$' "$OUT/index.html"
echo "pages.sh: wrote $OUT"
