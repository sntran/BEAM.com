#!/bin/sh
# Builds priv/ of native_nif_check from c_src/, as docs/NIFS.md shows:
# cosmocc (and cosmoc++) compiles each file for x86_64 and aarch64, and
# `ld -r` joins the objects of each CPU, with the members of libcxx.a that
# the C++ file needs, into priv/NAME.ARCH.o. The object keeps one global
# name, nif_init.
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
for f in native_nif_check native_nif_check_util native_nif_check_tls native_nif_check_missing; do
    cosmocc -O2 -Wall -I"$include" -c "$here/c_src/$f.c" -o "$f.o"
done
# The TLS models of Rust in assembly: cosmocc takes no .S file, so the
# compiler of each CPU. On aarch64 the plain gcc of the toolchain: the
# cosmo compiler (fixupobj) changes "mrs tpidr_el0" to "mov x28", and the
# code of Rust keeps it, so the loader must change it (tls_morph).
x86_64-unknown-cosmo-cc -c "$here/c_src/native_nif_check_tls.S" -o tls_asm.o
aarch64-linux-cosmo-gcc -nostdinc -c "$here/c_src/native_nif_check_tls.S" -o .aarch64/tls_asm.o
cosmoc++ -O2 -Wall -c "$here/c_src/native_nif_check_cxx.cpp" -o native_nif_check_cxx.o
lib=$(dirname "$(command -v cosmocc)")/..
x86_64-linux-cosmo-ld -r -o nif.x86_64.o native_nif_check.o native_nif_check_util.o \
    native_nif_check_tls.o tls_asm.o native_nif_check_cxx.o "$lib/x86_64-linux-cosmo/lib/libcxx.a"
aarch64-linux-cosmo-ld -r -o nif.aarch64.o .aarch64/native_nif_check.o \
    .aarch64/native_nif_check_util.o .aarch64/native_nif_check_tls.o .aarch64/tls_asm.o \
    .aarch64/native_nif_check_cxx.o "$lib/aarch64-linux-cosmo/lib/libcxx.a"
x86_64-unknown-cosmo-objcopy --keep-global-symbol=nif_init --strip-debug \
    nif.x86_64.o "$here/priv/native_nif_check.x86_64.o"
aarch64-unknown-cosmo-objcopy --keep-global-symbol=nif_init --strip-debug \
    nif.aarch64.o "$here/priv/native_nif_check.aarch64.o"
cp native_nif_check_missing.o "$here/priv/missing.x86_64.o"
cp .aarch64/native_nif_check_missing.o "$here/priv/missing.aarch64.o"
for arch in x86_64 aarch64; do
    printf 'not an object\n' > "$here/priv/broken.$arch.o"
done
