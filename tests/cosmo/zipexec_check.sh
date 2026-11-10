#!/bin/sh
# Builds tests/cosmo/zipexec_check.c with cosmocc (CC, default cosmocc)
# as OUT/zipexec_check.com, and adds the programs of the check to its zip
# with Info-ZIP zip, which keeps the modes:
#
#   zipexec/prog  a copy of the check itself (an APE file, mode 0755)
#   zipexec/sh    a copy of /bin/sh, when it is an ELF file (mode 0755)
#   zipexec/data  a file with no execute bit (mode 0644)
#
#   tests/cosmo/zipexec_check.sh OUT
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=$(cd "$1" && pwd)
cc=${CC:-cosmocc}
"$cc" -O2 -Wall -Wno-unused-function -o "$out/zipexec_check.com" "$here/zipexec_check.c"
stage=$out/zipexec_stage
rm -rf "$stage"
mkdir -p "$stage/zipexec"
cp "$out/zipexec_check.com" "$stage/zipexec/prog"
chmod 755 "$stage/zipexec/prog"
if [ -f /bin/sh ] && [ "$(head -c 4 /bin/sh | od -An -c | tr -d ' ')" = '177ELF' ]; then
    cp /bin/sh "$stage/zipexec/sh"
    chmod 755 "$stage/zipexec/sh"
fi
printf 'data\n' > "$stage/zipexec/data"
chmod 644 "$stage/zipexec/data"
(cd "$stage" && zip -q -r "$out/zipexec_check.com" zipexec)
rm -rf "$stage"
