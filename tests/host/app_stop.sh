#!/bin/sh
# A VM that stops, on the hosts of the npm package: workerd (wrangler dev)
# and Deno (deno serve), with app.com of tests/programs/stop_check.erl. A
# request with no answer in BEAM_REQUEST_TIMEOUT seconds gets 504. When the
# VM stops (erlang:halt/1, and a trap), its open request gets 503, and a
# later request gets 200 from a new VM.
#
#   sh tests/host/app_stop.sh DIR
#
# DIR: package.json, worker.js, wrangler.jsonc, deno.json and app.com, and
# node_modules with beam.com, wrangler and deno. With the wrangler.jsonc of
# examples/phoenix_demo, workerd runs the Durable Object; with the one of
# examples/worker, the stateless Worker.
set -eu
cd "$1"
export WRANGLER_SEND_METRICS=false BEAM_REQUEST_TIMEOUT=2
printf 'BEAM_REQUEST_TIMEOUT=2\n' > .dev.vars

# PORT PATH: the status of GET PATH (000: no answer in 20 s).
get() {
    curl --noproxy 127.0.0.1 -s -o /dev/null -w '%{http_code}' --max-time 20 "http://127.0.0.1:$1$2" || true
}

# NAME PORT LOG: the checks on the host on PORT.
check() {
    for i in $(seq 1 300); do [ "$(get "$2" /)" = 200 ] && break; sleep 0.5; done
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
check workers 18787 wrangler.log || status=1
stop workers.pid

host deno.pid npx deno serve -A --port 18788 worker.js > deno.log 2>&1
check deno 18788 deno.log || status=1
stop deno.pid
exit "$status"
