#!/bin/sh
# Makes the native NIF objects of a NIF part of the store (docs/NIFS.md):
# OUT/FILE.x86_64.o and OUT/FILE.aarch64.o, from DIR/LIB.a and
# DIR/.aarch64/LIB.a. load_nif/2 loads them for "PATH/FILE". FILE is LIB
# when it is not given, and it can have a directory (native/libLIB).
#
#   sh scripts/nif_object.sh /path/to/cosmocc LIB DIR OUT [FILE]
#
# The archive of a part is the NIF as the static build links it: its
# function LIB_nif_init, and the libraries that it needs. "ld -r" takes
# the members that LIB_nif_init needs, and the members of libcxx.a
# (libc++) that they need. The object then keeps one global name,
# LIB_nif_init, so its names do not collide with the names of the
# program. The program gives the libc and libc++abi.
set -eu
C=$1 lib=$2 dir=$3 out=$4 file=${5:-$2}
init=${lib}_nif_init
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nif_object.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$(dirname "$out/$file")"
for cpu in x86_64 aarch64; do
    case $cpu in
        x86_64) a=$dir/$lib.a ;;
        aarch64) a=$dir/.aarch64/$lib.a ;;
    esac
    [ -f "$a" ] || { echo "nif_object: no file $a" >&2; exit 1; }
    "$C/bin/$cpu-linux-cosmo-ld" -r -u "$init" -o "$tmp/$cpu.o" "$a" \
        "$C/$cpu-linux-cosmo/lib/libcxx.a"
    "$C/bin/$cpu-unknown-cosmo-objcopy" --keep-global-symbol="$init" --strip-debug \
        "$tmp/$cpu.o" "$tmp/$lib.$cpu.o"
    # An archive with no LIB_nif_init gives an object with no code.
    "$C/bin/$cpu-unknown-cosmo-nm" -g --defined-only "$tmp/$lib.$cpu.o" |
        grep -q " T $init\$" || { echo "nif_object: $a has no function $init" >&2; exit 1; }
    mv "$tmp/$lib.$cpu.o" "$out/$file.$cpu.o"
done
