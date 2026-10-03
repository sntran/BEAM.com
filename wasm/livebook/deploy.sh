#!/bin/sh
# The deploy command of Workers Builds (see build.sh): the iframe pages,
# and then the Worker of Livebook (worker.js, wrangler.jsonc). setup.sh
# made build/livebook.com, build/iframe and node_modules/beam.com. Workers
# Builds gives CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID. The Worker
# has no secret.
#
# The vars of the account: SUBDOMAIN (the workers.dev subdomain, for the
# URL of the iframe pages), and optionally INSTANCES (the instances at one
# time) and RETIRE ("a,b,c": objects of an earlier mode, which the sweep
# deletes once).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${SUBDOMAIN:?set SUBDOMAIN}"
B=$HERE/build
IFRAME=$(cat "$B/iframe/version")
(cd "$B/iframe" && npx --yes wrangler@4.144.0 deploy)
set -- --var "LIVEBOOK_IFRAME_URL:https://livebook-iframe.$SUBDOMAIN.workers.dev/iframe/$IFRAME"
[ -z "${INSTANCES:-}" ] || set -- "$@" --var "BEAM_INSTANCES:$INSTANCES"
[ -z "${RETIRE:-}" ] || set -- "$@" --var "BEAM_RETIRE:$RETIRE"
cd "$HERE" && npx --yes wrangler@4.144.0 deploy "$@"
