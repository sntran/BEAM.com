#!/bin/sh
# Build BEAM.com: Erlang/OTP's runtime (ERTS) as one Actually Portable
# Executable, with the OTP libraries, the beam.com commands and the hello
# release in its zip (redbean style).
#
# Usage: ./build.sh [step...]
#   Steps: toolchain openssl otp configure sqlite wasm make release
#          multicall bundle test
#   With no step, all steps run in order.
#
# Environment:
#   OTP_VERSION      OTP git tag without "OTP-" (default 29.1.1)
#   COSMOCC_VERSION  cosmocc release to download (default 4.0.2)
#   OPENSSL_VERSION  OpenSSL git tag without "openssl-" (default 4.0.2)
#   SQLITE           1: link SQLite (the esqlite NIF) into beam.com, and put
#                    the esqlite application in the zip (default 0)
#   SQLITE_VERSION   SQLite version (default 3.53.4), and SQLITE_YEAR, the
#                    year directory of its download on sqlite.org (2026)
#   WASM             1: link WebAssembly (WAMR) into beam.com, and put the
#                    wasm application in the zip (default 1)
#   WAMR_VERSION     WAMR git tag without "WAMR-" (default 2.4.5)
#   COSMOCC          Directory of an unpacked cosmocc (default build/cosmocc)
#   CC               C compiler (default cosmocc, which makes x86_64+aarch64
#                    fat binaries; x86_64-unknown-cosmo-cc makes x86_64 only)
#   AR               Archiver (default cosmoar; use x86_64-linux-cosmo-ar
#                    with x86_64-unknown-cosmo-cc)
#   BUILD            Build directory (default ./build)
#   JOBS             Parallel make jobs (default: number of CPUs)
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
OTP_VERSION=${OTP_VERSION:-29.1.1}
COSMOCC_VERSION=${COSMOCC_VERSION:-4.0.2}
OPENSSL_VERSION=${OPENSSL_VERSION:-4.0.2}
SQLITE=${SQLITE:-0}
# esqlite (Apache-2.0), with the SQLite amalgamation (public domain) of
# sqlite.org instead of the older copy in esqlite.
ESQLITE_COMMIT=${ESQLITE_COMMIT:-5c8d590d8eb70de17dd2c64dfc7502f4fd2fcba8}
SQLITE_VERSION=${SQLITE_VERSION:-3.53.4}
SQLITE_YEAR=${SQLITE_YEAR:-2026}
WASM=${WASM:-1}
WAMR_VERSION=${WAMR_VERSION:-2.4.5}
BUILD=${BUILD:-$ROOT/build}
COSMOCC=${COSMOCC:-$BUILD/cosmocc}
CC=${CC:-cosmocc}
AR=${AR:-cosmoar}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}

# The OTP applications in the zip. "beam.com build" copies the ones that
# a program needs into the new executable.
BUNDLE_APPS="kernel stdlib sasl compiler crypto asn1 public_key ssl inets"
# The small build (OTP_SMALL_BUILD) does not make these.
EXTRA_APPS="crypto asn1 public_key ssl"

ERL_TOP=$BUILD/otp
RELEASE=$BUILD/release
OPENSSL=$BUILD/openssl
ESQLITE=$BUILD/esqlite
WAMR=$BUILD/wamr
STAGE=$BUILD/stage
OUT=${OUT:-$BUILD/beam.com}

export ERL_TOP
PATH=$COSMOCC/bin:$PATH
export PATH

log() { printf '\n==> %s\n' "$*"; }

step_toolchain() {
    if [ -x "$COSMOCC/bin/cosmocc" ]; then
        log "Using cosmocc in $COSMOCC"
        return
    fi
    log "Downloading cosmocc $COSMOCC_VERSION"
    mkdir -p "$COSMOCC"
    url=https://github.com/jart/cosmopolitan/releases/download/$COSMOCC_VERSION/cosmocc-$COSMOCC_VERSION.zip
    curl -fsSL -o "$BUILD/cosmocc.zip" "$url"
    (cd "$COSMOCC" && unzip -q "$BUILD/cosmocc.zip")
    rm -f "$BUILD/cosmocc.zip"
}

