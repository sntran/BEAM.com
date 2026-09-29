#!/bin/sh
# Build BEAM.com: Erlang/OTP's runtime (ERTS) as one Actually Portable
# Executable, with the OTP libraries and the commands of beam.com (help,
# version and build) in its zip (redbean style).
#
# Usage: ./build.sh [step...]
#   Steps: toolchain openssl otp configure sqlite nifs wasm make elixir
#          release multicall wasm_runtime bundle test unit
#   With no step, all steps run in order.
#
# Environment:
#   OTP_VERSION      OTP git tag without "OTP-" (default 29.1.1)
#   COSMOCC_VERSION  cosmocc release to download (default 4.0.2)
#   OPENSSL_VERSION  OpenSSL git tag without "openssl-" (default 4.0.2)
#   SQLITE           0: leave out SQLite (the esqlite NIF, linked into
#                    beam.com, and the esqlite application in the zip;
#                    default 1)
#   SQLITE_VERSION   SQLite version (default 3.53.4), and SQLITE_YEAR, the
#                    year directory of its download on sqlite.org (2026)
#   EXQLITE_VERSION  Version of the hex.pm package exqlite (default 0.41.0),
#                    whose NIF is linked into beam.com (for ecto_sqlite3),
#                    with the SQLite of esqlite. Only with SQLITE=1 and
#                    ELIXIR=1.
#   BCRYPT_ELIXIR_VERSION  Version of the hex.pm package bcrypt_elixir
#                    (default 3.3.2), whose NIF is linked into beam.com (for
#                    phx.gen.auth). Only with ELIXIR=1.
#   ARGON2_ELIXIR_VERSION  Version of the hex.pm package argon2_elixir
#                    (default 4.1.3), whose NIF is linked into beam.com (for
#                    phx.gen.auth --hashing-lib argon2). Only with ELIXIR=1.
#   EXTRA_NIFS       More hex.pm packages whose NIFs are linked (a custom
#                    build), separated by spaces: picosat_elixir (for Ash).
#                    Only with ELIXIR=1.
#   WASM             1: link WebAssembly (WAMR) into beam.com, and put the
#                    wasm application in the zip (default 1)
#   WAMR_VERSION     WAMR git tag without "WAMR-" (default 2.4.5)
#   WASM_RUNTIME     The WebAssembly runtime for --target wasm32 (beam.wasm
#                    and beam.mjs: ERTS built with Emscripten, 5 MB, 2 MB in
#                    the zip): a directory with them, or "none" (not in the
#                    zip; BEAM_COM_WASM_RUNTIME gives it at build time).
#                    Default: the one of the step wasm_runtime, when it ran
#   EMSDK            An emsdk for the step wasm_runtime (default: one in
#                    $BUILD/emsdk, installed there at EMSDK_VERSION, 6.0.10)
#   ELIXIR           0: leave out Elixir (the elixir, eex, ex_unit, iex,
#                    logger and mix applications and bin/mix in the zip,
#                    for "beam.com INPUT -o OUTPUT" of Elixir code and the tools
#                    mix, iex, elixir and elixirc; default 1)
#   ELIXIR_VERSION   Elixir git tag without "v" (default 1.20.4)
#   COSMOCC          Directory of an unpacked cosmocc (default build/cosmocc)
#   CC               C compiler (default cosmocc, which makes x86_64+aarch64
#                    fat binaries; x86_64-unknown-cosmo-cc makes x86_64 only)
#   AR               Archiver (default cosmoar; use x86_64-linux-cosmo-ar
#                    with x86_64-unknown-cosmo-cc)
#   CXX              C++ compiler, for the JIT (default: CC with c++ for cc)
#   JIT              0: build the interpreter instead of the JIT (BeamAsm)
#                    (default 1). With cosmocc, the JIT has both backends.
#   OTP_APPS         More OTP applications in the zip, with spaces (for a
#                    custom build: "ssh mnesia"); their Erlang code only
#                    (the C code of an application, as the port programs of
#                    os_mon, is not built)
#   HEX              1: put Hex in the zip, for mix (a custom build;
#                    default 0). Only with ELIXIR=1.
#   REBAR3           1: put rebar3 in the zip, as the tool rebar3 (and for
#                    the rebar3 dependencies of mix; a custom build;
#                    default 0)
#   BUILD            Build directory (default ./build)
#   JOBS             Parallel make jobs (default: number of CPUs)
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
OTP_VERSION=${OTP_VERSION:-29.1.1}
COSMOCC_VERSION=${COSMOCC_VERSION:-4.0.2}
OPENSSL_VERSION=${OPENSSL_VERSION:-4.0.2}
EMSDK_VERSION=${EMSDK_VERSION:-6.0.10}
SQLITE=${SQLITE:-1}
# esqlite (Apache-2.0), with the SQLite amalgamation (public domain) of
# sqlite.org instead of the older copy in esqlite.
ESQLITE_COMMIT=${ESQLITE_COMMIT:-5c8d590d8eb70de17dd2c64dfc7502f4fd2fcba8}
SQLITE_VERSION=${SQLITE_VERSION:-3.53.4}
SQLITE_YEAR=${SQLITE_YEAR:-2026}
# The NIFs of Elixir packages (with the SHA-256 of the hex.pm tarball).
# The tools of Elixir compile these packages without a C compiler (see
# apps/beam_com/src/beam_com_make.erl).
EXQLITE_VERSION=${EXQLITE_VERSION:-0.41.0}
EXQLITE_SHA256=${EXQLITE_SHA256:-a7e9b6bed529ab72aa07ed2a925ac109c27e6877a7a8af252361c396a4192855}
BCRYPT_ELIXIR_VERSION=${BCRYPT_ELIXIR_VERSION:-3.3.2}
BCRYPT_ELIXIR_SHA256=${BCRYPT_ELIXIR_SHA256:-471be5151874ae7931911057d1467d908955f93554f7a6cd1b7d804cac8cef53}
ARGON2_ELIXIR_VERSION=${ARGON2_ELIXIR_VERSION:-4.1.3}
ARGON2_ELIXIR_SHA256=${ARGON2_ELIXIR_SHA256:-7c295b8d8e0eaf6f43641698f962526cdf87c6feb7d14bd21e599271b510608c}
PICOSAT_ELIXIR_VERSION=${PICOSAT_ELIXIR_VERSION:-0.2.3}
PICOSAT_ELIXIR_SHA256=${PICOSAT_ELIXIR_SHA256:-f76c9db2dec9d2561ffaa9be35f65403d53e984e8cd99c832383b7ab78c16c66}
# More packages whose NIFs are linked (custom builds), from the list of
# hex_nif_recipe(): for example "picosat_elixir". Only with ELIXIR=1.
EXTRA_NIFS=${EXTRA_NIFS:-}
WASM=${WASM:-1}
WAMR_VERSION=${WAMR_VERSION:-2.4.5}
ELIXIR=${ELIXIR:-1}
ELIXIR_VERSION=${ELIXIR_VERSION:-1.20.4}
ELIXIR_APPS="elixir eex ex_unit iex logger mix"
OTP_APPS=${OTP_APPS:-}
HEX=${HEX:-0}
REBAR3=${REBAR3:-0}
BUILD=${BUILD:-$ROOT/build}
COSMOCC=${COSMOCC:-$BUILD/cosmocc}
CC=${CC:-cosmocc}
AR=${AR:-cosmoar}
CXX=${CXX:-${CC%cc}c++}
JIT=${JIT:-1}
if [ "$JIT" = 1 ]; then FLAVOR=jit; else FLAVOR=emu; fi
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}

