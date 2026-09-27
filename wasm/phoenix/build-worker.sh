#!/bin/sh
# Build the Phoenix app of setup.sh as a Cloudflare Worker (wasm/worker): a
# Durable Object runs the WebAssembly runtime of wasm/erts, and writes the
# release (release.bin, packed in Erlang) into its file system at /app.
#
#   EMSDK=... BOOTSTRAP=/path/to/otp ELIXIR=/path/to/elixir wasm/phoenix/build-worker.sh
#   workerd serve wasm/phoenix/build/worker/worker.capnp   # http://localhost:8789/counter
#
# The runtime is built once (Emscripten); the release needs no toolchain.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${BOOTSTRAP:?set BOOTSTRAP}" "${ELIXIR:?set ELIXIR}"
DIR=${DIR:-$HERE/build}
RUNTIME=${RUNTIME:-$HERE/../erts/build/runtime}
if [ ! -f "$RUNTIME/beam.wasm" ]; then
    : "${EMSDK:?set EMSDK (to build the runtime)}"
    WORKER=1 WORKER_ROOTFS=none WORKER_OUT="$RUNTIME" "$HERE/../erts/build.sh"
fi
RUNTIME=$RUNTIME ESCRIPT="$BOOTSTRAP/bin/escript" "$HERE/../worker/build.sh" \
    "$DIR/hello/_build/prod/rel/hello" "$DIR/worker" "$BOOTSTRAP/lib" "$ELIXIR/lib"
