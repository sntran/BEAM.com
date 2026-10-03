#!/bin/sh
# phoenix_demo.com on the hosts of the npm package, as in a project that
# deploys at each git push (the files of examples/phoenix_demo): the Worker
# in workerd (wrangler dev) and deno.js of the package in Deno. Each host
# gives the home page with TEXT, and the WebSocket of LiveView gives 101.
# The app has no variables: SECRET_KEY_BASE and PHX_HOST come from the VM.
#
#   sh tests/host/app_hosts.sh DIR
#
# DIR: package.json, worker.js, wrangler.jsonc, deno.json and app.com, and
# node_modules with beam.com, wrangler and deno.
set -eu
cd "$1"
export WRANGLER_SEND_METRICS=false

# NAME PORT TEXT LOG: the page and the WebSocket of the host on PORT.
check() {
    for i in $(seq 1 300); do curl -fs -o /dev/null --max-time 2 "http://127.0.0.1:$2/" && break; sleep 0.5; done
    if ! curl -fsS --compressed --max-time 120 "http://127.0.0.1:$2/" | grep -q "$3"; then
        echo "$1: the home page has no \"$3\""; tail -n 40 "$4"; return 1
    fi
    # The socket stays open: curl stops at its time limit, after the status.
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --http1.1 -H 'Connection: Upgrade' \
        -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
        -H "Origin: http://127.0.0.1:$2" "http://127.0.0.1:$2/live/websocket?vsn=2.0.0" || true)
    if [ "$code" != 101 ]; then
        echo "$1: the WebSocket of LiveView gave $code, not 101"; tail -n 40 "$4"; return 1
    fi
    echo "$1: the home page, and the WebSocket of LiveView (101)"
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
host workers.pid npx wrangler dev --port 18787 --ip 127.0.0.1 > wrangler.log 2>&1
check workers 18787 'LiveView on Cloudflare Workers' wrangler.log || status=1
stop workers.pid

host deno.pid npx deno serve -A --port 18788 node_modules/beam.com/runtime/deno.js app.com > deno.log 2>&1
check deno 18788 'LiveView on Deno' deno.log || status=1
stop deno.pid
exit "$status"
