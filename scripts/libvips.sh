#!/bin/sh
# libvips and the libraries that it needs, as static libraries of cosmocc,
# for the NIF of vix (EXTRA_NIFS=vix, see build_vix_nif in steps.sh).
# Usage: scripts/libvips.sh [OUT]
#   OUT: the directory of the result (default $BUILD/libvips): OUT/x86_64
#   and OUT/aarch64, each with include/, lib/ and lib/pkgconfig/.
# Needs: cosmocc ($COSMOCC, default build/cosmocc), meson, ninja, cmake,
# nasm (the SIMD code of libjpeg-turbo on x86_64), pkg-config, curl, git
# and python3.
#
# The versions are those of sharp-libvips (the libvips of vix 0.42.0),
# with the SIMD code of zlib-ng, libjpeg-turbo, libwebp, Highway and aom,
# JPEG from libjpeg-turbo, and only the formats JPEG, PNG, WebP, GIF, PPM
# and AVIF (HEIF with AV1), and ICC transforms (lcms2). Each CPU is built
# alone, because the headers of glib and libffi differ. aarch64 is a cross
# build: no test program runs.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${BUILD:-$ROOT/build}
COSMOCC=${COSMOCC:-$BUILD/cosmocc}
OUT=${1:-$BUILD/libvips}
SRC=$BUILD/libvips-src
JOBS=${JOBS:-4}

log() { printf '\n==> %s\n' "$*"; }

# The downloads: NAME SHA-256 URL.
DOWNLOADS="
expat-2.8.5.tar.xz 1e727b8933ec51a77a9a9d9afcf8e688bce45d907c13e36ab7393fe36e703182 https://github.com/libexpat/libexpat/releases/download/R_2_8_5/expat-2.8.5.tar.xz
glib-2.90.0.tar.xz 17d15cac2af80a33271127408e0abc2748eb297c595c2a26409e81e14e7d1b8f https://download.gnome.org/sources/glib/2.90/glib-2.90.0.tar.xz
glib-without-gregex.patch b1f2930a11292e529de137c7eb723850e0cc0969b1a2b0358196389312acd272 https://gist.github.com/kleisauke/284d685efa00908da99ea6afbaaf39ae/raw/bdad5489a61c217850631571caf57f5db6ea8b2c/glib-without-gregex.patch
lcms2-2.20.tar.gz 18ff5504fa9cc8a2b1f3591180d90ead16c8a2ea78e530523b46eab70e1ca6b9 https://github.com/mm2/Little-CMS/releases/download/lcms2.20/lcms2-2.20.tar.gz
libaom-3.15.3.tar.gz 12c01dc731ed7b5a999e28120b45bf58a002ba3435a4ba2cfbc1e084a27c9c04 https://storage.googleapis.com/aom-releases/libaom-3.15.3.tar.gz
libffi-3.8.0.tar.gz 7da3e2d9a171eb0a038f592ecad3ff2bb2550f3496d87b3b29ad0cf4430c0db4 https://github.com/libffi/libffi/releases/download/v3.8.0/libffi-3.8.0.tar.gz
libheif-1.23.7.tar.gz f7483e818503ea6224c8863e4a56ac02c7089021a98472c811c12aa19faf2475 https://github.com/strukturag/libheif/releases/download/v1.23.7/libheif-1.23.7.tar.gz
libjpeg-turbo-3.2.1.tar.gz c27ad72a68da151177929aa969ae773a2da5ac2af9ce946079314fdac8cece7f https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.1/libjpeg-turbo-3.2.1.tar.gz
libwebp-1.6.0.tar.gz e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564 https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz
vips-8.18.7.tar.xz 5baaead3b0bb20ffdb9e9ff09aa9fda08620923df77b63b436654cb5e0b3bf94 https://github.com/libvips/libvips/releases/download/v8.18.7/vips-8.18.7.tar.xz
"
# The clones: NAME TAG COMMIT REPOSITORY.
CLONES="
zlib-ng 2.3.3 12731092979c6d07f42da27da673a9f6c7b13586 https://github.com/zlib-ng/zlib-ng
proxy-libintl 0.5 33934de09af6a6627eb44e310a8079df009abdbb https://github.com/frida/proxy-libintl
libpng v1.6.58 3061454d980de7d53608f594194cfac722721d2a https://github.com/pnggroup/libpng
highway 1.4.0 2607d3b5b0113992fe84d3848859eae13b3b52c1 https://github.com/google/highway
cgif v0.5.4 2dfb49c22fbe3894e46731f7e3b6ffa84311e44e https://github.com/dloebl/cgif
libimagequant v2.4.1 ce5fdeb1ccd9db288950faa21fd09c42c0a59bbb https://github.com/lovell/libimagequant
"

