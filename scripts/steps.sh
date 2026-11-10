#!/bin/sh
# The steps of the build of BEAM.com: Erlang/OTP's runtime (ERTS) as one
# Actually Portable Executable, with the OTP libraries and the commands of
# beam.com (help, version and build) in its zip (redbean style).
#
# The Makefile runs these steps, in the order of their needs, and runs a
# step again only when its inputs changed. Use make (see the Makefile):
#
#   make [step...]
#
# This script runs the steps that it gets, with no check of their needs:
#
#   scripts/steps.sh step...
#   Steps: toolchain openssl otp configure sqlite nifs wasm make elixir
#          release multicall wasm_runtime bundle test unit hex_nifs
#          nif_edge
#   With no step, all steps run in order (not hex_nifs and nif_edge).
#
# The keys of the steps (see "The keys of the steps" below):
#
#   scripts/steps.sh key STEP...    the key of each step
#   scripts/steps.sh inputs STEP    the inputs of the step, as text
#   scripts/steps.sh keys STEP...   the keys for the Makefile
#   scripts/steps.sh check_keys     a check of the lists of files
#   scripts/steps.sh cache_keys     the keys of the caches of CI
#   scripts/steps.sh part_keys      the keys of the parts of this build
#
# Environment:
#   OTP_VERSION      OTP git tag without "OTP-" (default 29.1.1)
#   COSMOCC_VERSION  cosmocc release to download (default 4.0.2)
#   OPENSSL_VERSION  OpenSSL git tag without "openssl-" (default 4.0.3)
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
#   NIFS_OMIT        The default NIFs to leave out, separated by spaces:
#                    exqlite, bcrypt_elixir, argon2_elixir (default none).
#   EXTRA_NIFS       More hex.pm packages whose NIFs are linked (a custom
#                    build), separated by spaces: picosat_elixir (for Ash),
#                    vix (libvips, for the image package; native only),
#                    rusty_csv (a NIF of Rust; native only, needs rustup),
#                    ex_pdfium (PDFium, a NIF of Rust; native only, needs
#                    rustup).
#   PDFIUM           For ex_pdfium: a directory with x64/ and arm64/, the
#                    static libpdfium.a of each CPU. Default: $BUILD/pdfium,
#                    made by scripts/pdfium.sh when it is not there.
#   RUST_NIGHTLY     For a NIF of Rust whose crate has no rust-toolchain.toml:
#                    the nightly Rust (default nightly-2026-11-01)
#   LIBVIPS          For vix: a directory with x86_64/ and aarch64/, the
#                    static libvips of each CPU. Default: $BUILD/libvips,
#                    made by scripts/libvips.sh when it is not there, or
#                    when it has other VIX_PARTS. Only with ELIXIR=1.
#   VIX_PARTS        For vix: the parts of libvips to add to its formats,
#                    separated by spaces (default none): icc (ICC
#                    transforms), gif (GIF save), avif (AVIF read and
#                    write; about 12 MB), svg (SVG load with resvg; needs
#                    rustup). See scripts/libvips.sh.
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
#                    custom build: "mnesia eldap"); their Erlang code only
#                    (the C code of an application, as the port programs of
#                    os_mon, is not built)
#   OTP_OMIT         Default OTP applications to leave out of the zip, with
#                    spaces (for a custom build: "ssh xmerl"). Only these:
#                    parsetools asn1 public_key ssl inets ssh xmerl
#                    runtime_tools tools. An application in the zip that
#                    needs one of them stops the build.
#   HEX              1: put Hex in the zip, for mix (a custom build;
#                    default 0). Only with ELIXIR=1.
#   REBAR3           1: put rebar3 in the zip, as the tool rebar3 (and for
#                    the rebar3 dependencies of mix; a custom build;
#                    default 0)
#   BUILD            Build directory (default ./build)
#   JOBS             Parallel make jobs (default: number of CPUs)
#   CCACHE           1: the compiles of cosmocc and cosmoc++ go through
#                    ccache (CI), in CCACHE_DIR (default build/ccache). It
#                    is not a setting of the Makefile: the result is the
#                    same file.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OTP_VERSION=${OTP_VERSION:-29.1.1}
COSMOCC_VERSION=${COSMOCC_VERSION:-4.0.2}
OPENSSL_VERSION=${OPENSSL_VERSION:-4.0.3}
EMSDK_VERSION=${EMSDK_VERSION:-6.0.10}
# The pins of the sources of the default versions: the commit of each
# git tag (a tag can move), and the SHA-256 of each download (a release
# asset can change). For another version, give its pin too.
OTP_COMMIT=${OTP_COMMIT:-ad05823719d77c8faee87348ea39513d4e2f99c5}
COSMOCC_SHA256=${COSMOCC_SHA256:-85b8c37a406d862e656ad4ec14be9f6ce474c1b436b9615e91a55208aced3f44}
# libc/calls/pledge-linux.c and libc/calls/unveil.c of the tag
# COSMOCC_VERSION (build_cosmo_file).
COSMO_PLEDGE_SHA256=${COSMO_PLEDGE_SHA256:-b8cc37f3d9047863abea3a42577d84eafa523d4eafaf98e4d3facbea73461a60}
COSMO_UNVEIL_SHA256=${COSMO_UNVEIL_SHA256:-d7456340c5f4bf0f1acef3458930d15b210fade2124d0a4f968fc01c1b236127}
OPENSSL_COMMIT=${OPENSSL_COMMIT:-af1775b60dfa141a4ad762585052cabeb9f37e9e}
EMSDK_COMMIT=${EMSDK_COMMIT:-a2b92777574c2feda07994cd4f1079a3dfc151f8}
SQLITE=${SQLITE:-1}
# esqlite (Apache-2.0), with the SQLite amalgamation (public domain) of
# sqlite.org instead of the older copy in esqlite.
ESQLITE_COMMIT=${ESQLITE_COMMIT:-5c8d590d8eb70de17dd2c64dfc7502f4fd2fcba8}
SQLITE_VERSION=${SQLITE_VERSION:-3.53.4}
SQLITE_YEAR=${SQLITE_YEAR:-2026}
SQLITE_SHA256=${SQLITE_SHA256:-1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d}
# The NIFs of Elixir packages (with the SHA-256 of the hex.pm tarball).
# The tools of Elixir compile these packages without a C compiler (see
# src/beam_com/beam_com_make.erl).
EXQLITE_VERSION=${EXQLITE_VERSION:-0.41.0}
EXQLITE_SHA256=${EXQLITE_SHA256:-a7e9b6bed529ab72aa07ed2a925ac109c27e6877a7a8af252361c396a4192855}
BCRYPT_ELIXIR_VERSION=${BCRYPT_ELIXIR_VERSION:-3.3.2}
BCRYPT_ELIXIR_SHA256=${BCRYPT_ELIXIR_SHA256:-471be5151874ae7931911057d1467d908955f93554f7a6cd1b7d804cac8cef53}
ARGON2_ELIXIR_VERSION=${ARGON2_ELIXIR_VERSION:-4.1.3}
ARGON2_ELIXIR_SHA256=${ARGON2_ELIXIR_SHA256:-7c295b8d8e0eaf6f43641698f962526cdf87c6feb7d14bd21e599271b510608c}
PICOSAT_ELIXIR_VERSION=${PICOSAT_ELIXIR_VERSION:-0.2.3}
PICOSAT_ELIXIR_SHA256=${PICOSAT_ELIXIR_SHA256:-f76c9db2dec9d2561ffaa9be35f65403d53e984e8cd99c832383b7ab78c16c66}
VIX_VERSION=${VIX_VERSION:-0.42.0}
VIX_SHA256=${VIX_SHA256:-c4c92051653859dc5219f553a93fa777d63525ee961c48e16e9f61fed02472ee}
VIX_PARTS=${VIX_PARTS:-}
NIFS_OMIT=${NIFS_OMIT:-}
for p in $NIFS_OMIT; do
    case $p in
        exqlite|bcrypt_elixir|argon2_elixir) ;;
        *) echo "Not a default NIF in NIFS_OMIT: $p (exqlite, bcrypt_elixir or argon2_elixir)" >&2; exit 1 ;;
    esac
done
RUSTY_CSV_VERSION=${RUSTY_CSV_VERSION:-0.4.6}
RUSTY_CSV_SHA256=${RUSTY_CSV_SHA256:-db9967f0889b9b967a9a1d084fcfbac56c1b0f09cb1faa84b6405e9450f6e059}
EX_PDFIUM_VERSION=${EX_PDFIUM_VERSION:-0.6.0}
EX_PDFIUM_SHA256=${EX_PDFIUM_SHA256:-a4f57f4074050e0062b1e80dc39db1fe8a5d9c5eb15928b0211939813c3b3f63}
# More packages whose NIFs are linked (custom builds), from the list of
# hex_nif_recipe(): for example "picosat_elixir". Only with ELIXIR=1.
EXTRA_NIFS=${EXTRA_NIFS:-}
WASM=${WASM:-1}
WAMR_VERSION=${WAMR_VERSION:-2.4.5}
WAMR_COMMIT=${WAMR_COMMIT:-25bd7eb63e828e4bd242cc9b38d260b4b31c6605}
ELIXIR=${ELIXIR:-1}
ELIXIR_VERSION=${ELIXIR_VERSION:-1.20.4}
ELIXIR_COMMIT=${ELIXIR_COMMIT:-759443e724f55bf58e71c0603644e99058918d52}
# rebar3 of a custom build (REBAR3=1).
REBAR3_VERSION=${REBAR3_VERSION:-3.27.1}
REBAR3_SHA256=${REBAR3_SHA256:-708407032479514dd68b581a0b09a68b5a781fb6f53dcf4ad81ce4ef6b92940f}
ELIXIR_APPS="elixir eex ex_unit iex logger mix"
OTP_APPS=${OTP_APPS:-}
OTP_OMIT=${OTP_OMIT:-}
HEX=${HEX:-0}
REBAR3=${REBAR3:-0}
BUILD=${BUILD:-$ROOT/build}
COSMOCC=${COSMOCC:-$BUILD/cosmocc}
CC=${CC:-cosmocc}
AR=${AR:-cosmoar}
CXX=${CXX:-${CC%cc}c++}
JIT=${JIT:-1}
if [ "$JIT" = 1 ]; then FLAVOR=jit; else FLAVOR=emu; fi
# The functions of the libc that the emulator takes from
# c_src/cosmo/beam_com_libc.h (docs/UPSTREAM.md C33 and C34). The link of
# the emulator and the check of step_test use the same list.
LIBC_WRAPS="-Wl,--wrap=memchr -Wl,--wrap=strncpy"
# The calls that the host list of --allow-net checks (only the link of
# the emulator; see c_src/cosmo/beam_com_net.c).
NET_WRAPS="-Wl,--wrap=connect -Wl,--wrap=bind -Wl,--wrap=sendto -Wl,--wrap=sendmsg -Wl,--wrap=socket"
# The calls that the check of the paths of Windows checks (only the link
# of the emulator; see c_src/cosmo/beam_com_fs.c). mkdir and chown have
# their wraps in c_src/cosmo/beam_com.c.
FS_WRAPS=""
for f in open openat creat opendir readlink readlinkat unlink unlinkat rmdir rename \
    renameat link linkat symlink symlinkat chmod fchmodat truncate utimes utimensat utime \
    mkdirat lchown fchownat; do
    FS_WRAPS="$FS_WRAPS -Wl,--wrap=$f"
done
# getcwd() in the sandbox of macOS (c_src/cosmo/beam_com_seatbelt.c).
MAC_WRAPS="-Wl,--wrap=getcwd"
# The writes to a non-blocking pipe on Windows, and select() for such a
# pipe (c_src/cosmo/beam_com_pipe.c).
PIPE_WRAPS="-Wl,--wrap=write -Wl,--wrap=writev -Wl,--wrap=select"
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}

# The OTP applications in the zip. "beam.com INPUT -o OUTPUT" copies the ones that
# a program needs into the new executable.
BUNDLE_APPS="kernel stdlib sasl compiler parsetools crypto asn1 public_key ssl inets
             ssh xmerl runtime_tools tools"
# The small build (OTP_SMALL_BUILD) does not make these.
EXTRA_APPS="crypto asn1 public_key ssl"
# Nor these, of which only the Erlang code is needed (src/): xmerl
# (Phoenix apps have swoosh, which includes xmerl.hrl), runtime_tools
# (in the extra_applications of a new Phoenix app; its C code is for
# dtrace and trace drivers), tools (cover, for "mix test --cover"), and
# ssh (an SSH daemon or client; it has no C code).
SRC_APPS="xmerl runtime_tools tools ssh"
# The applications of OTP_APPS (a custom build) that are not in the zip
# yet: their Erlang code too.
for app in $OTP_APPS; do
    case " $BUNDLE_APPS " in
        *" $app "*) ;;
        *) BUNDLE_APPS="$BUNDLE_APPS $app" SRC_APPS="$SRC_APPS $app" ;;
    esac
