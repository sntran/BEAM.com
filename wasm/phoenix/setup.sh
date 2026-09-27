#!/bin/sh
# Make the Phoenix LiveView app of the WebAssembly spike (docs/WASM.md):
# mix phx.new hello (no Ecto, no assets), a counter LiveView at /counter,
# and a release without ERTS (_build/prod/rel/hello).
#
#   BEAM_COM=/path/to/beam.com wasm/phoenix/setup.sh [DIR]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${BEAM_COM:?set BEAM_COM}"
DIR=${1:-$HERE/build}
mkdir -p "$DIR/bin"
for t in mix iex elixir elixirc escript; do ln -sf "$BEAM_COM" "$DIR/bin/$t$( [ $t = escript ] || echo .com)"; done
export PATH="$DIR/bin:$PATH" MIX_HOME="$DIR/.mix" HEX_HOME="$DIR/.hex" MIX_ENV=prod
cd "$DIR"
mix.com archive.install hex phx_new --force
[ -d hello ] || mix.com phx.new hello --no-ecto --no-mailer --no-dashboard --no-gettext --no-assets --no-install
cd hello
mkdir -p lib/hello_web/live
cp "$HERE/counter_live.ex" lib/hello_web/live/
grep -q 'live "/counter"' lib/hello_web/router.ex ||
    sed -i 's|    get "/", PageController, :home|    get "/", PageController, :home\n    live "/counter", CounterLive|' lib/hello_web/router.ex
grep -q 'releases:' mix.exs ||
    sed -i 's|      listeners: \[Phoenix.CodeReloader\]|      listeners: [Phoenix.CodeReloader],\n      releases: [hello: [include_erts: false, strip_beams: true]]|' mix.exs
mix.com deps.get
mix.com release --overwrite
