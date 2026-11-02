#!/bin/sh
# Usage: sh scripts/rust_link.sh COSMOCC CPU NAME OUT INPUT...
#
# One relocatable object OUT, from the objects and the archive of a Rust
# crate (a staticlib, built with LTO): the archive members that NAME needs,
# and one global name, NAME. Each other name becomes local, so two crates
# do not conflict, and the outline atomics of compiler_builtins (aarch64)
# do not conflict with those of libcosmo.a. OUT has no debug data, and no
# LLVM bitcode (.llvmbc).
#
# Caution: ld -r --gc-sections makes a wrong .eh_frame (the relocations of
# the removed FDEs stay), and a panic of Rust then cannot unwind. LTO
# removes the code that the crate does not use, in place of the GC.
#
# The unwinder of Cosmopolitan reads .eh_frame from __eh_frame_start to
# __eh_frame_end, and stops at an entry of length 0. When the .eh_frame of
# OUT has a size of 4 modulo 8, the link of the program puts 4 bytes of
# zero after it, before the next .eh_frame. So OUT then gets one more CIE
# (c_src/rust/eh_frame_pad.ld). See C43 in docs/UPSTREAM.md.
set -eu
C=$1 cpu=$2 name=$3 out=$4
shift 4
root=$(cd "$(dirname "$0")/.." && pwd)
ld=$C/bin/$cpu-linux-cosmo-ld
objcopy=$C/bin/$cpu-unknown-cosmo-objcopy
eh_frame_mod8() {
    sh "$objcopy" -O binary --only-section=.eh_frame "$out.r" "$out.eh"
    echo $(($(wc -c < "$out.eh") % 8))
}
sh "$ld" -r -u "$name" -o "$out.r" "$@"
if [ "$(eh_frame_mod8)" = 4 ]; then
    sh "$ld" -r -u "$name" -T "$root/c_src/rust/eh_frame_pad.ld" -o "$out.r" "$@"
    if [ "$(eh_frame_mod8)" != 0 ]; then
        echo "rust_link.sh: the .eh_frame of $out has a bad size" >&2
        exit 1
    fi
fi
sh "$objcopy" --keep-global-symbol="$name" --strip-debug \
    --remove-section=.llvmbc --remove-section=.llvmcmd "$out.r" "$out"
rm -f "$out.r" "$out.eh"
