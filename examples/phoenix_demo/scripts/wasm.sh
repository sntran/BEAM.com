#!/bin/sh
# Builds the demo for Cloudflare Workers and Deno Deploy with beam.com
# (https://github.com/sntran/BEAM.com). The result is one directory for both.
# It holds the runtime (BEAM in WebAssembly) and the release. On Workers, one
# Durable Object runs the server, and its SQLite storage keeps the database.
# On Deno Deploy, each isolate runs the server, and SQLite in the VM keeps
# the pages of the database in Deno KV.
#
#   BEAM_COM=/path/to/beam.com SUBDOMAIN=NAME scripts/wasm.sh [DIR]
#
# Then deploy from DIR (default: _build/wasm). The first deploy also sets the
# secret SECRET_KEY_BASE, from a file with one line SECRET_KEY_BASE=... (make
# it with `mix phx.gen.secret`):
#
#   npx wrangler deploy -c wrangler.durable.jsonc --secrets-file FILE
#
# For Deno Deploy (DENO_ORG given), DIR/deno.env has the variables of the app:
#
#   deno deploy create . --org ORG --app APP --source local \
#     --runtime-mode dynamic --entrypoint deno.js
#   deno deploy database provision DB --kind denokv --org ORG
#   deno deploy database assign DB --org ORG --app APP
#   deno deploy env load deno.env --org ORG --app APP
#   deno deploy env add SECRET_KEY_BASE VALUE --secret --org ORG --app APP
#   deno deploy . --org ORG --app APP --prod
#
# Variables:
# - SUBDOMAIN: the workers.dev subdomain of the account, for PHX_HOST.
# - WORKER: the name of the Worker (phoenix).
# - DENO_ORG, DENO_APP: the organization and the app on Deno Deploy (DENO_APP
#   defaults to WORKER), for PHX_HOST there.
set -eu
: "${BEAM_COM:?set BEAM_COM to the path of beam.com}"
: "${SUBDOMAIN:?set SUBDOMAIN to the workers.dev subdomain of the account}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR=${1:-$ROOT/_build/wasm}
WORKER=${WORKER:-phoenix}

# beam.com runs Mix when its name is mix.com.
BIN=$ROOT/_build/wasm-bin
mkdir -p "$BIN"
ln -sf "$BEAM_COM" "$BIN/mix.com"
export PATH="$BIN:$PATH" MIX_ENV=prod
cd "$ROOT"
mix.com local.hex --force --if-missing
mix.com deps.get --only prod
mix.com compile
mix.com assets.deploy
# mix release keeps the directories of old versions in lib/. Remove them.
rm -rf _build/prod/rel/phoenix_demo
RELEASE_ERTS=false mix.com release --overwrite

# The build runs the release once on this computer, to find the modules of its
# boot. runtime.exs needs a database and a secret for that run.
rm -rf "$DIR"
NATIVE=$(mktemp -d)
DATABASE_PATH="$NATIVE/native.db" SECRET_KEY_BASE=$(mix.com phx.gen.secret) \
    "$BEAM_COM" _build/prod/rel/phoenix_demo -o "$DIR" --target wasm32
rm -rf "$NATIVE"

# One Worker: release.bin is a module of the runtime Worker, not a second Worker.
mv "$DIR/release/release.bin" "$DIR/release.bin"
rm -rf "$DIR/release"
WORKER="$WORKER" SUBDOMAIN="$SUBDOMAIN" node -e '
const fs = require("fs"), p = process.argv[1] + "/wrangler.durable.jsonc", e = process.env;
const vars = {
  PHX_HOST: `${e.WORKER}.${e.SUBDOMAIN}.workers.dev`,
  // The database is the SQLite storage of the Durable Object; the path is a name.
  DATABASE_PATH: "/data/phoenix_demo.db",
  // No allocators of ERTS: a smaller VM.
  BEAM_ERL_FLAGS: "-Mea min",
  // beam.com sets PHX_SERVER for a release with phoenix. A beam.com
  // older than the fix of split_dir (sntran/BEAM.com#43) does not find
  // phoenix-1.9.0-dev (a version with "-"), so set it here too.
  PHX_SERVER: "true",
};
let text = fs.readFileSync(p, "utf8")
  .replace(/"name": "[^"]*"/, `"name": "${e.WORKER}"`)
  .replace(/\n\s*"services": \[[^\]]*\],/, "");
// Some templates have no "vars" key. Then add the key after "name".
text = /"vars": \{[^}]*\}/.test(text)
  ? text.replace(/"vars": \{[^}]*\}/, `"vars": ${JSON.stringify(vars)}`)
  : text.replace(/("name": "[^"]*",)/, `$1\n  "vars": ${JSON.stringify(vars)},`);
if (!text.includes("\"observability\""))
  text = text.replace(/\n}\s*$/, ",\n  \"observability\": { \"enabled\": true }\n}\n");
fs.writeFileSync(p, text);' "$DIR"
# The same variables for Deno Deploy, with its host name.
if [ -n "${DENO_ORG:-}" ]; then
    cat > "$DIR/deno.env" <<ENV
PHX_HOST=${DENO_APP:-$WORKER}.$DENO_ORG.deno.net
DATABASE_PATH=/data/phoenix_demo.db
BEAM_ERL_FLAGS="-Mea min"
PHX_SERVER=true
ENV
fi
echo "Built $DIR. Deploy to Workers: (cd $DIR && npx wrangler deploy -c wrangler.durable.jsonc)"
echo "Deploy to Deno Deploy: see the top of scripts/wasm.sh"
