#!/bin/sh
# The deploy command of Workers Builds (see build.sh): the release, the
# iframe pages, and then the Worker of the instances. Workers Builds gives
# CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID. The secret
# LIVEBOOK_SECRET_KEY_BASE of the Worker stays from one deploy to the next.
set -eu
B=$(cd "$(dirname "$0")" && pwd)/build
(cd "$B/worker/release" && npx --yes wrangler@4 deploy)
(cd "$B/iframe" && npx --yes wrangler@4 deploy)
cd "$B/worker" && npx --yes wrangler@4 deploy -c wrangler.durable.jsonc
