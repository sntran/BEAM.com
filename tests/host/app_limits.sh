#!/bin/sh
# The limits of the hosts of the npm package: workerd (wrangler dev) and
# Deno (deno serve), with app.com of tests/programs/limits_check.erl. A
# body of 32 MB goes to the app in parts (with content-length, and chunked
# to an app that reads slowly), and the memory of the VM stays below 64 MB. A
# request with no answer in BEAM_REQUEST_TIMEOUT seconds gets 504. When the
# VM stops (erlang:halt/1, and a trap), its open request gets 503, and a
# later request gets 200 from a new VM. While a process computes (/spin), a
# Durable Object and Deno answer other requests: the scheduler gives the
# host turns (BEAM_YIELD_REDS). A plain Worker does not, so the script does
# not check it there.
#
#   sh tests/host/app_limits.sh DIR
#
# DIR: package.json, worker.js, wrangler.jsonc, deno.json and app.com, and
# node_modules with beam.com, wrangler and deno. With the wrangler.jsonc of
# examples/phoenix_demo, workerd runs the Durable Object; with the one of
# examples/worker, the stateless Worker.
set -eu
cd "$1"
# 8 s: /spin computes for 1 to 3 s on a CI runner, and must end with 200.
export WRANGLER_SEND_METRICS=false BEAM_REQUEST_TIMEOUT=8
printf 'BEAM_REQUEST_TIMEOUT=8\n' > .dev.vars

# PORT PATH: the status of GET PATH (000: no answer in 20 s).
get() {
    curl --noproxy 127.0.0.1 -s -o /dev/null -w '%{http_code}' --max-time 20 "http://127.0.0.1:$1$2" || true
}

# PORT PATH: the seconds of GET PATH.
seconds() {
    curl --noproxy 127.0.0.1 -s -o /dev/null -w '%{time_total}' --max-time 60 "http://127.0.0.1:$1$2" || true
}

head -c 33554432 /dev/urandom > body.bin

# PORT PATH [chunked]: the answer of a POST of body.bin to PATH (with
# "chunked", with no content-length).
upload() {
    if [ "${3:-}" = chunked ]; then
        curl --noproxy 127.0.0.1 -s --max-time 120 -H 'Transfer-Encoding: chunked' \
            --data-binary @body.bin "http://127.0.0.1:$1$2" || true
    else
        curl --noproxy 127.0.0.1 -s --max-time 120 --data-binary @body.bin "http://127.0.0.1:$1$2" || true
    fi
}

# NAME PORT LOG [turns]: the checks on the host on PORT. With "turns", also
# the answer of / while /spin computes.
check() {
    for i in $(seq 1 300); do [ "$(get "$2" /)" = 200 ] && break; sleep 0.5; done
    out=$(upload "$2" /upload)
    [ "$out" = "got 33554432" ] || { echo "$1: /upload gave \"$out\""; tail -n 40 "$3"; return 1; }
    out=$(upload "$2" /upload-slow chunked)
    [ "$out" = "got 33554432" ] || { echo "$1: /upload-slow (chunked) gave \"$out\""; tail -n 40 "$3"; return 1; }
    peak=$(sed -n 's/.*beam: memory \([0-9]*\) MB (a new peak.*/\1/p' "$3" | sort -n | tail -n 1)
    [ "${peak:-0}" -lt 64 ] || { echo "$1: the memory of the VM grew to $peak MB with the uploads"; tail -n 40 "$3"; return 1; }
    if [ -n "$peak" ]; then echo "$1: two uploads of 32 MB, the memory of the VM at $peak MB at most"
    else echo "$1: two uploads of 32 MB, with no new peak of the memory of the VM"; fi
    if [ "${4:-}" = turns ]; then
        get "$2" /spin > spin.code &
        spin=$!
        sleep 1
        t=$(seconds "$2" /)
        wait "$spin"
        [ "$(cat spin.code)" = 200 ] || { echo "$1: /spin gave $(cat spin.code), not 200"; tail -n 40 "$3"; return 1; }
        awk "BEGIN { exit !($t < 2) }" ||
            { echo "$1: / took $t s while /spin computed (2 s at most)"; tail -n 40 "$3"; return 1; }
        echo "$1: / in $t s while /spin computed"
    fi
    code=$(get "$2" /slow)
    [ "$code" = 504 ] || { echo "$1: /slow gave $code, not 504"; tail -n 40 "$3"; return 1; }
    for p in /halt /abort; do
        code=$(get "$2" $p)
        [ "$code" = 503 ] || { echo "$1: $p gave $code, not 503"; tail -n 40 "$3"; return 1; }
        # A Durable Object resets first: 503 (retry-after: 1) until then.
        for i in $(seq 1 50); do code=$(get "$2" /); [ "$code" = 200 ] && break; sleep 0.2; done
        [ "$code" = 200 ] || { echo "$1: after $p, / gave $code, not 200"; tail -n 40 "$3"; return 1; }
    done
    grep -q 'beam: the VM stopped (exit status 3)' "$3" || { echo "$1: no log of the stop"; tail -n 40 "$3"; return 1; }
    echo "$1: /slow 504; /halt and /abort 503, and then 200 from a new VM"
}

# Each host in its own session (see app_hosts.sh).
host() {
    setsid sh -c 'echo $$ > "$0"; exec "$@"' "$@" &
    for i in $(seq 1 100); do [ -s "$1" ] && break; sleep 0.1; done
}
stop() {
    kill -9 "-$(cat "$1")" 2>/dev/null || true
}

status=0
rm -f workers.pid deno.pid
host workers.pid npx wrangler dev --port 18787 --ip 127.0.0.1 > wrangler.log 2>&1
turns=
grep -q durable_objects wrangler.jsonc && turns=turns
check workers 18787 wrangler.log $turns || status=1
stop workers.pid

host deno.pid npx deno serve -A --port 18788 worker.js > deno.log 2>&1
check deno 18788 deno.log turns || status=1
stop deno.pid
exit "$status"
