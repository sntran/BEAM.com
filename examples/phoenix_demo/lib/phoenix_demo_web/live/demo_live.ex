defmodule PhoenixDemoWeb.DemoLive do
  @moduledoc """
  The home page: facts that only a live BEAM process can give.

    * The clock of the server, pushed each second over the WebSocket.
    * The facts of the VM: on Cloudflare Workers and on Deno Deploy, the
      architecture is `wasm32-unknown-emscripten`.
    * The round-trip time of the WebSocket, measured in the browser.
    * The visitors online now (Phoenix.Presence).
    * A counter that all visitors share (Phoenix.PubSub), in the database.
    * The place of the server: the Cloudflare data center (from
      `/cdn-cgi/trace`, in the browser) or the region of Deno Deploy
      (`BEAM_REGION`), and the country of the request (the `cf-ipcountry`
      header of Cloudflare).

  The runtime of beam.com gives the host in `BEAM_HOST`: `cloudflare`,
  `deno-deploy` or `deno`. With no `BEAM_HOST`, the VM runs natively.
  """
  use PhoenixDemoWeb, :live_view

  alias PhoenixDemo.Counters
  alias PhoenixDemoWeb.Presence

  @topic "demo"
  @counter "clicks"

  # The words of the page for each host.
  @hosts %{
    "cloudflare" => %{
      name: "Cloudflare Workers",
      where: "BEAM runs in WebAssembly in a Durable Object.",
      place: "Cloudflare data center",
      store: "it stays in SQLite in the Durable Object"
    },
    "deno-deploy" => %{
      name: "Deno Deploy",
      where: "BEAM runs in WebAssembly in a Deno isolate.",
      place: "Deno Deploy region",
      store: "it is in SQLite in the memory of this isolate"
    },
    "deno" => %{
      name: "Deno",
      where: "BEAM runs in WebAssembly in Deno.",
      place: "Region",
      store: "it is in SQLite in the memory of this isolate"
    },
    "native" => %{
      name: "this server",
      where: "BEAM runs natively.",
      place: "Region",
      store: "it stays in SQLite"
    }
  }

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      :timer.send_interval(1000, :tick)
      Phoenix.PubSub.subscribe(PhoenixDemo.PubSub, @topic)
      {:ok, _ref} = Presence.track(self(), @topic, socket.id, %{})
    end

    {:ok,
     assign(socket,
       page_title: "LiveView on #{host().name}",
       host: host(),
       region: System.get_env("BEAM_REGION"),
       country: session["cf_country"],
       pid: inspect(self()),
       clicks: Counters.get(@counter),
       online: online(),
       now: now(),
       vm: vm()
     )}
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, assign(socket, now: now(), vm: vm())}

  def handle_info(%{event: "presence_diff"}, socket),
    do: {:noreply, assign(socket, online: online())}

  def handle_info({:clicks, clicks}, socket), do: {:noreply, assign(socket, clicks: clicks)}

  @impl true
  def handle_event("click", _params, socket) do
    clicks = Counters.increment(@counter)
    Phoenix.PubSub.broadcast(PhoenixDemo.PubSub, @topic, {:clicks, clicks})
    {:noreply, assign(socket, clicks: clicks)}
  end

  # The Ping hook measures the round trip of this event.
  def handle_event("ping", _params, socket), do: {:reply, %{}, socket}

  defp online, do: @topic |> Presence.list() |> map_size()

  defp host, do: Map.get(@hosts, System.get_env("BEAM_HOST", "native"), @hosts["native"])

  defp now, do: DateTime.utc_now() |> Calendar.strftime("%H:%M:%S UTC")

  defp vm do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    %{
      arch: to_string(:erlang.system_info(:system_architecture)),
      otp: to_string(:erlang.system_info(:otp_release)),
      erts: to_string(:erlang.system_info(:version)),
      elixir: System.version(),
      phoenix: to_string(Application.spec(:phoenix, :vsn)),
      live_view: to_string(Application.spec(:phoenix_live_view, :vsn)),
      processes: :erlang.system_info(:process_count),
      uptime: duration(div(uptime_ms, 1000))
    }
  end

  defp duration(s) when s < 60, do: "#{s} s"
  defp duration(s) when s < 3600, do: "#{div(s, 60)} min #{rem(s, 60)} s"
  defp duration(s), do: "#{div(s, 3600)} h #{div(rem(s, 3600), 60)} min"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
        <.header>
          Phoenix LiveView on {@host.name}
          <:subtitle>
            {@host.where} This page is a LiveView:
            the server pushes each change over a WebSocket.
          </:subtitle>
        </.header>

        <div class="stats stats-vertical sm:stats-horizontal w-full shadow">
          <div class="stat">
            <div class="stat-title">Server clock</div>
            <div id="clock" class="stat-value font-mono text-2xl">{@now}</div>
            <div class="stat-desc">pushed by the server each second</div>
          </div>
          <div class="stat">
            <div class="stat-title">WebSocket round trip</div>
            <div id="rtt" class="stat-value font-mono text-2xl" phx-hook=".Ping" phx-update="ignore">
              …
            </div>
            <div class="stat-desc">measured in your browser</div>
          </div>
          <div class="stat">
            <div class="stat-title">Visitors online</div>
            <div id="online" class="stat-value text-2xl">{@online}</div>
            <div class="stat-desc">open this page in another tab</div>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body flex-row items-center justify-between">
            <div>
              <h2 class="card-title">Shared counter: <span id="clicks">{@clicks}</span></h2>
              <p class="text-sm opacity-70">
                All visitors share it, and {@host.store}.
              </p>
            </div>
            <.button id="click" phx-click="click" class="btn btn-primary">+1</.button>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">The VM that serves this page</h2>
            <dl class="grid grid-cols-[auto_1fr] gap-x-6 gap-y-1 text-sm">
              <dt class="opacity-70">Architecture</dt>
              <dd id="arch" class="font-mono">{@vm.arch}</dd>
              <dt class="opacity-70">{@host.place}</dt>
              <dd
                id="colo"
                class="font-mono"
                phx-hook=".Colo"
                phx-update="ignore"
                data-region={@region}
              >
                {@region || "-"}
              </dd>
              <dt class="opacity-70">Country of the request</dt>
              <dd id="country" class="font-mono">{@country || "-"}</dd>
              <dt class="opacity-70">This LiveView process</dt>
              <dd class="font-mono">{@pid}</dd>
              <dt class="opacity-70">Processes in the VM</dt>
              <dd id="processes" class="font-mono">{@vm.processes}</dd>
              <dt class="opacity-70">VM uptime</dt>
              <dd id="uptime" class="font-mono">{@vm.uptime}</dd>
              <dt class="opacity-70">Versions</dt>
              <dd class="font-mono">
                OTP {@vm.otp} (ERTS {@vm.erts}), Elixir {@vm.elixir},
                Phoenix {@vm.phoenix}, LiveView {@vm.live_view}
              </dd>
            </dl>
          </div>
        </div>

        <p class="text-sm">
          <.link navigate={~p"/users/register"} class="link">Register</.link>
          or <.link navigate={~p"/users/log-in"} class="link">log in</.link>
          to try the authentication of <code>phx.gen.auth</code>.
        </p>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Colo">
        // Cloudflare answers /cdn-cgi/trace on each host that it serves, with
        // the data center of the connection in the line "colo=". Another host
        // gives its region in data-region.
        export default {
          mounted() {
            if (this.el.dataset.region) return
            fetch("/cdn-cgi/trace")
              .then((r) => (r.ok ? r.text() : ""))
              .then((t) => { this.el.textContent = (t.match(/^colo=(.+)$/m) || [])[1] || "-" })
              .catch(() => { this.el.textContent = "-" })
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Ping">
        export default {
          mounted() {
            const ping = () => {
              const start = performance.now()
              this.pushEvent("ping", {}, () => {
                this.el.textContent = `${Math.round(performance.now() - start)} ms`
              })
            }
            ping()
            this.timer = setInterval(ping, 3000)
          },
          destroyed() { clearInterval(this.timer) }
        }
      </script>
    </Layouts.app>
    """
  end
end
