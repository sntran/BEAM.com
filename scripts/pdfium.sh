#!/bin/sh
# PDFium as a static library for beam.com, built with cosmocc: for the NIF
# of ex_pdfium (pdfium-render with its feature "static").
# Usage: sh scripts/pdfium.sh CPU OUT
#   CPU  x64 or arm64
#   OUT  a directory for libpdfium.a and the public headers
#
# The checkout uses depot_tools (gclient), in PDFIUM_SRC (default
# build/pdfium-src). The settings follow the static and musl builds of
# bblanchon/pdfium-binaries: no V8 and no XFA, no PartitionAlloc, GCC and
# the C++ library of cosmocc (patches/pdfium/toolchain.gn), and one
# complete libpdfium.a (pdf_is_complete_lib).
#
# PDFIUM_KEEP_GOING=1: ninja goes on after an error (ninja -k 0), so that
# one build shows each file that does not compile.
set -eu
cpu=$1 out=$2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${BUILD:-$ROOT/build}
COSMOCC=${COSMOCC:-$BUILD/cosmocc}
SRC=${PDFIUM_SRC:-$BUILD/pdfium-src}
# The version of pdfium-render 0.9.3 (pdfium_7881) and of ex_pdfium 0.6.0.
PDFIUM_BRANCH=chromium/7881
PDFIUM_COMMIT=91b9d569b34be4f38eed7b3c49b227356c3aadad
DEPOT_TOOLS_COMMIT=bed65db1bb5d1022dab89cf62e7609b12084747b

case $cpu in x64|arm64) ;; *) echo "pdfium.sh: CPU must be x64 or arm64" >&2; exit 1 ;; esac
mkdir -p "$SRC" "$out"
cosmocc_bin=$(cd "$COSMOCC/bin" && pwd)

if [ ! -d "$SRC/depot_tools/.git" ]; then
    git clone -q https://chromium.googlesource.com/chromium/tools/depot_tools.git "$SRC/depot_tools"
fi
git -C "$SRC/depot_tools" checkout -q "$DEPOT_TOOLS_COMMIT"
export PATH="$SRC/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0

cd "$SRC"
if [ ! -f .gclient ]; then
    gclient config --unmanaged https://pdfium.googlesource.com/pdfium.git \
        --custom-var checkout_configuration=minimal
    echo "target_os = [ 'linux' ]" >> .gclient
fi
if [ "$(git -C pdfium rev-parse HEAD 2>/dev/null)" != "$PDFIUM_COMMIT" ]; then
    gclient sync -r "origin/$PDFIUM_BRANCH" --no-history --shallow
fi
got=$(git -C pdfium rev-parse HEAD)
if [ "$got" != "$PDFIUM_COMMIT" ]; then
    echo "pdfium.sh: $PDFIUM_BRANCH is at $got, not $PDFIUM_COMMIT" >&2
    exit 1
fi

cd pdfium
mkdir -p build/toolchain/cosmo
cp "$ROOT/patches/pdfium/toolchain.gn" build/toolchain/cosmo/BUILD.gn
dir=out/cosmo-$cpu
mkdir -p "$dir"
{
    echo 'is_debug = false'
    echo 'symbol_level = 0'
    echo 'pdf_is_standalone = true'
    echo 'pdf_is_complete_lib = true'
    echo 'pdf_use_partition_alloc = false'
    echo 'pdf_enable_v8 = false'
    echo 'pdf_enable_xfa = false'
    echo 'is_component_build = false'
    echo 'treat_warnings_as_errors = false'
    echo 'target_os = "linux"'
    echo "target_cpu = \"$cpu\""
    echo "custom_toolchain = \"//build/toolchain/cosmo:$cpu\""
    echo "cosmocc_bin = \"$cosmocc_bin\""
    echo 'is_clang = false'
    echo 'use_custom_libcxx = false'
    echo 'use_glib = false'
    echo 'use_sysroot = false'
    echo 'clang_use_chrome_plugins = false'
    if [ "$cpu" = arm64 ]; then
        echo 'libyuv_use_neon = false'
        echo 'libyuv_use_sme = false'
    fi
} > "$dir/args.gn"
gn gen "$dir"
if [ "${PDFIUM_KEEP_GOING:-0}" = 1 ]; then
    ninja -k 0 -C "$dir" pdfium
else
    ninja -C "$dir" pdfium
fi
cp "$dir/obj/libpdfium.a" "$out/libpdfium.a"
rm -rf "$out/include"
cp -R public "$out/include"
ls -l "$out/libpdfium.a"
