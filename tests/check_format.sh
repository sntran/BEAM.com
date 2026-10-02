#!/bin/sh
# Check the file formats of APE files: beam.com and the programs that it
# builds. Each check uses a tool that is not part of beam.com.
#
#   tests/check_format.sh FILE...
#
# For each FILE:
#
# - ZIP: "unzip -t" reads each entry with no error and no warning (for
#   example, no "extra bytes").
# - PE (Windows): "pecheck" of cosmocc passes. objdump reads a PE32+ for
#   x86-64, with the console subsystem and NX_COMPAT. No section is both
#   writable and executable, and each section is inside the file.
# - ELF for x86_64 and for aarch64 ("assimilate -e"): readelf reads an
#   executable for the correct machine. No segment is both writable and
#   executable, the stack is not executable, each segment is inside the
#   file, and the entry point is in an executable segment.
# - Mach-O for x86_64 ("assimilate -m"): llvm-objdump reads an executable
#   for x86_64. No segment starts writable and executable, each segment is
#   inside the file, and the start address is in an executable segment.
#   (macOS on arm64 runs the APE loader, not a Mach-O in the file.)
#
# Needs: COSMOCC (the directory of cosmocc, default build/cosmocc), GNU
# binutils, unzip, and llvm-objdump (LLVM_OBJDUMP, llvm-objdump on the
# PATH, or the llvm-objdump of an LLVM in /usr/lib or /usr/bin). The copies go to a temporary directory,
# or to FORMAT_TMP when it is set (then the script keeps them).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
COSMOCC=${COSMOCC:-$ROOT/build/cosmocc}
[ $# -gt 0 ] || { echo "usage: $0 FILE..." >&2; exit 2; }

objdump_macho=${LLVM_OBJDUMP:-}
if [ -z "$objdump_macho" ]; then
    for c in llvm-objdump /usr/lib/llvm-*/bin/llvm-objdump /usr/bin/llvm-objdump-*; do
        if command -v "$c" >/dev/null 2>&1; then objdump_macho=$c; break; fi
    done
fi
for t in "$COSMOCC/bin/assimilate" "$COSMOCC/bin/pecheck"; do
    [ -x "$t" ] || { echo "check_format: $t not found (set COSMOCC)" >&2; exit 2; }
done
for t in readelf objdump unzip "$objdump_macho"; do
    command -v "$t" >/dev/null 2>&1 || { echo "check_format: ${t:-llvm-objdump} not found" >&2; exit 2; }
done

if [ -n "${FORMAT_TMP:-}" ]; then
    tmp=$FORMAT_TMP
    mkdir -p "$tmp"
else
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
fi

# A hex number for awk: mawk (the default awk of Debian and Ubuntu) has
# no strtonum.
HEX='function hex(s,  i, v) { sub(/^0x/, "", s); v = 0;
    for (i = 1; i <= length(s); i++) v = v * 16 + index("0123456789abcdef", tolower(substr(s, i, 1))) - 1;
    return v }'

failures=0
fail() { echo "FAIL $file: $*"; failures=$((failures + 1)); }
pass() { echo "ok   $file: $*"; }

check_zip() {
    if ! out=$(unzip -tq "$file" 2>&1); then
        fail "zip: $out"
    elif echo "$out" | grep -qi warning; then
        fail "zip: $out"
    else
        pass "zip ($(unzip -Z1 "$file" | wc -l | tr -d ' ') entries)"
    fi
}

