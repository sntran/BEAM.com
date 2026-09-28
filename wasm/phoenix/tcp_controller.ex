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
        last = body |> String.trim_trailing() |> String.split("\n") |> List.last()
        "#{status} (#{byte_size(body)} bytes, #{System.monotonic_time(:millisecond) - t0} ms, #{mod}): #{last}"
      else
        error -> "error: #{inspect(error)}"
      end

    text(conn, result <> "\n")
  end

  @doc """
  A test of incoming TCP: GET /listen?port=P starts an echo server on port
  P (gen_tcp:listen, through the host), which answers each line with
  "echo: " and the line.
  """
  def listen(conn, %{"port" => port}) do
    port = String.to_integer(port)
    parent = self()

    spawn(fn ->
      result = :gen_tcp.listen(port, [:binary, packet: :line, active: false])
      send(parent, {:listen, result})

      with {:ok, listen} <- result, do: accept_loop(listen)
    end)

    receive do
      {:listen, {:ok, _}} -> text(conn, "listening on #{port}\n")
      {:listen, error} -> text(conn, "error: #{inspect(error)}\n")
    after
      5000 -> text(conn, "error: timeout\n")
    end
  end

  @doc """
  A test of incoming TCP with a real protocol: GET /ssh?port=P starts the
  SSH server of OTP on port P (user "demo", password "demo"), with the
  Erlang shell, and exec of Erlang expressions.
  """
  def ssh(conn, %{"port" => port}) do
    {:ok, _} = Application.ensure_all_started(:ssh)

    result =
      :ssh.daemon(String.to_integer(port),
        key_cb: {HelloWeb.SshKeys, []},
        modify_algorithms: [rm: [public_key: [:"rsa-sha2-512", :"rsa-sha2-256", :"ecdsa-sha2-nistp256", :"ecdsa-sha2-nistp384", :"ecdsa-sha2-nistp521", :"ssh-ed448"]]],
        user_passwords: [{~c"demo", ~c"demo"}],
        auth_methods: ~c"password",
        # ssh demo@host EXPR evaluates EXPR (an Erlang expression).
        exec: {:direct, &eval_erlang/1}
      )

    case result do
      {:ok, _} -> text(conn, "ssh on #{port}: ssh -p #{port} demo@localhost\n")
      error -> text(conn, "error: #{inspect(error)}\n")
    end
  end

  @doc """
  A test of a proxy that Erlang starts and the host runs: GET
  /splice?port=P&host=H&upstream=U listens on P, connects each connection
  to H:U, and joins the two sockets (:wasm_tcp.splice/2): the data no
  longer goes through Erlang.
  """
  def splice(conn, %{"port" => port, "host" => host, "upstream" => upstream}) do
    {:ok, listen} = :gen_tcp.listen(String.to_integer(port), [:binary, active: false])
    target = {String.to_charlist(host), String.to_integer(upstream)}
    :ok = :gen_tcp.controlling_process(listen, spawn(fn -> splice_loop(listen, target) end))
    text(conn, "proxy on #{port} to #{host}:#{upstream}\n")
  end

  defp splice_loop(listen, {host, port} = target) do
    {:ok, client} = :gen_tcp.accept(listen)

    case :gen_tcp.connect(host, port, [:binary, active: false], 5000) do
      {:ok, upstream} -> :ok = :wasm_tcp.splice(client, upstream)
      _ -> :gen_tcp.close(client)
    end

    splice_loop(listen, target)
  end

  defp eval_erlang(expr) do
    with {:ok, tokens, _} <- :erl_scan.string(expr),
         {:ok, exprs} <- :erl_parse.parse_exprs(tokens) do
      {:value, value, _} = :erl_eval.exprs(exprs, [])
      {:ok, value}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp accept_loop(listen) do
    {:ok, socket} = :gen_tcp.accept(listen)
    pid = spawn(fn -> receive(do: (:go -> echo(socket))) end)
    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, :go)
    accept_loop(listen)
  end

  defp echo(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, line} ->
        :gen_tcp.send(socket, ["echo: ", line])
        echo(socket)

      {:error, _} ->
        :gen_tcp.close(socket)
    end
  end

  defp read_all(mod, socket, acc) do
    case mod.recv(socket, 0, 5000) do
      {:ok, data} -> read_all(mod, socket, acc <> data)
      {:error, :closed} -> {:ok, acc}
      error -> error
    end
  end
end
