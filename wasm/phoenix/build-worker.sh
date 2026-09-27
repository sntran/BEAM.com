#!/bin/sh
# Build the Phoenix app of setup.sh as a Cloudflare Worker: a Durable Object
# that runs the WebAssembly emulator with the release in its memory (/app).
#
#   EMSDK=... BOOTSTRAP=/path/to/otp ELIXIR=/path/to/elixir wasm/phoenix/build-worker.sh
#   workerd serve wasm/phoenix/build/worker/worker.capnp   # http://localhost:8789/counter
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${EMSDK:?set EMSDK}" "${BOOTSTRAP:?set BOOTSTRAP}" "${ELIXIR:?set ELIXIR}"
DIR=${DIR:-$HERE/build}
REL=$DIR/hello/_build/prod/rel/hello
VSN=$(cut -d' ' -f2 "$REL/releases/start_erl.data")
F=$DIR/worker-rootfs/app
rm -rf "$DIR/worker-rootfs"
mkdir -p "$F/lib" "$F/bin" "$F/tmp" "$F/releases"
cp "$BOOTSTRAP/bin/start_clean.boot" "$F/bin/"
cp -R "$REL/releases/$VSN" "$F/releases/"
cp "$REL/releases/start_erl.data" "$F/releases/"
cp "$REL/releases/$VSN/sys.config" "$F/tmp/run.runtime.config"
cp -R "$REL"/lib/* "$F/lib/"
# Only the priv of the app: app.js has the JS of phoenix and LiveView.
for d in "$F"/lib/*/priv; do
    case $d in */hello-*) ;; *) rm -rf "$d" ;; esac
done
rm -f "$F/releases/$VSN"/*.script "$F/releases/$VSN"/env.* "$F/releases/$VSN"/*vm.args
# The OTP and Elixir applications of the release (ebin only).
sed -n 's/.*{\([a-z0-9_]*\),"\([0-9.]*\)",[a-z]*}.*/\1 \2/p' "$REL/releases/$VSN/hello.rel" |
while read -r app vsn; do
    [ -d "$F/lib/$app-$vsn" ] && continue
    for src in "$BOOTSTRAP/lib/$app" "$ELIXIR/lib/$app"; do
        if [ -d "$src/ebin" ]; then
            # An empty priv: the static NIFs (asn1rt_nif, crypto) are
            # loaded with a path in code:priv_dir/1.
            mkdir -p "$F/lib/$app-$vsn/priv"
            cp -R "$src/ebin" "$F/lib/$app-$vsn/"
            break
        fi
    done
done
"$BOOTSTRAP/bin/erl" -noshell -eval \
    "{ok, _} = beam_lib:strip_files(filelib:wildcard(\"$F/lib/*/ebin/*.beam\")), halt()."
du -sh "$F"

WORKER=1 WORKER_ROOTFS="$F" WORKER_MOUNT=/app WORKER_OUT="$DIR/worker" "$HERE/../erts/build.sh"
cp "$HERE/worker/worker.js" "$DIR/worker/"
key=$(head -c 48 /dev/urandom | base64 | tr -d '\n')
sed "s|@SECRET_KEY_BASE@|$key|; s|@VSN@|$VSN|g" "$HERE/worker/worker.capnp" > "$DIR/worker/worker.capnp"
