defmodule Live.Room do
  # The state of the tenant in this VM: a counter that all visitors share,
  # and the LiveView processes that are connected. The VM is the Durable
  # Object of one tenant, so this state is the state of the tenant.
  use GenServer

  @topic "room"

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def join(pid), do: GenServer.call(__MODULE__, {:join, pid})
  def inc(n), do: GenServer.call(__MODULE__, {:inc, n})
  def topic, do: @topic

  @impl true
  def init(nil), do: {:ok, %{count: 0, visitors: MapSet.new()}}

  @impl true
  def handle_call({:join, pid}, _from, s) do
    Process.monitor(pid)
    s = %{s | visitors: MapSet.put(s.visitors, pid)}
    broadcast(s)
    {:reply, view(s), s}
  end

  def handle_call({:inc, n}, _from, s) do
    s = %{s | count: s.count + n}
    broadcast(s)
    {:reply, view(s), s}
  end

  @impl true
  def handle_info({:DOWN, _, :process, pid, _}, s) do
    s = %{s | visitors: MapSet.delete(s.visitors, pid)}
    broadcast(s)
    {:noreply, s}
  end

  defp view(s), do: %{count: s.count, visitors: MapSet.size(s.visitors)}
  defp broadcast(s), do: Phoenix.PubSub.broadcast(Live.PubSub, @topic, {:room, view(s)})
end
