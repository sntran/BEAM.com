#!/bin/sh
# Boot the release of setup.sh in the WebAssembly ERTS (Node.js), as
# "bin/hello start" does, in interactive mode:
#
#   BOOTSTRAP=/path/to/otp ELIXIR=/path/to/elixir wasm/phoenix/run.sh [ERL ARGS]
#
# BOOTSTRAP: the native OTP build tree; ELIXIR: the Elixir source tree
# (lib/*/ebin). ROOT gets the versioned app directories of the boot script.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${BOOTSTRAP:?set BOOTSTRAP}" "${ELIXIR:?set ELIXIR}"
DIR=${DIR:-$HERE/build}
REL=$DIR/hello/_build/prod/rel/hello
VSN=$(cut -d' ' -f2 "$REL/releases/start_erl.data")
ROOT=$DIR/root
if [ ! -d "$ROOT" ]; then
    mkdir -p "$ROOT/lib" "$ROOT/bin"
    cp "$BOOTSTRAP/bin/start_clean.boot" "$ROOT/bin/"
    # The versions come from the .rel file of the release.
    sed -n 's/.*{\([a-z0-9_]*\),"\([0-9.]*\)",[a-z]*}.*/\1 \2/p' "$REL/releases/$VSN/hello.rel" |
    while read -r app vsn; do
        if [ -d "$BOOTSTRAP/lib/$app/ebin" ]; then ln -s "$BOOTSTRAP/lib/$app" "$ROOT/lib/$app-$vsn"
        elif [ -d "$ELIXIR/lib/$app/ebin" ]; then ln -s "$ELIXIR/lib/$app" "$ROOT/lib/$app-$vsn"
        fi
    done
fi
mkdir -p "$REL/tmp"
cp "$REL/releases/$VSN/sys.config" "$REL/tmp/run.runtime.config"
export RELEASE_ROOT="$REL" RELEASE_NAME=hello RELEASE_VSN="$VSN" RELEASE_MODE=interactive \
    RELEASE_TMP="$REL/tmp" RELEASE_SYS_CONFIG="$REL/tmp/run.runtime" RELEASE_PROG=hello
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(head -c 48 /dev/urandom | base64 | tr -d '\n')}" PHX_HOST="${PHX_HOST:-localhost}"
cd "$HERE/../erts/build"
# SERVE=1: Bandit serves HTTP on $PORT (4000), with TCP sockets of the
# Node.js host (wasm_tcp). The dirty I/O schedulers keep their default
# number: one of them waits for the events of the host.
host=beam-node.mjs beam=
if [ "${SERVE:-0}" = 1 ]; then
    export PHX_SERVER=true WASM_HOST=1
    host=$HERE/../erts/host/server.mjs beam=./beam.mjs
fi
# shellcheck disable=SC2086
exec env ROOTDIR="$ROOT" BINDIR="$ROOT/bin" EMU=beam PROGNAME=erl "${NODE:-node}" ${NODE_FLAGS:-} "$host" $beam \
    -S 1 -SDcpu 1 -A 0 -- -root "$ROOT" -bindir "$ROOT/bin" -progname erl -- \
    -home "${HOME:-/}" -mode interactive -config "$REL/tmp/run.runtime" \
    -boot "$REL/releases/$VSN/start" -boot_var RELEASE_LIB "$REL/lib" -noshell "$@"
