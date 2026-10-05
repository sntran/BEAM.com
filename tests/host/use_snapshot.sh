#!/bin/sh
# The project DIR of tests/host/app_hosts.sh with the snapshot of the build
# of its app.com (npx beam.com --snapshot): worker.js gives it to
# serve(app, { snapshot }) and waits for beam.ready, and wrangler.jsonc
# gives *.snapshot files as Data modules. ARGS: more arguments of
# --snapshot (--full, --warm PATH).
#
#   sh tests/host/use_snapshot.sh DIR [ARGS]...
set -eu
cd "$1"
shift
rm -f wrangler.log deno.log
npx beam.com --snapshot app.com "$@"
sed -i -e "s|^import { serve } from 'beam.com';|import snapshot from './app.snapshot' with { type: 'bytes' };\n&|" \
    -e "s|^const beam = serve(app);|const beam = serve(app, { snapshot });\nawait beam.ready;|" worker.js
sed -i 's|"globs": \["\*\*/\*.com"\]|"globs": ["**/*.com", "**/*.snapshot"]|' wrangler.jsonc
grep -q 'serve(app, { snapshot })' worker.js
grep -q '"\*\*/\*.snapshot"' wrangler.jsonc