fetch() {
    mkdir -p "$SRC/dl" "$SRC/git"
    echo "$DOWNLOADS" | while read -r name sha url; do
        [ -n "$name" ] || continue
        f=$SRC/dl/$name
        [ -f "$f" ] || { log "Downloading $name"; curl -fsSL -o "$f.part" "$url"; mv "$f.part" "$f"; }
        sum=$(sha256sum "$f" | cut -d' ' -f1)
        if [ "$sum" != "$sha" ]; then
            echo "Bad SHA-256 of $name: $sum" >&2
            exit 1
        fi
    done
    echo "$CLONES" | while read -r name tag commit url; do
        [ -n "$name" ] || continue
        d=$SRC/git/$name
        [ -d "$d/.git" ] || { log "Cloning $name $tag"; git clone -q --depth 1 --branch "$tag" "$url" "$d"; }
        head=$(git -C "$d" rev-parse HEAD)
        if [ "$head" != "$commit" ]; then
            echo "The clone of $name is at $head, not at the pinned commit $commit" >&2
            exit 1
        fi
    done
}

# build_cpu CPU: the libraries of one CPU in OUT/CPU.
build_cpu() {
    cpu=$1
    P=$OUT/$cpu
    W=$SRC/work-$cpu
    bin=$SRC/bin
    cc=$COSMOCC/bin/$cpu-unknown-cosmo-cc
    rm -rf "$P" "$W"
    mkdir -p "$P" "$W" "$bin"
    # meson starts its tools without a shell, and the tools of cosmocc are
    # APE files, which a shell starts. cosmocc has no ranlib: "ar s".
    printf '#!/bin/sh\nexec %s "$@"\n' "$COSMOCC/bin/$cpu-unknown-cosmo-ar" > "$bin/$cpu-ar"
    printf '#!/bin/sh\nexec %s s "$@"\n' "$COSMOCC/bin/$cpu-unknown-cosmo-ar" > "$bin/$cpu-ranlib"
    chmod +x "$bin/$cpu-ar" "$bin/$cpu-ranlib"
    ar=$bin/$cpu-ar ranlib=$bin/$cpu-ranlib
    if [ "$cpu" = x86_64 ]; then
        # The host runs x86_64 programs through sh (APE files). The check
        # of target_clones of libvips never ends under Cosmopolitan: each
        # test program gets 20 s.
        host= cmake_sys= wrapper="exe_wrapper = ['timeout', '20', 'sh']"
    else
        host=--host=$cpu-linux-gnu
        cmake_sys="-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=$cpu"
        wrapper=
    fi
    cross=$W/cross.ini
    cat > "$cross" <<EOF
[binaries]
c = '$cc'
cpp = '$COSMOCC/bin/$cpu-unknown-cosmo-c++'
ar = '$ar'
ranlib = '$ranlib'
strip = 'true'
pkg-config = 'pkg-config'
$wrapper

[built-in options]
c_args = ['-O2', '-I$P/include']
cpp_args = ['-O2', '-I$P/include']
c_link_args = ['-L$P/lib']
cpp_link_args = ['-L$P/lib']

[properties]
needs_exe_wrapper = true
pkg_config_libdir = '$P/lib/pkgconfig'

[host_machine]
system = 'linux'
cpu_family = '$cpu'
cpu = '$cpu'
endian = 'little'
EOF
    export PKG_CONFIG_PATH="$P/lib/pkgconfig" PKG_CONFIG_LIBDIR="$P/lib/pkgconfig"

    cmake_build() {
        # shellcheck disable=SC2086
        CFLAGS="-O2 -I$P/include" cmake -S . -B b -G Ninja $cmake_sys -DCMAKE_C_COMPILER="$cc" \
            -DCMAKE_CXX_COMPILER="$COSMOCC/bin/$cpu-unknown-cosmo-c++" \
            -DCMAKE_AR="$ar" -DCMAKE_RANLIB="$ranlib" -DCMAKE_INSTALL_PREFIX="$P" \
            -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release "$@" > ../log 2>&1
        ninja -C b -j"$JOBS" install >> ../log 2>&1
    }
    conf_build() {
        # shellcheck disable=SC2086
        CC=$cc AR=$ar RANLIB=$ranlib CPPFLAGS="-I$P/include" CFLAGS="-O2 -I$P/include" \
            LDFLAGS="-L$P/lib" ./configure $host --prefix="$P" --enable-static \
            --disable-shared --disable-dependency-tracking "$@" > ../log 2>&1
    }
    meson_build() {
        CC= CXX= AR= CPPFLAGS= CFLAGS= CXXFLAGS= LDFLAGS= meson setup b --cross-file "$cross" --default-library=static \
            --buildtype=release --prefix="$P" "$@" > ../log 2>&1
        ninja -C b -j"$JOBS" >> ../log 2>&1
        meson install -C b >> ../log 2>&1
    }
    # unpack NAME: a fresh copy of the source in W/NAME, and cd there.
    unpack() {
        cd "$W"
        case $1 in
            zlib-ng|proxy-libintl|libpng|highway|cgif|libimagequant) cp -r "$SRC/git/$1" "$W/$1" ;;
            *) tar xf "$SRC/dl/$(cd "$SRC/dl" && ls "$1".tar.*)" -C "$W" ;;
        esac
        cd "$W/$1"
        log "Building $1 ($cpu)"
    }

    # zlib-ng with its SIMD code (SSE2 to AVX-512 and VPCLMULQDQ on
    # x86_64, NEON and the CRC32 instructions on aarch64). It selects the
    # code for the CPU at run time: cpuid on x86_64, and getauxval() for
    # CRC32 on aarch64 (else the generic code). No -march=native.
    unpack zlib-ng
    cmake_build -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DZLIB_COMPAT=ON \
        -DWITH_OPTIM=ON -DWITH_RUNTIME_CPU_DETECTION=ON -DWITH_NATIVE_INSTRUCTIONS=OFF

    unpack libffi-3.8.0
    conf_build --disable-builddir --disable-multi-os-directory --disable-raw-api \
        --disable-structs --disable-docs --disable-exec-static-tramp
    make -j"$JOBS" install >> ../log 2>&1

    unpack expat-2.8.5
    conf_build --without-xmlwf --without-docbook --without-examples --without-tests
    make -j"$JOBS" install dist_cmake_DATA= nodist_cmake_DATA= >> ../log 2>&1

    unpack proxy-libintl
    meson_build

    # glib with no GRegex (the patch of sharp-libvips: no PCRE2), and the
    # changes for Cosmopolitan.
    unpack glib-2.90.0
    patch -p1 < "$SRC/dl/glib-without-gregex.patch" > /dev/null
    patch -p1 < "$ROOT/patches/libvips/glib-cosmopolitan.patch" > /dev/null
    meson_build --force-fallback-for=gvdb -Dintrospection=disabled -Dnls=disabled \
        -Dlibmount=disabled -Dsysprof=disabled -Dlibelf=disabled -Dselinux=disabled \
        -Dxattr=false -Dtests=false -Dglib_assert=false -Dglib_checks=false \
        -Dglib_debug=disabled

    unpack libjpeg-turbo-3.2.1
    # SIMD: NASM on x86_64, NEON on aarch64; a check of the CPU at run time.
    cmake_build -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_SIMD=ON \
        -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF

    unpack libpng
    conf_build --disable-tools --without-binconfigs --disable-unversioned-libpng-config
    make -j"$JOBS" install dist_man_MANS= >> ../log 2>&1

    unpack libwebp-1.6.0
    # SSE2 and SSE4.1 on x86_64, NEON on aarch64: libwebp checks the CPU
    # at run time.
    conf_build --enable-libwebpmux --enable-libwebpdemux
    make -j"$JOBS" install bin_PROGRAMS= noinst_PROGRAMS= man_MANS= >> ../log 2>&1

    # lcms2: the ICC transforms of libvips (icc_transform and the others).
    unpack lcms2-2.20
    meson_build -Dtests=disabled -Djpeg=disabled -Dtiff=disabled -Dutils=false

    # The GIF save of libvips: cgif writes the file, and libimagequant (the
    # fork of sharp-libvips with the BSD license) makes the palette.
    unpack libimagequant
    meson_build
    unpack cgif
    meson_build -Dexamples=false -Dtests=false

    # aom: the AV1 encoder and decoder of AVIF, with its SIMD code (NASM on
    # x86_64, NEON on aarch64). It selects the code for the CPU at run
    # time: cpuid on x86_64, and getauxval() on aarch64. MinSizeRel, as
    # sharp-libvips does: half the size of Release (about 4 MB of code).
    unpack libaom-3.15.3
    patch -p1 < "$ROOT/patches/libvips/aom-cosmopolitan.patch" > /dev/null
    case $cpu in x86_64) aom_cpu=x86_64 ;; *) aom_cpu=arm64 ;; esac
    cmake_build -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_SHARED_LIBS=OFF -DAOM_TARGET_CPU=$aom_cpu -DCONFIG_RUNTIME_CPU_DETECT=1 \
        -DENABLE_DOCS=0 -DENABLE_TESTS=0 -DENABLE_TESTDATA=0 -DENABLE_TOOLS=0 \
        -DENABLE_APPS=0 -DENABLE_EXAMPLES=0 -DENABLE_NASM=1 -DENABLE_RVV=0 \
        -DCONFIG_AV1_HIGHBITDEPTH=1 -DCONFIG_WEBM_IO=0

    # libheif (C++): AVIF read and write with aom only. No HEVC (libde265
    # and x265), no plugin loading. MinSizeRel: about 2.4 MB of code, in
    # place of 4.3 MB.
    unpack libheif-1.23.7
    cmake_build -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_SHARED_LIBS=OFF -DBUILD_DOCUMENTATION=OFF -DBUILD_TESTING=OFF \
        -DENABLE_PLUGIN_LOADING=OFF -DWITH_EXAMPLES=OFF -DWITH_GDK_PIXBUF=OFF \
        -DWITH_LIBDE265=OFF -DWITH_X265=OFF -DWITH_X264=OFF -DWITH_OpenH264_DECODER=OFF \
        -DWITH_DAV1D=OFF -DWITH_SvtEnc=OFF -DWITH_RAV1E=OFF -DWITH_KVAZAAR=OFF \
        -DWITH_JPEG_DECODER=OFF -DWITH_JPEG_ENCODER=OFF -DWITH_OpenJPEG_DECODER=OFF \
        -DWITH_OpenJPEG_ENCODER=OFF -DWITH_OPENJPH_ENCODER=OFF -DWITH_FFMPEG_DECODER=OFF \
        -DWITH_UNCOMPRESSED_CODEC=OFF -DWITH_AOM_DECODER=ON -DWITH_AOM_ENCODER=ON

    # Highway: the SIMD code of libvips (resize, convolution and others),
    # in C++. It selects the code for the CPU at run time.
    unpack highway
    cmake_build -DBUILD_SHARED_LIBS=OFF -DHWY_FORCE_STATIC_LIBS=ON \
        -DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_EXAMPLES=OFF -DHWY_ENABLE_CONTRIB=OFF \
        -DBUILD_TESTING=OFF

    # libvips: the C library only (vix uses no C++), no man pages, tools,
    # tests or fuzz programs.
    unpack vips-8.18.7
    sed -i "/^subdir('man')$/,/^subdir('fuzz')$/d" meson.build
    meson_build -Dauto_features=disabled -Ddeprecated=false -Dexamples=false \
        -Dcplusplus=false -Dmodules=disabled -Dintrospection=disabled \
        -Djpeg=enabled -Dpng=enabled -Dwebp=enabled -Dzlib=enabled -Dhighway=enabled \
        -Dlcms=enabled -Dcgif=enabled -Dimagequant=enabled -Dheif=enabled \
        -Dnsgif=true -Dppm=true -Danalyze=false -Dradiance=false
    cd "$ROOT"
}

fetch
for cpu in x86_64 aarch64; do
    build_cpu "$cpu"
done
log "libvips in $OUT"