check_pe() {
    if ! out=$("$COSMOCC/bin/pecheck" "$file" 2>&1); then
        fail "pe: pecheck: $out"
        return
    fi
    p=$(objdump -p "$file" 2>&1) || { fail "pe: objdump: $p"; return; }
    echo "$p" | grep -q 'file format pei-x86-64' || fail "pe: not pei-x86-64"
    echo "$p" | grep -q '^Magic[[:space:]]*020b' || fail "pe: not PE32+"
    echo "$p" | grep -q '^Subsystem.*(Windows CUI)' || fail "pe: not a console program"
    echo "$p" | grep -q 'NX_COMPAT' || fail "pe: no NX_COMPAT"
    size=$(wc -c < "$file" | tr -d ' ')
    # objdump -h: "Idx Name Size VMA LMA File off Algn", then a line
    # of flags (CODE, DATA, READONLY ...) for each section.
    bad=$(objdump -h "$file" | awk -v size="$size" "$HEX"'
        /^ *[0-9]+ / { name = $2; len = hex($3); off = hex($6); next }
        name != "" {
            if (off + len > size) print name ": outside the file";
            if ($0 ~ /CODE/ && $0 !~ /READONLY/) print name ": writable code";
            name = "" }')
    [ -z "$bad" ] || fail "pe: $bad"
    pass "pe"
}

check_elf() {
    arch=$1 flag=$2 machine=$3
    elf=$tmp/$(basename "$file").$arch.elf
    "$COSMOCC/bin/assimilate" -e "$flag" -o "$elf" "$file" >/dev/null || { fail "elf $arch: assimilate"; return; }
    h=$(readelf -hlW "$elf" 2>&1) || { fail "elf $arch: readelf: $h"; return; }
    echo "$h" | grep -q 'Type:[[:space:]]*EXEC' || fail "elf $arch: not EXEC"
    echo "$h" | grep -q "Machine:[[:space:]]*$machine" || fail "elf $arch: not $machine"
    size=$(wc -c < "$elf" | tr -d ' ')
    entry=$(echo "$h" | awk '/Entry point address:/ { print $4 }')
    bad=$(echo "$h" | awk -v size="$size" -v entry="$entry" "$HEX"'
        BEGIN { e = hex(entry); in_x = 0 }
        $1 == "LOAD" || $1 == "GNU_STACK" || $1 == "TLS" || $1 == "NOTE" {
            off = hex($2); va = hex($3); fsz = hex($5); msz = hex($6);
            flg = ""; for (i = 7; i < NF; i++) flg = flg $i;
            if (flg ~ /W/ && flg ~ /E/) print $1 " at " $3 ": writable and executable";
            if ($1 == "GNU_STACK") { stack = 1; if (flg ~ /E/) print "executable stack" }
            if ($1 == "LOAD" && off + fsz > size) print "LOAD at " $3 ": outside the file";
            if ($1 == "LOAD" && flg ~ /E/ && e >= va && e < va + msz) in_x = 1 }
        END { if (!stack) print "no GNU_STACK"; if (!in_x) print "entry point not in an executable LOAD" }')
    [ -z "$bad" ] || fail "elf $arch: $bad"
    pass "elf $arch"
}

check_macho() {
    macho=$tmp/$(basename "$file").x86_64.macho
    "$COSMOCC/bin/assimilate" -m -x -o "$macho" "$file" >/dev/null || { fail "macho: assimilate"; return; }
    h=$("$objdump_macho" --macho --private-headers "$macho" 2>&1) || { fail "macho: $h"; return; }
    echo "$h" | grep -q 'MH_MAGIC_64[[:space:]]*X86_64.*EXECUTE' || fail "macho: not an x86_64 executable"
    size=$(wc -c < "$macho" | tr -d ' ')
    bad=$(echo "$h" | awk -v size="$size" "$HEX"'
        $1 == "segname" { seg = $2 }
        $1 == "vmaddr" { va = hex($2) }
        $1 == "vmsize" { vs = hex($2) }
        $1 == "fileoff" { off = $2 + 0 }
        $1 == "filesize" { fsz = $2 + 0; if (off + fsz > size) print seg ": outside the file" }
        $1 == "initprot" {
            if ($2 ~ /w/ && $2 ~ /x/) print seg ": starts writable and executable";
            if ($2 ~ /x/) { xs[seg] = va; xe[seg] = va + vs } }
        { for (i = 1; i < NF; i++) if ($i == "rip") rip = hex($(i + 1)) }
        END { ok = 0; for (s in xs) if (rip >= xs[s] && rip < xe[s]) ok = 1;
              if (!ok) print "start address not in an executable segment" }')
    [ -z "$bad" ] || fail "macho: $bad"
    pass "macho x86_64"
}

for file in "$@"; do
    [ -f "$file" ] || { echo "FAIL $file: no such file"; failures=$((failures + 1)); continue; }
    check_zip
    check_pe
    check_elf x86_64 -x 'Advanced Micro Devices X86-64'
    check_elf aarch64 -a 'AArch64'
    check_macho
done
if [ "$failures" -gt 0 ]; then
    echo "check_format: $failures failures"
    exit 1
fi
