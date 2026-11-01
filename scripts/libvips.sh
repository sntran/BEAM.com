#!/bin/sh
# libvips and the libraries that it needs, as static libraries of cosmocc,
# for the NIF of vix (EXTRA_NIFS=vix, see build_vix_nif in steps.sh).
# Usage: scripts/libvips.sh [OUT]
#   OUT: the directory of the result (default $BUILD/libvips): OUT/x86_64
#   and OUT/aarch64, each with include/, lib/ and lib/pkgconfig/.
# Needs: cosmocc ($COSMOCC, default build/cosmocc), meson, ninja, cmake,
# pkg-config, curl, git and python3.
#
# The versions are those of sharp-libvips (the libvips of vix 0.42.0),
# with JPEG from libjpeg-turbo (no SIMD), and only the formats JPEG, PNG,
# WebP, GIF and PPM. Each CPU is built alone, because the headers of
# glib and libffi differ. aarch64 is a cross build: no test program runs.
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
libffi-3.8.0.tar.gz 7da3e2d9a171eb0a038f592ecad3ff2bb2550f3496d87b3b29ad0cf4430c0db4 https://github.com/libffi/libffi/releases/download/v3.8.0/libffi-3.8.0.tar.gz
libjpeg-turbo-3.2.1.tar.gz c27ad72a68da151177929aa969ae773a2da5ac2af9ce946079314fdac8cece7f https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.1/libjpeg-turbo-3.2.1.tar.gz
libwebp-1.6.0.tar.gz e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564 https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz
vips-8.18.7.tar.xz 5baaead3b0bb20ffdb9e9ff09aa9fda08620923df77b63b436654cb5e0b3bf94 https://github.com/libvips/libvips/releases/download/v8.18.7/vips-8.18.7.tar.xz
"
# The clones: NAME TAG COMMIT REPOSITORY.
CLONES="
zlib-ng 2.3.3 12731092979c6d07f42da27da673a9f6c7b13586 https://github.com/zlib-ng/zlib-ng
proxy-libintl 0.5 33934de09af6a6627eb44e310a8079df009abdbb https://github.com/frida/proxy-libintl
libpng v1.6.58 3061454d980de7d53608f594194cfac722721d2a https://github.com/pnggroup/libpng
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
            zlib-ng|proxy-libintl|libpng) cp -r "$SRC/git/$1" "$W/$1" ;;
            *) tar xf "$SRC/dl/$(cd "$SRC/dl" && ls "$1".tar.*)" -C "$W" ;;
        esac
        cd "$W/$1"
        log "Building $1 ($cpu)"
    }

    unpack zlib-ng
    cmake_build -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DZLIB_COMPAT=ON \
        -DWITH_OPTIM=OFF -DWITH_NATIVE_INSTRUCTIONS=OFF

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
    cmake_build -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_SIMD=OFF \
        -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF

    unpack libpng
    conf_build --disable-tools --without-binconfigs --disable-unversioned-libpng-config
    make -j"$JOBS" install dist_man_MANS= >> ../log 2>&1

    unpack libwebp-1.6.0
    conf_build --enable-libwebpmux --enable-libwebpdemux --disable-sse2 \
        --disable-sse4.1 --disable-neon
    make -j"$JOBS" install bin_PROGRAMS= noinst_PROGRAMS= man_MANS= >> ../log 2>&1

    # libvips: the C library only (vix uses no C++), no man pages, tools,
    # tests or fuzz programs.
    unpack vips-8.18.7
    sed -i "/^subdir('man')$/,/^subdir('fuzz')$/d" meson.build
    meson_build -Dauto_features=disabled -Ddeprecated=false -Dexamples=false \
        -Dcplusplus=false -Dmodules=disabled -Dintrospection=disabled \
        -Djpeg=enabled -Dpng=enabled -Dwebp=enabled -Dzlib=enabled \
        -Dnsgif=true -Dppm=true -Danalyze=false -Dradiance=false
    cd "$ROOT"
}

fetch
for cpu in x86_64 aarch64; do
    build_cpu "$cpu"
done
log "libvips in $OUT"
