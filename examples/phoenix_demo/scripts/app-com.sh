#!/bin/sh
# The build of app.com: the release of the demo in one native file of
# beam.com (https://github.com/sntran/BEAM.com), with its WebAssembly part.
# The build step of Workers Builds and of Deno Deploy runs it ("npm run
# build"), and the runtime of the npm package beam.com runs the file there
# (worker.js, deno.json).
#
#   npm run build            (or: sh scripts/app-com.sh)
#
# BEAM_COM: a beam.com file in place of the one of the npm package (npx
# beam.com downloads the file of the version of the package).
set -eu
cd "$(dirname "$0")/.."
beam() {
    if [ -n "${BEAM_COM:-}" ]; then sh "$BEAM_COM" "$@"; else npx beam.com "$@"; fi
}
export MIX_ENV=prod
beam mix local.hex --force --if-missing
beam mix deps.get --only prod
beam mix compile
beam mix assets.deploy
# mix release keeps the directories of old versions in lib/. Remove them.
rm -rf _build/prod/rel/phoenix_demo
RELEASE_ERTS=false beam mix release --overwrite
beam _build/prod/rel/phoenix_demo -o app.com
