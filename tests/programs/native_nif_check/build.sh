#!/bin/sh
# Builds priv/ of native_nif_check from c_src/, as docs/NIFS.md shows:
# cosmocc compiles each file for x86_64 and aarch64, and `ld -r` joins
# the objects of each CPU into priv/NAME.ARCH.o.
#
#   PATH=/path/to/cosmocc/bin:$PATH tests/programs/native_nif_check/build.sh
#
# NIF_INCLUDE: the headers (default: the directory of
# "beam.com --nif-include").
#
# priv/broken.ARCH.o is not an ELF object, and priv/missing.ARCH.o needs a
# function that the program does not have: the test checks the errors.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
include=${NIF_INCLUDE:-$(beam.com --nif-include)}
mkdir -p "$here/priv"
obj=$(mktemp -d "${TMPDIR:-/tmp}/native_nif_check.XXXXXX")
trap 'rm -rf "$obj"' EXIT
cd "$obj"
for f in native_nif_check native_nif_check_util native_nif_check_missing; do
    cosmocc -O2 -Wall -I"$include" -c "$here/c_src/$f.c" -o "$f.o"
done
x86_64-linux-cosmo-ld -r -o "$here/priv/native_nif_check.x86_64.o" \
    native_nif_check.o native_nif_check_util.o
aarch64-linux-cosmo-ld -r -o "$here/priv/native_nif_check.aarch64.o" \
    .aarch64/native_nif_check.o .aarch64/native_nif_check_util.o
cp native_nif_check_missing.o "$here/priv/missing.x86_64.o"
cp .aarch64/native_nif_check_missing.o "$here/priv/missing.aarch64.o"
for arch in x86_64 aarch64; do
    printf 'not an object\n' > "$here/priv/broken.$arch.o"
done
