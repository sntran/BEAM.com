#!/bin/sh
# Livebook on Cloudflare Workers (docs/history/WASM-LOG.md, "Livebook in a Durable
# Object"): a public Livebook with its embedded runtime. Each visitor starts
# an instance of its own (a Durable Object at /t/NAME, durable.js), with a
# time limit. A registry limits the instances at one time and keeps a
# queue. The files of /data (the notebooks and the settings) stay in the
# SQLite storage of the object (BEAM_PERSIST) until the limit. The Learn
# section has only the notebooks of beam.com (docs/notebooks).
#
#   BEAM_COM=/path/to/beam.com SUBDOMAIN=NAME wasm/livebook/setup.sh [DIR]
#
# SUBDOMAIN is the workers.dev subdomain of the account (for the URL of the
# iframe Worker), and INSTANCES the instances at one time (5). It makes
# DIR/livebook (the Hex package of Livebook with the changes of
# livebook.patch), its release, the Worker (DIR/worker, with the release
# in it) and the iframe Worker (DIR/iframe), and prints the commands to
# deploy. RETIRE ("a,b,c") names objects of an earlier mode to delete once.
# It needs curl, patch and Node.js 22 or later.
#
# Caution: each visitor can run code in its instance, with the network, and
# instances have no password. The code of a visitor can read the vars and
# the secrets of the Worker: give it no secret. Livebook makes a random
# secret_key_base in each VM.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${BEAM_COM:?set BEAM_COM}"
DIR=${1:-$HERE/build}
NODE=${NODE:-node}
SUBDOMAIN=${SUBDOMAIN:-SUBDOMAIN}
INSTANCES=${INSTANCES:-5}
VSN=${LIVEBOOK_VSN:-0.19.10}
mkdir -p "$DIR/bin"
for t in mix iex elixir elixirc escript; do ln -sf "$BEAM_COM" "$DIR/bin/$t$( [ $t = escript ] || echo .com)"; done
export PATH="$DIR/bin:$PATH" MIX_HOME="$DIR/.mix" HEX_HOME="$DIR/.hex" MIX_ENV=prod
cd "$DIR"