# The OTP applications in the zip. "beam.com INPUT -o OUTPUT" copies the ones that
# a program needs into the new executable.
BUNDLE_APPS="kernel stdlib sasl compiler parsetools crypto asn1 public_key ssl inets
             xmerl runtime_tools"
# The small build (OTP_SMALL_BUILD) does not make these.
EXTRA_APPS="crypto asn1 public_key ssl"
# Nor these, of which only the Erlang code is needed (src/): xmerl
# (Phoenix apps have swoosh, which includes xmerl.hrl), and runtime_tools
# (in the extra_applications of a new Phoenix app; its C code is for
# dtrace and trace drivers).
SRC_APPS="xmerl runtime_tools"
# The applications of OTP_APPS (a custom build) that are not in the zip
# yet: their Erlang code too.
for app in $OTP_APPS; do
    case " $BUNDLE_APPS " in
        *" $app "*) ;;
        *) BUNDLE_APPS="$BUNDLE_APPS $app" SRC_APPS="$SRC_APPS $app" ;;
    esac
done

ERL_TOP=$BUILD/otp
RELEASE=$BUILD/release
OPENSSL=$BUILD/openssl
ESQLITE=$BUILD/esqlite
HEXNIFS=$BUILD/hexnifs
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
       "$ROOT"/cosmo/beam_com_inet_gethost.c "$ROOT"/cosmo/beam_com_epmd.h \
       "$ROOT"/cosmo/beam_com_epmd.c "$ROOT"/cosmo/beam_com_epmd_srv.c \
       "$ROOT"/cosmo/beam_com_epmd_cli.c "$ROOT"/cosmo/beam_com_watch.c \
       "$ERL_TOP/erts/emulator/sys/unix/"
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
    # The JIT: the Erlang code does not use the native stack. That needs
    # signal handlers on an alternate stack, and OpenBSD does not allow it
    # (see patches/otp/0002-jit.patch).
    # With the fat compiler (cosmocc), the JIT has both backends: x86 in
    # the x86_64 half and arm in the aarch64 half (beam/jit/fat).
    if [ "$JIT" = 1 ]; then
        jit=--enable-jit
        enable_native_stack=no
        export enable_native_stack
        if [ "$(basename "$CC")" = cosmocc ]; then
            BEAM_COM_FAT_JIT=yes
            export BEAM_COM_FAT_JIT
        fi
    else
        jit=--disable-jit
    fi
    ./configure \
        CC="$CC" CXX="$CXX" AR="$AR" RANLIB=true LIBS="$OPENSSL/lib/libcrypto.a" \
        DED_LD="$ROOT/cosmo/noshared" DED_LDFLAGS="-no-pie" \
        DED_LD_FLAG_RUNTIME_LIBRARY_PATH="-Wl,-rpath," \
        CFLAGS="-O2 -g -DZSTD_DISABLE_ASM -include $ROOT/cosmo/erts_cosmo.h" \
        ac_cv_header_poll_h=no \
        ac_cv_func_sendfile=no \
        erts_cv_linux_thp=no \
        erl_cv_clock_gettime_monotonic_default_resolution=CLOCK_MONOTONIC \
        erl_cv_clock_gettime_monotonic_high_resolution=CLOCK_MONOTONIC \
        $jit \
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
    # The SQLite options of esqlite (rebar.config.script), and the ones of
    # exqlite (its Makefile), whose NIF uses the same SQLite (step_nifs).
    # Not the options SQLITE_OMIT_AUTOINIT and SQLITE_OMIT_PROGRESS_CALLBACK
    # of esqlite: exqlite does not call sqlite3_initialize(), and it uses
    # sqlite3_progress_handler(). The NIF is static: its init function is
    # esqlite3_nif_nif_init, which ERTS finds by the name of the module
    # (esqlite3_nif).
    flags="-Os -DSQLITE_DQS=0 -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_MEMSTATUS=0
        -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 -DSQLITE_LIKE_DOESNT_MATCH_BLOBS
        -DSQLITE_MAX_EXPR_DEPTH=0 -DSQLITE_OMIT_DEPRECATED
        -DSQLITE_USE_ALLOCA -DSQLITE_USE_URI -DSQLITE_ENABLE_FTS3
        -DSQLITE_ENABLE_FTS3_PARENTHESIS -DSQLITE_ENABLE_FTS4
        -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_MATH_FUNCTIONS
        -DSQLITE_ENABLE_JSON1 -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_GEOPOLY
        -DSQLITE_ENABLE_RBU -DSQLITE_ENABLE_DBSTAT_VTAB -DHAVE_USLEEP=1
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

