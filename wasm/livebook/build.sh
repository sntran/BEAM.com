#!/bin/sh
# The build command of Workers Builds: Cloudflare builds and deploys the
# Worker "livebook" at each push (docs/history/WASM-LOG.md, "Build and deploy at each
# push"). The settings of the Worker (Settings > Build):
#   Root directory:  wasm/livebook
#   Build command:   sh build.sh
#   Deploy command:  sh deploy.sh
#   Build watch paths: include wasm/livebook/*
#   Build variables: SUBDOMAIN (the workers.dev subdomain of the account),
#     and optionally INSTANCES, RETIRE (see setup.sh) and BEAM_COM_URL
#     (another beam.com; the default is the prerelease "edge" of
#     beam.com, from its branch main).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${SUBDOMAIN:?set the build variable SUBDOMAIN}"
URL=${BEAM_COM_URL:-https://github.com/sntran/beam.com/releases/download/edge/beam.com}
mkdir -p "$HERE/build/beam"
curl -sSfL -o "$HERE/build/beam/beam.com" "$URL"
# The SHA-256 beside the file, when the URL has one.
if curl -sfL -o "$HERE/build/beam/beam.com.sha256" "$URL.sha256"; then
    (cd "$HERE/build/beam" && sha256sum -c beam.com.sha256)
fi
chmod +x "$HERE/build/beam/beam.com"
"$HERE/build/beam/beam.com" --version
BEAM_COM="$HERE/build/beam/beam.com" sh "$HERE/setup.sh" "$HERE/build"
