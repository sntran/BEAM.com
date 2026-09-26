#!/bin/sh
# Build BEAM.com: Erlang/OTP's runtime (ERTS) as one Actually Portable
# Executable, with the OTP libraries and the hello module in its zip
# (redbean style).
#
# Usage: ./build.sh [step...]
#   Steps: toolchain otp configure make release multicall bundle test
#   With no step, all steps run in order.
#
# Environment:
#   OTP_VERSION      OTP git tag without "OTP-" (default 29.1.1)
#   COSMOCC_VERSION  cosmocc release to download (default 4.0.2)
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
BUILD=${BUILD:-$ROOT/build}
COSMOCC=${COSMOCC:-$BUILD/cosmocc}
CC=${CC:-cosmocc}
AR=${AR:-cosmoar}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}

ERL_TOP=$BUILD/otp
RELEASE=$BUILD/release
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
    ./configure \
        CC="$CC" AR="$AR" RANLIB=true \
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
        --without-ssl \
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

step_make() {
    log "Building OTP (small build)"
    cd "$ERL_TOP"
    # cosmocc does not support "-MM" with many input files. depcc runs
    # it once for each file.
    # There are no shared objects, so noshared writes placeholder files
    # for the NIF libraries (DED_LD).
    DEPCC_CC=$CC make -j"$JOBS" OTP_SMALL_BUILD=true \
        DEP_CC="$ROOT/cosmo/depcc" DED_LD="$ROOT/cosmo/noshared"
}

step_multicall() {
    log "Linking the multi-call emulator"
    t=$(target)
    objdir=obj/$t/opt/emu
    cd "$ERL_TOP/erts/emulator"
    objs="$objdir/beam_com.o $objdir/beam_com_child_setup.o $objdir/beam_com_inet_gethost.o"
    make -f "$t/Makefile" TYPE=opt FLAVOR=emu $objs
    rm -f "$ERL_TOP/bin/$t/beam.emu"
    make -f "$t/Makefile" TYPE=opt FLAVOR=emu EMU_LDFLAGS="$objs" \
        "$ERL_TOP/bin/$t/beam.emu"
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

    # OTP: boot scripts for tools, and the kernel and stdlib applications.
    cp "$RELEASE"/bin/start_clean.boot "$RELEASE"/bin/no_dot_erlang.boot \
       "$STAGE/bin/"
    for app in kernel stdlib; do
        dir=$(cd "$RELEASE/lib" && ls -d "$app"-* | head -n 1)
        mkdir -p "$STAGE/lib/$dir"
        cp -R "$RELEASE/lib/$dir/ebin" "$STAGE/lib/$dir/"
    done

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
}

if [ $# -eq 0 ]; then
    set -- toolchain otp configure make release multicall bundle test
fi
mkdir -p "$BUILD"
for s in "$@"; do
    "step_$s"
done
