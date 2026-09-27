#!/bin/sh
# Build Blink (the x86-64 Linux emulator of Justine Tunney) for WebAssembly
# with Emscripten, and run an x86-64 program in Node.js with it:
#
#   EMSDK=/path/to/emsdk NODE=/path/to/node wasm/blink/build.sh [PROGRAM ARGS...]
#
# Guest threads are host pthreads (Emscripten: one Worker each). No JIT,
# no sockets, no fork. See docs/WASM.md.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/build}
BLINK_COMMIT=${BLINK_COMMIT:-f006a4fc6f9b8de9272504fdff0dbbe5ce5dc580}
NODE=${NODE:-node}
PATH=$EMSDK/upstream/emscripten:$PATH
export PATH

if [ ! -d "$OUT/blink" ]; then
    git clone -q https://github.com/jart/blink.git "$OUT/blink"
    git -C "$OUT/blink" checkout -q "$BLINK_COMMIT"
    git -C "$OUT/blink" apply "$HERE/blink.patch"
fi
cd "$OUT/blink"
if [ ! -f config.mk ]; then
    CONFIG_RUNNER="$NODE" CC=emcc AR=emar CFLAGS="-O2 -pthread" \
    LDFLAGS="-pthread -sALLOW_MEMORY_GROWTH -sMAXIMUM_MEMORY=4GB -sNODERAWFS -sEXIT_RUNTIME -sPROXY_TO_PTHREAD -sPTHREAD_POOL_SIZE=8" \
        ./configure --disable-jit --disable-sockets --disable-fork
    # The test of configure cannot start Workers: turn threads on here.
    sed -i 's|^#define DISABLE_THREADS|// #define DISABLE_THREADS|' config.h
fi
make -j"$(nproc)" o//blink/blink
ls -l o//blink/blink o//blink/blink.wasm
[ $# -eq 0 ] || exec "$NODE" o//blink/blink "$@"
