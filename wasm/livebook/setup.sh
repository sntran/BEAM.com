#!/bin/sh
# Livebook on Cloudflare Workers (docs/WASM.md, "Livebook in a Durable
# Object"): Livebook with its embedded runtime, one Durable Object for each
# tenant. The files of /data (the notebooks and the settings) stay in the
# SQLite storage of the object (BEAM_PERSIST). The Learn section has the
# notebook beam_on_the_edge.livemd, after the welcome notebook.
#
#   BEAM_COM=/path/to/beam.com wasm/livebook/setup.sh [DIR]
#
# It makes DIR/livebook (the Hex package of Livebook with the changes of
# livebook.patch), its release, and the Workers (DIR/worker), and prints the
# commands to deploy. It needs curl, patch and Node.js 26.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${BEAM_COM:?set BEAM_COM}"
DIR=${1:-$HERE/build}
NODE=${NODE:-node}
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
# the notebook of the edge in the Learn section).
if [ ! -d livebook ]; then
    curl -sSfL -o livebook.tar "https://repo.hex.pm/tarballs/livebook-$VSN.tar"
    mkdir livebook
    tar -xOf livebook.tar contents.tar.gz | tar -xzf - -C livebook
    (cd livebook && patch -p1 < "$HERE/livebook.patch")
fi
cp "$HERE/beam_on_the_edge.livemd" livebook/lib/livebook/notebook/learn/
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
# One Durable Object for each tenant (BEAM_TENANTS), with -Mea min (no
# allocators of ERTS: 40 MB less memory), and /data in its storage.
"$NODE" -e '
const fs = require("fs"), p = "worker/wrangler.durable.jsonc";
const vars = { LIVEBOOK_PORT: "4000", LIVEBOOK_DEFAULT_RUNTIME: "embedded", BEAM_TENANTS: "cookie",
  BEAM_ERL_FLAGS: "-Mea min", BEAM_PERSIST: "/data", LIVEBOOK_DATA_PATH: "/data", LIVEBOOK_HOME: "/data" };
fs.writeFileSync(p, fs.readFileSync(p, "utf8")
  .replace(/"name": "livebook-durable"/, "\"name\": \"livebook\"")
  .replace(/"vars": \{[^}]*\}/, "\"vars\": " + JSON.stringify(vars)));'
cat <<EOF

Deploy (the release first):
  (cd $DIR/worker/release && wrangler deploy)
  cd $DIR/worker
  head -c 64 /dev/urandom | base64 | tr -d '\\n' | wrangler secret put LIVEBOOK_SECRET_KEY_BASE -c wrangler.durable.jsonc
  wrangler secret put LIVEBOOK_PASSWORD -c wrangler.durable.jsonc   # 12 characters or more
  wrangler deploy -c wrangler.durable.jsonc
Then open https://livebook.SUBDOMAIN.workers.dev/.tenant/NAME (a tenant).
EOF
