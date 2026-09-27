defmodule HelloWeb.TcpController do
  @moduledoc """
  A test of outgoing TCP (in the WebAssembly emulator, through the host):
  GET /tcp?host=H&port=P makes an HTTP/1.0 request with gen_tcp and
  returns the status line and the size of the answer.
  """
  use HelloWeb, :controller

  def show(conn, %{"host" => host, "port" => port} = params) do
    path = Map.get(params, "path", "/")
    t0 = System.monotonic_time(:millisecond)

    # tls=1: TLS with the ssl application of OTP, over the same socket
    # (verify_none: for a test server with its own certificate).
    mod = if params["tls"] == "1", do: :ssl, else: :gen_tcp
    opts = [:binary, active: false] ++ if(mod == :ssl, do: [verify: :verify_none], else: [])

    result =
      with {:ok, socket} <- mod.connect(String.to_charlist(host), String.to_integer(port), opts, 5000),
           :ok <- mod.send(socket, "GET #{path} HTTP/1.0\r\nHost: #{host}\r\n\r\n"),
           {:ok, body} <- read_all(mod, socket, "") do
        [status | _] = String.split(body, "\r\n", parts: 2)
        "#{status} (#{byte_size(body)} bytes, #{System.monotonic_time(:millisecond) - t0} ms, #{mod})"
      else
        error -> "error: #{inspect(error)}"
      end

    text(conn, result <> "\n")
  end

  defp read_all(mod, socket, acc) do
    case mod.recv(socket, 0, 5000) do
      {:ok, data} -> read_all(mod, socket, acc <> data)
      {:error, :closed} -> {:ok, acc}
      error -> error
    end
  end
end
