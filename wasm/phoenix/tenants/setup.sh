#!/bin/sh
# A Phoenix LiveView app for tenants on Cloudflare Workers (docs/WASM.md,
# "Tenants: Phoenix LiveView in Durable Objects"): each tenant is one
# Durable Object, with its own BEAM VM. The page has a counter that all
# the visitors of the tenant share (Phoenix.PubSub in that VM).
#
#   BEAM_COM=/path/to/beam.com wasm/phoenix/tenants/setup.sh [DIR]
#
# It makes DIR/live (mix phx.new, no Ecto, no assets), its release, the
# Workers (DIR/worker) and a snapshot of the build (Node.js 26), and prints
# the commands to deploy.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${BEAM_COM:?set BEAM_COM}"
DIR=${1:-$HERE/build}
NODE=${NODE:-node}
HOST=${PHX_HOST:-live.example.workers.dev}
mkdir -p "$DIR/bin"
for t in mix iex elixir elixirc escript; do ln -sf "$BEAM_COM" "$DIR/bin/$t$( [ $t = escript ] || echo .com)"; done
export PATH="$DIR/bin:$PATH" MIX_HOME="$DIR/.mix" HEX_HOME="$DIR/.hex" MIX_ENV=prod
cd "$DIR"
mix.com local.hex --force --if-missing
mix.com archive.install hex phx_new --force
[ -d live ] || mix.com phx.new live --no-ecto --no-mailer --no-dashboard --no-gettext --no-assets --no-install
cd live
mkdir -p lib/live_web/live
cp "$HERE/room.ex" lib/live/
cp "$HERE/room_live.ex" lib/live_web/live/
# The tenant: the front Worker (durable.js, BEAM_TENANTS) gives its name in
# the header x-beam-tenant.
grep -q put_tenant lib/live_web/router.ex || {
    sed -i 's|    plug :put_secure_browser_headers|    plug :put_secure_browser_headers\n    plug :put_tenant|' lib/live_web/router.ex
    sed -i 's|    get "/", PageController, :home|    live "/", RoomLive|' lib/live_web/router.ex
    sed -i 's|^end$|\n  defp put_tenant(conn, _opts) do\n    case get_req_header(conn, "x-beam-tenant") do\n      [tenant \| _] -> put_session(conn, :tenant, tenant)\n      [] -> conn\n    end\n  end\nend|' lib/live_web/router.ex
}
grep -q 'Live.Room,' lib/live/application.ex ||
    sed -i 's|{Phoenix.PubSub, name: Live.PubSub},|{Phoenix.PubSub, name: Live.PubSub},\n      Live.Room,|' lib/live/application.ex
grep -q 'releases:' mix.exs ||
    sed -i 's|      listeners: \[Phoenix.CodeReloader\]|      listeners: [Phoenix.CodeReloader],\n      releases: [live: [include_erts: false, strip_beams: true]]|' mix.exs
mix.com deps.get
# No esbuild: app.js is phoenix.js, phoenix_live_view.js and the LiveSocket.
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
mix.com release --overwrite
cd "$DIR"
"$BEAM_COM" live/_build/prod/rel/live -o worker --target wasm32
# The snapshot of the build is in the Worker: the secret of the snapshot
# must be the secret of the Worker.
SECRET=$(head -c 48 /dev/urandom | base64 | tr -d '\n')
"$NODE" "$HERE/../../snapshot/snapshot.mjs" worker --warm 4000:/ \
    --env SECRET_KEY_BASE="$SECRET" --env PHX_HOST="$HOST"
printf '%s\n' "$SECRET" > secret_key_base
cat <<MSG
Set the vars of $DIR/worker/wrangler.durable-global.jsonc:
  "vars": { "BEAM_WARM": "/", "PHX_HOST": "$HOST", "BEAM_TENANTS": "cookie" }
then:
  cd $DIR/worker && wrangler deploy -c wrangler.durable-global.jsonc --name live
  wrangler secret put SECRET_KEY_BASE --name live < $DIR/secret_key_base
Tenants: https://$HOST/.tenant/NAME
MSG
