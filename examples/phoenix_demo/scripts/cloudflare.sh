#!/bin/sh
# Builds the demo for Cloudflare Workers with beam.com (https://github.com/sntran/BEAM.com).
# The result is one Worker. It holds the runtime (BEAM in WebAssembly) and the
# release. One Durable Object runs the server, and its SQLite storage keeps the
# database.
#
#   BEAM_COM=/path/to/beam.com SUBDOMAIN=NAME scripts/cloudflare.sh [DIR]
#
# Then deploy from DIR (default: _build/cloudflare). The first deploy also
# sets the secret SECRET_KEY_BASE, from a file with one line
# SECRET_KEY_BASE=... (make it with `mix phx.gen.secret`):
#
#   npx wrangler deploy -c wrangler.durable.jsonc --secrets-file FILE
#
# Variables:
# - SUBDOMAIN: the workers.dev subdomain of the account, for PHX_HOST.
# - WORKER: the name of the Worker (phoenix).
set -eu
: "${BEAM_COM:?set BEAM_COM to the path of beam.com}"
: "${SUBDOMAIN:?set SUBDOMAIN to the workers.dev subdomain of the account}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR=${1:-$ROOT/_build/cloudflare}
WORKER=${WORKER:-phoenix}

# beam.com runs Mix when its name is mix.com.
BIN=$ROOT/_build/cloudflare-bin
mkdir -p "$BIN"
ln -sf "$BEAM_COM" "$BIN/mix.com"
export PATH="$BIN:$PATH" MIX_ENV=prod
cd "$ROOT"
mix.com local.hex --force --if-missing
mix.com deps.get --only prod
mix.com compile
mix.com assets.deploy
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
};
fs.writeFileSync(p, fs.readFileSync(p, "utf8")
  .replace(/"name": "[^"]*"/, `"name": "${e.WORKER}"`)
  .replace(/\n\s*"services": \[[^\]]*\],/, "")
  .replace(/"vars": \{[^}]*\}/, `"vars": ${JSON.stringify(vars)}`)
  .replace(/\n}\s*$/, ",\n  \"observability\": { \"enabled\": true }\n}\n"));' "$DIR"
echo "Built $DIR. Deploy: (cd $DIR && npx wrangler deploy -c wrangler.durable.jsonc)"