# The NIFs of Elixir packages are linked when their package is enabled.
use_exqlite() { [ "$SQLITE" = 1 ] && [ "$ELIXIR" = 1 ]; }
# The packages of hex_nif_recipe() whose NIFs are linked.
hex_nif_packages() {
    [ "$ELIXIR" = 1 ] || return 0
    # shellcheck disable=SC2086
    echo bcrypt_elixir argon2_elixir $EXTRA_NIFS
}

# hex_nif_recipe NAME: the version, the SHA-256 of the tarball and the
# name of the NIF (STATIC_ERLANG_NIF_LIBNAME, and the name of its archive)
# of a package, or an error for a package that is not in the list.
hex_nif_recipe() {
    case $1 in
        bcrypt_elixir) echo "$BCRYPT_ELIXIR_VERSION $BCRYPT_ELIXIR_SHA256 bcrypt_nif" ;;
        argon2_elixir) echo "$ARGON2_ELIXIR_VERSION $ARGON2_ELIXIR_SHA256 argon2_nif" ;;
        picosat_elixir) echo "$PICOSAT_ELIXIR_VERSION $PICOSAT_ELIXIR_SHA256 picosat_nif" ;;
        # Only for the WebAssembly runtime (step_wasm_runtime): the native
        # beam.com links exqlite in step_nifs.
        exqlite) echo "$EXQLITE_VERSION $EXQLITE_SHA256 sqlite3_nif" ;;
        *) echo "EXTRA_NIFS: no recipe for the package $1" >&2
           return 1 ;;
    esac
}

