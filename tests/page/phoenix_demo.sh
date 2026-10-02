#!/bin/sh
# Builds examples/phoenix_demo as a static site (DIR/page/) with beam.com,
# for the browser check (tests/page/check.mjs):
#
#   tests/page/phoenix_demo.sh BEAM_COM DIR
#
# beam.com runs Mix when its name is mix.com. The kernel must run APE
# files (CI registers the APE loader).
set -eu
[ $# -eq 2 ] || { echo "usage: $0 BEAM_COM DIR" >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BEAM_COM=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
mkdir -p "$2"
DIR=$(cd "$2" && pwd)
APP=$ROOT/examples/phoenix_demo

BIN=$APP/_build/page-bin
mkdir -p "$BIN"
ln -sf "$BEAM_COM" "$BIN/mix.com"
export PATH="$BIN:$PATH" MIX_ENV=prod
cd "$APP"
mix.com local.hex --force --if-missing
mix.com deps.get --only prod
mix.com compile
mix.com assets.deploy
# mix release keeps the directories of old versions in lib/. Remove them.
rm -rf _build/prod/rel/phoenix_demo
RELEASE_ERTS=false mix.com release --overwrite

# The build runs the release once on this computer, to find the modules of
# its boot. runtime.exs needs a database and a secret for that run.
NATIVE=$(mktemp -d)
trap 'rm -rf "$NATIVE"' EXIT
rm -rf "$DIR"
DATABASE_PATH="$NATIVE/native.db" SECRET_KEY_BASE=$(mix.com phx.gen.secret) \
    "$BEAM_COM" _build/prod/rel/phoenix_demo -o "$DIR" --target wasm32
echo "phoenix_demo.sh: wrote $DIR/page"