done
# The default applications that a custom build can leave out (OTP_OMIT).
# The others (kernel, stdlib, sasl, compiler and crypto) are for beam.com
# itself. The build still makes them: only the zip leaves them out.
OMITTABLE_APPS="parsetools asn1 public_key ssl inets ssh xmerl runtime_tools tools"
for app in $OTP_OMIT; do
    case " $OMITTABLE_APPS " in
        *" $app "*) ;;
        *) echo "OTP_OMIT: $app cannot be left out (only: $OMITTABLE_APPS)" >&2
           exit 1 ;;
    esac
    case " $OTP_APPS " in
        *" $app "*) echo "OTP_OMIT: $app is also in OTP_APPS" >&2
                    exit 1 ;;
    esac
done
apps=
for app in $BUNDLE_APPS; do
    case " $OTP_OMIT " in
        *" $app "*) ;;
        *) apps="$apps $app" ;;
    esac
done
BUNDLE_APPS=${apps# }

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

# CCACHE=1: copies of cosmocc and cosmoc++ in BUILD/ccache-bin, first on
# the PATH. Each copy runs the compilers of COSMOCC/bin, and each of its
# four compilers (gcc and g++ for x86_64 and aarch64) goes through
# ccache. cosmocc makes one object with each compiler, so each compile is
# a plain compile for ccache.
# The compilers are APE files, which only a shell or an APE loader starts,
# and ccache starts a compiler with execv(). So ccache runs real/NAME,
# which starts the compiler with sh, and it hashes the SHA-256 of the
# compiler (compiler_check=string:SHA), not real/NAME.
if [ "${CCACHE:-0}" = 1 ]; then
    if ! command -v ccache > /dev/null; then
        echo "CCACHE=1 needs ccache" >&2
        exit 1
    fi
    d=$BUILD/ccache-bin
    mkdir -p "$d/real"
    for t in x86_64 aarch64; do
        for c in gcc g++; do
            n=$t-linux-cosmo-$c
            sha=$(sha256sum "$COSMOCC/bin/$n" | cut -d' ' -f1)
            printf '#!/bin/sh\nexec sh %s "$@"\n' "$COSMOCC/bin/$n" > "$d/real/$n"
            printf '#!/bin/sh\nCCACHE_COMPILERCHECK=string:%s exec ccache %s "$@"\n' \
                "$sha" "$d/real/$n" > "$d/$n"
            chmod +x "$d/real/$n" "$d/$n"
        done
    done
    for p in cosmocc cosmoc++; do
        sed -e "s#^BIN=\${0%/\*}\$#BIN=$COSMOCC/bin#" \
            -e "s#=\"\$BIN/\(x86_64\|aarch64\)-linux-cosmo-\(gcc\|g++\)\"#=\"$d/\1-linux-cosmo-\2\"#" \
            "$COSMOCC/bin/$p" > "$d/$p.new"
        # The copy must use the wrappers: else ccache does nothing.
        if [ "$(grep -c "^BIN=$COSMOCC/bin\$" "$d/$p.new")" != 1 ] ||
            [ "$(grep -c "=\"$d/" "$d/$p.new")" != 4 ]; then
            echo "CCACHE=1: $COSMOCC/bin/$p is not the expected cosmocc" >&2
            exit 1
        fi
        chmod +x "$d/$p.new"
        mv "$d/$p.new" "$d/$p"
    done
    CCACHE_DIR=${CCACHE_DIR:-$BUILD/ccache}
    CCACHE_BASEDIR=$ROOT CCACHE_NOHASHDIR=1 CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-2G}
    export CCACHE_DIR CCACHE_BASEDIR CCACHE_NOHASHDIR CCACHE_MAXSIZE
    PATH=$d:$PATH
fi
export PATH

log() { printf '\n==> %s\n' "$*"; }

# The SHA-256 of a download: FILE EXPECTED NAME.
check_sha256() {
    sum=$(sha256sum "$1" | cut -d' ' -f1)
    if [ "$sum" != "$2" ]; then
        echo "Bad SHA-256 of $3: $sum (expected $2)" >&2
        exit 1
    fi
}

# The commit of a clone: DIR EXPECTED NAME. A tag can move to another
# commit.
check_commit() {
    head=$(git -C "$1" rev-parse HEAD)
    if [ "$head" != "$2" ]; then
        echo "The clone of $3 is at $head, not at the pinned commit $2" >&2
        exit 1
    fi
}

# The APE loader of x86_64 in cosmocc (bin/ape-x86_64.elf) has a code
# segment that can be executed but not read (PF_X with no PF_R). The
# kernel of x86_64 reads such pages all the same, but Rosetta for Linux
# runs on arm64, which has execute-only pages, and the loader faults at
# once (issue 149, C49 of docs/UPSTREAM.md). Each PT_LOAD segment gets
# PF_R, as ape-aarch64.elf has. apelink then puts the changed loader in
# each APE file (cosmocc and step_bundle give it this file).
fix_ape_loader() {
    f=$COSMOCC/bin/ape-x86_64.elf
    [ -f "$f" ] || return 0
    # An ELF file of x86_64: the magic, and e_machine 62 at offset 18.
    [ "$(od -An -c -N4 "$f" | tr -d ' ')" = '177ELF' ] || return 0
    [ "$(od -An -tu1 -j18 -N1 "$f" | tr -d ' ')" = 62 ] || return 0
    phnum=$(od -An -tu2 -j56 -N2 "$f" | tr -d ' ')
    i=0
    while [ "$i" -lt "$phnum" ]; do
        ph=$((64 + 56 * i))
        if [ "$(od -An -tu4 -j"$ph" -N4 "$f" | tr -d ' ')" = 1 ]; then
            flags=$(od -An -tu1 -j$((ph + 4)) -N1 "$f" | tr -d ' ')
            if [ $((flags & 4)) = 0 ]; then
                # shellcheck disable=SC2059 # the octal escape is the format.
                printf "\\$(printf '%03o' $((flags | 4)))" |
                    dd of="$f" bs=1 seek=$((ph + 4)) conv=notrunc 2>/dev/null
                log "The APE loader of x86_64: PT_LOAD $i is readable now"
            fi
        fi
        i=$((i + 1))
    done
}

# Each PT_LOAD segment of the APE loader of x86_64 in the APE file $1
# has PF_R. The shell part of the file gives the place of the loader:
# the first line that unpacks a loader to "$t.$$".
check_ape_loader() {
    line=$(head -c 65536 "$1" | grep -a -m1 'gzip -dc >"$t\.\$\$"')
    skip=$(echo "$line" | sed -n 's/.*skip=\([0-9]*\).*/\1/p')
    count=$(echo "$line" | sed -n 's/.*count=\([0-9]*\).*/\1/p')
    if [ -z "$skip" ] || [ -z "$count" ]; then
        echo "$1: no APE loader in the shell part" >&2
        exit 1
    fi
    dd if="$1" skip="$skip" count="$count" bs=1 2>/dev/null | gzip -dc > "$BUILD/ape-loader.elf"
    [ "$(od -An -tu1 -j18 -N1 "$BUILD/ape-loader.elf" | tr -d ' ')" = 62 ] || {
        echo "$1: the first APE loader is not for x86_64" >&2
        exit 1
    }
    phnum=$(od -An -tu2 -j56 -N2 "$BUILD/ape-loader.elf" | tr -d ' ')
    i=0
    while [ "$i" -lt "$phnum" ]; do
        ph=$((64 + 56 * i))
        if [ "$(od -An -tu4 -j"$ph" -N4 "$BUILD/ape-loader.elf" | tr -d ' ')" = 1 ] &&
           [ $(($(od -An -tu1 -j$((ph + 4)) -N1 "$BUILD/ape-loader.elf") & 4)) = 0 ]; then
            echo "$1: PT_LOAD $i of the APE loader of x86_64 cannot be read" >&2
            exit 1
        fi
        i=$((i + 1))
    done
}

# The APE loader of macOS arm64 in cosmocc (bin/ape-m1.c), which apelink
# puts in each APE file as source: the shell header compiles it with cc
# on the Mac. patches/cosmo/ape-m1.patch makes the loader check that the
# fixed addresses of the program are free, and start again when they are
# not (issue 177, C51 of docs/UPSTREAM.md). The original stays in
# ape-m1.c.orig, and the mark has the SHA-256 of the patch, so a new
# patch applies to the original.
fix_ape_m1() {
    f=$COSMOCC/bin/ape-m1.c
    [ -f "$f" ] || return 0
    patch_sum=$(sha256sum "$ROOT/patches/cosmo/ape-m1.patch" | cut -d' ' -f1)
    [ "$(cat "$f.beam_com_patched" 2>/dev/null)" = "$patch_sum" ] && return 0
    [ -f "$f.orig" ] || cp "$f" "$f.orig"
    cp "$f.orig" "$f"
    patch -s -p1 -d "$COSMOCC/bin" < "$ROOT/patches/cosmo/ape-m1.patch"
    echo "$patch_sum" > "$f.beam_com_patched"
    log "The APE loader of macOS arm64: patches/cosmo/ape-m1.patch"
}

