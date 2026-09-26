#!/bin/sh
# Run beam.com and the example programs, and check what they print.
# Usage: tests/run.sh DIR   (DIR holds beam.com and, if made, the example
#                            releases). Run it from the top of the
#                            repository to also test "beam.com build".
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

greeter='said hello 3 times'
crypto_check='sha256(abc) = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad@@hmac-sha256 = 5031fe3d989c6d1537a013fa6e739da23463fdaec3b70137d828e36ace221bd0@@16 random bytes = 16 bytes@@aes-256-gcm round trip = hello'
tls_check='ports: ok@@tls: local handshake ok@@tls: remote [^ ]* ok'
hashsum='^ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc$'

check beam.com 'Arguments   : \["hello","world"\]' hello world

# Releases made with rebar3 and added with zip (by CI).
for app in greeter crypto_check tls_check; do
    if [ -f "$dir/$app.com" ]; then
        eval "check $app.com \"\$$app\""
    fi
done

# beam.com build, on this system: the examples of the repository.
if [ -d examples ]; then
    check beam.com 'wrote .*hashsum.b.com' \
        build examples/hashsum.erl -o "$dir/hashsum.b.com"
    [ -f "$dir/hashsum.b.com" ] && check hashsum.b.com "$hashsum" abc
    for app in greeter crypto_check tls_check; do
        check beam.com "wrote .*$app.b.com" \
            build "examples/$app" -o "$dir/$app.b.com"
        if [ -f "$dir/$app.b.com" ]; then
            eval "check $app.b.com \"\$$app\""
        fi
    done
fi

# The SQLite probe: beam-sqlite.com (built with SQLITE=1).
sqlite='sqlite: version 3@@sqlite: json \["alpha","beta","gamma"\]@@sqlite: 3 rows in '
if [ -d examples ] && [ -f "$dir/beam-sqlite.com" ]; then
    check beam-sqlite.com 'wrote .*sqlite_check.b.com' \
        build examples/sqlite_check.erl -o "$dir/sqlite_check.b.com"
    if [ -f "$dir/sqlite_check.b.com" ]; then
        check sqlite_check.b.com "$sqlite:memory:"
        rm -f "$dir/test.db"
        check sqlite_check.b.com "${sqlite}$dir/test.db" "$dir/test.db"
    fi
fi
exit $fail
