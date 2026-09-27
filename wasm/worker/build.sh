#!/bin/sh
# Makes a Cloudflare Worker of a release, with no toolchain: the runtime of
# wasm/erts (beam.wasm and beam.mjs, built once with WORKER=1
# WORKER_ROOTFS=none), release.bin (pack.erl, in Erlang), worker.js and the
# workerd configuration.
#
#   RUNTIME=dir ESCRIPT=escript wasm/worker/build.sh REL_DIR OUT_DIR LIB_DIR...
#   workerd serve OUT_DIR/worker.capnp
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${RUNTIME:?set RUNTIME (beam.wasm and beam.mjs)}"
REL=$1 OUT=$2
shift 2
mkdir -p "$OUT"
"${ESCRIPT:-escript}" "$HERE/pack.erl" "$REL" "$OUT/release.bin" "$@"
cp "$RUNTIME/beam.wasm" "$RUNTIME/beam.mjs" "$HERE/worker.js" "$OUT/"
key=$(head -c 48 /dev/urandom | base64 | tr -d '\n')
sed "s|@SECRET_KEY_BASE@|$key|" "$HERE/worker.capnp" > "$OUT/worker.capnp"
ls -l "$OUT"
