#!/bin/sh
# Build priv/nifs/lazy_html-0.1.13/: lazy_html 0.1.13 (the HTML parser of
# Phoenix.LiveViewTest, a C++ NIF with fine and lexbor) as a NIF library
# in WebAssembly, and its AOT files (docs/NIFS.md, "C++"). beam.com
# copies these files into the priv directory of a Mix project with
# lazy_html 0.1.13 (src/beam_com/beam_com_make.erl).
#
#   ZIG=zig WAMRC=wamrc scripts/lazy_html.sh
#
# ZIG: Zig 0.17 (its C and C++ compilers for wasm32-wasi). WAMRC: wamrc of
# WAMR 2.4.5, the WAMR of beam.com. NIF_INCLUDE: the headers of
# "beam.com --nif-include" (default: that command). WORK: the directory
# of the sources and objects (default: tmp/lazy_html).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
: "${ZIG:?set ZIG to Zig 0.17}"
: "${WAMRC:?set WAMRC to wamrc of WAMR 2.4.5}"
include=${NIF_INCLUDE:-$(beam.com --nif-include)}
work=${WORK:-$root/tmp/lazy_html}
out=$root/priv/nifs/lazy_html-0.1.13

# The packages of hex.pm, with the outer checksums of mix.lock, and the
# commit of lexbor of lazy_html 0.1.13 (@lexbor_git_sha of its mix.exs).
LAZY_HTML_SHA256=9a8405d6785fe6f8423b86e0ec5f21806ef79941fe853eac3d14fbbb173c34e9
FINE_SHA256=5638eb4495488e885ebec167fa57973e5c35e1a50c344eb7666c90ec1c4e3b12
LEXBOR_COMMIT=244b84956a6dc7eec293781d051354f351274c46

sha256() {
    if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# hex_package NAME VERSION SHA256: the files of the package in
# $work/NAME (the contents.tar.gz of the tarball of hex.pm).
hex_package() {
    tar=$work/$1-$2.tar
    [ -f "$tar" ] || curl -fsSL -o "$tar" "https://repo.hex.pm/tarballs/$1-$2.tar"
    got=$(sha256 "$tar")
    if [ "$got" != "$3" ]; then
        echo "$0: $tar: SHA-256 $got, not $3" >&2
        exit 1
    fi
    rm -rf "${work:?}/$1"
    mkdir -p "$work/$1"
    tar -xOf "$tar" contents.tar.gz | tar -xzf - -C "$work/$1"
}

mkdir -p "$work"
hex_package lazy_html 0.1.13 "$LAZY_HTML_SHA256"
hex_package fine 0.1.6 "$FINE_SHA256"
(cd "$work/fine" && for p in "$root"/patches/fine/*.patch; do patch -s -p1 < "$p"; done)
(cd "$work/lazy_html" && for p in "$root"/patches/lazy_html/*.patch; do patch -s -p1 < "$p"; done)

# lexbor at its commit (git checks the content of the commit).
if [ ! -d "$work/lexbor/.git" ]; then
    git init -q "$work/lexbor"
    git -C "$work/lexbor" fetch -q --depth 1 https://github.com/lexbor/lexbor "$LEXBOR_COMMIT"
fi
git -C "$work/lexbor" checkout -q "$LEXBOR_COMMIT"

# lexbor: each .c file of source/lexbor, but ports/windows_nt (the flags
# of its CMake build).
objs=$work/lexbor-obj
rm -rf "$objs"
mkdir -p "$objs"
(cd "$work/lexbor/source" && find lexbor -name '*.c' ! -path '*/ports/windows_nt/*' | sort) |
    while IFS= read -r f; do
        "$ZIG" cc -target wasm32-wasi -O2 -std=c99 -DLEXBOR_STATIC -D_POSIX_C_SOURCE=199309L \
            -I"$work/lexbor/source" -c "$work/lexbor/source/$f" \
            -o "$objs/$(echo "$f" | tr / _ | sed 's/\.c$/.o/')"
    done
rm -f "$work/liblexbor.a"
"$ZIG" ar rcs "$work/liblexbor.a" "$objs"/*.o

# The NIF, as the Makefile of lazy_html builds it, with no C++
# exceptions (patches/fine, patches/lazy_html).
mkdir -p "$out"
"$ZIG" c++ -target wasm32-wasi -mexec-model=reactor -O3 -std=c++17 \
    -fno-exceptions -DFINE_NO_EXCEPTIONS -DLEXBOR_STATIC -fvisibility=hidden \
    -I"$include" -I"$work/fine/c_include" -I"$work/lexbor/source" \
    "$work/lazy_html/c_src/lazy_html.cpp" "$work/liblexbor.a" \
    -s -o "$out/liblazy_html.wasm"
"$WAMRC" --target=x86_64 --cpu=x86-64 --bounds-checks=1 \
    -o "$out/liblazy_html.x86_64.aot" "$out/liblazy_html.wasm" > /dev/null
"$WAMRC" --target=aarch64 --cpu=generic --bounds-checks=1 \
    --cpu-features=+reserve-x18,+reserve-x28 \
    -o "$out/liblazy_html.aarch64.aot" "$out/liblazy_html.wasm" > /dev/null
ls -l "$out"
