defmodule LiveWeb.RoomLive do
  # The page of a tenant: a counter that all its visitors share (through
  # Phoenix.PubSub in the one VM of the tenant), and facts of that VM.
  use LiveWeb, :live_view

  def mount(_params, session, socket) do
    tenant = session["tenant"] || "main"
    room =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Live.PubSub, Live.Room.topic())
        :timer.send_interval(1000, :tick)
        Live.Room.join(self())
      else
        %{count: 0, visitors: 0}
      end

    {:ok, socket |> assign(tenant: tenant, room: room, connected: 0) |> assign(vm())}
  end

  def handle_event("inc", _params, socket), do: {:noreply, assign(socket, room: Live.Room.inc(1))}
  def handle_event("dec", _params, socket), do: {:noreply, assign(socket, room: Live.Room.inc(-1))}
  def handle_info({:room, room}, socket), do: {:noreply, assign(socket, room: room)}
  def handle_info(:tick, socket), do: {:noreply, socket |> update(:connected, &(&1 + 1)) |> assign(vm())}

  defp vm do
    %{
      arch: to_string(:erlang.system_info(:system_architecture)),
      otp: to_string(:erlang.system_info(:otp_release)),
      memory: div(:erlang.memory(:total), 1_048_576),
      processes: :erlang.system_info(:process_count)
    }
  end

  def render(assigns) do
    ~H"""
    <main style="font-family: system-ui, sans-serif; max-width: 36rem; margin: 3rem auto; padding: 0 1rem">
      <h1>Tenant <code id="tenant">{@tenant}</code></h1>
      <p>Count, for all the visitors of this tenant: <b id="count">{@room.count}</b></p>
      <button phx-click="dec">-1</button> <button phx-click="inc">+1</button>
      <p>Visitors now: <b id="visitors">{@room.visitors}</b></p>
      <hr />
      <p>
        One BEAM VM for this tenant: Erlang/OTP {@otp} on {@arch}, in a
        Cloudflare Durable Object: {@memory} MB, {@processes} processes.
        Connected for <span id="connected">{@connected}</span> s.
      </p>
      <p>Other tenants: <a href="/.tenant/alpha">alpha</a>, <a href="/.tenant/beta">beta</a>,
        <a href="/.tenant/gamma">gamma</a> (the name goes into a cookie).</p>
    </main>
    """
  end
end
