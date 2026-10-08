#!/bin/sh
# Build priv/ of nif_check from c_src/nif_check.c, as docs/NIFS.md shows:
#   - priv/nif_check.wasm, with a C compiler for wasm32-wasip1 (CC);
#   - the AOT files, with wamrc (WAMRC) of the WAMR version of beam.com.
#
#   CC="zig cc -target wasm32-wasi" tests/programs/nif_check/build.sh
#   CC="clang --target=wasm32-wasip1 --sysroot=$WASI_SDK/share/wasi-sysroot" \
#       WAMRC=wamrc tests/programs/nif_check/build.sh
#
# NIF_INCLUDE: the headers (default: the directory of
# "beam.com --nif-include").
#
# c_src/nif_check_mv.c gets the multi-value ABI (clang): its function has
# four results, for the test NIF four_results. Only that file: the ABI
# also changes the calls of compiler-rt.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
: "${CC:?set CC to a C compiler for wasm32-wasip1}"
include=${NIF_INCLUDE:-$(beam.com --nif-include)}
mkdir -p "$here/priv"
obj=$(mktemp -d "${TMPDIR:-/tmp}/nif_check.XXXXXX")
trap 'rm -rf "$obj"' EXIT
# shellcheck disable=SC2086
$CC -O2 -Wall -I"$include" -mmultivalue -Xclang -target-abi -Xclang experimental-mv \
    -c -o "$obj/nif_check_mv.o" "$here/c_src/nif_check_mv.c"
# shellcheck disable=SC2086
$CC -O2 -s -Wall -I"$include" -mexec-model=reactor \
    -o "$here/priv/nif_check.wasm" "$here/c_src/nif_check.c" "$obj/nif_check_mv.o"
if [ -n "${WAMRC:-}" ]; then
    "$WAMRC" --target=x86_64 --cpu=x86-64 --bounds-checks=1 \
        -o "$here/priv/nif_check.x86_64.aot" "$here/priv/nif_check.wasm"
    "$WAMRC" --target=aarch64 --cpu=generic --bounds-checks=1 \
        --cpu-features=+reserve-x18,+reserve-x28 \
        -o "$here/priv/nif_check.aarch64.aot" "$here/priv/nif_check.wasm"
fi
