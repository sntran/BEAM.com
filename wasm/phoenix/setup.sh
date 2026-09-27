#!/bin/sh
# Make the Phoenix LiveView app of the WebAssembly spike (docs/WASM.md):
# mix phx.new hello (no Ecto, no assets), a counter LiveView at /counter,
# and a release without ERTS (_build/prod/rel/hello).
#
#   BEAM_COM=/path/to/beam.com wasm/phoenix/setup.sh [DIR]
#
# PHOENIX=main: the installer, Phoenix and LiveView from the main branches
# on GitHub (the next versions, before their release).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${BEAM_COM:?set BEAM_COM}"
DIR=${1:-$HERE/build}
mkdir -p "$DIR/bin"
for t in mix iex elixir elixirc escript; do ln -sf "$BEAM_COM" "$DIR/bin/$t$( [ $t = escript ] || echo .com)"; done
export PATH="$DIR/bin:$PATH" MIX_HOME="$DIR/.mix" HEX_HOME="$DIR/.hex" MIX_ENV=prod
cd "$DIR"
mix.com local.hex --force --if-missing
if [ "${PHOENIX:-hex}" = main ]; then
    [ -d phoenix-src ] || git clone -q --depth 1 https://github.com/phoenixframework/phoenix phoenix-src
    (cd phoenix-src/installer && mix.com archive.build -o ../../phx_new.ez)
    mix.com archive.install ./phx_new.ez --force
else
    mix.com archive.install hex phx_new --force
fi
[ -d hello ] || mix.com phx.new hello --no-ecto --no-mailer --no-dashboard --no-gettext --no-assets --no-install
cd hello
mkdir -p lib/hello_web/live
cp "$HERE/counter_live.ex" lib/hello_web/live/
grep -q 'live "/counter"' lib/hello_web/router.ex ||
    sed -i 's|    get "/", PageController, :home|    get "/", PageController, :home\n    live "/counter", CounterLive|' lib/hello_web/router.ex
grep -q 'releases:' mix.exs ||
    sed -i 's|      listeners: \[Phoenix.CodeReloader\]|      listeners: [Phoenix.CodeReloader],\n      releases: [hello: [include_erts: false, strip_beams: true]]|' mix.exs
# The installer on main keeps the version of the last release, so it asks for
# Phoenix from Hex.
[ "${PHOENIX:-hex}" = main ] &&
    sed -i -e 's|{:phoenix, "[^"]*"}|{:phoenix, github: "phoenixframework/phoenix", override: true}|' \
        -e 's|{:phoenix_live_view, "[^"]*"}|{:phoenix_live_view, github: "phoenixframework/phoenix_live_view", override: true}|' mix.exs
mix.com deps.get

# The WebAssembly host adapter (wasm/phoenix/wasm_host): the Elixir side in
# lib/, the NIF stub in src/, and the adapter at run time with WASM_HOST=1.
mkdir -p lib/wasm_host src
cp "$HERE"/wasm_host/*.ex lib/wasm_host/
cp "$HERE/../erts/host/wasm_host.erl" "$HERE/../erts/host/wasm_tcp.erl" "$HERE/../erts/host/wasm_tcp_dist.erl" src/
cp "$HERE/tcp_controller.ex" lib/hello_web/controllers/
cp "$HERE/ssh_keys.ex" lib/hello_web/
grep -q '"/tcp"' lib/hello_web/router.ex ||
    sed -i 's|    live "/counter", CounterLive|    live "/counter", CounterLive\n    get "/tcp", TcpController, :show|' lib/hello_web/router.ex
grep -q '"/listen"' lib/hello_web/router.ex ||
    sed -i 's|    get "/tcp", TcpController, :show|    get "/tcp", TcpController, :show\n    get "/listen", TcpController, :listen|' lib/hello_web/router.ex
grep -q '"/ssh"' lib/hello_web/router.ex ||
    sed -i 's|    get "/listen", TcpController, :listen|    get "/listen", TcpController, :listen\n    get "/ssh", TcpController, :ssh|' lib/hello_web/router.ex
# The SSH test server (GET /ssh): the ssh application in the release.
grep -q ':ssh' mix.exs ||
    sed -i 's|extra_applications: \[:logger, :runtime_tools\]|extra_applications: [:logger, :runtime_tools, :ssh]|' mix.exs
grep -q WASM_HOST config/runtime.exs || cat >> config/runtime.exs <<'EXS'

# The WebAssembly emulator. WASM_HOST=1: the JavaScript host serves HTTP and
# WebSockets (WasmHost.PhoenixAdapter). WASM_HOST=tcp: Bandit serves them,
# on TCP sockets of the host (:wasm_tcp).
if System.get_env("WASM_HOST") == "1" do
  config :hello, HelloWeb.Endpoint, adapter: WasmHost.PhoenixAdapter
end
EXS
sed -i 's|^if System.get_env("WASM_HOST") do$|if System.get_env("WASM_HOST") == "1" do|' config/runtime.exs
grep -q 'WasmHost.Server.children' lib/hello/application.ex ||
    sed -i 's|^    children = \[$|    children = WasmHost.Server.children() ++ [|' lib/hello/application.ex
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
