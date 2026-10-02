#!/bin/sh
# Build BEAM.com: the old command line of the Makefile.
#
#   ./build.sh [STEP...]    runs    make [STEP...]
#
# It runs the make of cosmocc (build/cosmocc/bin/make) when it is there,
# else the GNU make on the PATH. MAKE gives another make. See the Makefile
# for the steps and the settings.
set -eu
ROOT=$(cd "$(dirname "$0")" && pwd)
make=${MAKE:-}
if [ -z "$make" ]; then
    cosmo_make=${COSMOCC:-${BUILD:-$ROOT/build}/cosmocc}/bin/make
    if [ -x "$cosmo_make" ]; then make=$cosmo_make; else make=make; fi
fi
exec "$make" -C "$ROOT" "$@"
