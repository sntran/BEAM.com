#!/bin/sh
# Builds the site of BEAM.com for GitHub Pages into OUT, with the tools of
# BEAM_COM (mix, elixir). When LIVEBOOK_DIR names the directory of
# wasm/livebook/setup.sh, the root of the site is Livebook in the page
# (wasm/livebook/page.sh), with the documentation as the notebooks of its
# Learn section. Else the root goes to docs/. OUT also gets:
# - docs/: the same documentation as static pages (ExDoc, docs/site). The
#   page of Livebook goes there in a browser with no JSPI, with
#   docs-map.json (the page of each notebook);
# - repl/: the Erlang shell of examples/worker in the page;
# - phx/: the studio of examples/studio in the page: mix phx.new and a
#   Phoenix app;
# - NAME.html and livebook/: the old addresses of the pages and of
#   Livebook, which go to the new ones.
#
#   [LIVEBOOK_DIR=DIR] sh docs/site.sh BEAM_COM OUT
set -eu
BEAM_COM=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
mkdir -p "$2"
OUT=$(cd "$2" && pwd)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SITE=$ROOT/docs/site
BIN=$(mktemp -d)
trap 'rm -rf "$BIN"' EXIT
# beam.com runs Mix when its name is mix.com.
for t in mix elixir; do ln -s "$BEAM_COM" "$BIN/$t.com"; done
export PATH="$BIN:$PATH" MIX_HOME="$BIN/.mix" HEX_HOME="$BIN/.hex"
rm -rf "$SITE/pages" "$SITE/doc"
elixir.com "$SITE/prepare.exs" "$SITE/pages"
(cd "$SITE" && mix.com local.hex --force --if-missing && mix.com deps.get && mix.com docs)
rm -rf "$OUT/docs"
cp -R "$SITE/doc" "$OUT/docs"
sh "$ROOT/examples/worker/pages.sh" "$BEAM_COM" "$OUT/repl"
# TEMPORARY: the files of a test. Does GitHub Pages compress .com, .zip,
# .wasm and .bin? Remove docs/probe and these lines after the test.
rm -rf "$OUT/probe"
cp -R "$ROOT/docs/probe" "$OUT/probe"
BEAM_COM=$BEAM_COM sh "$ROOT/examples/studio/scripts/page.sh" "$OUT/phx"

# A page that goes to another address, with the part of the address after
# # (the path in Livebook, or an anchor).
redirect() {
    cat > "$1" <<EOF
<!doctype html>
<meta charset="utf-8">
<title>BEAM.com</title>
<meta http-equiv="refresh" content="0; url=$2">
<link rel="canonical" href="$2">
<script>location.replace('$2' + location.hash)</script>
<a href="$2">$2</a>
EOF
}

if [ -n "${LIVEBOOK_DIR:-}" ]; then
    BEAM_COM=$BEAM_COM sh "$ROOT/wasm/livebook/page.sh" "$LIVEBOOK_DIR" "$OUT"
    elixir.com "$ROOT/docs/notebooks/build.exs" "$BIN/notebooks"
    cp "$BIN/notebooks/docs-map.json" "$OUT/"
    mkdir -p "$OUT/livebook"
    redirect "$OUT/livebook/index.html" ../
else
    redirect "$OUT/index.html" docs/
fi
# The pages were at the root of the site before: their old addresses go
# to docs/.
for page in "$OUT"/docs/*.html; do
    name=$(basename "$page")
    case $name in index.html|404.html) continue ;; esac
    redirect "$OUT/$name" "docs/$name"
done
echo "site.sh: wrote $OUT"
