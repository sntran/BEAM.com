#!/bin/sh
# The probe of Rust on Cosmopolitan: a staticlib of Rust (std of the
# target *-unknown-linux-musl) for x86_64 and aarch64, with the calls of
# c_src/rust/cosmo_rust.c, in one APE file.
# Usage: sh build.sh COSMOCC OUT
#
# On aarch64, Cosmopolitan reserves x18 and x28 (cosmocc: -ffixed-x18
# -ffixed-x28). The std of Rust for Linux uses them, and the unwinder then
# crashes. So the aarch64 archive and its std build with these registers
# reserved: a nightly Rust (RUST_NIGHTLY) with rust-src, and -Zbuild-std.
set -eu
C=$1 OUT=$2
nightly=${RUST_NIGHTLY:-nightly-2026-11-01}
here=$(cd "$(dirname "$0")" && pwd)
shim=$here/../../../c_src/rust/cosmo_rust.c
SYMS="syscall clock_gettime clock_nanosleep __errno_location pthread_attr_init
pthread_attr_destroy pthread_attr_setstacksize pthread_attr_getstack
pthread_attr_getguardsize pthread_getattr_np pthread_create open openat mmap
getauxval sched_getaffinity fstat stat lstat fstatat"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$here"
for cpu in x86_64 aarch64; do
  d=$work; [ $cpu = aarch64 ] && d=$work/.aarch64 && mkdir -p "$d"
  if [ $cpu = aarch64 ]; then
    RUSTFLAGS="-C target-feature=+reserve-x18,+reserve-x28" CARGO_PROFILE_RELEASE_LTO=fat \
      cargo "+$nightly" build -q --release --target $cpu-unknown-linux-musl \
      -Zbuild-std=std,panic_unwind --target-dir target/reserved
    cp target/reserved/$cpu-unknown-linux-musl/release/librust_probe.a "$d/librust_probe.a"
  else
    CARGO_PROFILE_RELEASE_LTO=fat cargo build -q --release --target $cpu-unknown-linux-musl
    cp target/$cpu-unknown-linux-musl/release/librust_probe.a "$d/librust_probe.a"
  fi
  args=; for s in $SYMS; do args="$args --redefine-sym $s=beam_rs_$s"; done
  # shellcheck disable=SC2086
  sh "$C/bin/$cpu-unknown-cosmo-objcopy" $args "$d/librust_probe.a"
  sh "$C/bin/$cpu-unknown-cosmo-cc" -O2 -c -o "$d/shim.o" "$shim"
  # As build_rust_nif in scripts/steps.sh: one object with one global
  # name, rs_probe.
  sh "$here/../../../scripts/rust_link.sh" "$C" $cpu rs_probe "$d/probe.o" \
    "$d/shim.o" "$d/librust_probe.a"
done
cp main.c "$work/main.c"
(cd "$work" && sh "$C/bin/cosmocc" -O2 -o probe.com main.c probe.o)
cp "$work/probe.com" "$OUT"
