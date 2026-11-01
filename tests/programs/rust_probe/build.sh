#!/bin/sh
# The probe of Rust on Cosmopolitan: a staticlib of Rust (std of the
# target *-unknown-linux-musl) for x86_64 and aarch64, with the calls of
# c_src/rust/cosmo_rust.c, in one APE file.
# Usage: sh build.sh COSMOCC OUT
set -eu
C=$1 OUT=$2
here=$(cd "$(dirname "$0")" && pwd)
shim=$here/../../../c_src/rust/cosmo_rust.c
SYMS="syscall clock_gettime clock_nanosleep __errno_location pthread_attr_init
pthread_attr_destroy pthread_attr_setstacksize pthread_attr_getstack
pthread_attr_getguardsize pthread_getattr_np pthread_create open openat mmap
getauxval sched_getaffinity"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$here"
for cpu in x86_64 aarch64; do
  d=$work; [ $cpu = aarch64 ] && d=$work/.aarch64 && mkdir -p "$d"
  cargo build -q --release --target $cpu-unknown-linux-musl
  cp target/$cpu-unknown-linux-musl/release/librust_probe.a "$d/librust_probe.a"
  args=; for s in $SYMS; do args="$args --redefine-sym $s=beam_rs_$s"; done
  # shellcheck disable=SC2086
  sh "$C/bin/$cpu-unknown-cosmo-objcopy" $args "$d/librust_probe.a"
  if [ $cpu = aarch64 ]; then
    # The outline atomics of compiler_builtins: libcosmo.a has them too.
    lse=$(sh "$C/bin/$cpu-unknown-cosmo-ar" t "$d/librust_probe.a" | grep -- '-lse_' || true)
    # shellcheck disable=SC2086
    [ -z "$lse" ] || sh "$C/bin/$cpu-unknown-cosmo-ar" d "$d/librust_probe.a" $lse
  fi
  sh "$C/bin/$cpu-unknown-cosmo-cc" -O2 -c -o "$d/shim.o" "$shim"
done
cp main.c "$work/main.c"
(cd "$work" && sh "$C/bin/cosmocc" -O2 -o probe.com main.c shim.o librust_probe.a -Wl,--gc-sections)
cp "$work/probe.com" "$OUT"