step_openssl() {
    if [ -f "$OPENSSL/lib/libcrypto.a" ]; then
        log "Using OpenSSL in $OPENSSL"
        return
    fi
    src=$BUILD/openssl-src
    if [ ! -d "$src/.git" ]; then
        log "Cloning OpenSSL $OPENSSL_VERSION"
        git clone -q --depth 1 --branch "openssl-$OPENSSL_VERSION" \
            https://github.com/openssl/openssl.git "$src"
    fi
    log "Building a static libcrypto with $CC"
    cd "$src"
    # Only libcrypto is used (by the crypto NIF). No assembly code, so
    # that the same C code compiles for x86_64 and aarch64.
    ./Configure linux-generic64 CC="$CC" AR="$AR" RANLIB=true \
        --prefix="$OPENSSL" --libdir=lib \
        no-shared no-asm no-dso no-engine no-async no-tests no-apps \
        no-docs no-module no-afalgeng no-uplink no-secure-memory
    make -j"$JOBS" build_libs
    make install_dev
    # A fat archive has its aarch64 twin in .aarch64/, and "make install"
    # does not copy it.
    if [ -f .aarch64/libcrypto.a ]; then
        mkdir -p "$OPENSSL/lib/.aarch64"
        cp .aarch64/libcrypto.a "$OPENSSL/lib/.aarch64/"
    fi
}

