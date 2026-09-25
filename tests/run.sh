#!/bin/sh
# Run beam.com and greeter.com, and check what they print.
# Usage: tests/run.sh DIR   (DIR holds beam.com and, if made, greeter.com)
#
# RUNNER is the command that starts an APE file (default: sh). On NetBSD
# and OpenBSD, sh stops at the NUL bytes of the APE header, so use the
# APE loader there: RUNNER=DIR/ape-x86_64.elf.
set -u
dir=${1:-.}
limit=${LIMIT:-120}
runner=${RUNNER:-sh}
tmp=${TMPDIR:-/tmp}/beam_com_test.$$
fail=0

check() {
    name=$1 pattern=$2
    shift 2
    echo "==> $name"
    chmod +x "$dir/$name"
    # Run through $runner (sh, as a user without binfmt_misc would do
    # it). A watchdog stops it after $limit seconds.
    [ "$runner" = sh ] || chmod +x "$runner"
    BEAM_COM_VERBOSE=1 $runner "$dir/$name" "$@" > "$tmp" 2>&1 &
    pid=$!
    ( sleep "$limit"; kill -9 "$pid" ) >/dev/null 2>&1 &
    watchdog=$!
    wait "$pid"
    rc=$?
    kill "$watchdog" 2>/dev/null
    out=$(cat "$tmp")
    printf '%s\n' "$out"
    if [ $rc -eq 137 ]; then
        echo "FAIL: $name did not stop in $limit seconds"
        ps -ef 2>/dev/null | grep -v grep | grep -e "$name" -e beam || true
    fi
    if [ $rc -ne 0 ]; then
        echo "FAIL: $name exited with $rc"
        fail=1
    elif ! printf '%s\n' "$out" | grep -q "$pattern"; then
        echo "FAIL: $name did not print \"$pattern\""
        fail=1
    else
        echo "PASS: $name"
    fi
}

check beam.com 'Arguments   : \["hello","world"\]' hello world
if [ -f "$dir/greeter.com" ]; then
    check greeter.com 'said hello 3 times'
fi
exit $fail
