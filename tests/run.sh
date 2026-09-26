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
    else
        # The patterns are separated by "@@". Each one must be found.
        ok=1
        rest=$pattern
        while [ -n "$rest" ]; do
            p=${rest%%@@*}
            case $rest in *@@*) rest=${rest#*@@} ;; *) rest= ;; esac
            if ! printf '%s\n' "$out" | grep -q "$p"; then
                echo "FAIL: $name did not print \"$p\""
                ok=0
                fail=1
            fi
        done
        [ $ok -eq 1 ] && echo "PASS: $name"
    fi
}

check beam.com 'Arguments   : \["hello","world"\]' hello world
if [ -f "$dir/greeter.com" ]; then
    check greeter.com 'said hello 3 times'
fi
if [ -f "$dir/crypto_check.com" ]; then
    check crypto_check.com \
        'sha256(abc) = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad@@hmac-sha256 = 5031fe3d989c6d1537a013fa6e739da23463fdaec3b70137d828e36ace221bd0@@16 random bytes = 16 bytes@@aes-256-gcm round trip = hello'
fi
if [ -f "$dir/tls_check.com" ]; then
    check tls_check.com 'ports: \(ok\|not supported on windows\)@@tls: local handshake ok@@tls: remote [^ ]* ok'
fi
exit $fail
