#!/bin/sh
# Livebook on Cloudflare Workers (docs/history/WASM-LOG.md, "Livebook in a Durable
# Object"): a public Livebook with its embedded runtime. Each visitor starts
# an instance of its own (a Durable Object at /t/NAME, durable.js), with a
# time limit. A registry limits the instances at one time and keeps a
# queue. The files of /data (the notebooks and the settings) stay in the
# SQLite storage of the object (BEAM_PERSIST) until the limit. The Learn
# section has the documentation of beam.com as notebooks (docs/notebooks).
#
#   BEAM_COM=/path/to/beam.com wasm/livebook/setup.sh [DIR]
#
# It makes DIR/livebook (the Hex package of Livebook with the changes of
# livebook.patch) and its release, DIR/livebook.com (the release as one
# app.com), DIR/iframe (the iframe Worker), and node_modules/beam.com (the
# npm package of BEAM_COM). worker.js and wrangler.jsonc are the Worker,
# and deploy.sh deploys both Workers (DIR must be wasm/livebook/build). It
# needs curl, patch, unzip and Node.js 22 or later.
#
# Caution: each visitor can run code in its instance, with the network, and
# instances have no password. The code of a visitor can read the vars and
# the secrets of the Worker: give it no secret. Livebook makes a random
# secret_key_base in each VM.
#
# The same worker.js runs on Deno (deno serve). Deno has no Durable
# Objects: all the visitors of an isolate share one Livebook and see the
# sessions of the others. On Deno Deploy, the app "livebook" of beam.com
# has these variables:
#   LIVEBOOK_PORT=4000 LIVEBOOK_DEFAULT_RUNTIME=embedded
#   LIVEBOOK_TOKEN_ENABLED=false LIVEBOOK_DATA_PATH=/tmp LIVEBOOK_HOME=/tmp
#   LIVEBOOK_IFRAME_URL=https://livebook-iframe.SUBDOMAIN.workers.dev/iframe/vN.html
#   BEAM_SQLITE=off BEAM_CONNECT=example.com:80,hex.pm:443
# Caution: there, a visitor can run code for all the others, with the
# hosts of BEAM_CONNECT. Give the app no secret, and keep BEAM_CONNECT short.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${BEAM_COM:?set BEAM_COM}"
DIR=${1:-$HERE/build}
VSN=${LIVEBOOK_VSN:-0.19.10}
# The pins of the downloads: the SHA-256 of the Hex package of Livebook,
# the commit of the OTP tag (for the files of os_mon), and the dated CA
# bundle of curl with its SHA-256. For another version, give its pin.
LIVEBOOK_SHA256=${LIVEBOOK_SHA256:-0ebd5c52181f1f350eeaf97d9a9af22298734f800e93f403a2c472afffaa080c}
CACERT_DATE=${CACERT_DATE:-2026-09-25}
CACERT_SHA256=${CACERT_SHA256:-a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505}
check_sha256() {  # FILE EXPECTED
    [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ] || { echo "Bad SHA-256 of $1" >&2; exit 1; }
}
mkdir -p "$DIR/bin"
for t in mix iex elixir elixirc escript; do ln -sf "$BEAM_COM" "$DIR/bin/$t$( [ $t = escript ] || echo .com)"; done
export PATH="$DIR/bin:$PATH" MIX_HOME="$DIR/.mix" HEX_HOME="$DIR/.hex" MIX_ENV=prod
cd "$DIR"

# os_mon: Livebook starts it, and beam.com does not have it (a custom build
# with OTP_APPS=os_mon has it). Its Erlang code, from the source of the OTP
# of beam.com. The patch turns off its port programs.
OTP=$("$BEAM_COM" --version | sed -n 's/^ *Erlang\/OTP *: *//p')
# The files of the commit of the tag, not of the tag (a tag can move).
if [ -z "${OTP_COMMIT:-}" ] && [ "$OTP" = 29.1.1 ]; then
    OTP_COMMIT=ad05823719d77c8faee87348ea39513d4e2f99c5
fi
: "${OTP_COMMIT:?set OTP_COMMIT, the commit of the tag OTP-$OTP}"
OS_MON=https://raw.githubusercontent.com/erlang/otp/$OTP_COMMIT/lib/os_mon
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
    check_sha256 livebook.tar "$LIVEBOOK_SHA256"
    mkdir livebook
    tar -xOf livebook.tar contents.tar.gz | tar -xzf - -C livebook
    (cd livebook && patch -p1 < "$HERE/livebook.patch")
    cp "$HERE/livebook.patch" livebook/.beam.patch
elif ! cmp -s livebook/.beam.patch "$HERE/livebook.patch"; then
    # A new livebook.patch: take out the old one, and apply the new one.
    (cd livebook && patch -R -p1 < .beam.patch && patch -p1 < "$HERE/livebook.patch")
    cp "$HERE/livebook.patch" livebook/.beam.patch
fi
# The documentation of beam.com as the notebooks of the Learn section
# (livebook.patch): docs/notebooks/build.exs makes a notebook of each page,
# with the covers, the files and the index. The anatomy notebook gets the
# first bytes and the zip list of BEAM_COM.
elixir.com "$HERE/../../docs/notebooks/build.exs" \
    "$DIR/livebook/lib/livebook/notebook/learn/beam" "$BEAM_COM"
(cd livebook && mix.com local.hex --force --if-missing && mix.com deps.get &&
     mix.com release livebook --overwrite)

# The trusted root certificates of the runtime (TLS): the bundle of Mozilla
# that curl publishes, not the store of this computer.
curl -sSfL -o cacert.pem "https://curl.se/ca/cacert-$CACERT_DATE.pem"
check_sha256 cacert.pem "$CACERT_SHA256"

# Livebook as one app.com: the same file runs natively and in the Worker
# (worker.js, with the engine of the npm package beam.com). The engine
# serves the static files of Livebook from the file, before the VM.
"$BEAM_COM" livebook/_build/prod/rel/livebook -o livebook.com --cacerts cacert.pem
# The npm package beam.com of this beam.com (the runtime must be the one
# that built livebook.com), in node_modules/ of wasm/livebook.
rm -rf runtime-dir npm && mkdir npm
"$BEAM_COM" "$HERE/../../examples/hashsum.erl" -o runtime-dir --target wasm32 > /dev/null
(cd "$HERE/../.." && sh scripts/npm.sh "$BEAM_COM" "$DIR/runtime-dir" && npm pack --pack-destination "$DIR/npm" > /dev/null)
rm -rf runtime-dir
(cd "$HERE" && npm install --no-save --no-package-lock --no-audit --no-fund "$DIR"/npm/beam.com-*.tgz)
# The iframe pages of Livebook on their own site: Kino draws its JS outputs
# there. livebookusercontent.com does not have the page of this version.
rm -rf iframe && mkdir -p iframe/static/iframe
# Livebook has them as .gz files only.
unzip -j -q livebook.com 'lib/livebook-*/priv/static/iframe/*.html.gz' -d iframe/static/iframe
gunzip iframe/static/iframe/*.html.gz
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
echo "$IFRAME" > iframe/version
cat <<EOF

Deploy (the iframe Worker first): SUBDOMAIN=NAME sh $HERE/deploy.sh
Then open https://livebook.NAME.workers.dev/ and start an instance.
EOF
