#!/bin/sh
# Builds the release of the studio (_build/prod/rel/studio), with no ERTS,
# for beam.com. page.sh runs it.
#
#   BEAM_COM=/path/to/beam.com scripts/release.sh
set -eu
: "${BEAM_COM:?set BEAM_COM to the path of beam.com}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# beam.com runs Mix when its name is mix.com, and escript for rebar3.
BIN=$ROOT/_build/wasm-bin
mkdir -p "$BIN"
ln -sf "$BEAM_COM" "$BIN/mix.com"
ln -sf "$BEAM_COM" "$BIN/escript"
export PATH="$BIN:$PATH" MIX_ENV=prod
cd "$ROOT"
mix.com local.hex --force --if-missing
mix.com deps.get --only prod
mix.com compile
# mix release keeps the directories of old versions in lib/. Remove them.
rm -rf _build/prod/rel/studio
RELEASE_ERTS=false mix.com release --overwrite