step_toolchain() {
    if [ -x "$COSMOCC/bin/cosmocc" ]; then
        log "Using cosmocc in $COSMOCC"
        fix_ape_loader
        fix_ape_m1
        return
    fi
    log "Downloading cosmocc $COSMOCC_VERSION"
    mkdir -p "$COSMOCC"
    url=https://github.com/jart/cosmopolitan/releases/download/$COSMOCC_VERSION/cosmocc-$COSMOCC_VERSION.zip
    curl -fsSL -o "$BUILD/cosmocc.zip" "$url"
    check_sha256 "$BUILD/cosmocc.zip" "$COSMOCC_SHA256" "cosmocc-$COSMOCC_VERSION.zip"
    (cd "$COSMOCC" && unzip -q "$BUILD/cosmocc.zip")
    rm -f "$BUILD/cosmocc.zip"
    fix_ape_loader
    fix_ape_m1
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
    check_commit "$src" "$OPENSSL_COMMIT" "OpenSSL $OPENSSL_VERSION"
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
    # A built tree with the key of this build, from the store. All its
    # files get the same time, so a file that a later step writes (the
    # files of c_src/cosmo below, the NIFs) is newer, and make builds only
    # what depends on it.
    if [ -n "${PARTS_URL:-}" ] && ! otp_from_part; then
        key=$(otp_part_key)
        rm -rf "$ERL_TOP.part"
        if part_get otp "$key" "$ERL_TOP.part"; then
            rm -rf "$ERL_TOP"
            mv "$ERL_TOP.part/$(basename "$ERL_TOP")" "$ERL_TOP"
            rm -rf "$ERL_TOP.part"
            now=$(date +%Y%m%d%H%M.%S)
            find "$ERL_TOP" -exec touch -h -t "$now" {} +
            echo "$key" > "$ERL_TOP/.beam_com_part"
        else
            rm -rf "$ERL_TOP.part"
        fi
    fi
    if [ ! -d "$ERL_TOP/.git" ]; then
        log "Cloning Erlang/OTP $OTP_VERSION"
        git clone -q --depth 1 --branch "OTP-$OTP_VERSION" \
            https://github.com/erlang/otp.git "$ERL_TOP"
    fi
    check_commit "$ERL_TOP" "$OTP_COMMIT" "Erlang/OTP $OTP_VERSION"
    if [ ! -f "$ERL_TOP/.beam_com_patched" ]; then
        log "Applying patches"
        for p in "$ROOT"/patches/otp/*.patch; do
            echo "  $p"
            git -C "$ERL_TOP" apply "$p"
        done
        touch "$ERL_TOP/.beam_com_patched"
    fi
    # The multi-call wrappers compile with the ERTS flags.
    cp "$ROOT"/c_src/cosmo/beam_com.c "$ROOT"/c_src/cosmo/beam_com_child_setup.c \
       "$ROOT"/c_src/cosmo/beam_com_inet_gethost.c "$ROOT"/c_src/cosmo/beam_com_epmd.h \
       "$ROOT"/c_src/cosmo/beam_com_epmd.c "$ROOT"/c_src/cosmo/beam_com_epmd_srv.c \
       "$ROOT"/c_src/cosmo/beam_com_epmd_cli.c "$ROOT"/c_src/cosmo/beam_com_watch.c \
       "$ROOT"/c_src/cosmo/beam_com_agent.c "$ROOT"/c_src/cosmo/beam_com_pipe.c \
       "$ROOT"/c_src/cosmo/beam_com_libc.h "$ROOT"/c_src/cosmo/beam_com_net.c \
       "$ROOT"/c_src/cosmo/beam_com_net.h "$ROOT"/c_src/cosmo/beam_com_fs.c \
       "$ROOT"/c_src/cosmo/beam_com_fs.h "$ROOT"/c_src/cosmo/beam_com_seatbelt.c \
       "$ROOT"/c_src/cosmo/beam_com_seatbelt.h "$ROOT"/c_src/cosmo/beam_com_nif.c \
       "$ROOT"/c_src/cosmo/beam_com_nif.h "$ROOT"/c_src/cosmo/beam_com_nif_syms.c \
       "$ROOT"/c_src/cosmo/beam_com_nif_libc.h "$ROOT"/c_src/cosmo/beam_com_nif_cxx.h \
       "$ROOT"/c_src/cosmo/beam_com_sha1dc.c \
       "$ERL_TOP/erts/emulator/sys/unix/"
    # The library of beam_com_sha1dc.c (sha1collisiondetection), which it
    # includes as sha1dc/sha1.c and sha1dc/ubc_check.c.
    mkdir -p "$ERL_TOP/erts/emulator/sys/unix/sha1dc"
    cp "$ROOT"/c_src/cosmo/sha1dc/sha1.c "$ROOT"/c_src/cosmo/sha1dc/sha1.h \
       "$ROOT"/c_src/cosmo/sha1dc/ubc_check.c "$ROOT"/c_src/cosmo/sha1dc/ubc_check.h \
       "$ERL_TOP/erts/emulator/sys/unix/sha1dc/"
}

step_configure() {
    if otp_from_part; then
        log "Using the configured OTP of the store"
        return 0
    fi
    rm -f "$ERL_TOP/.beam_com_part"
    log "Configuring OTP with $CC"
    cd "$ERL_TOP"
    # Notes on the cache variables:
    #  - poll.h: the POLL* constants of Cosmopolitan are not compile-time
    #    constants, which ERTS needs. The select() back-end uses its own.
    #  - sendfile: inet_drv only knows the Linux/BSD/Solaris variants.
    #  - linux_thp: 2 MiB page alignment breaks the APE layout.
    #  - clock ids: CLOCK_UPTIME exists in the headers but only works on BSD.
    #  - DED_LD*: there are no shared objects. c_src/cosmo/noshared writes
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
        DED_LD="$ROOT/c_src/cosmo/noshared" DED_LDFLAGS="-no-pie" \
        DED_LD_FLAG_RUNTIME_LIBRARY_PATH="-Wl,-rpath," \
        CFLAGS="-O2 -g -DZSTD_DISABLE_ASM -include $ROOT/c_src/cosmo/erts_cosmo.h" \
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
        check_sha256 "$BUILD/$amalgamation.zip" "$SQLITE_SHA256" "$amalgamation.zip"
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

# The NIFs of Elixir packages are linked when their package is enabled,
# and the default NIFs (exqlite, bcrypt_elixir, argon2_elixir) when
# NIFS_OMIT does not name them.
omit_nif() { case " $NIFS_OMIT " in *" $1 "*) return 0 ;; esac; return 1; }
use_exqlite() { [ "$SQLITE" = 1 ] && [ "$ELIXIR" = 1 ] && ! omit_nif exqlite; }
# The packages of hex_nif_recipe() whose NIFs are linked.
hex_nif_packages() {
    [ "$ELIXIR" = 1 ] || return 0
    for p in bcrypt_elixir argon2_elixir; do
        omit_nif "$p" || printf '%s ' "$p"
    done
    # shellcheck disable=SC2086
    echo $EXTRA_NIFS
}

# The packages of hex_nif_packages() for the WebAssembly runtime: not
# vix (libvips uses threads, and the runtime has none), and no NIF of
# Rust (its std has the system calls of Linux).
edge_hex_nif_packages() {
    for p in $(hex_nif_packages); do
        [ "$p" = vix ] || [ -n "$(rust_nif_crate "$p")" ] || printf '%s ' "$p"
    done
}

# build_vix_nif SRC OUT CFLAGS: the NIF of vix (in SRC) for each CPU, with
# the compiler and the static libvips of that CPU (LIBVIPS/x86_64 and
# LIBVIPS/aarch64: their headers differ). OUT/vix.a and OUT/.aarch64/vix.a
# have the objects of the NIF and of all the libraries of libvips, so the
# link needs only this archive (STATIC_NIFS has one archive for each NIF).
build_vix_nif() {
    src=$1 out=$2 cflags=$3
    bin=$COSMOCC/bin
    libvips=${LIBVIPS:-$BUILD/libvips}
    # The parts of VIX_PARTS, sorted, as scripts/libvips.sh writes them in
    # LIBVIPS/parts.
    parts=$(printf '%s\n' $VIX_PARTS | sort -u | tr '\n' ' ' | sed 's/^ *//; s/ *$//')
    # The static libvips of scripts/libvips.sh, once for each set of
    # parts (about 5 minutes for the two CPUs, and about 12 more for
    # avif). LIBVIPS names a build that exists.
    if [ -z "${LIBVIPS:-}" ] && { [ ! -f "$libvips/aarch64/lib/libvips.a" ] ||
            [ "$(cat "$libvips/parts" 2>/dev/null)" != "$parts" ]; }; then
        COSMOCC=$COSMOCC BUILD=$BUILD VIX_PARTS="$parts" sh "$ROOT/scripts/libvips.sh" "$libvips"
    fi
    if [ "$(cat "$libvips/parts" 2>/dev/null)" != "$parts" ]; then
        echo "$libvips has the parts \"$(cat "$libvips/parts" 2>/dev/null)\", not \"$parts\" (VIX_PARTS)" >&2
        exit 1
    fi
    # The libraries of the archive: those of each part, and then those of
    # the formats of each build.
    libs=vips
    case " $parts " in *" avif "*) libs="$libs heif aom" ;; esac
    case " $parts " in *" icc "*) libs="$libs lcms2" ;; esac
    case " $parts " in *" gif "*) libs="$libs cgif imagequant" ;; esac
    # svg: resvg (native/vips_resvg) for c_src/vips/resvgload.c, as
    # OUT/vips_resvg.a and OUT/.aarch64/vips_resvg.a, with one global name.
    # A subshell: build_rust_nif sets src, out and bin.
    case " $parts " in
        *" svg "*) (build_rust_nif vips_resvg "$ROOT" "$out" vips_resvg "$cflags" vips_resvg) ;;
    esac
    libs="$libs hwy webpmux webpdemux webp sharpyuv png16 jpeg expat gio-2.0 gmodule-2.0"
    libs="$libs gobject-2.0 glib-2.0 intl ffi z"
    for cpu in x86_64 aarch64; do
        p=$libvips/$cpu
        if [ ! -f "$p/lib/libvips.a" ]; then
            echo "Missing $p/lib/libvips.a (LIBVIPS)" >&2
            exit 1
        fi
        case $cpu in x86_64) a=$out/vix.a ;; *) mkdir -p "$out/.aarch64"; a=$out/.aarch64/vix.a ;; esac
        obj=$out/vix-$cpu
        rm -rf "$obj" "$a"
        mkdir -p "$obj"
        # Not the -DHAVE_CONFIG_H of vips.pc: erl_nif.h then reads a
        # config.h.
        vips=$(PKG_CONFIG_LIBDIR=$p/lib/pkgconfig pkg-config --cflags vips |
            sed 's/-DHAVE_CONFIG_H//g')
        for c in "$src"/c_src/*.c "$src"/c_src/g_object/*.c; do
            # shellcheck disable=SC2086
            "$bin/$cpu-unknown-cosmo-cc" -O2 -std=c11 -D_POSIX_C_SOURCE=200809L                 -DSTATIC_ERLANG_NIF_LIBNAME=vix $cflags $vips                 -c "$c" -o "$obj/$(basename "$c" .c).o"
        done
        # One object with one global name, vix_nif_init: the other
        # names of the NIF (such as raise_exception) are also in other
        # static NIFs (crypto).
        "$bin/$cpu-linux-cosmo-ld" -r -o "$obj/vix_nif.r" "$obj"/*.o
        "$bin/$cpu-unknown-cosmo-objcopy" --keep-global-symbol=vix_nif_init \
            "$obj/vix_nif.r" "$obj/vix_nif.o.all"
        {
            echo "CREATE $a"
            echo "ADDMOD $obj/vix_nif.o.all"
            for l in $libs; do
                echo "ADDLIB $p/lib/lib$l.a"
            done
            case " $parts " in
                *" svg "*) echo "ADDLIB $(dirname "$a")/vips_resvg.a" ;;
            esac
            echo SAVE
            echo END
        } | "$bin/$cpu-unknown-cosmo-ar" -M
    done
}

# The calls of the C library that a Rust NIF makes with the numbers of
# Linux (c_src/rust/cosmo_rust.c), and dlopen() and dlsym(), with which
# Rustler finds the NIF functions of ERTS (c_src/rust/enif_table.c).
RUST_SHIM_SYMS="syscall clock_gettime clock_nanosleep __errno_location
    pthread_attr_init pthread_attr_destroy pthread_attr_setstacksize
    pthread_attr_getstack pthread_attr_getguardsize pthread_getattr_np
    pthread_create open openat mmap getauxval sched_getaffinity fstat stat
    lstat fstatat dlopen dlsym dlerror dlclose"

# rust_nif_crate NAME: the directory of the Rust crate of a package with a
# NIF of Rustler, and its Cargo features. Empty for another package.
rust_nif_crate() {
    case $1 in
        # nif_version_2_17: the NIF version of the precompiled NIFs of
        # rusty_csv for OTP 27 to 29.
        rusty_csv) echo "native/rustycsv nif_version_2_17" ;;
        # static: pdfium-render links libpdfium.a (rust_nif_env), and
        # loads no library.
        ex_pdfium) echo "native/ex_pdfium static" ;;
        # Not a NIF: the SVG loader of the part svg of vix (build_vix_nif).
        vips_resvg) echo "native/vips_resvg" ;;
    esac
}

# rust_nif_env NAME CPU: more variables of the environment of cargo for
# the crate of NAME, for CPU (x86_64 or aarch64).
rust_nif_env() {
    case $1 in
        ex_pdfium)
            case $2 in x86_64) c=x64 ;; *) c=arm64 ;; esac
            echo "PDFIUM_STATIC_LIB_PATH=${PDFIUM:-$BUILD/pdfium}/$c" ;;
    esac
}

# rust_nif_prepare NAME: the libraries that the crate of NAME links.
rust_nif_prepare() {
    case $1 in
        ex_pdfium)
            # The static libpdfium of scripts/pdfium.sh, once (about 30
            # minutes for each CPU). PDFIUM names a build that exists.
            p=${PDFIUM:-$BUILD/pdfium}
            for c in x64 arm64; do
                if [ -z "${PDFIUM:-}" ] && [ ! -f "$p/$c/libpdfium.a" ]; then
                    COSMOCC=$COSMOCC BUILD=$BUILD sh "$ROOT/scripts/pdfium.sh" "$c" "$p/$c"
                fi
                if [ ! -f "$p/$c/libpdfium.a" ]; then
                    echo "Missing $p/$c/libpdfium.a (PDFIUM)" >&2
                    exit 1
                fi
            done ;;
    esac
}

# build_rust_nif NAME SRC OUT LIB CFLAGS [GLOBAL]: the NIF of Rustler of
# the package NAME, in SRC (rust_nif_crate), as OUT/LIB.a and
# OUT/.aarch64/LIB.a. LIB is the name of the crate: Rustler exports
# LIB_nif_init, the init function of a static NIF of that name. GLOBAL
# names another global name, for a crate that is not a NIF.
#
# The crate builds as a staticlib with the std of *-unknown-linux-musl,
# with the Rust toolchain of its rust-toolchain.toml (else RUST_NIGHTLY).
# objcopy gives the calls of RUST_SHIM_SYMS the beam_rs_ names of the
# shims. On aarch64, Cosmopolitan reserves x18 and x28, so the crate and
# its std build again with these registers reserved (-Zbuild-std, with
# rust-src). One object keeps one global name, LIB_nif_init
# (scripts/rust_link.sh): two NIFs of Rust each have their own std.
build_rust_nif() {
    name=$1 src=$2 out=$3 lib=$4 cflags=$5 global=${6:-${4}_nif_init}
    bin=$COSMOCC/bin
    # shellcheck disable=SC2046 # the directory and the features
    set -- $(rust_nif_crate "$name")
    crate=$src/$1 features=${2:-}
    # A crate with no rust-toolchain.toml (ex_pdfium) uses RUST_NIGHTLY.
    tc=
    if [ -f "$crate/rust-toolchain.toml" ]; then
        tc=$(sed -n 's/^channel *= *"\([^"]*\)".*/\1/p' "$crate/rust-toolchain.toml")
    fi
    tc=${tc:-${RUST_NIGHTLY:-nightly-2026-11-01}}
    if ! command -v rustup > /dev/null; then
        echo "The NIF of $name needs Rust: install rustup" >&2
        exit 1
    fi
    rustup toolchain install "$tc" --profile minimal --component rust-src \
        --target x86_64-unknown-linux-musl > /dev/null
    rust_nif_prepare "$name"
    # The names of the NIF functions of ERTS, for the table of dlsym().
    # The build of cargo stays in OUT/cargo-LIB for the next build.
    gen=$out/rust-$lib
    rm -rf "$gen" "$out/$lib.a" "$out/.aarch64/$lib.a"
    mkdir -p "$gen" "$out/.aarch64"
    sed -n '/^#ifdef ERL_NIF_API_FUNC_DECL$/,/^#endif \/\* ERL_NIF_API_FUNC_DECL \*\//p' \
        "$ERL_TOP/erts/emulator/beam/erl_nif_api_funcs.h" | sed '1d;$d' |
        sed -n 's/^ERL_NIF_API_FUNC_DECL([^,]*,[ ]*\(enif_[A-Za-z0-9_]*\).*/X(\1)/p; /^#/p' \
        > "$gen/enif_names.h"
    grep -q '^X(enif_make_atom)$' "$gen/enif_names.h"
    redefine=
    for s in $RUST_SHIM_SYMS; do redefine="$redefine --redefine-sym $s=beam_rs_$s"; done
    for cpu in x86_64 aarch64; do
        t=$cpu-unknown-linux-musl
        obj=$gen/$cpu
        mkdir -p "$obj"
        if [ $cpu = aarch64 ]; then
            set -- -Zbuild-std=std,panic_unwind
            rf="-C target-feature=+reserve-x18,+reserve-x28"
        else
            set --
            rf=
        fi
        # LTO: the object has only the code that the crate uses (see
        # scripts/rust_link.sh).
        # shellcheck disable=SC2046,SC2086
        # RUSTFLAGS is an assignment of the shell (no split of its words).
        (cd "$crate" && RUSTFLAGS=$rf CARGO_PROFILE_RELEASE_LTO=fat env $(rust_nif_env "$name" "$cpu") \
            cargo "+$tc" rustc --release --locked --lib \
            --crate-type staticlib --target "$t" --target-dir "$out/cargo-$lib" \
            ${features:+--features "$features"} "$@")
        cp "$out/cargo-$lib/$t/release/lib$lib.a" "$obj/lib$lib.a"
        # shellcheck disable=SC2086
        "$bin/$cpu-unknown-cosmo-objcopy" $redefine "$obj/lib$lib.a"
        # shellcheck disable=SC2086
        for c in cosmo_rust enif_table; do
            "$bin/$cpu-unknown-cosmo-cc" -O2 -I"$gen" $cflags \
                -c "$ROOT/c_src/rust/$c.c" -o "$obj/$c.o"
        done
        # One object with one global name, LIB_nif_init or GLOBAL.
        sh "$ROOT/scripts/rust_link.sh" "$COSMOCC" "$cpu" "$global" \
            "$obj/$lib.o" "$obj/cosmo_rust.o" "$obj/enif_table.o" "$obj/lib$lib.a"
        case $cpu in x86_64) a=$out/$lib.a ;; *) a=$out/.aarch64/$lib.a ;; esac
        "$bin/$cpu-unknown-cosmo-ar" rcs "$a" "$obj/$lib.o"
    done
}

