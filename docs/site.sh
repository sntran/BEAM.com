#!/bin/sh
# Builds the site of BEAM.com for GitHub Pages into OUT, with the tools of
# BEAM_COM (mix, elixir): the documentation (ExDoc, docs/site), and the
# Erlang shell of examples/worker in the page, at repl/.
#
#   sh docs/site.sh BEAM_COM OUT
set -eu
BEAM_COM=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
OUT=$2
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
mkdir -p "$OUT"
cp -R "$SITE/doc/." "$OUT/"
sh "$ROOT/examples/worker/pages.sh" "$BEAM_COM" "$OUT/repl"
echo "site.sh: wrote $OUT"
