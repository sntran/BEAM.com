#!/bin/sh
# The blue-green spike, from end to end (README.md): versions 1, 2 and 3
# of bluegreen.erl, built with BEAM_COM; an upgrade from version 1 to
# version 2 under load; then three upgrades that the server refuses.
#
#   examples/bluegreen/check.sh BEAM_COM [PORT] [N]
#
# RUNNER is the command that starts an APE file (default sh), as for
# tests/run.sh. Unix only: the new server starts with nohup.
set -u
[ $# -ge 1 ] || { echo "usage: $0 BEAM_COM [PORT] [N]" >&2; exit 2; }
beam_com=$1 port=${2:-18451} n=${3:-2000}
run=${RUNNER:-sh}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
# At the end, stop a server that is still running (after a failure).
trap '$run "$work/v1.com" stop "$port" > /dev/null 2>&1; rm -rf "$work"' EXIT

mkdir "$work/v2" "$work/v3"
sed 's/-define(VERSION, 1)\./-define(VERSION, 2)./' "$here/bluegreen.erl" > "$work/v2/bluegreen.erl"
# Version 3 refuses each state: no clause of its migrate/1 matches.
sed -e 's/-define(VERSION, 1)\./-define(VERSION, 3)./' \
    -e 's/^migrate(#{count := _} = State) ->/migrate(#{count := _} = State) when false ->/' \
    "$here/bluegreen.erl" > "$work/v3/bluegreen.erl"
BEAM_COM_CACHE=$work/cache
export BEAM_COM_CACHE
for v in 1 2 3; do
    case $v in 1) src=$here/bluegreen.erl ;; *) src=$work/v$v/bluegreen.erl ;; esac
    $run "$beam_com" "$src" -o "$work/v$v.com" > "$work/build.log" 2>&1 || {
        cat "$work/build.log"
        exit 1
    }
done
chmod +x "$work"/*.com

$run "$work/v1.com" serve "$port" > "$work/serve.log" 2>&1 &
$run "$work/v1.com" wait "$port" || exit 1
$run "$work/v1.com" load "$port" "$n" > "$work/load.log" 2>&1 &
load=$!
$run "$work/v1.com" upgrade "$port" "$work/v2.com"
wait "$load"
cat "$work/load.log"
# A state that migrate/1 refuses, a file that is not executable, and a
# file that does not exist.
for f in "$work/v3.com" "$work/build.log" "$work/none.com"; do
    $run "$work/v2.com" upgrade "$port" "$f"
done
$run "$work/v2.com" load "$port" 3
$run "$work/v2.com" stop "$port"