# hex_nif_recipe NAME: the version, the SHA-256 of the tarball and the
# name of the NIF (STATIC_ERLANG_NIF_LIBNAME, and the name of its archive)
# of a package, or an error for a package that is not in the list.
hex_nif_recipe() {
    case $1 in
        bcrypt_elixir) echo "$BCRYPT_ELIXIR_VERSION $BCRYPT_ELIXIR_SHA256 bcrypt_nif" ;;
        argon2_elixir) echo "$ARGON2_ELIXIR_VERSION $ARGON2_ELIXIR_SHA256 argon2_nif" ;;
        picosat_elixir) echo "$PICOSAT_ELIXIR_VERSION $PICOSAT_ELIXIR_SHA256 picosat_nif" ;;
        vix) echo "$VIX_VERSION $VIX_SHA256 vix" ;;
        rusty_csv) echo "$RUSTY_CSV_VERSION $RUSTY_CSV_SHA256 rustycsv" ;;
        ex_pdfium) echo "$EX_PDFIUM_VERSION $EX_PDFIUM_SHA256 ex_pdfium" ;;
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
    if [ "$name" = vix ]; then
        build_vix_nif "$src" "$out" "$cflags"
        return 0
    fi
    if [ -n "$(rust_nif_crate "$name")" ]; then
        build_rust_nif "$name" "$src" "$out" "$lib" "$cflags"
        return 0
    fi
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
            # (c_src/erts_wasm/sqlite_vfs.c). The options of its Makefile, a
            # batch atomic write for a commit of the host, and no WAL: the
            # host files have no shared memory, and in the memory files of
            # Emscripten the close of a database in WAL mode does not end.
            sed 's/^ERL_NIF_INIT(Elixir\.Exqlite\.Sqlite3NIF,/ERL_NIF_INIT(wasm_host_exqlite,/' \
                "$src/c_src/sqlite3_nif.c" > "$src/c_src/wasm_sqlite3_nif.c"
            grep -q '^ERL_NIF_INIT(wasm_host_exqlite,' "$src/c_src/wasm_sqlite3_nif.c"
            q="-DNDEBUG=1 -Ic_src -DSQLITE_THREADSAFE=1 -DSQLITE_USE_URI=1
               -DSQLITE_LIKE_DOESNT_MATCH_BLOBS=1 -DSQLITE_DQS=0 -DHAVE_USLEEP=1
               -DSQLITE_ENABLE_FTS3=1 -DSQLITE_ENABLE_FTS4=1 -DSQLITE_ENABLE_FTS5=1
               -DSQLITE_ENABLE_GEOPOLY=1 -DSQLITE_ENABLE_MATH_FUNCTIONS=1 -DSQLITE_ENABLE_RBU=1
               -DSQLITE_ENABLE_RTREE=1 -DSQLITE_OMIT_DEPRECATED=1 -DSQLITE_ENABLE_DBSTAT_VTAB=1
               -DSQLITE_ENABLE_BATCH_ATOMIC_WRITE=1 -DSQLITE_EXTRA_INIT=beam_vfs_init
               -DSQLITE_OMIT_WAL=1"
            set -- "c_src/wasm_sqlite3_nif.c:$nif $q" "c_src/sqlite3.c:$q" \
                "$ROOT/c_src/erts_wasm/sqlite_vfs.c:$q" ;;
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
        # Its archive for each CPU: static/LIB.a and static/.aarch64/LIB.a.
        # The name in its own variable: build_vix_nif and
        # rust_nif_prepare set p.
        pkg=$p
        lib=$(hex_nif_recipe "$pkg" | cut -d' ' -f3)
        key=$(nif_part_key "$pkg")
        # The NIF of ex_pdfium also has the license texts of PDFium, for
        # the step bundle.
        set -- "$lib.a" ".aarch64/$lib.a"
        [ "$pkg" = ex_pdfium ] && set -- "$@" licenses-pdfium
        if part_get "nif-$pkg" "$key" "$HEXNIFS/static" &&
            [ -f "$HEXNIFS/static/$lib.a" ] && [ -f "$HEXNIFS/static/.aarch64/$lib.a" ]; then
            continue
        fi
        build_hex_nif "$pkg" "$HEXNIFS/static" "$CC" "$AR" "$erl_flags"
        lib=$(hex_nif_recipe "$pkg" | cut -d' ' -f3)
        if [ "$pkg" = ex_pdfium ]; then
            rm -rf "$HEXNIFS/static/licenses-pdfium"
            mkdir -p "$HEXNIFS/static/licenses-pdfium"
            cp "${PDFIUM:-$BUILD/pdfium}"/x64/licenses/* "$HEXNIFS/static/licenses-pdfium/"
        fi
        part_put "nif-$pkg" "$key" "$HEXNIFS/static" "$@"
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

# The WAMR sources for the interpreter and the AOT loader with WASI (from
# the CMake files of WAMR, for the cosmopolitan platform). The relocations
# of the AOT code for each CPU are in c_src/wasm/aot_reloc.c.
WAMR_SOURCES="
    core/iwasm/aot/aot_intrinsic.c
    core/iwasm/aot/aot_loader.c
    core/iwasm/aot/aot_runtime.c
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

# The clone of WAMR, with the patches of patches/wamr.
wamr_clone() {
    if [ ! -d "$WAMR/.git" ]; then
        log "Cloning WAMR $WAMR_VERSION"
        git clone -q --depth 1 --branch "WAMR-$WAMR_VERSION" \
            https://github.com/bytecodealliance/wasm-micro-runtime.git "$WAMR"
    fi
    check_commit "$WAMR" "$WAMR_COMMIT" "WAMR $WAMR_VERSION"
    # patches/README.md lists the patches and their items. Each patch that
    # is not in the clone yet, also in a clone of an earlier build.
    for p in "$ROOT"/patches/wamr/*.patch; do
        git -C "$WAMR" apply --reverse --check "$p" 2>/dev/null && continue
        echo "  $p"
        git -C "$WAMR" apply "$p"
    done
}

step_wasm() {
    [ "$WASM" = 1 ] || return 0
    wamr_clone
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
    #  - WASM_ENABLE_REF_TYPES: current compilers (LLVM 19 and later) use
    #    reference types by default for wasm32.
    #  - WASM_ENABLE_AOT: the AOT files of the NIF libraries in
    #    WebAssembly (c_src/wasm/nif_wasm.c, docs/NIFS.md).
    #  - BEAM_COM_RESERVE_LINEAR_MEMORY: a linear memory grows with no
    #    copy (patches/wamr/0002-reserve-linear-memory.patch).
    flags="-O2 -include $ROOT/c_src/wasm/wamr_target.h
        -DBH_PLATFORM_COSMOPOLITAN -DBH_MALLOC=wasm_runtime_malloc
        -DBH_FREE=wasm_runtime_free -D_GNU_SOURCE
        -DWASM_ENABLE_INTERP=1 -DWASM_ENABLE_FAST_INTERP=1 -DWASM_ENABLE_AOT=1
        -DWASM_ENABLE_REF_TYPES=1
        -DWASM_ENABLE_LIBC_WASI=1 -DWASM_ENABLE_BULK_MEMORY=1
        -DWASM_ENABLE_BULK_MEMORY_OPT=1 -DWASM_ENABLE_SHRUNK_MEMORY=1
        -DWASM_ENABLE_MODULE_INST_CONTEXT=1 -DWASM_ENABLE_SIMD=0
        -DWASM_DISABLE_HW_BOUND_CHECK=1 -DWASM_DISABLE_STACK_HW_BOUND_CHECK=1
        -DWASM_DISABLE_WAKEUP_BLOCKING_OP=0 -DWASM_DISABLE_WRITE_GS_BASE=1
        -DWASM_HAVE_MREMAP=0 -DWASM_GLOBAL_HEAP_SIZE=10485760
        -DBEAM_COM_RESERVE_LINEAR_MEMORY
        -Icore/iwasm/include -Icore/iwasm/common -Icore/iwasm/interpreter
        -Icore/iwasm/aot
        -Icore/iwasm/libraries/libc-wasi/sandboxed-system-primitives/include
        -Icore/iwasm/libraries/libc-wasi/sandboxed-system-primitives/src
        -Icore/shared/platform/cosmopolitan -Icore/shared/platform/include
        -Icore/shared/platform/common/libc-util -Icore/shared/mem-alloc
        -Icore/shared/utils -Icore/shared/utils/uncommon"
    for src in $WAMR_SOURCES "$ROOT/c_src/wasm/aot_reloc.c"; do
        # shellcheck disable=SC2086
        "$CC" $flags -c "$src" -o "$obj/$(basename "$src" .c).o"
    done
    # cosmocc does not take assembler files, so the trampoline is made
    # with the compiler of each CPU (the aarch64 object goes in .aarch64/).
    x86_64-unknown-cosmo-cc -c -Icore/iwasm/common/arch \
        "$ROOT/c_src/wasm/invokeNative.S" -o "$obj/invokeNative.o"
    aarch64-unknown-cosmo-cc -c -Icore/iwasm/common/arch \
        "$ROOT/c_src/wasm/invokeNative.S" -o "$obj/.aarch64/invokeNative.o"
    "$CC" -O2 -DSTATIC_ERLANG_NIF_LIBNAME=wasm -Icore/iwasm/include \
        -I"$ERL_TOP/erts/emulator/beam" -I"$ERL_TOP/erts/include" \
        -I"$ERL_TOP/erts/include/$t" \
        -I"$ROOT/c_src/wasm" -c "$ROOT/c_src/wasm/wasm_nif.c" -o "$obj/wasm_nif.o"
    # The loader of the NIF libraries in WebAssembly: it sets the hook
    # erts_wasm_nif_open of ERTS (patches/otp/0003-wasm-nif.patch).
    # wasm_nif.o calls nif_wasm_runtime_init(), so the linker takes it.
    "$CC" -O2 -DBEAM_COM_ERTS_HOOK -Icore/iwasm/include -I"$ROOT/c_src/wasm" \
        -I"$ERL_TOP/erts/emulator/beam" -I"$ERL_TOP/erts/include" \
        -I"$ERL_TOP/erts/include/$t" \
        -c "$ROOT/c_src/wasm/nif_wasm.c" -o "$obj/nif_wasm.o"
    rm -f wasm.a .aarch64/wasm.a
    (cd "$obj" && "$AR" rcs "$WAMR/wasm.a" ./*.o)
}

# The loader of NIF libraries in WebAssembly for the WebAssembly runtime
# of --target wasm32 (wasm/erts/build.sh runs this step): one object
# NIF_EDGE_OUT, made with the compiler NIF_EDGE_CC (emcc) and the flags
# NIF_EDGE_CFLAGS (the include directories of its ERTS). The engine of
# the host runs the modules there (c_src/wasm/nif_wasm_host.c), so only
# the headers of WAMR are used. The constructor of nif_wasm.c sets the
# hook of ERTS.
step_nif_edge() {
    wamr_clone
    obj=$WAMR/obj-edge
    rm -rf "$obj"
    mkdir -p "$obj"
    for src in nif_wasm nif_wasm_host; do
        # shellcheck disable=SC2086
        $NIF_EDGE_CC -O2 -Wall -DBEAM_COM_ERTS_HOOK -I"$WAMR/core/iwasm/include" \
            -I"$ROOT/c_src/wasm" $NIF_EDGE_CFLAGS -c "$ROOT/c_src/wasm/$src.c" -o "$obj/$src.o"
    done
    $NIF_EDGE_CC -r -o "$NIF_EDGE_OUT" "$obj"/*.o
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

# The keys of the steps (docs/BUILDING.md, "The keys of the steps"). A
# key is the SHA-256 of the inputs of a step, and the Makefile runs a
# step again only when its key changed. The store of parts and the
# caches of CI use keys of the same kind. A key hashes these inputs:
#
#   - The code of the step function, and of each function that this code
#     names, again and again (steps_code). Comment lines are not code, so
#     a change of a comment does not change a key.
#   - The value of each variable in capitals that this code reads (the
#     settings), except the variables of KEY_IGNORE.
#   - The SHA-256 of each file of its list (step_files), as the work tree
#     has it.
#
# The key of a step does not hash the keys of the steps that it needs:
# the Makefile runs a step again when a step that it needs ran again.

# The variables that do not change what a step makes.
KEY_IGNORE="PATH JOBS PARTS_URL PARTS_PUT CCACHE CCACHE_DIR CCACHE_MAXSIZE"

# The steps of the Makefile, each with a key.
KEY_STEPS="toolchain openssl otp configure sqlite nifs wasm make elixir release
    multicall wasm_runtime bundle"

# The functions that find keys. Their code names the steps only to find
# a key, so steps_code does not follow these names.
KEY_FUNCS="steps_code key_settings key_files step_roots step_files step_inputs step_key
    write_keys step_check_keys wasm_runtime_inputs step_wasm_runtime_key step_cache_keys
    nif_part_key otp_part_key elixir_part_key step_part_keys otp_from_part"

# steps_code MODE NAME...: the functions NAME... of scripts/steps.sh, and
# each function that their code names, again and again. A NAME with "-"
# before it is a function not to follow, as the functions of KEY_FUNCS.
# MODE "text": their code with no comment lines, in the order of the
# names. MODE "names": their names. MODE "settings": the variables in
# capitals that their code reads. A function starts at a line "NAME() {"
# or "NAME() (", and ends at the next line "}" or ")", or on its first
# line.
steps_code() {
    awk -v mode="$1" -v roots="$(shift; echo "$*")" -v stops="$KEY_FUNCS" '
        function add(n) {
            if ((n in code) && !(n in seen) && !(n in stop)) {
                seen[n] = 1
                todo[++last] = n
            }
        }
        !on && /^[a-z_][a-z0-9_]*\(\) [{(]/ {
            name = substr($0, 1, index($0, "(") - 1)
            code[name] = $0 "\n"
            if ($0 ~ /[{(][[:space:]]*$/) on = 1
            next
        }
        on {
            if ($0 !~ /^[[:space:]]*#/) code[name] = code[name] $0 "\n"
            if ($0 == "}" || $0 == ")") on = 0
        }
        END {
            n = split(stops, r, /[[:space:]]+/)
            for (i = 1; i <= n; i++) stop[r[i]] = 1
            n = split(roots, r, " ")
            for (i = 1; i <= n; i++) if (r[i] ~ /^-/) stop[substr(r[i], 2)] = 1
            for (i = 1; i <= n; i++) {
                if (r[i] ~ /^-/) continue
                delete stop[r[i]]
                if (!(r[i] in code)) {
                    print "steps_code: no function " r[i] " in scripts/steps.sh" > "/dev/stderr"
                    exit 1
                }
                add(r[i])
            }
            for (i = 1; i <= last; i++) {
                k = split(code[todo[i]], w, /[^A-Za-z0-9_]+/)
                for (j = 1; j <= k; j++) add(w[j])
            }
            for (i = 2; i <= last; i++) {
                v = todo[i]
                for (j = i - 1; j >= 1 && todo[j] > v; j--) todo[j + 1] = todo[j]
                todo[j + 1] = v
            }
            for (i = 1; i <= last; i++) {
                if (mode == "names") print todo[i]
                else if (mode == "text") printf "%s", code[todo[i]]
                else {
                    s = code[todo[i]]
                    while (match(s, /\$[{]?[A-Z][A-Z0-9_]*/)) {
                        v = substr(s, RSTART, RLENGTH)
                        sub(/^\$[{]?/, "", v)
                        vars[v] = 1
                        s = substr(s, RSTART + RLENGTH)
                    }
                }
            }
            if (mode == "settings") for (v in vars) print v
        }' "$ROOT/scripts/steps.sh"
}

