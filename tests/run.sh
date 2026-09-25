#!/bin/sh
# Run beam.com and greeter.com, and check what they print.
# Usage: tests/run.sh DIR   (DIR holds beam.com and, if made, greeter.com)
set -u
dir=${1:-.}
fail=0

check() {
    name=$1 pattern=$2
    shift 2
    echo "==> $name"
    chmod +x "$dir/$name"
    # Run through sh, as a user without binfmt_misc would do it.
    out=$(sh "$dir/$name" "$@" 2>&1)
    rc=$?
    printf '%s\n' "$out"
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
