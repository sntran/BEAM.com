#!/bin/sh
# Phase A of the WebAssembly spike (docs/WASM.md): pthreads as green
# threads on JSPI. Builds test.wasm and runs it with Node.js 26 or later.
#
#   CC      a clang with the wasm32 target (default: clang-18)
#   SYSROOT a WASI sysroot (default: /usr, the Ubuntu package wasi-libc)
#   NODE    node with JSPI (WebAssembly.Suspending and promising)
#   OPT     the optimization (default: -O2)
set -e
cd "$(dirname "$0")"
CC=${CC:-clang-18}
SYSROOT=${SYSROOT:-/usr}
NODE=${NODE:-node}
OPT=${OPT:--O2}
"$CC" --target=wasm32-wasi --sysroot="$SYSROOT" -mexec-model=reactor $OPT \
    -Wall -Wextra -Iinclude test.c jspi_pthread.c sp.S -o test.wasm
"$NODE" --no-warnings run.mjs test.wasm