# key_settings NAME...: a line "NAME=VALUE" for each variable NAME, except
# the variables of KEY_IGNORE. Each NAME is a name in capitals of
# steps_code.
key_settings() (
    for ks in "$@"; do
        case " $KEY_IGNORE " in *" $ks "*) continue ;; esac
        eval "printf '%s=%s\n' \"\$ks\" \"\${$ks-}\""
    done
)

# key_files PATH...: the SHA-256 of each file of these paths that git
# knows, as the work tree has it. A PATH can have the patterns of git,
# for example c_src/cosmo/*.c. In a tree with no git (the source archive
# of a release), each file of these paths.
key_files() (
    cd "$ROOT"
    if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        git ls-files -z -- "$@" | xargs -0r sha256sum
    else
        set +f
        # shellcheck disable=SC2048,SC2086 # The patterns of the paths.
        find $* -type f 2> /dev/null | LC_ALL=C sort | tr '\n' '\0' | xargs -0r sha256sum
    fi
)

# step_roots STEP: the functions of the code of the step STEP, for
# steps_code. The step wasm_runtime also has the steps that
# wasm/erts/build.sh runs. These build only the NIFs of
# edge_hex_nif_packages, so not vix and no NIF of Rust.
step_roots() {
    case $1 in
        wasm_runtime) echo step_wasm_runtime step_hex_nifs step_nif_edge \
            -build_vix_nif -build_rust_nif ;;
        *) echo "step_$1" ;;
    esac
}

# step_files STEP: the files of this repository that the step STEP reads,
# as paths for git ls-files. "sh scripts/steps.sh check_keys" finds each
# path of ROOT in the code of a step that is not in its list.
# Caution: a file that a step starts to read must be in its list.
step_files() {
    case $1 in
        toolchain) echo "patches/cosmo/ape-m1.patch" ;;
        openssl|release) ;;
        otp) echo "patches/otp c_src/cosmo/*.c c_src/cosmo/*.h c_src/cosmo/sha1dc" ;;
        configure) echo "c_src/cosmo/erts_cosmo.h c_src/cosmo/noshared" ;;
        sqlite) echo "patches/esqlite" ;;
        nifs) echo "scripts/libvips.sh patches/libvips c_src/vips native/vips_resvg
                    scripts/pdfium.sh patches/pdfium c_src/rust scripts/rust_link.sh
                    c_src/erts_wasm/sqlite_vfs.c" ;;
        wasm) echo "c_src/wasm patches/wamr" ;;
        make) echo "c_src/cosmo/depcc" ;;
        elixir) echo "patches/elixir" ;;
        multicall) echo "patches/cosmo" ;;
        wasm_runtime) echo "wasm/erts c_src/erts_wasm c_src/wasm patches/otp patches/wamr" ;;
        bundle) echo "src priv licenses c_src/cosmo/*.inetrc c_src/wasm/include LICENSE NOTICE" ;;
        *) echo "step_files: no step $1" >&2
           return 1 ;;
    esac
}

# step_inputs STEP: the inputs of the step STEP, as text.
step_inputs() (
    set -f
    roots=$(step_roots "$1")
    files=$(step_files "$1")
    code=$(steps_code text $roots)
    settings=$(steps_code settings $roots | LC_ALL=C sort)
    values=$(key_settings $settings)
    sums=
    [ -z "$files" ] || sums=$(key_files $files)
    printf 'step %s\n%s\n%s\n%s\n' "$1" "$code" "$values" "$sums"
)

# step_key STEP: the key of the step STEP.
step_key() (
    inputs=$(step_inputs "$1")
    printf '%s\n' "$inputs" | sha256sum | cut -d' ' -f1
)

# write_keys STEP...: the key of each step STEP in BUILD/stamps/STEP.key,
# and its inputs in BUILD/stamps/STEP.inputs. A key is written again only
# when it changed, because the Makefile compares the times of these
# files. To see why a step runs again, compare its file of inputs with
# the output of "sh scripts/steps.sh inputs STEP" before the build.
write_keys() (
    mkdir -p "$BUILD/stamps"
    for wk in "$@"; do
        inputs=$(step_inputs "$wk")
        k=$(printf '%s\n' "$inputs" | sha256sum | cut -d' ' -f1)
        f=$BUILD/stamps/$wk
        if [ "$(cat "$f.key" 2>/dev/null)" != "$k" ]; then
            printf '%s\n' "$inputs" > "$f.inputs"
            echo "$k" > "$f.key.new"
            mv "$f.key.new" "$f.key"
        fi
    done
)

# The check of the lists of files: each path of ROOT in the code of a
# step must be in the list of the step (step_files). The code can give
# only the start of a path ("$ROOT/patches/otp/*.patch" gives
# patches/otp/), so a file of the list must start with it.
step_check_keys() (
    bad=0
    set -f
    for ck in $KEY_STEPS; do
        files=$(step_files "$ck")
        known=
        [ -z "$files" ] || known=$(cd "$ROOT" && git ls-files -- $files)
        code=$(steps_code text $(step_roots "$ck"))
        paths=$(printf '%s\n' "$code" |
            grep -o '\$[{]\{0,1\}ROOT[}]\{0,1\}"\{0,1\}/[A-Za-z0-9_./-]*' |
            sed 's#^[^/]*/##' | LC_ALL=C sort -u)
        for path in $paths; do
            if ! printf '%s\n' "$known" | awk -v p="$path" 'index($0, p) == 1 { f = 1 } END { exit !f }'; then
                echo "check_keys: the step $ck reads $path, which is not in step_files" >&2
                bad=1
            fi
        done
    done
    [ "$bad" = 0 ] || exit 1
    echo "check_keys: ok"
)

# The inputs of the WebAssembly runtime, as one SHA-256: the pinned
# versions, the settings that change it, the code of the step
# wasm_runtime (with the steps hex_nifs and nif_edge, which
# wasm/erts/build.sh runs), and its files. The cache of CI has this key,
# and the workflows find it before the build. So this key names its
# settings: a variable of the environment of the build, which the
# workflow does not have, must not change it.
wasm_runtime_inputs() (
    code=$(steps_code text $(step_roots wasm_runtime))
    files=$(key_files $(step_files wasm_runtime))
    {
        echo "OTP $OTP_VERSION $OTP_COMMIT OPENSSL $OPENSSL_VERSION $OPENSSL_COMMIT"
        echo "EMSDK $EMSDK_VERSION $EMSDK_COMMIT WAMR $WAMR_VERSION $WAMR_COMMIT"
        echo "HEX_NIFS $(edge_hex_nif_packages)$(use_exqlite && echo " exqlite")"
        echo "WASM_CFLAGS ${WASM_CFLAGS:-} EXTRA_LDFLAGS ${EXTRA_LDFLAGS:-} WASM64 ${WASM64:-0}"
        # The version and the SHA-256 of each package of HEX_NIFS.
        for p in $(edge_hex_nif_packages); do echo "$p $(hex_nif_recipe "$p")"; done
        if use_exqlite; then echo "exqlite $(hex_nif_recipe exqlite)"; fi
        printf '%s\n%s\n' "$code" "$files"
    } | sha256sum | cut -d' ' -f1
)

# The SHA-256 of wasm_runtime_inputs, for the cache key of the runtime in
# CI (the workflows). It needs no build.
step_wasm_runtime_key() {
    wasm_runtime_inputs
}