# build_hex_nif NAME OUT CC AR CFLAGS: build the NIF of the package NAME
# (in $HEXNIFS) as OUT/NIF.a, with the compiler CC and the archiver AR.
# CFLAGS has the include directories of ERTS. The C files and flags are
# those of the Makefile of the package.
build_hex_nif() {
    name=$1 out=$2 cc=$3 ar=$4 cflags=$5
    set -- $(hex_nif_recipe "$name")
    vsn=$1 sha=$2 lib=$3
    fetch_hex "$name" "$vsn" "$sha"
    log "Building the $name NIF as a static NIF ($cc)"
    src=$HEXNIFS/$name-$vsn
    obj=$out/$name
    rm -rf "$obj" "$out/$lib.a" "$out/.aarch64/$lib.a"
    mkdir -p "$obj"
    nif="-DSTATIC_ERLANG_NIF_LIBNAME=$lib $cflags"
    case $name in
        bcrypt_elixir)
            set -- "c_src/bcrypt_nif.c:$nif -Ic_src" "c_src/blowfish.c:-Ic_src" ;;
        argon2_elixir)
            # The reference implementation of Argon2, with threads for the
            # lanes where there are threads (ARGON2_THREADS=0: none).
            a="-Iargon2/include -Iargon2/src"
            if [ "${ARGON2_THREADS:-1}" = 1 ]; then a="$a -pthread"; else a="$a -DARGON2_NO_THREADS"; fi
            set -- "c_src/argon2_nif.c:$nif $a"
            for f in argon2 core blake2/blake2b thread encoding ref; do
                set -- "$@" "argon2/src/$f.c:$a"
            done ;;
        picosat_elixir)
            # NGETRUSAGE: no getrusage() (only for its statistics; the
            # header sys/unistd.h is not everywhere).
            p="-std=c99 -DNDEBUG -DNGETRUSAGE"
            set -- "c_src/picosat_nif.c:$nif $p" "c_src/picosat.c:$p" ;;
        exqlite)
            # The WebAssembly runtime: the NIF is the module wasm_host_exqlite
            # (the module Exqlite.Sqlite3NIF of a release sends the SQL to
            # the host or to this NIF, see wasm_host_sqlite), with the
            # SQLite of exqlite and the VFS of the host files
            # (wasm/erts/sqlite_vfs.c). The options of its Makefile, and a
            # batch atomic write for a commit of the host.
            sed 's/^ERL_NIF_INIT(Elixir\.Exqlite\.Sqlite3NIF,/ERL_NIF_INIT(wasm_host_exqlite,/' \
                "$src/c_src/sqlite3_nif.c" > "$src/c_src/wasm_sqlite3_nif.c"
            grep -q '^ERL_NIF_INIT(wasm_host_exqlite,' "$src/c_src/wasm_sqlite3_nif.c"
            q="-DNDEBUG=1 -Ic_src -DSQLITE_THREADSAFE=1 -DSQLITE_USE_URI=1
               -DSQLITE_LIKE_DOESNT_MATCH_BLOBS=1 -DSQLITE_DQS=0 -DHAVE_USLEEP=1
               -DSQLITE_ENABLE_FTS3=1 -DSQLITE_ENABLE_FTS4=1 -DSQLITE_ENABLE_FTS5=1
               -DSQLITE_ENABLE_GEOPOLY=1 -DSQLITE_ENABLE_MATH_FUNCTIONS=1 -DSQLITE_ENABLE_RBU=1
               -DSQLITE_ENABLE_RTREE=1 -DSQLITE_OMIT_DEPRECATED=1 -DSQLITE_ENABLE_DBSTAT_VTAB=1
               -DSQLITE_ENABLE_BATCH_ATOMIC_WRITE=1 -DSQLITE_EXTRA_INIT=beam_vfs_init"
            set -- "c_src/wasm_sqlite3_nif.c:$nif $q" "c_src/sqlite3.c:$q" \
                "$ROOT/wasm/erts/sqlite_vfs.c:$q" ;;
    esac
    for f in "$@"; do
        c=${f%%:*}
        # shellcheck disable=SC2086
        (cd "$src" && "$cc" -O2 ${f#*:} -c "$c" -o "$obj/$(basename "$c" .c).o")
    done
    "$ar" rcs "$out/$lib.a" "$obj"/*.o
}

# Fetch the source of a hex.pm package into $HEXNIFS/NAME-VSN, and check
# the SHA-256 of its tarball.
fetch_hex() {
    [ -f "$HEXNIFS/$1-$2/mix.exs" ] && return 0
    log "Fetching $1 $2 from hex.pm"
    mkdir -p "$HEXNIFS/$1-$2"
    curl -fsSL -o "$HEXNIFS/$1-$2.tar" "https://repo.hex.pm/tarballs/$1-$2.tar"
    sum=$(sha256sum "$HEXNIFS/$1-$2.tar" | cut -d' ' -f1)
    if [ "$sum" != "$3" ]; then
        echo "Bad SHA-256 of $1-$2.tar: $sum" >&2
        exit 1
    fi
    tar -xOf "$HEXNIFS/$1-$2.tar" contents.tar.gz | tar -xzf - -C "$HEXNIFS/$1-$2"
    rm -f "$HEXNIFS/$1-$2.tar"
}

# The NIFs of the Elixir packages exqlite (for ecto_sqlite3),
# bcrypt_elixir and argon2_elixir (for phx.gen.auth), and those of
# EXTRA_NIFS, as static NIFs. ERTS finds a static NIF by the name of its
# module (for example Elixir.Bcrypt.Base), before it opens the file that
# load_nif/2 gets (priv/bcrypt_nif): so these files are not needed.
step_nifs() {
    t=$(target)
    erl_flags="-I$ERL_TOP/erts/emulator/beam -I$ERL_TOP/erts/include
        -I$ERL_TOP/erts/include/$t"
    if use_exqlite; then
        if [ ! -f "$ESQLITE/esqlite3_nif.a" ]; then
            echo "Missing $ESQLITE/esqlite3_nif.a: run the sqlite step first" >&2
            exit 1
        fi
        fetch_hex exqlite "$EXQLITE_VERSION" "$EXQLITE_SHA256"
        log "Building the exqlite NIF as a static NIF"
        cd "$HEXNIFS/exqlite-$EXQLITE_VERSION"
        # The SQLite of esqlite (sqlite3.o is in esqlite3_nif.a, before
        # this archive in STATIC_NIFS), not the copy in exqlite: one
        # SQLite in beam.com. The init function is sqlite3_nif_nif_init.
        # (Its Makefile gives -DSTATIC_ERLANG_NIF=1, which erl_nif.h
        # defines again, with a warning.) The functions update_callback
        # and on_load are not static: the names get a prefix, because
        # esqlite3_nif.o also has an update_callback.
        # shellcheck disable=SC2086
        "$CC" -O2 -DNDEBUG=1 -DSTATIC_ERLANG_NIF_LIBNAME=sqlite3_nif \
            -Dupdate_callback=exqlite_update_callback -Don_load=exqlite_on_load \
            -I"$ESQLITE/c_src/sqlite3" \
            $erl_flags -c c_src/sqlite3_nif.c -o sqlite3_nif.o
        rm -f sqlite3_nif.a .aarch64/sqlite3_nif.a
        "$AR" rcs sqlite3_nif.a sqlite3_nif.o
    fi
    for p in $(hex_nif_packages); do
        build_hex_nif "$p" "$HEXNIFS/static" "$CC" "$AR" "$erl_flags"
    done
    return 0
}

# The Elixir packages whose NIFs are linked ("name vsn" on each line),
# for the env of the beam_com application (beam_com_make).
hex_nifs() {
    use_exqlite && echo "exqlite $EXQLITE_VERSION"
    for p in $(hex_nif_packages); do
        echo "$p $(hex_nif_recipe "$p" | cut -d' ' -f1)"
    done
    return 0
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
    [ "$SQLITE" = 1 ] || [ "$WASM" = 1 ] || [ "$ELIXIR" = 1 ] || return 0
    t=$(target)
    printf '%s' "$ERL_TOP/lib/asn1/priv/lib/$t/asn1rt_nif.a" \
        " $ERL_TOP/lib/crypto/priv/lib/$t/crypto.a"
    [ "$SQLITE" = 1 ] && printf ' %s' "$ESQLITE/esqlite3_nif.a"
    # After esqlite3_nif.a, which has the SQLite that exqlite uses.
    use_exqlite && printf ' %s' "$HEXNIFS/exqlite-$EXQLITE_VERSION/sqlite3_nif.a"
    for p in $(hex_nif_packages); do
        printf ' %s' "$HEXNIFS/static/$(hex_nif_recipe "$p" | cut -d' ' -f3).a"
    done
    [ "$WASM" = 1 ] && printf ' %s' "$WAMR/wasm.a"
    return 0
}

# Stop early when a static NIF archive of an enabled option is missing
# (its step did not run).
check_static_nifs() {
    for a in $(static_nifs); do
        [ -f "$a" ] || case $a in
            */lib/asn1/*|*/lib/crypto/*) ;;  # made by the OTP build
            *) echo "Missing $a: run the sqlite, nifs and wasm steps first" >&2
               exit 1 ;;
        esac
    done
}

# The WebAssembly runtime of --target wasm32 (Cloudflare Workers): ERTS
# built with Emscripten (wasm/erts/build.sh, the variant for Workers), from
# a clone of the same OTP, with this build of OTP as its bootstrap. The
# step bundle puts it in the zip (WASM_RUNTIME).
step_wasm_runtime() {
    [ "${WASM_RUNTIME:-}" = none ] && return 0
    emsdk=${EMSDK:-$BUILD/emsdk}
    if [ ! -x "$emsdk/upstream/emscripten/emcc" ]; then
        log "Installing emsdk $EMSDK_VERSION"
        [ -d "$emsdk" ] || git clone -q --depth 1 https://github.com/emscripten-core/emsdk.git "$emsdk"
        "$emsdk/emsdk" install "$EMSDK_VERSION" > "$BUILD/emsdk.log" 2>&1
        "$emsdk/emsdk" activate "$EMSDK_VERSION" >> "$BUILD/emsdk.log" 2>&1
    fi
    log "Building the WebAssembly runtime"
    EMSDK=$emsdk BOOTSTRAP=$ERL_TOP OUT=$BUILD/wasm OTP_VERSION=$OTP_VERSION \
        OPENSSL_VERSION=$OPENSSL_VERSION WASM_NODE=0 WORKER=1 WORKER_ROOTFS=none \
        WORKER_OUT=$BUILD/wasm-runtime BUILD=$BUILD \
        HEX_NIFS="$(hex_nif_packages)$(use_exqlite && echo " exqlite")" \
        "$ROOT/wasm/erts/build.sh"
}

# The NIFs of the packages HEX_NIFS for the WebAssembly runtime
# (wasm/erts/build.sh runs this step): in HEX_NIF_OUT, with the compiler
# HEX_NIF_CC, the archiver HEX_NIF_AR and the flags HEX_NIF_CFLAGS (the
# include directories of its ERTS), and "NAME VSN" lines in HEX_NIF_LIST.
# No threads for argon2 there: the green threads run one at a time.
step_hex_nifs() {
    mkdir -p "$HEX_NIF_OUT"
    for p in $HEX_NIFS; do
        ARGON2_THREADS=0 build_hex_nif "$p" "$HEX_NIF_OUT" "$HEX_NIF_CC" "$HEX_NIF_AR" \
            "$HEX_NIF_CFLAGS"
        echo "$p $(hex_nif_recipe "$p" | cut -d' ' -f1)" >> "$HEX_NIF_LIST"
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
    for app in $SRC_APPS; do
        log "Building $app (Erlang code)"
        PATH=$ERL_TOP/bootstrap/bin:$PATH make -C "lib/$app/src" opt
    done
}

step_multicall() {
    log "Linking the multi-call emulator"
    t=$(target)
    objdir=obj/$t/opt/$FLAVOR
    cd "$ERL_TOP/erts/emulator"
    objs="$objdir/beam_com.o $objdir/beam_com_child_setup.o $objdir/beam_com_inet_gethost.o"
    objs="$objs $objdir/beam_com_epmd.o $objdir/beam_com_epmd_srv.o $objdir/beam_com_epmd_cli.o"
    objs="$objs $objdir/beam_com_watch.o"
    make -f "$t/Makefile" TYPE=opt FLAVOR=$FLAVOR $objs
    rm -f "$ERL_TOP/bin/$t/beam.$FLAVOR"
    # The table of static NIFs depends on STATIC_NIFS, and make does not
    # know it (neither for driver_tab.c nor for its object).
    rm -f "$t/opt/$FLAVOR/driver_tab.c" "$objdir/driver_tab.o"
    nifs=$(static_nifs)
    # --wrap=close, --wrap=mkdir and --wrap=chown: see __wrap_close(),
    # __wrap_mkdir() and __wrap_chown() in cosmo/beam_com.c.
    make -f "$t/Makefile" TYPE=opt FLAVOR=$FLAVOR \
        EMU_LDFLAGS="$objs -Wl,--wrap=close -Wl,--wrap=mkdir -Wl,--wrap=chown" \
        ${nifs:+"STATIC_NIFS=$nifs"} "$ERL_TOP/bin/$t/beam.$FLAVOR"
}

# Elixir, compiled with the Erlang/OTP of this build (its erl and erlc
# run on the build machine).
step_elixir() {
    [ "$ELIXIR" = 1 ] || return 0
    log "Building Elixir $ELIXIR_VERSION"
    src=$BUILD/elixir-$ELIXIR_VERSION
    if [ ! -f "$src/Makefile" ]; then
        curl -fsSL -o "$BUILD/elixir.tar.gz" \
            "https://github.com/elixir-lang/elixir/archive/refs/tags/v$ELIXIR_VERSION.tar.gz"
        tar -xzf "$BUILD/elixir.tar.gz" -C "$BUILD"
    fi
    (cd "$src" && PATH="$ERL_TOP/bin:$PATH" make compile)
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
    # include for "beam.com INPUT -o OUTPUT").
    cp "$RELEASE"/bin/start_clean.boot "$RELEASE"/bin/no_dot_erlang.boot \
       "$STAGE/bin/"
    cp "$ROOT/cosmo/windows.inetrc" "$ROOT/cosmo/sandbox.inetrc" "$STAGE/bin/"
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

    # Elixir: the applications without debug information, but with their
    # docs (for h/1 in iex) and attributes. They are for "beam.com INPUT -o OUTPUT"
    # of Elixir code, and for the tools of Elixir (mix, iex, elixir,
    # elixirc; bin/mix is the script of mix). A program gets only the
    # applications that it uses, without docs.
    if [ "$ELIXIR" = 1 ]; then
        for app in $ELIXIR_APPS; do
            src=$BUILD/elixir-$ELIXIR_VERSION/lib/$app/ebin
            vsn=$(sed -n 's/.*{vsn, *"\([^"]*\)".*/\1/p' "$src/$app.app")
            mkdir -p "$STAGE/lib/$app-$vsn/ebin"
            cp "$src"/*.beam "$src/$app.app" "$STAGE/lib/$app-$vsn/ebin/"
        done
        "$ERL_TOP/bin/erl" -noshell -eval \
            "beam_lib:strip_files([F || A <- string:lexemes(\"$ELIXIR_APPS\", \" \"), F <- filelib:wildcard(\"$STAGE/lib/\" ++ A ++ \"-*/ebin/*.beam\")], [\"Attr\", \"Docs\"]), halt()."
        mkdir -p "$STAGE/bin"
        cp "$BUILD/elixir-$ELIXIR_VERSION/bin/mix" "$STAGE/bin/mix"
    fi

    # Hex (HEX=1, a custom build): the application of the archive that
    # "mix local.hex" installs (the newest Hex for this Elixir and OTP).
    # beam.com puts lib/hex-VSN in the code path of the Elixir tools, and
    # mix uses Hex when it is loaded.
    if [ "$HEX" = 1 ]; then
        [ "$ELIXIR" = 1 ] || { echo "HEX=1 needs ELIXIR=1" >&2; exit 1; }
        mixhome=$BUILD/mix-home
        rm -rf "$mixhome"
        MIX_HOME=$mixhome PATH="$ERL_TOP/bin:$BUILD/elixir-$ELIXIR_VERSION/bin:$PATH" \
            mix local.hex --force
        hexdir=$(ls -d "$mixhome"/archives/hex-*/hex-* | head -n 1)
        [ -f "$hexdir/ebin/hex.app" ] || { echo "No Hex in $mixhome" >&2; exit 1; }
        mkdir -p "$STAGE/lib/$(basename "$hexdir")"
        cp -R "$hexdir/ebin" "$STAGE/lib/$(basename "$hexdir")/"
    fi

    # rebar3 (REBAR3=1, a custom build): the newest release, an escript,
    # as bin/rebar3. beam.com runs it as the tool rebar3 (rebar3.com, or
    # "beam.com rebar3"), and gives it to mix (MIX_REBAR3).
    if [ "$REBAR3" = 1 ]; then
        curl -fsSL -o "$STAGE/bin/rebar3" \
            https://github.com/erlang/rebar3/releases/latest/download/rebar3
        head -c 2 "$STAGE/bin/rebar3" | grep -q '#!' || { echo "Not an escript: rebar3" >&2; exit 1; }
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
    # The .app file gets the full version of OTP, and the Elixir packages
    # whose NIFs are linked ([{exqlite, "0.41.0"}, ...]).
    nifs=$(hex_nifs | awk '{printf "%s{%s, \"%s\"}", (NR > 1 ? ", " : ""), $1, $2}')
    sed -e "s/{otp_version, \"\"}/{otp_version, \"$OTP_VERSION\"}/" \
        -e "s/{nifs, \[\]}/{nifs, [$nifs]}/" \
        "$ROOT/apps/beam_com/src/beam_com.app.src" \
        > "$STAGE/lib/beam_com/ebin/beam_com.app"
    "$ERL_TOP/bin/erlc" -o "$STAGE/lib/beam_com_script-0.1.0/ebin" \
        "$ROOT"/apps/beam_com_script/src/*.erl
    cp "$ROOT/apps/beam_com_script/src/beam_com_script.app.src" \
       "$STAGE/lib/beam_com_script-0.1.0/ebin/beam_com_script.app"

    # The host of the WebAssembly runtime (--target wasm32): Erlang code
    # that a Worker release gets, and the files of the Workers. With
    # WASM_RUNTIME=dir (beam.wasm and beam.mjs of wasm/erts/build.sh,
    # WORKER=1), the runtime too (5 MB).
    wh=$STAGE/lib/wasm_host-0.1.0
    # The hosts of worker.js: Workers (priv/worker), Deno (priv/deno) and a
    # web page (priv/browser).
    mkdir -p "$wh/ebin" "$wh/priv"
    "$ERL_TOP/bin/erlc" -o "$wh/ebin" "$ROOT"/apps/wasm_host/src/*.erl
    cp "$ROOT/apps/wasm_host/src/wasm_host.app.src" "$wh/ebin/wasm_host.app"
    for host in worker deno browser; do
        rm -rf "$wh/priv/$host"
        cp -R "$ROOT/apps/wasm_host/priv/$host" "$wh/priv/$host"
    done
    runtime=${WASM_RUNTIME:-$BUILD/wasm-runtime}
    if [ "$runtime" != none ] && [ -f "$runtime/beam.wasm" ]; then
        mkdir -p "$wh/priv/runtime"
        cp "$runtime/beam.wasm" "$runtime/beam.mjs" "$wh/priv/runtime/"
        [ ! -f "$runtime/nifs" ] || cp "$runtime/nifs" "$wh/priv/runtime/"
    fi

    # The license of beam.com, and the notices and the license texts of
    # the software in the file (NOTICE). The programs that beam.com makes
    # keep them too (beam_com_build:keep/2 keeps the top-level entries).
    mkdir -p "$STAGE/licenses/otp"
    cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$ROOT"/licenses/*.txt "$STAGE/licenses/"
    cp "$ERL_TOP"/LICENSES/*.txt "$STAGE/licenses/otp/"

    # There is no release: beam.com runs its command line (run, -o,
    # --help, --version). A release that is added to the zip runs instead.

    emu=$ERL_TOP/bin/$t/beam.$FLAVOR
    if [ "$(od -An -c -N4 "$emu" | tr -d ' ')" = '177ELF' ]; then
        # A compiler for one CPU (x86_64-unknown-cosmo-cc) makes an ELF
        # file. apelink makes it an APE file, with the zip of the ELF.
        case $(target) in
            aarch64-*) loader=$COSMOCC/bin/ape-aarch64.elf ;;
            *) loader=$COSMOCC/bin/ape-x86_64.elf ;;
        esac
        apelink -l "$loader" -o "$OUT" "$emu"
    else
        cp "$emu" "$OUT"
    fi
    chmod +x "$OUT"
    # The code of kernel and stdlib is stored, not compressed: the boot
    # loads most of it, and stored entries need no inflating. It costs
    # about 2 MB, and a program starts about 50 ms faster (a quarter of
    # its start time; see docs/BENCHMARKS.md). beam.com INPUT -o OUTPUT keeps the
    # entries as they are, so the programs get the same.
    (cd "$STAGE" &&
     zip -q -r -9 "$OUT" bin lib licenses -x 'lib/kernel-*/ebin/*' -x 'lib/stdlib-*/ebin/*' &&
     zip -q -r -0 "$OUT" lib/kernel-*/ebin lib/stdlib-*/ebin)
    ls -l "$OUT"
}

