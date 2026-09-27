#!/bin/sh
# Makes a Cloudflare Worker of a release, with no toolchain: the runtime of
# wasm/erts (beam.wasm and beam.mjs, built once with WORKER=1
# WORKER_ROOTFS=none), release.bin (pack.erl, in Erlang), worker.js and the
# workerd configuration.
#
#   RUNTIME=dir ESCRIPT=escript wasm/worker/build.sh REL_DIR OUT_DIR LIB_DIR...
#   workerd serve OUT_DIR/worker.capnp
#
# MODE=object (default): one Durable Object runs the VM. MODE=plain: a plain
# Worker, with one VM for each isolate (no binding to set up). MODE=split: a
# runtime Worker with no application, and the release in a second Worker
# (app.js) that it reaches with a service binding.
# MODULES=file: only the .beam files of these modules (pack.erl --modules).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${RUNTIME:?set RUNTIME (beam.wasm and beam.mjs)}"
REL=$1 OUT=$2
shift 2
mkdir -p "$OUT"
"${ESCRIPT:-escript}" "$HERE/pack.erl" ${MODULES:+--modules "$MODULES"} "$REL" "$OUT/release.bin" "$@"
cp "$RUNTIME/beam.wasm" "$RUNTIME/beam.mjs" "$HERE/worker.js" "$OUT/"
key=$(head -c 48 /dev/urandom | base64 | tr -d '\n')
case ${MODE:-object} in
    object) conf=worker.capnp ;;
    plain) conf=worker-plain.capnp ;;
    split) conf=worker-split.capnp; cp "$HERE/app.js" "$OUT/" ;;
    *) echo "MODE: object, plain or split" >&2; exit 2 ;;
esac
sed "s|@SECRET_KEY_BASE@|$key|" "$HERE/$conf" > "$OUT/worker.capnp"
ls -l "$OUT"