# The keys of the other caches of CI, as lines NAME=KEY for the file
# GITHUB_ENV of a workflow. They need no build.
#   PDFIUM_INPUTS   libpdfium.a (scripts/pdfium.sh).
#   LIBVIPS_INPUTS  libvips of VIX_PARTS (scripts/libvips.sh).
#   CCACHE_INPUTS   ccache of OTP: the files that change the objects.
step_cache_keys() {
    pdfium=$(key_files scripts/pdfium.sh patches/pdfium)
    libvips=$(key_files scripts/libvips.sh patches/libvips c_src/vips)
    ccache=$(key_files patches/otp c_src/cosmo)
    parts=$(printf '%s\n' $VIX_PARTS | LC_ALL=C sort -u | tr '\n' ' ')
    echo "PDFIUM_INPUTS=$(printf '%s\n' "$pdfium" | sha256sum | cut -d' ' -f1)"
    echo "LIBVIPS_INPUTS=$(printf '%s\n%s\n' "$parts" "$libvips" | sha256sum | cut -d' ' -f1)"
    echo "CCACHE_INPUTS=$(printf '%s\n' "$ccache" | sha256sum | cut -d' ' -f1)"
}

# The store of prebuilt parts (docs/BUILDING.md, "The store of parts"). A
# part is the output of a step, NAME-KEY.tar.xz, and KEY is the SHA-256
# of all its inputs: the same inputs give the same name, so a part never
# goes stale. The settings:
#
#   PARTS_URL   the address of the store with no "/" at the end, for
#               example the files of the release "parts". Empty: no store.
#   PARTS_PUT   an absolute directory for each part that a step built.
#               Empty: none. In CI, a later step with the token puts these
#               files in the store, so the build itself has no token.
#
# Caution: a part is code that goes into the files of beam.com. Only the
# workflows of main may put parts (custom-build.yml and
# custom-build-caches.yml), never a pull request.

# part_get NAME KEY DIR: unpack the part NAME-KEY into DIR. Status 1 when
# the store has no such part (or there is no store).
part_get() {
    [ -n "${PARTS_URL:-}" ] || return 1
    pg_file=$BUILD/parts/$1-$2.tar.xz
    mkdir -p "$BUILD/parts" "$3"
    if ! curl -fsSL --retry 3 -o "$pg_file.tmp" "$PARTS_URL/$1-$2.tar.xz" 2>/dev/null; then
        rm -f "$pg_file.tmp"
        return 1
    fi
    mv "$pg_file.tmp" "$pg_file"
    xz -dc "$pg_file" | tar -xf - -C "$3"
    rm -f "$pg_file"
    log "Using the part $1 of the store ($2)"
}

