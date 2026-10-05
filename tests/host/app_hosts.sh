#!/bin/sh
# An app.com on the hosts of the npm package, as in a project that deploys
# at each git push: the same worker.js in workerd (wrangler dev) and in
# Deno (deno serve). The app has no variables.
#
#   sh tests/host/app_hosts.sh DIR PATH WORKERS_TEXT DENO_TEXT [WS_PATH]
#
# DIR: package.json, worker.js, wrangler.jsonc, deno.json and app.com, and
# node_modules with beam.com, wrangler and deno. Each host gives PATH with
# its TEXT (in the headers or the body, in any case), and with WS_PATH the
# upgrade of a WebSocket there gives 101.
# examples/phoenix_demo is stateful (the Durable Object Beam), with the
# WebSocket of LiveView; examples/worker is stateless.
set -eu
cd "$1"
path=$2 workers_text=$3 deno_text=$4 ws=${5:-}
export WRANGLER_SEND_METRICS=false

# NAME PORT TEXT LOG: PATH and WS_PATH of the host on PORT.
check() {
    for i in $(seq 1 300); do curl -fs -o /dev/null --max-time 2 "http://127.0.0.1:$2$path" && break; sleep 0.5; done
    if ! curl -fsSi --compressed --max-time 120 "http://127.0.0.1:$2$path" | grep -qi "$3"; then
        echo "$1: $path has no \"$3\""; tail -n 40 "$4"; return 1
    fi
    [ -n "$ws" ] || { echo "$1: $path"; return 0; }
    # The socket stays open: curl stops at its time limit, after the status.
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --http1.1 -H 'Connection: Upgrade' \
        -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
        -H "Origin: http://127.0.0.1:$2" "http://127.0.0.1:$2$ws" || true)
    if [ "$code" != 101 ]; then
        echo "$1: the WebSocket of $ws gave $code, not 101"; tail -n 40 "$4"; return 1
    fi
    echo "$1: $path, and the WebSocket of $ws (101)"
}

# Each host in its own session: the shell there writes its process id,
# the id of the group, so that all the processes of the host stop (deno
# serve does not stop at SIGTERM).
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
check workers 18787 "$workers_text" wrangler.log || status=1
stop workers.pid

host deno.pid npx deno serve -A --port 18788 worker.js > deno.log 2>&1
check deno 18788 "$deno_text" deno.log || status=1
stop deno.pid
exit "$status"
