#!/bin/sh
# Boot the Worker release of build-worker.sh (build/worker/release/release.bin,
# with wasm_host) in the WebAssembly ERTS in Node.js (wasm/erts/build, the
# Node.js build), as the Worker does:
#
#   wasm/phoenix/run.sh [ERL ARGS]             # the boot only (no server)
#   SERVE=1 wasm/phoenix/run.sh                # http://localhost:4000/counter
#
# SERVE=1: the Node.js host (wasm/erts/host/server.mjs) gives the TCP
# sockets of wasm_tcp (WASM_HOST), and Bandit serves HTTP on PORT (4000).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=${DIR:-$HERE/build}
APP=$DIR/node-app
rm -rf "$APP"
eval "$(node "$HERE/../erts/host/unpack.mjs" "$DIR/worker/release/release.bin" "$APP")"
export RELEASE_ROOT="$APP" RELEASE_NAME RELEASE_VSN RELEASE_MODE=interactive \
    RELEASE_TMP="$APP/tmp" RELEASE_SYS_CONFIG="$APP/tmp/run.runtime" RELEASE_PROG="$RELEASE_NAME"
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(head -c 48 /dev/urandom | base64 | tr -d '\n')}" PHX_HOST="${PHX_HOST:-localhost}"
cd "$HERE/../erts/build"
# The dirty I/O schedulers keep their default number: one of them waits for
# the events of the host.
host=beam-node.mjs beam=
if [ "${SERVE:-0}" = 1 ]; then
    # shellcheck disable=SC2086
    export $RELEASE_ENV WASM_HOST=1
    host=$HERE/../erts/host/server.mjs beam=./beam.mjs
fi
# shellcheck disable=SC2086
exec env ROOTDIR="$APP" BINDIR="$APP/bin" EMU=beam PROGNAME=erl "${NODE:-node}" ${NODE_FLAGS:-} "$host" $beam \
    -S 1 -SDcpu 1 -A 0 -- -root "$APP" -bindir "$APP/bin" -progname erl -- \
    -home "${HOME:-/}" $RELEASE_ARGS -noshell "$@"
