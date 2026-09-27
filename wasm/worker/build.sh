#!/bin/sh
# Makes the Cloudflare Workers of a release, with no toolchain: the BEAM
# runtime Worker (worker.js, and beam.wasm and beam.mjs of wasm/erts, built
# once with WORKER=1 WORKER_ROOTFS=none), and a Worker with the release
# (app.js and release.bin, packed in Erlang by pack.erl). The runtime gets
# the release at the first request of an isolate.
#
#   RUNTIME=dir ESCRIPT=escript wasm/worker/build.sh REL_DIR OUT_DIR LIB_DIR...
#   workerd serve OUT_DIR/worker.capnp
#
# MODULES=file: only the .beam files of these modules (pack.erl --modules).
# BOOT_MODULES=file: load these modules in one batch at the boot
# (--boot-modules). NO_START=apps: do not start these applications
# (--no-start), as bandit,thousand_island when the host serves HTTP.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${RUNTIME:?set RUNTIME (beam.wasm and beam.mjs)}"
REL=$1 OUT=$2
shift 2
mkdir -p "$OUT"
"${ESCRIPT:-escript}" "$HERE/pack.erl" ${MODULES:+--modules "$MODULES"} \
    ${BOOT_MODULES:+--boot-modules "$BOOT_MODULES"} ${NO_START:+--no-start "$NO_START"} \
    "$REL" "$OUT/release.bin" "$@"
cp "$RUNTIME/beam.wasm" "$RUNTIME/beam.mjs" "$HERE/worker.js" "$HERE/app.js" "$OUT/"
key=$(head -c 48 /dev/urandom | base64 | tr -d '\n')
sed "s|@SECRET_KEY_BASE@|$key|" "$HERE/worker.capnp" > "$OUT/worker.capnp"
ls -l "$OUT"
