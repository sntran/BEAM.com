#!/bin/sh
# The deploy command of Workers Builds (see build.sh): the iframe pages,
# and then the Worker of Livebook (with its release). Workers Builds gives
# CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID. The Worker has no
# secret.
set -eu
B=$(cd "$(dirname "$0")" && pwd)/build
(cd "$B/iframe" && npx --yes wrangler@4.144.0 deploy)
cd "$B/worker" && npx --yes wrangler@4.144.0 deploy -c wrangler.durable.jsonc
