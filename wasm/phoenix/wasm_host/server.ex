defmodule WasmHost.Server do
  @moduledoc """
  Takes the events of the JavaScript host (`:wasm_host.recv/0`) and
  dispatches them: an HTTP request to a new process that runs the plug,
  a WebSocket frame to the process of its connection.

  An event is a JSON header, a newline, and the body:

      {"t":"http","id":1,"method":"GET","path":"/x?a=1","headers":[["host","h"]],"scheme":"https"}
      {"t":"ws_msg","id":1,"op":"text"}
      {"t":"ws_close","id":1}
  """
  use GenServer

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    plug = Keyword.fetch!(opts, :plug)
    pump = spawn_link(fn -> pump(plug) end)
    # The host can take requests now.
    send_host(%{t: "ready"})
    {:ok, %{pump: pump}}
  end

  @doc "Registers the calling process as the owner of WebSocket `id`."
  def register(id), do: :ets.insert(@table, {id, self()})
  def unregister(id), do: :ets.delete(@table, id)

  @doc "Sends a message (a header map and a body) to the host."
  def send_host(header, body \\ "") do
    :wasm_host.send([:json.encode(header), ?\n, body])
  end

  defp pump(plug) do
    event = :wasm_host.recv()
    [header, body] = :binary.split(event, "\n")
    meta = :json.decode(header)

    case meta do
      %{"t" => "http"} ->
        spawn(fn -> WasmHost.Conn.run(plug, meta, body) end)

      %{"t" => t, "id" => id} when t in ["ws_msg", "ws_close"] ->
        case :ets.lookup(@table, id) do
          [{^id, pid}] -> send(pid, {:wasm_host, t, meta, body})
          [] -> :ok
        end

      _ ->
        :ok
    end

    pump(plug)
  end
end
