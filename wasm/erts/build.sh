#!/bin/sh
# Build ERTS (the interpreter) for WebAssembly with Emscripten, with the
# threads of ERTS as green threads on JSPI (see docs/WASM.md, phase B):
#
#   EMSDK=/path/to/emsdk BOOTSTRAP=/path/to/otp wasm/erts/build.sh
#
# BOOTSTRAP is a native build of the same OTP version (the build tree of
# ./build.sh, build/otp): its bootstrap system gives escript and
# yielding_c_fun for the build, and its .beam files are used at run time.
# The result is $OUT/beam.wasm and $OUT/beam.mjs (Node.js, an ES module); run it with
# wasm/erts/run.sh.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
# WASM64=1: wasm64 (-sMEMORY64): 64-bit terms (60-bit small integers, as
# on native), in $HERE/build64.
if [ "${WASM64:-0}" = 1 ]; then
    OUT=${OUT:-$HERE/build64}
    WASM_TARGET=wasm64-unknown-emscripten WASM_ARCH_FLAGS=-sMEMORY64 SP=sp64.S OSSL_TARGET=linux-generic64
else
    OUT=${OUT:-$HERE/build}
    WASM_TARGET=wasm32-unknown-emscripten WASM_ARCH_FLAGS= SP=sp.S OSSL_TARGET=linux-generic32
fi
export WASM_TARGET WASM_ARCH_FLAGS
OTP_VERSION=${OTP_VERSION:-29.1.1}
JOBS=${JOBS:-$(nproc)}
: "${EMSDK:?set EMSDK}" "${BOOTSTRAP:?set BOOTSTRAP}"
PATH=$BOOTSTRAP/bootstrap/bin:$EMSDK/upstream/emscripten:$PATH
export PATH
T=$WASM_TARGET
OTP=$OUT/otp
OPENSSL_VERSION=${OPENSSL_VERSION:-4.0.2}
WASM_OPENSSL=$OUT/openssl
export EMSDK WASM_OPENSSL

# libcrypto for the crypto NIF (linked into the emulator), without
# threads, sockets or assembly code.
if [ ! -f "$WASM_OPENSSL/lib/libcrypto.a" ]; then
    src=$OUT/openssl-src
    [ -d "$src" ] || git clone -q --depth 1 --branch "openssl-$OPENSSL_VERSION" \
        https://github.com/openssl/openssl.git "$src"
    (cd "$src" && ./Configure $OSSL_TARGET CC="emcc $WASM_ARCH_FLAGS" AR=emar RANLIB=emranlib \
        --prefix="$WASM_OPENSSL" --libdir=lib no-shared no-asm no-dso no-engine \
        no-async no-tests no-apps no-docs no-module no-afalgeng no-uplink \
        no-secure-memory no-threads no-sock no-ui-console &&
     make -j"$JOBS" build_libs && make install_dev) > "$OUT/openssl.log" 2>&1
fi

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
emcc -O2 -Wall $WASM_ARCH_FLAGS -c "$HERE/jspi_pthread.c" -o "$OUT/jspi_pthread.o"
emcc -O2 $WASM_ARCH_FLAGS -c "$HERE/$SP" -o "$OUT/sp.o"

# The static NIFs: asn1 and crypto (the configured ones), and wasm_host
# (messages with the JavaScript host). The table of static NIFs is made
# from this list.
emcc -O2 -Wall $WASM_ARCH_FLAGS -DSTATIC_ERLANG_NIF -DSTATIC_ERLANG_NIF_LIBNAME=wasm_host \
    -I"$OTP/erts/emulator/beam" -I"$OTP/erts/include" -I"$OTP/erts/include/$T" \
    -c "$HERE/wasm_host_nif.c" -o "$OUT/wasm_host_nif.o"
rm -f "$OUT/wasm_host.a"
emar rcs "$OUT/wasm_host.a" "$OUT/wasm_host_nif.o"
NIFS="$OTP/lib/asn1/priv/lib/$T/asn1rt_nif.a $OTP/lib/crypto/priv/lib/$T/crypto.a $OUT/wasm_host.a:wasm_host"
rm -f "erts/emulator/$T/opt/emu/driver_tab.c"

