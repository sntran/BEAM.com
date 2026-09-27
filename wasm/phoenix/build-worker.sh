#!/bin/sh
# Build the Phoenix app of setup.sh for Cloudflare Workers: the release
# directory is the input of beam.com (--target wasm32), and the runtime is
# the WebAssembly ERTS of wasm/erts (built once, with Emscripten).
#
#   BEAM_COM=/path/to/beam.com [EMSDK=...] wasm/phoenix/build-worker.sh
#   workerd serve wasm/phoenix/build/worker/worker.capnp   # http://127.0.0.1:8789/counter
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${BEAM_COM:?set BEAM_COM}"
DIR=${DIR:-$HERE/build}
RUNTIME=${RUNTIME:-$HERE/../erts/build/runtime}
if [ ! -f "$RUNTIME/beam.wasm" ]; then
    : "${EMSDK:?set EMSDK (to build the runtime)}"
    WORKER=1 WORKER_ROOTFS=none WORKER_OUT="$RUNTIME" "$HERE/../erts/build.sh"
fi
BEAM_COM_WASM_RUNTIME=$RUNTIME "$BEAM_COM" "$DIR/hello/_build/prod/rel/hello" \
    -o "$DIR/worker" --target wasm32
