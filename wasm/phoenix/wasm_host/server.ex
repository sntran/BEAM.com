defmodule WasmHost.Server do
  @moduledoc """
  Takes the events of the JavaScript host (`:wasm_host.recv/0`) and
  dispatches them: an HTTP request to a new process that runs the plug,
  a WebSocket frame to the process of its connection.

  An event is a JSON header, a newline, and the body:

      {"t":"http","id":1,"method":"GET","path":"/x?a=1","headers":[["host","h"]],"scheme":"https"}
      {"t":"ws_msg","id":1,"op":"text"}
      {"t":"ws_close","id":1}
      {"t":"tcp_data","id":"t7"}
      {"t":"tcp_accept","id":"l3","conn":"a9","host":"1.2.3.4","port":5678}

  The events of TCP sockets (`:wasm_tcp`) go to the process of the socket.
  """
  use GenServer

  @table __MODULE__

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The children to start first in an application with `WASM_HOST=tcp`: the
  pump alone, for the TCP sockets of `:wasm_tcp` (the HTTP server of the
  app, as Bandit, listens with `:gen_tcp`).
  """
  def children do
    if System.get_env("WASM_HOST") == "tcp", do: [__MODULE__], else: []
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    # gen_tcp:connect makes sockets of the host (wasm_tcp).
    :inet_db.set_tcp_module(:wasm_tcp)
    # No native resolver (inet_gethost is a port program): the hosts file.
    :inet_db.set_lookup([:file])

    plug = Keyword.get(opts, :plug)
    pump = spawn_link(fn -> pump(plug) end)
    # After the pump: a listener waits for an event of the host.
    spawn(fn -> start_distribution() end)
    # WASM_HOST_BOOT_MODULES=file: the modules that the boot loaded, for
    # pack.erl --boot-modules.
    if path = System.get_env("WASM_HOST_BOOT_MODULES") do
      File.write!(path, for({m, _} <- Enum.sort(:code.all_loaded()), do: [Atom.to_string(m), ?\n]))
    end

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

  # Distributed Erlang over wasm_tcp (the boot has -proto_dist wasm_tcp and
  # -erl_epmd_port: no epmd). It starts here, when wasm_tcp works:
  # DIST_NAME=name@host, DIST_COOKIE, DIST_LISTEN=true to take connections
  # (in Workers: WebSockets to /.tcp/DIST_PORT), DIST_CONNECT=node to connect
  # to that node, and again when the connection ends.
  defp start_distribution do
    if name = System.get_env("DIST_NAME") do
      listen = System.get_env("DIST_LISTEN") == "true"
      # The listener takes DIST_PORT (all nodes use it: no epmd).
      port = String.to_integer(System.get_env("DIST_PORT", "4370"))
      Application.put_env(:kernel, :inet_dist_listen_min, port)
      Application.put_env(:kernel, :inet_dist_listen_max, port)

      {:ok, _} =
        :net_kernel.start(String.to_atom(name), %{name_domain: :longnames, dist_listen: listen})

      if cookie = System.get_env("DIST_COOKIE"), do: Node.set_cookie(String.to_atom(cookie))

      if node = System.get_env("DIST_CONNECT") do
        spawn(fn -> keep_connected(String.to_atom(node)) end)
      end
    end
  end

  defp keep_connected(node) do
    if Node.connect(node) == true do
      :erlang.monitor_node(node, true)
      receive do: ({:nodedown, ^node} -> :ok)
    else
      Process.sleep(2000)
    end

    keep_connected(node)
  end

  defp pump(plug) do
    event = :wasm_host.recv()
    [header, body] = :binary.split(event, "\n")
    meta = :json.decode(header)

    case meta do
      %{"t" => "http"} when plug != nil ->
        spawn(fn -> WasmHost.Conn.run(plug, meta, body) end)

      # A connection to a listener of wasm_tcp: its events go to the listener
      # until the process of the connection registers.
      %{"t" => "tcp_accept", "id" => id, "conn" => conn} ->
        case :ets.lookup(@table, id) do
          [{^id, pid}] ->
            :ets.insert_new(@table, {conn, pid})
            send(pid, {:wasm_host, "tcp_accept", meta, body})

          [] ->
            send_host(%{t: "tcp_close", id: conn})
        end

      %{"t" => t, "id" => id}
      when t in ["ws_msg", "ws_close", "tcp_open", "tcp_data", "tcp_closed", "tcp_error", "tcp_listening"] ->
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
