#!/bin/sh
# Build ERTS (the interpreter) for WebAssembly with Emscripten, with the
# threads of ERTS as green threads on JSPI (see docs/WASM.md, phase B):
#
#   EMSDK=/path/to/emsdk BOOTSTRAP=/path/to/otp wasm/erts/build.sh
#
# BOOTSTRAP is a native build of the same OTP version (the build tree of
# ./build.sh, build/otp): its bootstrap system gives escript and
# yielding_c_fun for the build, and its .beam files are used at run time.
# The result is $OUT/beam.wasm and $OUT/beam.cjs (Node.js); run it with
# wasm/erts/run.sh.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/build}
OTP_VERSION=${OTP_VERSION:-29.1.1}
JOBS=${JOBS:-$(nproc)}
: "${EMSDK:?set EMSDK}" "${BOOTSTRAP:?set BOOTSTRAP}"
PATH=$BOOTSTRAP/bootstrap/bin:$EMSDK/upstream/emscripten:$PATH
export PATH
T=wasm32-unknown-emscripten
OTP=$OUT/otp

if [ ! -d "$OTP" ]; then
    git clone -q --depth 1 --branch "OTP-$OTP_VERSION" https://github.com/erlang/otp.git "$OTP"
    git -C "$OTP" apply "$HERE/otp.patch"
fi
cd "$OTP"
export ERL_TOP=$OTP
if [ ! -f "erts/$T/config.h" ]; then
    ./otp_build configure --xcomp-conf="$HERE/erl-xcomp-wasm32-emscripten.conf" > "$OUT/configure.log" 2>&1
    # Configure finds mallopt() at link time; Emscripten does not declare it.
    sed -i 's|^#define HAVE_MALLOPT 1|/* #undef HAVE_MALLOPT */|' "erts/$T/config.h"
fi
# yielding_c_fun runs on the build machine.
mkdir -p "erts/lib_src/yielding_c_fun/bin/$T"
cp "$BOOTSTRAP/bootstrap/bin/yielding_c_fun" "erts/lib_src/yielding_c_fun/bin/$T/"
make -C erts/lib_src -j"$JOBS" TARGET=$T TYPE=opt opt > "$OUT/lib_src.log" 2>&1

# The green threads (pthreads on JSPI).
emcc -O2 -Wall -c "$HERE/jspi_pthread.c" -o "$OUT/jspi_pthread.o"
emcc -O2 -c "$HERE/sp.S" -o "$OUT/sp.o"

# -fno-exceptions: erl_crash_dump.c needs no C++-style unwinding (configure
# adds -fexceptions). Our pthread functions come first and replace the
# stubs of Emscripten's libc.
LDF="-O2 -sJSPI -sALLOW_MEMORY_GROWTH -sMAXIMUM_MEMORY=4GB -sSTACK_SIZE=1MB -sNODERAWFS -sEXIT_RUNTIME ${EXTRA_LDFLAGS:-} --js-library $HERE/jspi_lib.js -Wl,--allow-multiple-definition $OUT/jspi_pthread.o $OUT/sp.o"
rm -f "bin/$T/beam.emu" "bin/$T/beam.smp" "bin/$T/beam.wasm"
make -C erts/emulator -j"$JOBS" TARGET=$T FLAVOR=emu TYPE=opt ARCHCFLAGS=-fno-exceptions EMU_LDFLAGS="$LDF" opt > "$OUT/emulator.log" 2>&1
cp "bin/$T/beam.wasm" "$OUT/beam.wasm"
cp "bin/$T/beam.emu" "$OUT/beam.cjs"
ls -l "$OUT/beam.wasm" "$OUT/beam.cjs"

# The variant for Workers (Cloudflare workerd; hosts without files and
# without run-time compilation of WebAssembly): an ES module, and the
# stripped kernel and stdlib in the memory of the module (/otp).
if [ "${WORKER:-0}" = 1 ]; then
    F=$OUT/rootfs/otp
    rm -rf "$OUT/rootfs"
    mkdir -p "$F/bin" "$F/lib/kernel/ebin" "$F/lib/stdlib/ebin"
    cp "$BOOTSTRAP/bin/start_clean.boot" "$F/bin/"
    cp "$BOOTSTRAP"/lib/kernel/ebin/* "$F/lib/kernel/ebin/"
    cp "$BOOTSTRAP"/lib/stdlib/ebin/* "$F/lib/stdlib/ebin/"
    "$BOOTSTRAP/bin/erl" -noshell -eval \
        "{ok, _} = beam_lib:strip_files(filelib:wildcard(\"$F/lib/*/ebin/*.beam\")), halt()."
    LDF="-O2 -sJSPI -sALLOW_MEMORY_GROWTH -sMAXIMUM_MEMORY=4GB -sSTACK_SIZE=1MB -sMODULARIZE -sEXPORT_ES6 -sENVIRONMENT=web -sEXPORTED_RUNTIME_METHODS=ENV,HEAPU8 -sINCOMING_MODULE_JS_API=arguments,preRun,print,printErr,instantiateWasm,onExit --embed-file $F@/otp --js-library $HERE/jspi_lib.js -Wl,--allow-multiple-definition $OUT/jspi_pthread.o $OUT/sp.o"
    rm -f "bin/$T/beam.emu" "bin/$T/beam.smp" "bin/$T/beam.wasm"
    make -C erts/emulator -j"$JOBS" TARGET=$T FLAVOR=emu TYPE=opt ARCHCFLAGS=-fno-exceptions EMU_LDFLAGS="$LDF" opt > "$OUT/worker.log" 2>&1
    mkdir -p "$OUT/worker"
    cp "bin/$T/beam.emu" "$OUT/worker/beam.mjs"
    cp "bin/$T/beam.wasm" "$OUT/worker/beam.wasm"
    cp "$HERE/worker/worker.js" "$HERE/worker/worker.capnp" "$OUT/worker/"
    ls -l "$OUT/worker/beam.wasm"
    # Run it: workerd serve $OUT/worker/worker.capnp (http://127.0.0.1:8788/?eval=EXPR)
fi
