#!/bin/sh
# The ports to bindings of the hosts of the npm package, with app.com of
# tests/programs/ports_check.erl and the hosts of tests/host/ports/:
# workerd (wrangler dev) with the VM in a Durable Object and in a plain
# Worker, where the ports are Durable Objects, and Deno (deno serve), where
# the ports are the objects of serve(app, { env }). On each host: 4 MiB to
# a port and back, the sends to a port that reads slowly wait for it, a
# path that is no binding gives enoent, the bytes of a port through the
# VM, and the result of a port as the response (x-beam-port), with the
# response before and after the input of the port.
#
#   sh tests/host/app_ports.sh DIR
#
# DIR: app.com, deno.json, and node_modules with beam.com, wrangler and
# deno. The script copies the files of tests/host/ports/ into DIR.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cp "$here"/ports/* "$1/"
cd "$1"
export WRANGLER_SEND_METRICS=false

# PORT PATH: the body of GET PATH.
body() {
    curl --noproxy 127.0.0.1 -s --max-time 60 "http://127.0.0.1:$1$2" || true
}

# PORT PATH: the status of GET PATH (000: no answer in 60 s).
code() {
    curl --noproxy 127.0.0.1 -s -o /dev/null -w '%{http_code}' --max-time 60 "http://127.0.0.1:$1$2" || true
}

# PORT PATH SIZE: the body of PATH is the pattern of SIZE bytes of the VM.
same() {
    curl --noproxy 127.0.0.1 -s --max-time 60 -o got.bin "http://127.0.0.1:$1$2" || true
    curl --noproxy 127.0.0.1 -s --max-time 60 -o want.bin "http://127.0.0.1:$1/bytes/$3" || true
    [ "$(wc -c < want.bin)" -eq "$3" ] && cmp -s got.bin want.bin
}

# NAME PORT LOG: the checks on the host on PORT.
check() {
    for i in $(seq 1 300); do [ "$(code "$2" /)" = 200 ] && break; sleep 0.5; done
    for p in "/echo|echo 4194304 true" "/sink|sink 4194304 true" "/missing|missing enoent"; do
        path=${p%%|*} want=${p#*|}
        out=$(body "$2" "$path")
        [ "$out" = "$want" ] || { echo "$1: $path gave \"$out\", not \"$want\""; tail -n 40 "$3"; return 1; }
    done
    echo "$1: 4 MiB to a port and back, the sends wait for a slow port, and enoent"
    for p in "/through|4194304" "/splice|4194304" "/splice-after|1048576" "/splice-before|65536"; do
        path=${p%%|*} size=${p#*|}
        same "$2" "$path" "$size" || { echo "$1: $path did not give the $size bytes of the port"; tail -n 40 "$3"; return 1; }
    done
    out=$(code "$2" /splice-none)
    [ "$out" = 502 ] || { echo "$1: /splice-none gave $out, not 502"; tail -n 40 "$3"; return 1; }
    echo "$1: the bytes of a port through the VM, and as the response (x-beam-port)"
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
rm -f workers.pid plain.pid deno.pid
host workers.pid npx wrangler dev --port 18787 --ip 127.0.0.1 > wrangler.log 2>&1
check durable 18787 wrangler.log || status=1
stop workers.pid

host plain.pid npx wrangler dev -c wrangler.plain.jsonc --port 18789 --ip 127.0.0.1 > plain.log 2>&1
check plain 18789 plain.log || status=1
stop plain.pid

host deno.pid npx deno serve -A --port 18788 deno.js > deno.log 2>&1
check deno 18788 deno.log || status=1
stop deno.pid
exit "$status"
