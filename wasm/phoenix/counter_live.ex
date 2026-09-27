defmodule HelloWeb.CounterLive do
  use HelloWeb, :live_view

  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(1000, :tick)
    {:ok, assign(socket, count: 0, ticks: 0, node: node(), arch: to_string(:erlang.system_info(:system_architecture)))}
  end

  def handle_event("inc", _params, socket), do: {:noreply, update(socket, :count, &(&1 + 1))}
  def handle_event("dec", _params, socket), do: {:noreply, update(socket, :count, &(&1 - 1))}

  def handle_info(:tick, socket), do: {:noreply, update(socket, :ticks, &(&1 + 1))}

  def render(assigns) do
    ~H"""
    <div id="counter">
      <h1>LiveView on {@arch}</h1>
      <p>Count: <span id="count">{@count}</span></p>
      <button phx-click="dec">-</button>
      <button phx-click="inc">+</button>
      <p>Seconds connected: <span id="ticks">{@ticks}</span></p>
    </div>
    """
  end
end