# The unit tests of the Erlang code (tests/unit), with coverage. They
# run on the Erlang of the OTP build tree.
step_unit() {
    log "Running the unit tests"
    if [ ! -f "$ERL_TOP/lib/eunit/ebin/eunit.beam" ]; then
        PATH=$ERL_TOP/bootstrap/bin:$PATH make -C "$ERL_TOP/lib/eunit" opt
    fi
    ELIXIR_LIB=$BUILD/elixir-$ELIXIR_VERSION/lib \
        "$ERL_TOP/bin/escript" "$ROOT/tests/unit/run.escript" "$BUILD/unit"
    # The JavaScript of the WebAssembly host (Node.js 20.6 or later).
    if command -v node >/dev/null 2>&1; then
        log "Running the tests of the WebAssembly host"
        node --test "$ROOT"/tests/host/*.test.mjs
    fi
}

step_test() {
    log "Running $OUT"
    "$OUT" --version | tee "$BUILD/test.out"
    grep -q "Erlang/OTP  : $OTP_VERSION" "$BUILD/test.out"
    [ "$ELIXIR" = 1 ] && grep -q "Elixir      : $ELIXIR_VERSION" "$BUILD/test.out"
    # The commands use the name of their file (beam.com, beam-emu.com).
    "$OUT" --help > "$BUILD/test.out"
    grep -q "usage: $(basename "$OUT") \[FLAGS\] \[INPUT\] \[-- ARGUMENTS\]" "$BUILD/test.out"
    log "Running a program with $OUT, and building it with -o"
    BEAM_COM_CACHE=$BUILD/cache "$OUT" "$ROOT/examples/hashsum.erl" -- abc | tee "$BUILD/test.out"
    grep -q "^ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc" \
        "$BUILD/test.out"
    "$OUT" "$ROOT/examples/hashsum.erl" -o "$BUILD/hashsum.com"
    "$BUILD/hashsum.com" abc | tee "$BUILD/test.out"
    grep -q "^ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc" \
        "$BUILD/test.out"
    # The program keeps the code of kernel and stdlib stored (step_bundle).
    unzip -v "$BUILD/hashsum.com" | grep -q ' Stored .* lib/kernel-[^/]*/ebin/code.beam$'
    unzip -v "$BUILD/hashsum.com" | grep -q ' Stored .* lib/stdlib-[^/]*/ebin/lists.beam$'
    # beam.com and the program keep the license texts (step_bundle).
    unzip -l "$OUT" | grep -q ' licenses/NOTICE$'
    unzip -l "$OUT" | grep -q ' licenses/otp/MIT.txt$'
    unzip -l "$BUILD/hashsum.com" | grep -q ' licenses/LICENSE$'
    if [ "$WASM" = 1 ]; then
        "$OUT" "$ROOT/tests/programs/wasm_check.erl" -o "$BUILD/wasm_check.com"
        "$BUILD/wasm_check.com" | tee "$BUILD/test.out"
        grep -q '^wasm: wasi exit code 7' "$BUILD/test.out"
    fi
    if [ "$SQLITE" = 1 ]; then
        "$OUT" "$ROOT/tests/programs/sqlite_check.erl" -o "$BUILD/sqlite_check.com"
        "$BUILD/sqlite_check.com" | tee "$BUILD/test.out"
        grep -q '^sqlite: json \["alpha","beta","gamma"\]' "$BUILD/test.out"
    fi
}

if [ $# -eq 0 ]; then
    set -- toolchain openssl otp configure sqlite nifs wasm make elixir release \
        multicall wasm_runtime bundle test unit
fi
mkdir -p "$BUILD"
for s in "$@"; do
    "step_$s"
done
