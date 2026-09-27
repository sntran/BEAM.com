#!/bin/sh
# Run the ERTS of wasm/erts/build.sh in Node.js (24 or newer: JSPI), with the
# .beam files of a native build:
#
#   BOOTSTRAP=/path/to/otp wasm/erts/run.sh [EMULATOR FLAGS] -- [ERL ARGS]
#   wasm/erts/run.sh -S 1 -- -noshell -eval 'io:format("hello~n"), halt().'
#
# Without erlexec, the emulator flags start with "-" (as -S 1 for +S 1).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/build}
NODE=${NODE:-node}
: "${BOOTSTRAP:?set BOOTSTRAP}"
emu=""
while [ $# -gt 0 ] && [ "$1" != "--" ]; do emu="$emu $1"; shift; done
[ $# -gt 0 ] && shift
cd "$OUT"
# shellcheck disable=SC2086
exec env BINDIR="$BOOTSTRAP/bin" ROOTDIR="$BOOTSTRAP" EMU=beam PROGNAME=erl \
    "$NODE" ${NODE_FLAGS:-} beam-node.cjs $emu -- -root "$BOOTSTRAP" -bindir "$BOOTSTRAP/bin" \
    -progname erl -- -home "${HOME:-/}" -boot "$BOOTSTRAP/bin/start_clean" "$@"
