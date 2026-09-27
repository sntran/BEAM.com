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

# The WebAssembly host adapter (wasm/phoenix/wasm_host): the Elixir side in
# lib/, the NIF stub in src/, and the adapter at run time with WASM_HOST=1.
mkdir -p lib/wasm_host src
cp "$HERE"/wasm_host/*.ex lib/wasm_host/
cp "$HERE/../erts/host/wasm_host.erl" src/
grep -q WASM_HOST config/runtime.exs || cat >> config/runtime.exs <<'EXS'

# The WebAssembly emulator: the JavaScript host serves HTTP and WebSockets.
if System.get_env("WASM_HOST") do
  config :hello, HelloWeb.Endpoint, adapter: WasmHost.PhoenixAdapter
end
EXS
# WebSockAdapter knows only a fixed list of adapters.
f=deps/websock_adapter/lib/websock_adapter.ex
grep -q WasmHost.Conn "$f" ||
    sed -i 's|^  defp tuple_for(adapter, _websock, _state, _opts),|  defp tuple_for(WasmHost.Conn, websock, state, opts), do: {websock, state, opts}\n\n  defp tuple_for(adapter, _websock, _state, _opts),|' "$f"

# No esbuild: app.js is phoenix.js, phoenix_live_view.js and the start of
# the LiveSocket, as the comments of the generated app.js say.
js=priv/static/assets/js/app.js
grep -q LiveSocket "$js" || {
    cat deps/phoenix/priv/static/phoenix.js deps/phoenix_live_view/priv/static/phoenix_live_view.js > "$js.new"
    cat >> "$js.new" <<'JS'

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {params: {_csrf_token: csrfToken}});
liveSocket.connect();
window.liveSocket = liveSocket;
JS
    mv "$js.new" "$js"
}
mix.com deps.compile websock_adapter --force
mix.com release --overwrite