step_otp() {
    if [ ! -d "$ERL_TOP/.git" ]; then
        log "Cloning Erlang/OTP $OTP_VERSION"
        git clone -q --depth 1 --branch "OTP-$OTP_VERSION" \
            https://github.com/erlang/otp.git "$ERL_TOP"
    fi
    if [ ! -f "$ERL_TOP/.beam_com_patched" ]; then
        log "Applying patches"
        for p in "$ROOT"/patches/otp/*.patch; do
            echo "  $p"
            git -C "$ERL_TOP" apply "$p"
        done
        touch "$ERL_TOP/.beam_com_patched"
    fi
    # The multi-call wrappers compile with the ERTS flags.
    cp "$ROOT"/cosmo/beam_com.c "$ROOT"/cosmo/beam_com_child_setup.c \
       "$ROOT"/cosmo/beam_com_inet_gethost.c "$ERL_TOP/erts/emulator/sys/unix/"
}

step_configure() {
    log "Configuring OTP with $CC"
    cd "$ERL_TOP"
    # Notes on the cache variables:
    #  - poll.h: the POLL* constants of Cosmopolitan are not compile-time
    #    constants, which ERTS needs. The select() back-end uses its own.
    #  - sendfile: inet_drv only knows the Linux/BSD/Solaris variants.
    #  - linux_thp: 2 MiB page alignment breaks the APE layout.
    #  - clock ids: CLOCK_UPTIME exists in the headers but only works on BSD.
    #  - DED_LD*: there are no shared objects. cosmo/noshared writes
    #    placeholder files for NIF libraries, and the configure tests of
    #    the NIFs link normal programs (no -shared).
    # The crypto and asn1 NIFs are linked into the emulator
    # (--enable-static-nifs), so libcrypto must be linked into it too.
    ./configure \
        CC="$CC" AR="$AR" RANLIB=true LIBS="$OPENSSL/lib/libcrypto.a" \
        DED_LD="$ROOT/cosmo/noshared" DED_LDFLAGS="-no-pie" \
        DED_LD_FLAG_RUNTIME_LIBRARY_PATH="-Wl,-rpath," \
        CFLAGS="-O2 -g -DZSTD_DISABLE_ASM -include $ROOT/cosmo/erts_cosmo.h" \
        ac_cv_header_poll_h=no \
        ac_cv_func_sendfile=no \
        erts_cv_linux_thp=no \
        erl_cv_clock_gettime_monotonic_default_resolution=CLOCK_MONOTONIC \
        erl_cv_clock_gettime_monotonic_high_resolution=CLOCK_MONOTONIC \
        --disable-jit \
        --disable-kernel-poll \
        --disable-esock \
        --disable-security-hardening-flags \
        --disable-pie \
        --disable-parallel-configure \
        --without-termcap \
        --with-ssl="$OPENSSL" \
        --disable-dynamic-ssl-lib \
        --enable-static-nifs \
        --without-javac \
        --without-wx \
        --without-odbc \
        --without-debugger \
        --without-observer \
        --without-et
    # The top-level configure does not stop when a sub-configure fails.
    if ! tail -n 1 erts/config.log | grep -q "exit 0"; then
        grep "error:" erts/config.log | tail -n 5
        echo "The ERTS configure failed. See $ERL_TOP/erts/config.log" >&2
        exit 1
    fi
}

target() {
    "$ERL_TOP/make/autoconf/config.guess"
}

step_sqlite() {
    [ "$SQLITE" = 1 ] || return 0
    if [ ! -d "$ESQLITE/.git" ]; then
        log "Fetching esqlite $ESQLITE_COMMIT"
        mkdir -p "$ESQLITE"
        git -C "$ESQLITE" init -q
        git -C "$ESQLITE" fetch -q --depth 1 \
            https://github.com/mmzeeman/esqlite.git "$ESQLITE_COMMIT"
        git -C "$ESQLITE" checkout -q FETCH_HEAD
    fi
    # The amalgamation of SQLITE_VERSION: 3.53.4 is 3530400 in the name.
    amalgamation=$(echo "$SQLITE_VERSION" | awk -F. '{printf "sqlite-amalgamation-%d%02d%02d00", $1, $2, $3}')
    if ! grep -q "define SQLITE_VERSION *\"$SQLITE_VERSION\"" "$ESQLITE/c_src/sqlite3/sqlite3.h"; then
        log "Downloading SQLite $SQLITE_VERSION"
        curl -fsSL -o "$BUILD/$amalgamation.zip" \
            "https://sqlite.org/$SQLITE_YEAR/$amalgamation.zip"
        (cd "$BUILD" && unzip -q -o "$amalgamation.zip")
        cp "$BUILD/$amalgamation/sqlite3.c" "$BUILD/$amalgamation/sqlite3.h" \
            "$ESQLITE/c_src/sqlite3/"
        rm -rf "$BUILD/$amalgamation" "$BUILD/$amalgamation.zip"
    fi
    log "Building the esqlite NIF (SQLite) as a static NIF"
    t=$(target)
    cd "$ESQLITE"
    # The SQLite options of esqlite (rebar.config.script). The NIF is
    # static: its init function is esqlite3_nif_nif_init, which ERTS
    # finds by the name of the module (esqlite3_nif).
    flags="-Os -DSQLITE_DQS=0 -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_MEMSTATUS=0
        -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 -DSQLITE_LIKE_DOESNT_MATCH_BLOBS
        -DSQLITE_MAX_EXPR_DEPTH=0 -DSQLITE_OMIT_DEPRECATED
        -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_USE_ALLOCA
        -DSQLITE_OMIT_AUTOINIT -DSQLITE_USE_URI -DSQLITE_ENABLE_FTS3
        -DSQLITE_ENABLE_FTS3_PARENTHESIS -DSQLITE_ENABLE_FTS4
        -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_MATH_FUNCTIONS
        -DSQLITE_ENABLE_JSON1 -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_GEOPOLY
        -DSTATIC_ERLANG_NIF_LIBNAME=esqlite3_nif -Ic_src/sqlite3
        -I$ERL_TOP/erts/emulator/beam -I$ERL_TOP/erts/include
        -I$ERL_TOP/erts/include/$t"
    # shellcheck disable=SC2086
    "$CC" $flags -c c_src/esqlite3_nif.c -o esqlite3_nif.o
    # shellcheck disable=SC2086
    "$CC" $flags -c c_src/sqlite3/sqlite3.c -o sqlite3.o
    rm -f esqlite3_nif.a .aarch64/esqlite3_nif.a
    "$AR" rcs esqlite3_nif.a esqlite3_nif.o sqlite3.o
}

# The WAMR sources for the interpreter with WASI (from the CMake files of
# WAMR, for the cosmopolitan platform).
WAMR_SOURCES="
    core/shared/platform/cosmopolitan/platform_init.c
    core/shared/platform/common/posix/posix_blocking_op.c
    core/shared/platform/common/posix/posix_clock.c
    core/shared/platform/common/posix/posix_file.c
    core/shared/platform/common/posix/posix_malloc.c
    core/shared/platform/common/posix/posix_memmap.c
    core/shared/platform/common/posix/posix_sleep.c
    core/shared/platform/common/posix/posix_socket.c
    core/shared/platform/common/posix/posix_thread.c
    core/shared/platform/common/posix/posix_time.c
    core/shared/platform/common/libc-util/libc_errno.c
    core/shared/platform/common/memory/mremap.c
    core/shared/mem-alloc/ems/ems_alloc.c
    core/shared/mem-alloc/ems/ems_gc.c
    core/shared/mem-alloc/ems/ems_hmu.c
    core/shared/mem-alloc/ems/ems_kfc.c
    core/shared/mem-alloc/mem_alloc.c
    core/shared/utils/bh_assert.c
    core/shared/utils/bh_bitmap.c
    core/shared/utils/bh_common.c
    core/shared/utils/bh_hashmap.c
    core/shared/utils/bh_leb128.c
    core/shared/utils/bh_list.c
    core/shared/utils/bh_log.c
    core/shared/utils/bh_queue.c
    core/shared/utils/bh_vector.c
    core/shared/utils/runtime_timer.c
    core/iwasm/libraries/libc-wasi/libc_wasi_wrapper.c
    core/iwasm/libraries/libc-wasi/sandboxed-system-primitives/src/blocking_op.c
    core/iwasm/libraries/libc-wasi/sandboxed-system-primitives/src/posix.c
    core/iwasm/libraries/libc-wasi/sandboxed-system-primitives/src/random.c
    core/iwasm/libraries/libc-wasi/sandboxed-system-primitives/src/str.c
    core/iwasm/common/wasm_application.c
    core/iwasm/common/wasm_blocking_op.c
    core/iwasm/common/wasm_c_api.c
    core/iwasm/common/wasm_exec_env.c
    core/iwasm/common/wasm_loader_common.c
    core/iwasm/common/wasm_memory.c
    core/iwasm/common/wasm_native.c
    core/iwasm/common/wasm_runtime_common.c
    core/iwasm/common/wasm_shared_memory.c
    core/iwasm/interpreter/wasm_interp_fast.c
    core/iwasm/interpreter/wasm_loader.c
    core/iwasm/interpreter/wasm_runtime.c"

step_wasm() {
    [ "$WASM" = 1 ] || return 0
    if [ ! -d "$WAMR/.git" ]; then
        log "Cloning WAMR $WAMR_VERSION"
        git clone -q --depth 1 --branch "WAMR-$WAMR_VERSION" \
            https://github.com/bytecodealliance/wasm-micro-runtime.git "$WAMR"
    fi
    log "Building WAMR and the wasm NIF as a static NIF"
    t=$(target)
    obj=$WAMR/obj
    rm -rf "$obj"
    mkdir -p "$obj/.aarch64" "$WAMR/.aarch64"
    cd "$WAMR"
    # Notes on the options:
    #  - WASM_DISABLE_WRITE_GS_BASE: on x86_64, WAMR writes the GS base
    #    register, and Cosmopolitan keeps its thread-local storage there.
    #  - WASM_HAVE_MREMAP=0: Cosmopolitan has no mremap() (only
    #    cosmo_mremap()). WAMR then uses its own (mremap.c).
    #  - WASM_DISABLE_HW_BOUND_CHECK: no guard pages and signal handlers
    #    for the linear memory (the Windows emulation of signals).
    #  - SIMD needs SIMDe, which is not in the WAMR repository.
    flags="-O2 -include $ROOT/apps/wasm/c_src/wamr_target.h
        -DBH_PLATFORM_COSMOPOLITAN -DBH_MALLOC=wasm_runtime_malloc
        -DBH_FREE=wasm_runtime_free -D_GNU_SOURCE
        -DWASM_ENABLE_INTERP=1 -DWASM_ENABLE_FAST_INTERP=1
        -DWASM_ENABLE_LIBC_WASI=1 -DWASM_ENABLE_BULK_MEMORY=1
        -DWASM_ENABLE_BULK_MEMORY_OPT=1 -DWASM_ENABLE_SHRUNK_MEMORY=1
        -DWASM_ENABLE_MODULE_INST_CONTEXT=1 -DWASM_ENABLE_SIMD=0
        -DWASM_DISABLE_HW_BOUND_CHECK=1 -DWASM_DISABLE_STACK_HW_BOUND_CHECK=1
        -DWASM_DISABLE_WAKEUP_BLOCKING_OP=0 -DWASM_DISABLE_WRITE_GS_BASE=1
        -DWASM_HAVE_MREMAP=0 -DWASM_GLOBAL_HEAP_SIZE=10485760
        -Icore/iwasm/include -Icore/iwasm/common -Icore/iwasm/interpreter
        -Icore/iwasm/libraries/libc-wasi/sandboxed-system-primitives/include
        -Icore/iwasm/libraries/libc-wasi/sandboxed-system-primitives/src
        -Icore/shared/platform/cosmopolitan -Icore/shared/platform/include
        -Icore/shared/platform/common/libc-util -Icore/shared/mem-alloc
        -Icore/shared/utils -Icore/shared/utils/uncommon"
    for src in $WAMR_SOURCES; do
        # shellcheck disable=SC2086
        "$CC" $flags -c "$src" -o "$obj/$(basename "$src" .c).o"
    done
    # cosmocc does not take assembler files, so the trampoline is made
    # with the compiler of each CPU (the aarch64 object goes in .aarch64/).
    x86_64-unknown-cosmo-cc -c -Icore/iwasm/common/arch \
        "$ROOT/apps/wasm/c_src/invokeNative.S" -o "$obj/invokeNative.o"
    aarch64-unknown-cosmo-cc -c -Icore/iwasm/common/arch \
        "$ROOT/apps/wasm/c_src/invokeNative.S" -o "$obj/.aarch64/invokeNative.o"
    "$CC" -O2 -DSTATIC_ERLANG_NIF_LIBNAME=wasm -Icore/iwasm/include \
        -I"$ERL_TOP/erts/emulator/beam" -I"$ERL_TOP/erts/include" \
        -I"$ERL_TOP/erts/include/$t" \
        -c "$ROOT/apps/wasm/c_src/wasm_nif.c" -o "$obj/wasm_nif.o"
    rm -f wasm.a .aarch64/wasm.a
    (cd "$obj" && "$AR" rcs "$WAMR/wasm.a" ./*.o)
}

# The STATIC_NIFS value for the emulator Makefile. Empty: the configured
# static NIFs (crypto and asn1).
static_nifs() {
    [ "$SQLITE" = 1 ] || [ "$WASM" = 1 ] || return 0
    t=$(target)
    printf '%s' "$ERL_TOP/lib/asn1/priv/lib/$t/asn1rt_nif.a" \
        " $ERL_TOP/lib/crypto/priv/lib/$t/crypto.a"
    [ "$SQLITE" = 1 ] && printf ' %s' "$ESQLITE/esqlite3_nif.a"
    [ "$WASM" = 1 ] && printf ' %s' "$WAMR/wasm.a"
    return 0
}

# Stop early when a static NIF archive of an enabled option is missing
# (its step did not run).
check_static_nifs() {
    for a in $(static_nifs); do
        [ -f "$a" ] || case $a in
            */lib/asn1/*|*/lib/crypto/*) ;;  # made by the OTP build
            *) echo "Missing $a: run the sqlite and wasm steps first" >&2
               exit 1 ;;
        esac
    done
}

step_make() {
    log "Building OTP (small build)"
    cd "$ERL_TOP"
    # cosmocc does not support "-MM" with many input files. depcc runs
    # it once for each file.
    check_static_nifs
    nifs=$(static_nifs)
    DEPCC_CC=$CC make -j"$JOBS" OTP_SMALL_BUILD=true \
        DEP_CC="$ROOT/cosmo/depcc" ${nifs:+"STATIC_NIFS=$nifs"}
    for app in $EXTRA_APPS; do
        log "Building $app"
        PATH=$ERL_TOP/bootstrap/bin:$PATH DEPCC_CC=$CC \
            make -C "lib/$app" opt DEP_CC="$ROOT/cosmo/depcc"
    done
}

step_multicall() {
    log "Linking the multi-call emulator"
    t=$(target)
    objdir=obj/$t/opt/emu
    cd "$ERL_TOP/erts/emulator"
    objs="$objdir/beam_com.o $objdir/beam_com_child_setup.o $objdir/beam_com_inet_gethost.o"
    make -f "$t/Makefile" TYPE=opt FLAVOR=emu $objs
    rm -f "$ERL_TOP/bin/$t/beam.emu"
    # The table of static NIFs depends on STATIC_NIFS, and make does not
    # know it.
    rm -f "$t/opt/emu/driver_tab.c"
    nifs=$(static_nifs)
    make -f "$t/Makefile" TYPE=opt FLAVOR=emu EMU_LDFLAGS="$objs" \
        ${nifs:+"STATIC_NIFS=$nifs"} "$ERL_TOP/bin/$t/beam.emu"
}

step_release() {
    log "Installing a release tree in $RELEASE"
    cd "$ERL_TOP"
    rm -rf "$RELEASE"
    make release RELEASE_ROOT="$RELEASE" OTP_SMALL_BUILD=true
    (cd "$RELEASE" && ./Install -minimal "$RELEASE" >/dev/null)
}

step_bundle() {
    log "Bundling $OUT"
    t=$(target)
    rm -rf "$STAGE"
    mkdir -p "$STAGE/bin"

    # OTP: boot scripts for tools, and the applications (ebin, and
    # include for "beam.com build").
    cp "$RELEASE"/bin/start_clean.boot "$RELEASE"/bin/no_dot_erlang.boot \
       "$STAGE/bin/"
    cp "$ROOT/cosmo/windows.inetrc" "$STAGE/bin/"
    for app in $BUNDLE_APPS; do
        src=$ERL_TOP/lib/$app
        vsn=$(sed -n 's/.*{vsn, *"\([^"]*\)".*/\1/p' "$src/ebin/$app.app")
        [ -n "$vsn" ] || { echo "No version for $app" >&2; exit 1; }
        mkdir -p "$STAGE/lib/$app-$vsn/ebin"
        cp "$src"/ebin/*.beam "$src/ebin/$app.app" "$STAGE/lib/$app-$vsn/ebin/"
        if ls "$src"/include/*.hrl >/dev/null 2>&1; then
            mkdir -p "$STAGE/lib/$app-$vsn/include"
            cp "$src"/include/*.hrl "$STAGE/lib/$app-$vsn/include/"
        fi
    done

    # SQLite: the Erlang code of esqlite (its NIF is in the emulator).
    if [ "$SQLITE" = 1 ]; then
        vsn=$(sed -n 's/.*{vsn, *"\([^"]*\)".*/\1/p' "$ESQLITE/src/esqlite.app.src")
        mkdir -p "$STAGE/lib/esqlite-$vsn/ebin"
        "$ERL_TOP/bin/erlc" -o "$STAGE/lib/esqlite-$vsn/ebin" "$ESQLITE"/src/*.erl
        cp "$ESQLITE/src/esqlite.app.src" "$STAGE/lib/esqlite-$vsn/ebin/esqlite.app"
    fi

    # WebAssembly: the wasm application (its NIF is in the emulator).
    if [ "$WASM" = 1 ]; then
        mkdir -p "$STAGE/lib/wasm-0.1.0/ebin"
        "$ERL_TOP/bin/erlc" -o "$STAGE/lib/wasm-0.1.0/ebin" "$ROOT"/apps/wasm/src/*.erl
        cp "$ROOT/apps/wasm/src/wasm.app.src" "$STAGE/lib/wasm-0.1.0/ebin/wasm.app"
    fi

    # The commands of beam.com (lib/beam_com has no version, so that
    # beam_com.c can find it), and the runner of one-file programs.
    mkdir -p "$STAGE/lib/beam_com/ebin" "$STAGE/lib/beam_com_script-0.1.0/ebin"
    "$ERL_TOP/bin/erlc" -o "$STAGE/lib/beam_com/ebin" "$ROOT"/apps/beam_com/src/*.erl
    cp "$ROOT/apps/beam_com/src/beam_com.app.src" \
       "$STAGE/lib/beam_com/ebin/beam_com.app"
    "$ERL_TOP/bin/erlc" -o "$STAGE/lib/beam_com_script-0.1.0/ebin" \
        "$ROOT"/apps/beam_com_script/src/*.erl
    cp "$ROOT/apps/beam_com_script/src/beam_com_script.app.src" \
       "$STAGE/lib/beam_com_script-0.1.0/ebin/beam_com_script.app"

    # The hello release, made like any other OTP release.
    erts_vsn=$(cd "$RELEASE" && ls -d erts-* | sed 's/^erts-//')
    kernel_vsn=$(cd "$STAGE/lib" && ls -d kernel-* | sed 's/^kernel-//')
    stdlib_vsn=$(cd "$STAGE/lib" && ls -d stdlib-* | sed 's/^stdlib-//')
    app=$STAGE/lib/hello-0.1.0
    rel=$STAGE/releases/0.1.0
    mkdir -p "$app/ebin" "$rel"
    "$ERL_TOP/bin/erlc" -o "$app/ebin" \
        "$ROOT/hello/hello.erl" "$ROOT/hello/hello_app.erl"
    cp "$ROOT/hello/hello.app" "$app/ebin/"
    printf '{release, {"hello", "0.1.0"}, {erts, "%s"},\n [{kernel, "%s"}, {stdlib, "%s"}, {hello, "0.1.0"}]}.\n' \
        "$erts_vsn" "$kernel_vsn" "$stdlib_vsn" > "$rel/hello.rel"
    "$ERL_TOP/bin/escript" "$ROOT/tools/make_boot.escript" "$rel/hello" "$STAGE"
    cp "$ROOT/hello/sys.config" "$ROOT/hello/vm.args" "$rel/"
    echo "$erts_vsn 0.1.0" > "$STAGE/releases/start_erl.data"

    cp "$ERL_TOP/bin/$t/beam.emu" "$OUT"
    chmod +x "$OUT"
    (cd "$STAGE" && zip -q -r -9 "$OUT" bin lib releases)
    ls -l "$OUT"
}

step_test() {
    log "Running $OUT"
    "$OUT" one two | tee "$BUILD/test.out"
    grep -q "Hello, World!" "$BUILD/test.out"
    log "Building a program with $OUT build"
    "$OUT" build "$ROOT/examples/hashsum.erl" -o "$BUILD/hashsum.com"
    "$BUILD/hashsum.com" abc | tee "$BUILD/test.out"
    grep -q "^ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc" \
        "$BUILD/test.out"
    if [ "$WASM" = 1 ]; then
        "$OUT" build "$ROOT/examples/wasm_check.erl" -o "$BUILD/wasm_check.com"
        "$BUILD/wasm_check.com" | tee "$BUILD/test.out"
        grep -q '^wasm: wasi exit code 7' "$BUILD/test.out"
    fi
    if [ "$SQLITE" = 1 ]; then
        "$OUT" build "$ROOT/examples/sqlite_check.erl" -o "$BUILD/sqlite_check.com"
        "$BUILD/sqlite_check.com" | tee "$BUILD/test.out"
        grep -q '^sqlite: json \["alpha","beta","gamma"\]' "$BUILD/test.out"
    fi
}

if [ $# -eq 0 ]; then
    set -- toolchain openssl otp configure sqlite wasm make release \
        multicall bundle test
fi
mkdir -p "$BUILD"
for s in "$@"; do
    "step_$s"
done