# -fno-exceptions: erl_crash_dump.c needs no C++-style unwinding (configure
# adds -fexceptions). DEXPORT empty: no dynamic NIFs or drivers, so no
# export of all symbols (-export-dynamic makes a JS wrapper for each). Our pthread functions come first and replace the
# stubs of Emscripten's libc.
LDF="-O2 $WASM_ARCH_FLAGS -sJSPI -sALLOW_MEMORY_GROWTH -sMAXIMUM_MEMORY=4GB -sSTACK_SIZE=1MB -sNODERAWFS -sEXIT_RUNTIME -sMODULARIZE -sEXPORT_ES6 ${EXTRA_LDFLAGS:-} --js-library $HERE/jspi_lib.js -Wl,--allow-multiple-definition $OUT/jspi_pthread.o $OUT/sp.o"
rm -f "bin/$T/beam.emu" "bin/$T/beam.smp" "bin/$T/beam.wasm"
make -C erts/emulator -j"$JOBS" TARGET=$T FLAVOR=emu TYPE=opt ARCHCFLAGS="-fno-exceptions ${WASM_CFLAGS:-}" DEXPORT= STATIC_NIFS="$NIFS" EMU_LDFLAGS="$LDF" opt > "$OUT/emulator.log" 2>&1
cp "bin/$T/beam.wasm" "$OUT/beam.wasm"
cp "bin/$T/beam.emu" "$OUT/beam.mjs"
cp "$HERE/beam-node.mjs" "$OUT/"
ls -l "$OUT/beam.wasm" "$OUT/beam.mjs"

# The variant for Workers (Cloudflare workerd; hosts without files and
# without run-time compilation of WebAssembly): an ES module, and the
# stripped kernel and stdlib in the memory of the module (/otp).
# WORKER_ROOTFS: another directory to embed, at WORKER_MOUNT (/otp), and
# the result in WORKER_OUT ($OUT/worker).
if [ "${WORKER:-0}" = 1 ]; then
    F=${WORKER_ROOTFS:-$OUT/rootfs/otp}
    if [ -z "${WORKER_ROOTFS:-}" ] && [ "$F" != none ]; then
        rm -rf "$OUT/rootfs"
        mkdir -p "$F/bin" "$F/lib/kernel/ebin" "$F/lib/stdlib/ebin"
        cp "$BOOTSTRAP/bin/start_clean.boot" "$F/bin/"
        cp "$BOOTSTRAP"/lib/kernel/ebin/* "$F/lib/kernel/ebin/"
        cp "$BOOTSTRAP"/lib/stdlib/ebin/* "$F/lib/stdlib/ebin/"
        "$BOOTSTRAP/bin/erl" -noshell -eval \
            "{ok, _} = beam_lib:strip_files(filelib:wildcard(\"$F/lib/*/ebin/*.beam\")), halt()."
    fi
    WOUT=${WORKER_OUT:-$OUT/worker}
    # WORKER_ROOTFS=none: no files in the module (the runtime of the
    # Workers of beam.com --target wasm32: the host writes a release into
    # the file system, FS).
    if [ "$F" = none ]; then
        FILES="-sFORCE_FILESYSTEM -sEXPORTED_RUNTIME_METHODS=ENV,HEAPU8,FS"
    else
        FILES="-sEXPORTED_RUNTIME_METHODS=ENV,HEAPU8 --embed-file $F@${WORKER_MOUNT:-/otp}"
    fi
    LDF="-O2 $WASM_ARCH_FLAGS -sJSPI -sALLOW_MEMORY_GROWTH -sMAXIMUM_MEMORY=4GB -sSTACK_SIZE=1MB -sMODULARIZE -sEXPORT_ES6 -sENVIRONMENT=web $FILES -sINCOMING_MODULE_JS_API=arguments,preRun,print,printErr,instantiateWasm,onExit,jspiSchedule,noInitialRun,onRuntimeInitialized --js-library $HERE/jspi_lib.js -Wl,--allow-multiple-definition $OUT/jspi_pthread.o $OUT/sp.o"
    rm -f "bin/$T/beam.emu" "bin/$T/beam.smp" "bin/$T/beam.wasm"
    make -C erts/emulator -j"$JOBS" TARGET=$T FLAVOR=emu TYPE=opt ARCHCFLAGS="-fno-exceptions ${WASM_CFLAGS:-}" DEXPORT= STATIC_NIFS="$NIFS" EMU_LDFLAGS="$LDF" opt > "$OUT/worker.log" 2>&1
    mkdir -p "$WOUT"
    cp "bin/$T/beam.emu" "$WOUT/beam.mjs"
    cp "bin/$T/beam.wasm" "$WOUT/beam.wasm"
    [ -n "${WORKER_ROOTFS:-}" ] || cp "$HERE/worker/worker.js" "$HERE/worker/worker.capnp" "$WOUT/"
    ls -l "$WOUT/beam.wasm"
    # Run it: workerd serve $OUT/worker/worker.capnp (http://127.0.0.1:8788/?eval=EXPR)
fi
