defmodule WasmHost.Conn do
  @moduledoc """
  A `Plug.Conn.Adapter` over the JavaScript host: the answer of a request
  goes back with `WasmHost.Server.send_host/2`. A WebSocket upgrade
  (`WebSockAdapter.upgrade/4`) makes this process the loop of the
  connection (`WasmHost.WebSocket`).
  """
  @behaviour Plug.Conn.Adapter

  def run(plug, meta, body) do
    %{"id" => id, "method" => method, "path" => path, "headers" => headers} = meta
    scheme = String.to_atom(Map.get(meta, "scheme", "http"))
    uri = URI.parse(path)
    req_headers = for [k, v] <- headers, do: {String.downcase(k), v}
    host_header = List.keyfind(req_headers, "host", 0, {"host", "localhost"}) |> elem(1)
    [host | port] = String.split(host_header, ":")
    port = case port do
      [p] -> String.to_integer(p)
      [] -> if scheme == :https, do: 443, else: 80
    end

    payload = %{id: id, body: body, chunked: false, upgrade: nil}

    conn = %Plug.Conn{
      adapter: {__MODULE__, payload},
      host: host,
      port: port,
      method: method,
      owner: self(),
      path_info: split_path(uri.path || "/"),
      request_path: uri.path || "/",
      query_string: uri.query || "",
      remote_ip: {127, 0, 0, 1},
      req_headers: req_headers,
      scheme: scheme
    }

    conn =
      try do
        plug.call(conn, plug.init([]))
      catch
        kind, reason ->
          send_resp(payload, 500, [], "Internal Server Error")
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    case conn.adapter do
      {__MODULE__, %{upgrade: {:websocket, {handler, state, opts}}}} ->
        WasmHost.WebSocket.run(id, handler, state, opts)

      {__MODULE__, %{chunked: true}} ->
        WasmHost.Server.send_host(%{t: "end", id: id})

      _ ->
        :ok
    end
  end

  defp split_path(path), do: for(s <- String.split(path, "/"), s != "", do: s)

  defp head(t, id, status, headers),
    do: %{t: t, id: id, status: status, headers: for({k, v} <- headers, do: [k, v])}

  @impl true
  def send_resp(%{id: id} = payload, status, headers, body) do
    WasmHost.Server.send_host(head("resp", id, status, headers), body)
    {:ok, nil, payload}
  end

  @impl true
  def send_file(payload, status, headers, path, offset, length) do
    data = File.read!(path)
    data = if length == :all, do: binary_part(data, offset, byte_size(data) - offset), else: binary_part(data, offset, length)
    send_resp(payload, status, headers, data)
  end

  @impl true
  def send_chunked(%{id: id} = payload, status, headers) do
    WasmHost.Server.send_host(head("head", id, status, headers))
    {:ok, nil, %{payload | chunked: true}}
  end

  @impl true
  def chunk(%{id: id} = payload, body) do
    WasmHost.Server.send_host(%{t: "chunk", id: id}, body)
    {:ok, nil, payload}
  end

  @impl true
  def read_req_body(%{body: body} = payload, _opts), do: {:ok, body, %{payload | body: ""}}

  @impl true
  def push(_payload, _path, _headers), do: {:error, :not_supported}

  @impl true
  def inform(_payload, _status, _headers), do: {:error, :not_supported}

  @impl true
  def upgrade(payload, :websocket, args), do: {:ok, %{payload | upgrade: {:websocket, args}}}
  def upgrade(_payload, _protocol, _args), do: {:error, :not_supported}

  @impl true
  def get_peer_data(_payload), do: %{address: {127, 0, 0, 1}, port: 0, ssl_cert: nil}

  @impl true
  def get_sock_data(_payload), do: %{address: {127, 0, 0, 1}, port: 0}

  @impl true
  def get_ssl_data(_payload), do: nil

  @impl true
  def get_http_protocol(_payload), do: :"HTTP/1.1"
end