# part_put NAME KEY DIR PATH...: pack PATH... of DIR as the part NAME-KEY,
# in the directory PARTS_PUT.
part_put() {
    [ -n "${PARTS_PUT:-}" ] || return 0
    case $PARTS_PUT in
        /*) ;;
        *) echo "PARTS_PUT: an absolute directory, not $PARTS_PUT" >&2
           exit 1 ;;
    esac
    pp_name=$1 pp_key=$2 pp_dir=$3
    shift 3
    pp_file=$PARTS_PUT/$pp_name-$pp_key.tar.xz
    mkdir -p "$PARTS_PUT"
    log "Packing the part $pp_name for the store ($pp_key)"
    tar -cf - -C "$pp_dir" "$@" | xz -T0 -3 > "$pp_file.tmp"
    mv "$pp_file.tmp" "$pp_file"
}

# The key of the NIF of the package $1 (step_nifs): its recipe, the NIF
# API of this OTP (the headers that the NIF reads), cosmocc, the code that
# builds it (build_hex_nif and fetch_hex, with each function that they
# call), and its settings and files. Not the OTP version: a NIF of the
# same API works with each version of OTP 29. The key names its settings,
# so a setting of another NIF does not change it.
nif_part_key() (
    t=$(target)
    code=$(steps_code text build_hex_nif fetch_hex)
    case $1 in
        vix) files=$(key_files scripts/libvips.sh patches/libvips c_src/vips native/vips_resvg \
                 c_src/rust scripts/rust_link.sh) ;;
        ex_pdfium) files=$(key_files scripts/pdfium.sh patches/pdfium c_src/rust scripts/rust_link.sh) ;;
        *) files=
           [ -z "$(rust_nif_crate "$1")" ] || files=$(key_files c_src/rust scripts/rust_link.sh) ;;
    esac
    {
        echo "nif $1 $(hex_nif_recipe "$1")"
        echo "COSMOCC $COSMOCC_VERSION $COSMOCC_SHA256 RUST_NIGHTLY ${RUST_NIGHTLY:-}"
        for h in erts/emulator/beam/erl_nif.h erts/emulator/beam/erl_nif_api_funcs.h \
                 erts/emulator/beam/erl_drv_nif.h "erts/include/$t/erl_int_sizes_config.h"; do
            echo "$h $(sha256sum "$ERL_TOP/$h" | cut -d' ' -f1)"
        done
        case $1 in
            vix) echo "VIX_PARTS $(printf '%s\n' $VIX_PARTS | sort -u | tr '\n' ' ') LIBVIPS ${LIBVIPS:-}" ;;
            ex_pdfium) echo "PDFIUM ${PDFIUM:-}" ;;
        esac
        echo "RUST_SHIM_SYMS $RUST_SHIM_SYMS"
        printf '%s\n%s\n' "$code" "$files"
    } | sha256sum | cut -d' ' -f1
)

# The key of the built OTP tree (the steps otp, configure and make): the
# versions, the settings of the configure and of the build, the code of
# the three steps, the files that change each object (patches/otp,
# erts_cosmo.h, noshared, depcc), and the path of the tree, which its
# Makefiles hold. The other files of c_src/cosmo go into the step
# multicall, which compiles them again.
otp_part_key() (
    code=$(steps_code text step_otp step_configure step_make)
    files=$(key_files patches/otp c_src/cosmo/erts_cosmo.h c_src/cosmo/noshared c_src/cosmo/depcc)
    {
        echo "OTP $OTP_VERSION $OTP_COMMIT OPENSSL $OPENSSL_VERSION $OPENSSL_COMMIT"
        echo "COSMOCC $COSMOCC_VERSION $COSMOCC_SHA256 CC $CC CXX $CXX AR $AR"
        echo "JIT $JIT CCACHE ${CCACHE:-0} BUILD $BUILD ERL_TOP $ERL_TOP"
        echo "EXTRA_APPS $EXTRA_APPS"
        echo "SRC_APPS $(printf '%s\n' $SRC_APPS | sort -u | tr '\n' ' ')"
        printf '%s\n%s\n' "$code" "$files"
    } | sha256sum | cut -d' ' -f1
)

# The key of the built Elixir (the step elixir): its version, its
# patches, its code, and the OTP that compiled it.
elixir_part_key() (
    code=$(steps_code text step_elixir)
    files=$(key_files patches/elixir)
    otp=$(otp_part_key)
    {
        echo "ELIXIR $ELIXIR_VERSION $ELIXIR_COMMIT OTP $otp"
        printf '%s\n%s\n' "$code" "$files"
    } | sha256sum | cut -d' ' -f1
)

# The NIF packages of this build as native NIF objects (docs/NIFS.md):
# "PACKAGE VERSION LIB FILE" on each line. LIB.a is the archive of the NIF
# part, and FILE is the object in the priv directory of the package, with
# no suffix: LIB for an elixir_make package (vix), native/libLIB for a
# crate of Rustler, where Rustler loads it. For the job Build of
# build.yml.
step_nif_recipes() (
    for p in $(hex_nif_packages); do
        set -- $(hex_nif_recipe "$p")
        if [ -n "$(rust_nif_crate "$p")" ]; then
            echo "$p $1 $3 native/lib$3"
        else
            echo "$p $1 $3 $3"
        fi
    done
)

# The key of each part of this build, one "NAME KEY" on each line (for
# the logs of CI). It needs the steps otp and configure: the NIF keys read
# the headers of the OTP tree.
step_part_keys() (
    k=$(otp_part_key)
    echo "otp $k"
    if [ "$ELIXIR" = 1 ]; then
        k=$(elixir_part_key)
        echo "elixir $k"
    fi
    for p in $(hex_nif_packages); do
        k=$(nif_part_key "$p")
        echo "nif-$p $k"
    done
)

# 1 when the build uses a store (PARTS_URL) and the OTP tree is a part
# with the key of this build: the steps configure and make then have
# nothing to do. Without a store, make runs as before, so a change in
# the tree by hand is built.
otp_from_part() {
    [ -n "${PARTS_URL:-}" ] &&
        [ "$(cat "$ERL_TOP/.beam_com_part" 2>/dev/null)" = "$(otp_part_key)" ]
}

# The WebAssembly runtime of --target wasm32 (Cloudflare Workers): ERTS
# built with Emscripten (wasm/erts/build.sh, the variant for Workers), from
# a clone of the same OTP, with this build of OTP as its bootstrap. The
# step bundle puts it in the zip (WASM_RUNTIME).
step_wasm_runtime() {
    [ "${WASM_RUNTIME:-}" = none ] && return 0
    # A runtime of the same inputs (for example from the cache of CI)
    # stays. Its file "inputs" has the SHA-256 of wasm_runtime_inputs.
    inputs=$(wasm_runtime_inputs)
    out=$BUILD/wasm-runtime
    if [ -f "$out/beam.wasm" ] && [ -f "$out/beam.mjs" ] && [ -f "$out/nifs" ] &&
        [ "$(cat "$out/inputs" 2>/dev/null)" = "$inputs" ]; then
        log "Using the WebAssembly runtime in $out (the same inputs)"
        return 0
    fi
    rm -f "$out/inputs"
    emsdk=${EMSDK:-$BUILD/emsdk}
    if [ ! -x "$emsdk/upstream/emscripten/emcc" ]; then
        log "Installing emsdk $EMSDK_VERSION"
        [ -d "$emsdk" ] || git clone -q --depth 1 --branch "$EMSDK_VERSION" \
            https://github.com/emscripten-core/emsdk.git "$emsdk"
        check_commit "$emsdk" "$EMSDK_COMMIT" "emsdk $EMSDK_VERSION"
        "$emsdk/emsdk" install "$EMSDK_VERSION" > "$BUILD/emsdk.log" 2>&1
        "$emsdk/emsdk" activate "$EMSDK_VERSION" >> "$BUILD/emsdk.log" 2>&1
    fi
    log "Building the WebAssembly runtime"
    EMSDK=$emsdk BOOTSTRAP=$ERL_TOP OUT=$BUILD/wasm OTP_VERSION=$OTP_VERSION \
        OTP_COMMIT=$OTP_COMMIT OPENSSL_VERSION=$OPENSSL_VERSION OPENSSL_COMMIT=$OPENSSL_COMMIT \
        WASM_NODE=0 WORKER=1 WORKER_ROOTFS=none \
        WORKER_OUT=$BUILD/wasm-runtime BUILD=$BUILD \
        HEX_NIFS="$(edge_hex_nif_packages)$(use_exqlite && echo " exqlite")" \
        "$ROOT/wasm/erts/build.sh"
    echo "$inputs" > "$out/inputs"
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
    if otp_from_part; then
        log "Using the built OTP of the store"
        return 0
    fi
    log "Building OTP (small build)"
    cd "$ERL_TOP"
    # cosmocc does not support "-MM" with many input files. depcc runs
    # it once for each file.
    check_static_nifs
    nifs=$(static_nifs)
    DEPCC_CC=$CC make -j"$JOBS" OTP_SMALL_BUILD=true \
        DEP_CC="$ROOT/c_src/cosmo/depcc" ${nifs:+"STATIC_NIFS=$nifs"}
    for app in $EXTRA_APPS; do
        log "Building $app"
        PATH=$ERL_TOP/bootstrap/bin:$PATH DEPCC_CC=$CC \
            make -C "lib/$app" opt DEP_CC="$ROOT/c_src/cosmo/depcc"
    done
    for app in $SRC_APPS; do
        log "Building $app (Erlang code)"
        PATH=$ERL_TOP/bootstrap/bin:$PATH make -C "lib/$app/src" opt
    done
    if [ -n "${PARTS_PUT:-}" ]; then
        key=$(otp_part_key)
        echo "$key" > "$ERL_TOP/.beam_com_part"
        part_put otp "$key" "$(dirname "$ERL_TOP")" "$(basename "$ERL_TOP")"
    fi
}

# build_cosmo_file NAME SHA256 OBJECT: libc/calls/NAME.c of Cosmopolitan at
# the tag COSMOCC_VERSION, with patches/cosmo/NAME.patch, in OBJECT. The
# object defines the symbols of NAME.o of libcosmo.a, so the linker does
# not take that object. The flags are those of the build of Cosmopolitan.
#   pledge-linux  pledge() of Linux, with the options of sockets that inet
#                 sets and reads (C47 of docs/UPSTREAM.md). It defines
#                 kPledge and sys_pledge_linux.
#   unveil        unveil() of Linux, which also controls the removal of a
#                 file and of a directory (C50). It defines unveil,
#                 sys_unveil_linux and init_landlock_version.
build_cosmo_file() {
    src=$BUILD/cosmo-$1-$COSMOCC_VERSION
    # The mark has the SHA-256 of the patch, so a new patch applies again.
    patch_sum=$(sha256sum "$ROOT/patches/cosmo/$1.patch" | cut -d' ' -f1)
    if [ "$(cat "$src/.beam_com_patched" 2>/dev/null)" != "$patch_sum" ]; then
        rm -rf "$src"
        mkdir -p "$src/libc/calls"
        curl -fsSL -o "$src/libc/calls/$1.c" \
            "https://raw.githubusercontent.com/jart/cosmopolitan/$COSMOCC_VERSION/libc/calls/$1.c"
        check_sha256 "$src/libc/calls/$1.c" "$2" \
            "libc/calls/$1.c of Cosmopolitan $COSMOCC_VERSION"
        patch -p1 -d "$src" < "$ROOT/patches/cosmo/$1.patch"
        echo "$patch_sum" > "$src/.beam_com_patched"
    fi
    "$CC" -std=gnu23 -D_COSMO_SOURCE -Os -ffreestanding -fno-omit-frame-pointer \
        -c "$src/libc/calls/$1.c" -o "$3"
}

step_multicall() {
    log "Linking the multi-call emulator"
    t=$(target)
    objdir=obj/$t/opt/$FLAVOR
    cd "$ERL_TOP/erts/emulator"
    objs="$objdir/beam_com.o $objdir/beam_com_child_setup.o $objdir/beam_com_inet_gethost.o"
    objs="$objs $objdir/beam_com_epmd.o $objdir/beam_com_epmd_srv.o $objdir/beam_com_epmd_cli.o"
    objs="$objs $objdir/beam_com_watch.o $objdir/beam_com_agent.o $objdir/beam_com_net.o"
    objs="$objs $objdir/beam_com_fs.o $objdir/beam_com_pipe.o $objdir/beam_com_sha1dc.o"
    objs="$objs $objdir/beam_com_seatbelt.o $objdir/beam_com_nif.o $objdir/beam_com_nif_syms.o"
    make -f "$t/Makefile" TYPE=opt FLAVOR=$FLAVOR $objs
    build_cosmo_file pledge-linux "$COSMO_PLEDGE_SHA256" "$objdir/beam_com_pledge.o"
    build_cosmo_file unveil "$COSMO_UNVEIL_SHA256" "$objdir/beam_com_unveil.o"
    objs="$objs $objdir/beam_com_pledge.o $objdir/beam_com_unveil.o"
    rm -f "$ERL_TOP/bin/$t/beam.$FLAVOR"
    # The table of static NIFs depends on STATIC_NIFS, and make does not
    # know it (neither for driver_tab.c nor for its object).
    rm -f "$t/opt/$FLAVOR/driver_tab.c" "$objdir/driver_tab.o"
    nifs=$(static_nifs)
    # --wrap=close, --wrap=mkdir and --wrap=chown: see __wrap_close(),
    # __wrap_mkdir() and __wrap_chown() in c_src/cosmo/beam_com.c. The
    # wraps of LIBC_WRAPS are in c_src/cosmo/beam_com_libc.h, and the
    # wraps of NET_WRAPS (--allow-net=HOST,...) in beam_com_net.c, and
    # the wraps of FS_WRAPS (the paths on Windows) in beam_com_fs.c, and
    # the wrap of MAC_WRAPS (getcwd() in Seatbelt) in beam_com_seatbelt.c,
    # and the wraps of PIPE_WRAPS (pipes on Windows) in beam_com_pipe.c.
    make -f "$t/Makefile" TYPE=opt FLAVOR=$FLAVOR \
        EMU_LDFLAGS="$objs -Wl,--wrap=close -Wl,--wrap=mkdir -Wl,--wrap=chown $LIBC_WRAPS $NET_WRAPS $FS_WRAPS $MAC_WRAPS $PIPE_WRAPS" \
        ${nifs:+"STATIC_NIFS=$nifs"} "$ERL_TOP/bin/$t/beam.$FLAVOR"
}

# Elixir, compiled with the Erlang/OTP of this build (its erl and erlc
# run on the build machine).
step_elixir() {
    [ "$ELIXIR" = 1 ] || return 0
    src=$BUILD/elixir-$ELIXIR_VERSION
    if [ -n "${PARTS_URL:-}${PARTS_PUT:-}" ]; then
        key=$(elixir_part_key)
        if [ -n "${PARTS_URL:-}" ] && [ "$(cat "$src/.beam_com_part" 2>/dev/null)" = "$key" ]; then
            log "Using the built Elixir of the store"
            return 0
        fi
        rm -rf "$src.part"
        if part_get elixir "$key" "$src.part"; then
            rm -rf "$src"
            mv "$src.part/$(basename "$src")" "$src"
            rm -rf "$src.part"
            echo "$key" > "$src/.beam_com_part"
            return 0
        fi
        rm -rf "$src.part"
    fi
    log "Building Elixir $ELIXIR_VERSION"
    if [ ! -d "$src/.git" ]; then
        rm -rf "$src"
        git clone -q --depth 1 --branch "v$ELIXIR_VERSION" \
            https://github.com/elixir-lang/elixir.git "$src"
    fi
    check_commit "$src" "$ELIXIR_COMMIT" "Elixir $ELIXIR_VERSION"
    if [ ! -f "$src/.beam_com_patched" ]; then
        log "Applying the patches of Elixir"
        for p in "$ROOT"/patches/elixir/*.patch; do
            echo "  $p"
            git -C "$src" apply "$p"
        done
        touch "$src/.beam_com_patched"
    fi
    (cd "$src" && PATH="$ERL_TOP/bin:$PATH" make compile)
    if [ -n "${PARTS_PUT:-}" ]; then
        echo "$key" > "$src/.beam_com_part"
        part_put elixir "$key" "$BUILD" "$(basename "$src")"
    fi
}

step_release() {
    log "Installing a release tree in $RELEASE"
    cd "$ERL_TOP"
    rm -rf "$RELEASE"
    make release RELEASE_ROOT="$RELEASE" OTP_SMALL_BUILD=true
    (cd "$RELEASE" && ./Install -minimal "$RELEASE" >/dev/null)
}

# Stop when an application of the zip needs (in the applications of its
# .app file) an application of OTP_OMIT.
check_omitted_apps() {
    [ -n "$OTP_OMIT" ] || return 0
    for app in $BUNDLE_APPS; do
        needs=$(tr -d '\n' < "$ERL_TOP/lib/$app/ebin/$app.app" |
            sed -n 's/.*{applications, *\[\([^]]*\)\].*/\1/p' | tr -d ' \t' | tr , ' ')
        for need in $needs; do
            case " $OTP_OMIT " in
                *" $need "*) echo "OTP_OMIT: $app needs $need" >&2
                             exit 1 ;;
            esac
        done
    done
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
    cp "$ROOT/c_src/cosmo/windows.inetrc" "$ROOT/c_src/cosmo/sandbox.inetrc" "$STAGE/bin/"
    check_omitted_apps
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
        # The style sheet of the HTML pages of cover (tools).
        if [ -f "$src/priv/styles.css" ]; then
            mkdir -p "$STAGE/lib/$app-$vsn/priv"
            cp "$src/priv/styles.css" "$STAGE/lib/$app-$vsn/priv/"
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
    # applications that it uses, without docs. A protocol (a module with
    # __protocol__/1) keeps its debug information: the consolidation of
    # Mix reads it, else it fails with missing_chunk.
    if [ "$ELIXIR" = 1 ]; then
        for app in $ELIXIR_APPS; do
            src=$BUILD/elixir-$ELIXIR_VERSION/lib/$app/ebin
            vsn=$(sed -n 's/.*{vsn, *"\([^"]*\)".*/\1/p' "$src/$app.app")
            mkdir -p "$STAGE/lib/$app-$vsn/ebin"
            cp "$src"/*.beam "$src/$app.app" "$STAGE/lib/$app-$vsn/ebin/"
        done
        "$ERL_TOP/bin/erl" -noshell -eval "
            Fs = [F || A <- string:lexemes(\"$ELIXIR_APPS\", \" \"), F <- filelib:wildcard(\"$STAGE/lib/\" ++ A ++ \"-*/ebin/*.beam\")],
            Protocol = fun(F) -> {ok, {_, [{exports, E}]}} = beam_lib:chunks(F, [exports]), lists:member({'__protocol__', 1}, E) end,
            {Protocols, Others} = lists:partition(Protocol, Fs),
            {ok, _} = beam_lib:strip_files(Others, [\"Attr\", \"Docs\"]),
            {ok, _} = beam_lib:strip_files(Protocols, [\"Attr\", \"Docs\", \"Dbgi\"]),
            halt()."
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

    # rebar3 (REBAR3=1, a custom build): REBAR3_VERSION, an escript,
    # as bin/rebar3. beam.com runs it as the tool rebar3 (rebar3.com, or
    # "beam.com rebar3"), and gives it to mix (MIX_REBAR3).
    if [ "$REBAR3" = 1 ]; then
        curl -fsSL -o "$STAGE/bin/rebar3" \
            "https://github.com/erlang/rebar3/releases/download/$REBAR3_VERSION/rebar3"
        check_sha256 "$STAGE/bin/rebar3" "$REBAR3_SHA256" "rebar3 $REBAR3_VERSION"
    fi

    # WebAssembly: the wasm application (its NIF is in the emulator).
    if [ "$WASM" = 1 ]; then
        mkdir -p "$STAGE/lib/wasm-0.1.0/ebin"
        "$ERL_TOP/bin/erlc" -o "$STAGE/lib/wasm-0.1.0/ebin" "$ROOT"/src/wasm/*.erl
        cp "$ROOT/src/wasm/wasm.app.src" "$STAGE/lib/wasm-0.1.0/ebin/wasm.app"
        # The headers of a NIF library in WebAssembly, for
        # "beam.com --nif-include" (docs/NIFS.md): those of ERTS, with
        # patches/otp/0003-wasm-nif.patch, and the C types of wasm32.
        mkdir -p "$STAGE/lib/wasm-0.1.0/priv/include"
        cp "$ERL_TOP/erts/emulator/beam/erl_nif.h" \
           "$ERL_TOP/erts/emulator/beam/erl_nif_api_funcs.h" \
           "$ERL_TOP/erts/emulator/beam/erl_drv_nif.h" \
           "$ROOT/c_src/wasm/include/erl_int_sizes_config.h" \
           "$STAGE/lib/wasm-0.1.0/priv/include/"
    fi

    # The commands of beam.com (lib/beam_com has no version, so that
    # beam_com.c can find it), and the runner of one-file programs.
    # BEAM_COM_SHA1DC: the file has the helper git_sha1dc, so the git
    # client always checks the objects (beam_com_git).
    mkdir -p "$STAGE/lib/beam_com/ebin" "$STAGE/lib/beam_com_script-0.1.0/ebin"
    "$ERL_TOP/bin/erlc" -DBEAM_COM_SHA1DC -o "$STAGE/lib/beam_com/ebin" "$ROOT"/src/beam_com/*.erl
    # The .app file gets the full version of OTP, and the Elixir packages
    # whose NIFs are linked ([{exqlite, "0.41.0"}, ...]).
    nifs=$(hex_nifs | awk '{printf "%s{%s, \"%s\"}", (NR > 1 ? ", " : ""), $1, $2}')
    sed -e "s/{otp_version, \"\"}/{otp_version, \"$OTP_VERSION\"}/" \
        -e "s/{nifs, \[\]}/{nifs, [$nifs]}/" \
        "$ROOT/src/beam_com/beam_com.app.src" \
        > "$STAGE/lib/beam_com/ebin/beam_com.app"
    # The NIF libraries in WebAssembly of Elixir packages
    # (scripts/lazy_html.sh), which beam_com_make copies.
    mkdir -p "$STAGE/lib/beam_com/priv"
    cp -R "$ROOT/priv/nifs" "$STAGE/lib/beam_com/priv/"
    # The warning of --allow-net=*.DOMAIN (beam_com_build:net_shared/2).
    cp "$ROOT/priv/public_suffix_list.dat" "$STAGE/lib/beam_com/priv/"
    "$ERL_TOP/bin/erlc" -o "$STAGE/lib/beam_com_script-0.1.0/ebin" \
        "$ROOT"/src/beam_com_script/*.erl
    cp "$ROOT/src/beam_com_script/beam_com_script.app.src" \
       "$STAGE/lib/beam_com_script-0.1.0/ebin/beam_com_script.app"
    # The reload of new code in a program (beam_com_reload): each program
    # keeps lib/beam_com_reload (no version, so that beam_com.c can find
    # it), and beam_com.c starts it.
    mkdir -p "$STAGE/lib/beam_com_reload/ebin"
    "$ERL_TOP/bin/erlc" -o "$STAGE/lib/beam_com_reload/ebin" "$ROOT"/src/beam_com_reload/*.erl
    cp "$ROOT/src/beam_com_reload/beam_com_reload.app.src" \
       "$STAGE/lib/beam_com_reload/ebin/beam_com_reload.app"

    # The host of the WebAssembly runtime (--target wasm32): Erlang code
    # that a Worker release gets, and the files of the Workers. With
    # WASM_RUNTIME=dir (beam.wasm and beam.mjs of wasm/erts/build.sh,
    # WORKER=1), the runtime too (5 MB).
    wh=$STAGE/lib/wasm_host-0.1.0
    # The hosts of worker.js: Workers (priv/worker), Deno (priv/deno) and a
    # web page (priv/browser), and the static site of an app (priv/page).
    mkdir -p "$wh/ebin" "$wh/priv"
    "$ERL_TOP/bin/erlc" -o "$wh/ebin" "$ROOT"/src/wasm_host/*.erl
    cp "$ROOT/src/wasm_host/wasm_host.app.src" "$wh/ebin/wasm_host.app"
    for host in worker deno browser page; do
        rm -rf "$wh/priv/$host"
        cp -R "$ROOT/priv/wasm_host/$host" "$wh/priv/$host"
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
    cp "$ROOT/LICENSE" "$ROOT"/licenses/*.txt "$STAGE/licenses/"
    # NOTICE names the default versions of Erlang/OTP, OpenSSL and
    # Elixir. A build of other versions (OTP_VERSION, OPENSSL_VERSION,
    # ELIXIR_VERSION) names its versions.
    sed -e "s|^Erlang/OTP [0-9][0-9.]* (|Erlang/OTP $OTP_VERSION (|" \
        -e "s|^OpenSSL [0-9][0-9.]* (|OpenSSL $OPENSSL_VERSION (|" \
        -e "s|^  Erlang/OTP [0-9][0-9.]* and OpenSSL [0-9][0-9.]*,|  Erlang/OTP $OTP_VERSION and OpenSSL $OPENSSL_VERSION,|" \
        -e "s|^Elixir [0-9][0-9.]* (|Elixir $ELIXIR_VERSION (|" \
        "$ROOT/NOTICE" > "$STAGE/licenses/NOTICE"
    cp "$ERL_TOP"/LICENSES/*.txt "$STAGE/licenses/otp/"
    # The NIF of ex_pdfium has PDFium and its third-party code: their
    # license texts, from scripts/pdfium.sh.
    if hex_nif_packages | grep -qw ex_pdfium; then
        mkdir -p "$STAGE/licenses/pdfium"
        cp "$HEXNIFS/static/licenses-pdfium"/* "$STAGE/licenses/pdfium/"
    fi
    # The license texts of the Elixir source (LICENSES/), when Elixir is
    # in the zip.
    if [ "$ELIXIR" = 1 ] && [ -d "$BUILD/elixir-$ELIXIR_VERSION/LICENSES" ]; then
        mkdir -p "$STAGE/licenses/elixir"
        cp "$BUILD/elixir-$ELIXIR_VERSION"/LICENSES/* "$STAGE/licenses/elixir/"
    fi

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

# The tests of the Mix project (mix.exs, tests/): the ExUnit tests of the
# Erlang code, and the tests of the JavaScript of the WebAssembly host
# (Node.js 20.6 or later). They run with coverage (cover, of the
# application tools) on the beam.com of the build: "beam.com mix", so
# that the name of the file is beam.com, as the tests expect. The links
# in unit-bin are the programs that the tests and the dependencies start
# (elixir, escript).
step_unit() {
    log "Running the tests of the Mix project with $OUT"
    [ -f "$OUT" ] || { echo "No $OUT: run make first" >&2; exit 1; }
    bin=$BUILD/unit-bin
    rm -rf "$bin"
    mkdir -p "$bin"
    for t in elixir escript; do ln -s "$OUT" "$bin/$t"; done
    (
        cd "$ROOT"
        export PATH="$bin:$PATH"
        export MIX_HOME="$BUILD/mix-home-test" HEX_HOME="$BUILD/hex-home-test"
        export MIX_BUILD_ROOT="$BUILD/mix" MIX_DEPS_PATH="$BUILD/deps"
        export LC_ALL=C.UTF-8 MIX_ENV=test
        # The differential test (tests/wasm_diff_test.exs) runs when the
        # build has the WebAssembly runtime (the step wasm_runtime).
        if [ -f "$BUILD/wasm-runtime/beam.wasm" ]; then
            export BEAM_COM_WASM_RUNTIME="$BUILD/wasm-runtime"
        fi
        # The tests of tests/check_format.sh use the beam.com of the build.
        if [ -x "$COSMOCC/bin/assimilate" ]; then
            export BEAM_COM_FORMAT_FILE="$OUT" COSMOCC
        fi
        "$OUT" mix local.hex --force --if-missing
        "$OUT" mix local.rebar --force --if-missing
        "$OUT" mix deps.get
        "$OUT" mix compile --warnings-as-errors
        "$OUT" mix format --check-formatted
        "$OUT" mix test --cover
        # The tests of the studio (examples/studio): the import rewrite.
        cd examples/studio
        MIX_BUILD_ROOT="$BUILD/mix-studio" MIX_DEPS_PATH="$BUILD/deps-studio" "$OUT" mix deps.get
        MIX_BUILD_ROOT="$BUILD/mix-studio" MIX_DEPS_PATH="$BUILD/deps-studio" "$OUT" mix test
    )
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
    # The APE loader of x86_64 in the files can be read (fix_ape_loader,
    # C49 of docs/UPSTREAM.md).
    log "Checking the APE loader of x86_64 in $OUT and in a program"
    check_ape_loader "$OUT"
    check_ape_loader "$BUILD/hashsum.com"
    # The program keeps the code of kernel and stdlib stored (step_bundle).
    unzip -v "$BUILD/hashsum.com" | grep -q ' Stored .* lib/kernel-[^/]*/ebin/code.beam$'
    unzip -v "$BUILD/hashsum.com" | grep -q ' Stored .* lib/stdlib-[^/]*/ebin/lists.beam$'
    # beam.com and the program keep the license texts (step_bundle).
    unzip -l "$OUT" | grep -q ' licenses/NOTICE$'
    unzip -l "$OUT" | grep -q ' licenses/otp/MIT.txt$'
    unzip -l "$OUT" | grep -q ' licenses/sha1collisiondetection.txt$'
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
    # The functions of the libc at the edges of a mapping
    # (tests/cosmo/libc_edges.c): first as the libc has them, for the log
    # (a new cosmocc can make a wrap unnecessary), then with the wraps of
    # the emulator, which must not fault.
    if [ "$CC" = cosmocc ]; then
        log "Checking the functions of the libc at the edges of a mapping"
        cosmocc -O2 -fno-builtin -o "$BUILD/libc_edges.com" "$ROOT/tests/cosmo/libc_edges.c"
        "$BUILD/libc_edges.com"
        # shellcheck disable=SC2086 # LIBC_WRAPS is a list of flags.
        cosmocc -O2 -fno-builtin -DBEAM_COM_LIBC_WRAPS $LIBC_WRAPS \
            -o "$BUILD/libc_edges_wrap.com" "$ROOT/tests/cosmo/libc_edges.c"
        "$BUILD/libc_edges_wrap.com" | tee "$BUILD/test.out"
        grep -q '^results: ok$' "$BUILD/test.out"
        grep -q '^functions with a fault: 0$' "$BUILD/test.out"
        # The parts of the host list of --allow-net that need no network
        # (c_src/cosmo/beam_com_net.c): tests/run.sh has the rest.
        log "Checking the host list of --allow-net"
        cosmocc -O2 -Wno-unused-function -o "$BUILD/net_check.com" "$ROOT/tests/cosmo/net_check.c"
        "$BUILD/net_check.com" | tee "$BUILD/test.out"
        grep -q '^net_check: ok$' "$BUILD/test.out"
        # The check of the paths of Windows (c_src/cosmo/beam_com_fs.c).
        log "Checking the paths of the sandbox of Windows"
        cosmocc -O2 -Wno-unused-function -o "$BUILD/fs_check.com" "$ROOT/tests/cosmo/fs_check.c"
        "$BUILD/fs_check.com" | tee "$BUILD/test.out"
        grep -q '^fs_check: ok$' "$BUILD/test.out"
        # The writes to a non-blocking pipe (c_src/cosmo/beam_com_pipe.c).
        # Here only the data; tests/run.ps1 runs the check on Windows.
        log "Checking the writes to a non-blocking pipe"
        cosmocc -O2 -Wno-unused-function -o "$BUILD/pipe_check.com" "$ROOT/tests/cosmo/pipe_check.c"
        "$BUILD/pipe_check.com" | tee "$BUILD/test.out"
        grep -q '^pipe_check: ok$' "$BUILD/test.out"
        # The SHA-1 check of the git client (c_src/cosmo/beam_com_sha1dc.c),
        # with the vectors of the SHA-1 collisions. tests/run.sh and
        # tests/run.ps1 run the helper of beam.com on each system.
        log "Checking the SHA-1 check of the git client"
        cosmocc -O2 -Wall -Wno-unused-function -o "$BUILD/sha1dc_check.com" \
            "$ROOT/tests/cosmo/sha1dc_check.c"
        "$BUILD/sha1dc_check.com" "$ROOT/tests/programs/sha1dc_vectors.txt" | tee "$BUILD/test.out"
        grep -q '^sha1dc_check: ok$' "$BUILD/test.out"
        # The profile of the sandbox of macOS (c_src/cosmo/beam_com_seatbelt.c).
        log "Checking the profile of the sandbox of macOS"
        cosmocc -O2 -o "$BUILD/seatbelt_check.com" "$ROOT/tests/cosmo/seatbelt_check.c"
        "$BUILD/seatbelt_check.com" | tee "$BUILD/test.out"
        grep -q '^seatbelt_check: ok$' "$BUILD/test.out"
        # The loader of native NIF objects (c_src/cosmo/beam_com_nif.c),
        # with its test objects for both CPUs. tests/run.sh loads a NIF
        # object in a program on each system.
        log "Checking the loader of native NIF objects"
        # A NIF_LIBC name of the table must not be an IFUNC symbol of the
        # libc (beam_com_nif_libc.h): its address breaks each call of it.
        bin=$(dirname "$(command -v cosmocc)")
        for arch in x86_64 aarch64; do
            "$bin/$arch-linux-cosmo-nm" "$bin/../$arch-linux-cosmo/lib/libcosmo.a" 2>/dev/null |
                awk '$2 == "i" { print $3 }'
        done | sort -u > "$BUILD/nif_ifunc.txt"
        ifunc=$(sed -n 's/^NIF_LIBC(\(.*\))$/\1/p' "$ROOT/c_src/cosmo/beam_com_nif_libc.h" \
            "$ROOT/c_src/cosmo/beam_com_nif_cxx.h" | grep -xF -f "$BUILD/nif_ifunc.txt" || true)
        if [ -n "$ifunc" ]; then
            echo "IFUNC symbols in c_src/cosmo/beam_com_nif_libc.h (use NIF_LIBC_IFUNC):" $ifunc >&2
            exit 1
        fi
        sh "$ROOT/tests/cosmo/nif_load_objs.sh" "$BUILD/nif_load"
        cosmocc -O2 -Wall -Wno-unused-function -I"$BUILD/nif_load" \
            -o "$BUILD/nif_load_check.com" "$ROOT/tests/cosmo/nif_load_check.c"
        "$BUILD/nif_load_check.com" | tee "$BUILD/test.out"
        grep -q '^nif_load_check: ok$' "$BUILD/test.out"
        # The names that a native NIF object needs (tests/cosmo/nif_needs.c),
        # with the table of the program: none for native_nif_check, one for
        # its object missing.x86_64.o. CI runs it on the NIF parts of the
        # store (build.yml).
        log "Checking the names that a native NIF object needs"
        cosmocc -O2 -Wall -Wno-unused-function -I"$ERL_TOP/erts/emulator/beam" \
            -o "$BUILD/nif_needs.com" "$ROOT/tests/cosmo/nif_needs.c"
        priv=$ROOT/tests/programs/native_nif_check/priv
        "$BUILD/nif_needs.com" "$priv/native_nif_check.x86_64.o" | tee "$BUILD/test.out"
        grep -q ': ok$' "$BUILD/test.out"
        if "$BUILD/nif_needs.com" "$priv/missing.x86_64.o" > "$BUILD/test.out"; then
            echo "nif_needs: missing.x86_64.o gave no missing name" >&2
            exit 1
        fi
        cat "$BUILD/test.out"
        grep -q ': no no_such_function$' "$BUILD/test.out"
    fi
}

if [ $# -eq 0 ]; then
    set -- toolchain openssl otp configure sqlite nifs wasm make elixir release \
        multicall wasm_runtime bundle test unit
fi
# "keys STEP...": write the key of each step for the Makefile. "key
# STEP...": print the key of each step, one "STEP KEY" on each line.
# "inputs STEP": print the inputs of the step.
case $1 in
    inputs)
        step_inputs "$2"
        exit 0 ;;
    keys)
        shift
        write_keys "$@"
        exit 0 ;;
    key)
        shift
        for s in "$@"; do
            k=$(step_key "$s")
            echo "$s $k"
        done
        exit 0 ;;
esac
mkdir -p "$BUILD"
for s in "$@"; do
    "step_$s"
done
