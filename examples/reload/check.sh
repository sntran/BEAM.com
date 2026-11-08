#!/bin/sh
# New code in a running program, from end to end (README.md): version 1
# of examples/reload, built with BEAM_COM, runs. Then zip puts versions 2
# and 3 of some modules into its file, and the program loads them.
#
#   examples/reload/check.sh BEAM_COM [PORT]
#
# RUNNER is the command that starts an APE file (default sh), as for
# tests/run.sh. Unix only: on Windows a running file cannot get a new
# file in its place.
set -u
[ $# -ge 1 ] || { echo "usage: $0 BEAM_COM [PORT]" >&2; exit 2; }
command -v zip > /dev/null || { echo "$0: zip (Info-ZIP) is not installed" >&2; exit 2; }
beam_com=$1 port=${2:-18461}
run=${RUNNER:-sh}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
pids=
# At the end, stop the programs that still run (after a failure).
trap 'for p in $pids; do kill "$p" 2> /dev/null; done; rm -rf "$work"' EXIT

BEAM_COM_CACHE=$work/cache
export BEAM_COM_CACHE
cp -R "$here" "$work/reload"
$run "$beam_com" "$work/reload" -o "$work/reload.com" > "$work/build.log" 2>&1 || {
    cat "$work/build.log"
    exit 1
}
chmod +x "$work/reload.com"

# One command to the program on PORT: the line of its answer.
ask() {
    $run "$beam_com" -noshell -eval "
        {ok, S} = gen_tcp:connect({127,0,0,1}, $1, [binary, {packet, line}, {active, false}]),
        ok = gen_tcp:send(S, <<\"$2\\n\">>),
        {ok, L} = gen_tcp:recv(S, 0, 5000),
        io:put_chars(L), halt()." 2> /dev/null
}

# Wait (at most 20 s) until the answer to a command matches a pattern.
wait_for() {
    i=0
    while [ $i -lt 100 ]; do
        answer=$(ask "$1" "$2")
        if echo "$answer" | grep -q "$3"; then
            return 0
        fi
        sleep 0.2
        i=$((i + 1))
    done
    echo "no answer of $2 that matches $3; the last one: $answer"
    return 1
}

# Version N of some modules, compiled into $work/stage, and put into the
# file of the program with zip (which writes a new file and renames it).
version() {
    rm -rf "$work/stage"
    ebin=$work/stage/lib/reload-1.0.0/ebin
    mkdir -p "$ebin"
    modules=$*
    for m in $modules; do
        sed -e "s/^version() -> \"v1\"\./version() -> \"v$n\"./" \
            -e "s/^-define(VERSION, 1)\./-define(VERSION, $n)./" \
            "$here/src/$m.erl" > "$work/$m.erl"
    done
    (cd "$work" && $run "$beam_com" -noshell -eval "
        [{ok, _} = compile:file(M, [{outdir, \"$ebin\"}, debug_info]) || M <- string:lexemes(\"$modules\", \" \")],
        halt().") || exit 1
    (cd "$work/stage" && zip -qr "$work/reload.com" lib) || exit 1
}

RELOAD_PORT=$port BEAM_COM_RELOAD=200 $run "$work/reload.com" > "$work/run.log" 2>&1 &
pids="$pids $!"
wait_for "$port" hello '^v1 1$' || exit 1
echo "hello: $(ask "$port" hello)"

# Version 2 of reload_text and reload_loop. reload_server has the same
# code (with its debug information now): it does not load again, and its
# state stays.
n=2 version reload_text reload_loop reload_server
wait_for "$port" status 'last => {ok,' || exit 1
echo "status: $(ask "$port" status)"
echo "hello: $(ask "$port" hello)"
# The loop of reload_loop still runs version 1, now the old code.
echo "loop: $(ask "$port" loop)"

# Version 3 of reload_loop waits: a process runs the old code (version 1).
n=3 version reload_loop
wait_for "$port" status 'waiting' || exit 1
echo "status: $(ask "$port" status)"
# The loop moves to the current code (version 2). Then version 3 loads.
echo "move: $(ask "$port" move)"
wait_for "$port" status 'last => {ok,\[reload_loop\]}' || exit 1
echo "status: $(ask "$port" status)"
echo "after move: $(ask "$port" loop)"

# BEAM_COM_RELOAD=0: no reload.
cp "$work/reload.com" "$work/off.com"
RELOAD_PORT=$((port + 1)) BEAM_COM_RELOAD=0 $run "$work/off.com" > "$work/off.log" 2>&1 &
pids="$pids $!"
wait_for $((port + 1)) hello '^v2 1$' || exit 1
echo "off: $(ask $((port + 1)) status)"
grep -h "beam.com: loaded\|beam.com: new code" "$work/run.log"