# os_mon: Livebook starts it, and beam.com does not have it (a custom build
# with OTP_APPS=os_mon has it). Its Erlang code, from the source of the OTP
# of beam.com. The patch turns off its port programs.
OTP=$("$BEAM_COM" --version | sed -n 's/^ *Erlang\/OTP *: *//p')
OS_MON=https://raw.githubusercontent.com/erlang/otp/OTP-$OTP/lib/os_mon
if [ ! -f otp/os_mon.done ]; then
    rm -rf otp && mkdir -p otp/os_mon/src otp/os_mon/include otp/os_mon/ebin
    for f in cpu_sup disksup memsup nteventlog os_mon os_mon_mib os_mon_sysinfo os_sup; do
        curl -sSfL -o "otp/os_mon/src/$f.erl" "$OS_MON/src/$f.erl"
    done
    curl -sSfL -o otp/os_mon/src/os_mon.app.src "$OS_MON/src/os_mon.app.src"
    curl -sSfL -o otp/os_mon/include/memsup.hrl "$OS_MON/include/memsup.hrl"
    curl -sSfL -o otp/os_mon/vsn.mk "$OS_MON/vsn.mk"
    OS_MON_VSN=$(sed -n 's/^OS_MON_VSN *= *//p' otp/os_mon/vsn.mk)
    sed "s/%VSN%/$OS_MON_VSN/" otp/os_mon/src/os_mon.app.src > otp/os_mon/ebin/os_mon.app
    (cd otp/os_mon && BEAM_COM_ERL=1 "$BEAM_COM" -noshell -eval '
        R = [compile:file(F, [return_errors, {outdir, "ebin"}, {i, "include"}])
             || F <- filelib:wildcard("src/*.erl")],
        halt(case [E || E <- R, element(1, E) =/= ok] of [] -> 0; E -> io:format("~p~n", [E]), 1 end).')
    mv otp/os_mon "otp/os_mon-$OS_MON_VSN"
    touch otp/os_mon.done
fi
export ERL_LIBS="$DIR/otp"

# Livebook: the Hex package, with the changes of livebook.patch (no
# distribution, memory data with +Mea min, Kino and ExUnit in the release,
# only the notebooks of beam.com in the Learn section).
if [ ! -d livebook ]; then
    curl -sSfL -o livebook.tar "https://repo.hex.pm/tarballs/livebook-$VSN.tar"
    mkdir livebook
    tar -xOf livebook.tar contents.tar.gz | tar -xzf - -C livebook
    (cd livebook && patch -p1 < "$HERE/livebook.patch")
fi
# The notebooks of beam.com, with their index (the order, the text of the
# cards and the covers), for the Learn section (livebook.patch).
rm -rf livebook/lib/livebook/notebook/learn/beam
mkdir -p livebook/lib/livebook/notebook/learn/beam
cp "$HERE"/../../docs/notebooks/*.livemd "$HERE"/../../docs/notebooks/*.svg \
   "$HERE/../../docs/notebooks/index.exs" livebook/lib/livebook/notebook/learn/beam/
(cd livebook && mix.com local.hex --force --if-missing && mix.com deps.get &&
     mix.com release livebook --overwrite)

# The trusted root certificates of the runtime (TLS): the bundle of Mozilla
# that curl publishes, not the store of this computer.
curl -sSfL -o cacert.pem https://curl.se/ca/cacert.pem
curl -sSfL -o cacert.pem.sha256 https://curl.se/ca/cacert.pem.sha256
sha256sum -c cacert.pem.sha256

rm -rf worker
"$BEAM_COM" livebook/_build/prod/rel/livebook -o worker --target wasm32 --cacerts cacert.pem
# The static files of Livebook (12 MB) as the static assets of the Worker.
"$NODE" "$HERE/../erts/host/static.mjs" worker livebook
# The iframe pages of Livebook on their own site: Kino draws its JS outputs
# there. livebookusercontent.com does not have the page of this version.
rm -rf iframe && mkdir -p iframe/static/iframe
cp worker/static/iframe/*.html iframe/static/iframe/
IFRAME=$(cd iframe/static/iframe && ls v*.html | sort -V | tail -1)
printf '/iframe/*\n  Access-Control-Allow-Origin: *\n  Content-Type: text/html; charset=utf-8\n  Cache-Control: public, max-age=31536000\n' \
    > iframe/static/_headers
cat > iframe/wrangler.jsonc <<'JSON'
// The iframe pages of Livebook, on their own site: the JS outputs of Kino
// run there, apart from the pages and the cookies of Livebook.
{
  "name": "livebook-iframe",
  "compatibility_date": "2026-09-01",
  "assets": { "directory": "static", "html_handling": "none" }
}
JSON
# One Worker for Livebook: release.bin is a module of the runtime Worker
# (worker.js imports it when there is no binding APP), not a second Worker.
mv worker/release/release.bin worker/release.bin
rm -rf worker/release
# Instances (BEAM_TENANTS "path", BEAM_INSTANCES), with -Mea min (no
# allocators of ERTS: 20 MB less memory), /data in the storage, a sweep
# each 30 minutes, and the logs of the Worker in Cloudflare
# (observability). RETIRE: objects of an earlier mode, which the sweep
# deletes once (BEAM_RETIRE).
IFRAME_URL="https://livebook-iframe.$SUBDOMAIN.workers.dev/iframe/$IFRAME" INSTANCES="$INSTANCES" \
RETIRE="${RETIRE:-}" "$NODE" -e '
const fs = require("fs"), p = "worker/wrangler.durable.jsonc";
const vars = { LIVEBOOK_PORT: "4000", LIVEBOOK_DEFAULT_RUNTIME: "embedded", LIVEBOOK_TOKEN_ENABLED: "false",
  LIVEBOOK_IFRAME_URL: process.env.IFRAME_URL, BEAM_TENANTS: "path", BEAM_INSTANCES: process.env.INSTANCES,
  BEAM_INSTANCE_TTL: "1800", BEAM_INSTANCE_HOURS: "24", BEAM_INSTANCES_PER_IP: "2",
  BEAM_INSTANCE_TITLE: "Livebook on the edge",
  BEAM_ERL_FLAGS: "-Mea min", BEAM_PERSIST: "/data", LIVEBOOK_DATA_PATH: "/data", LIVEBOOK_HOME: "/data" };
if (process.env.RETIRE) vars.BEAM_RETIRE = process.env.RETIRE;
fs.writeFileSync(p, fs.readFileSync(p, "utf8")
  .replace(/"name": "livebook-durable"/, "\"name\": \"livebook\"")
  .replace(/\n\s*"services": \[[^\]]*\],/, "")
  .replace(/"vars": \{[^}]*\}/, "\"vars\": " + JSON.stringify(vars))
  .replace(/\n}\s*$/, ",\n  \"triggers\": { \"crons\": [\"*/30 * * * *\"] },\n  \"observability\": { \"enabled\": true }\n}\n"));'
cat <<EOF

Deploy (the iframe Worker first):
  (cd $DIR/iframe && wrangler deploy)
  (cd $DIR/worker && wrangler deploy -c wrangler.durable.jsonc)
Then open https://livebook.$SUBDOMAIN.workers.dev/ and start an instance.
EOF
