#!/bin/sh
# Builds the studio for Cloudflare Workers with beam.com
# (https://github.com/sntran/BEAM.com). Each visitor starts an instance: a
# Durable Object with its own VM, at /t/NAME/ (a path tenant). An instance
# lives 30 minutes. At most INSTANCES (5) run at one time, then new
# visitors wait in a queue, and one address has at most 2. The files of the
# project stay in the storage of the object (/data/studio) while the
# instance lives.
#
#   BEAM_COM=/path/to/beam.com scripts/wasm.sh [DIR]
#
# Then deploy from DIR (default: _build/wasm):
#
#   npx wrangler deploy -c wrangler.durable.jsonc
#
# Variables: WORKER, the name of the Worker (studio), and INSTANCES.
#
# Caution: an instance runs the code of its visitor, as a public instance
# of Livebook does. The Durable Object of the instance is its sandbox.
set -eu
: "${BEAM_COM:?set BEAM_COM to the path of beam.com}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR=${1:-$ROOT/_build/wasm}
WORKER=${WORKER:-studio}
INSTANCES=${INSTANCES:-5}

sh "$ROOT/scripts/release.sh"
cd "$ROOT"

# The build runs the release once on this computer, to find the modules of
# its boot.
rm -rf "$DIR"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/studio-wasm.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
STUDIO_ROOT="$TMP/root" PORT=0 "$BEAM_COM" _build/prod/rel/studio -o "$DIR" --target wasm32

# One Worker: release.bin is a module of the runtime Worker, not a second Worker.
mv "$DIR/release/release.bin" "$DIR/release.bin"
rm -rf "$DIR/release"
WORKER="$WORKER" INSTANCES="$INSTANCES" node -e '
const fs = require("fs"), p = process.argv[1] + "/wrangler.durable.jsonc", e = process.env;
const vars = {
  // Instances at /t/NAME/, with a landing page and a queue.
  BEAM_TENANTS: "path", BEAM_INSTANCES: e.INSTANCES, BEAM_INSTANCE_TTL: "1800",
  BEAM_INSTANCE_HOURS: "24", BEAM_INSTANCES_PER_IP: "2",
  BEAM_INSTANCE_TITLE: "phx.new on the edge",
  // No allocators of ERTS: a smaller VM. /data is in the storage of the object.
  BEAM_ERL_FLAGS: "-Mea min", BEAM_PERSIST: "/data",
  STUDIO_ROOT: "/data/studio", HOME: "/data",
};
let text = fs.readFileSync(p, "utf8")
  .replace(/"name": "[^"]*"/, `"name": "${e.WORKER}"`)
  .replace(/\n\s*"services": \[[^\]]*\],/, "");
text = /"vars": \{[^}]*\}/.test(text)
  ? text.replace(/"vars": \{[^}]*\}/, `"vars": ${JSON.stringify(vars)}`)
  : text.replace(/("name": "[^"]*",)/, `$1\n  "vars": ${JSON.stringify(vars)},`);
// A sweep each 30 minutes ends the old instances.
text = text.replace(/\n}\s*$/, ",\n  \"triggers\": { \"crons\": [\"*/30 * * * *\"] },\n  \"observability\": { \"enabled\": true }\n}\n");
fs.writeFileSync(p, text);' "$DIR"
echo "Built $DIR. Deploy: (cd $DIR && npx wrangler deploy -c wrangler.durable.jsonc)"
