defmodule WasmHostFetchTest do
  @moduledoc """
  The tests of `:wasm_host_fetch`, the fetch path, natively: the CA and
  its certificates, the TLS server, and the HTTP of `serve/3` with a
  stand-in for the host (the function of the call).
  """
  use ExUnit.Case, async: true

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:inets)
    %{ca: :wasm_host_fetch.new_ca()}
  end

  describe "the CA" do
    test "a client that trusts the CA accepts the certificate of each SNI name", %{ca: ca} do
      for name <- [~c"api.cloudflare.com", ~c"hooks.example.com"] do
        assert {:ok, tls} = tls_client(ca, name, ca)
        :ssl.close(tls)
      end
    end

    @tag :capture_log
    test "a client that trusts another CA refuses it", %{ca: ca} do
      assert {:error, {:tls_alert, {:unknown_ca, _}}} =
               tls_client(ca, ~c"api.cloudflare.com", :wasm_host_fetch.new_ca())
    end

    test "with no SNI, the certificate has the invalid name fetch.invalid", %{ca: ca} do
      assert {:ok, tls} = tls_client(ca, :disable, ca)
      {:ok, der} = :ssl.peercert(tls)
      assert [{:dNSName, ~c"fetch.invalid"}] == san(der)
      :ssl.close(tls)
    end

    test "ALPN gives http/1.1 only", %{ca: ca} do
      assert {:ok, tls} =
               tls_client(ca, ~c"api.cloudflare.com", ca,
                 alpn_advertised_protocols: ["h2", "http/1.1"]
               )

      assert {:ok, "http/1.1"} == :ssl.negotiated_protocol(tls)
      :ssl.close(tls)
    end

    test "store_with/2 adds the CA to a store, and leaves no store as none", %{ca: ca} do
      assert :none == :wasm_host_fetch.store_with([], ca)
      other = :wasm_host_fetch.new_ca()
      pem = :wasm_host_fetch.store_with([other.cert], ca)
      assert [{:Certificate, der1, _}, {:Certificate, der2, _}] = :public_key.pem_decode(pem)
      assert [der1, der2] == [other.cert, ca.cert]
    end
  end

  describe "serve/3" do
    test "a GET, and a second request on the same connection" do
      {socket, calls} =
        serve_plain(fn _req ->
          {:ok, 200, "", [{"content-type", "text/plain"}], data(["hel", "lo"])}
        end)

      :ok =
        :gen_tcp.send(
          socket,
          "GET /a?b=1 HTTP/1.1\r\nHost: api.cloudflare.com\r\nAccept-Encoding: gzip\r\nX-K: v\r\n\r\n"
        )

      assert {200, headers, "hello"} = response(socket)
      assert {"connection", "keep-alive"} in headers

      assert_receive {:call, %{method: "GET", path: "/a?b=1", headers: [{"x-k", "v"}], body: ""}},
                     5000

      :ok = :gen_tcp.send(socket, "GET /2 HTTP/1.1\r\nConnection: close\r\n\r\n")
      assert {200, headers, "hello"} = response(socket)
      assert {"connection", "close"} in headers
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5000)
      assert 2 == calls.()
    end

    test "a chunked body, and 100-continue" do
      {socket, _} = serve_plain(fn _req -> {:ok, 201, "Created", [], data([])} end)

      :ok =
        :gen_tcp.send(
          socket,
          "POST /p HTTP/1.1\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n"
        )

      assert {:ok, "HTTP/1.1 100 Continue\r\n\r\n"} = :gen_tcp.recv(socket, 25, 5000)
      :ok = :gen_tcp.send(socket, "3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n")
      assert {201, _, ""} = response(socket)
      assert_receive {:call, %{method: "POST", body: "abcde"}}, 5000
    end

    test "HEAD and 304 have no body" do
      {socket, _} =
        serve_plain(fn _req -> {:ok, 200, "", [{"content-length", "5"}], data(["hello"])} end)

      :ok = :gen_tcp.send(socket, "HEAD / HTTP/1.1\r\n\r\n")
      {:ok, head} = :gen_tcp.recv(socket, 0, 5000)
      assert String.ends_with?(head, "\r\n\r\n")
      refute head =~ "transfer-encoding"
      refute head =~ "content-length"
    end

    test "a failure of fetch() gives 502 and closes" do
      {socket, _} = serve_plain(fn _req -> {:error, "network down"} end)
      :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\n\r\n")
      assert {502, _, "beam.com: fetch() failed: network down"} = response(socket)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5000)
    end

    test "a failure after the head closes the connection" do
      {socket, _} =
        serve_plain(fn _req ->
          {:ok, 200, "", [], fn -> {:data, "part", fn -> {:error, "reset"} end} end}
        end)

      :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\n\r\n")
      assert {:ok, bytes} = recv_all(socket)
      assert bytes =~ "4\r\npart\r\n"
      refute bytes =~ "0\r\n\r\n"
    end

    test "no upgrade, no bad framing, no body over 32 MiB, and no call for them" do
      for {request, status} <- [
            {"GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n", 501},
            {"POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n", 400},
            {"POST / HTTP/1.1\r\nContent-Length: 40000000\r\n\r\n", 413},
            {"OPTIONS * HTTP/1.1\r\n\r\n", 400},
            {"NOT HTTP\r\n\r\n", 400}
          ] do
        {socket, calls} = serve_plain(fn _req -> {:ok, 200, "", [], data([])} end)
        :ok = :gen_tcp.send(socket, request)
        assert {^status, _, _} = response(socket)
        assert 0 == calls.()
      end
    end

    test "httpc through TLS: the response of the call", %{ca: ca} do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      test = self()

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, tls} = :ssl.handshake(socket, :wasm_host_fetch.handshake_opts(ca), 10_000)

        reply = fn req ->
          send(test, {:call, req})
          {:ok, 200, "", [{"x-r", "1"}], data(["{\"ok\":true}"])}
        end

        :wasm_host_fetch.serve({:ssl, tls}, reply, "")
      end)

      opts = [
        ssl: [
          verify: :verify_peer,
          cacerts: [ca.cert],
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      ]

      assert {:ok, {{_, 200, _}, headers, ~c"{\"ok\":true}"}} =
               :httpc.request(
                 :post,
                 {~c"https://localhost:#{port}/v4/x", [{~c"authorization", ~c"Bearer t"}],
                  ~c"application/json", "{}"},
                 opts,
                 []
               )

      assert {~c"x-r", ~c"1"} in headers

      assert_receive {:call, %{method: "POST", path: "/v4/x", body: "{}", headers: req_headers}},
                     5000

      assert {"authorization", "Bearer t"} in req_headers
      refute List.keymember?(req_headers, "host", 0)
    end
  end

  # A server of serve/3 on a plain TCP connection: the socket of the client,
  # and a function that gives the count of the calls.
  defp serve_plain(reply) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test = self()
    counter = :counters.new(1, [])

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)

      :wasm_host_fetch.serve(
        {:gen_tcp, socket},
        fn req ->
          :counters.add(counter, 1, 1)
          send(test, {:call, req})
          reply.(req)
        end,
        ""
      )
    end)

    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])
    {socket, fn -> :counters.get(counter, 1) end}
  end

  defp data(parts) do
    Enum.reduce(Enum.reverse(parts), fn -> :done end, fn part, next ->
      fn -> {:data, part, next} end
    end)
  end

  # One response with a chunked body: {status, headers, body}.
  defp response(socket, buffer \\ "") do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        ["HTTP/1.1 " <> status | lines] = String.split(head, "\r\n")
        headers = for l <- lines, [k, v] = String.split(l, ": ", parts: 2), do: {k, v}
        {String.to_integer(binary_part(status, 0, 3)), headers, chunked(socket, rest, headers)}

      [_] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
        response(socket, buffer <> data)
    end
  end

  defp chunked(socket, buffer, headers) do
    if {"transfer-encoding", "chunked"} in headers do
      case :wasm_host_http.dechunk(buffer, []) do
        {:ok, body, ""} ->
          body

        {:more, _, _} ->
          {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
          chunked(socket, buffer <> data, headers)
      end
    else
      buffer
    end
  end

  defp recv_all(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> {:ok, acc}
    end
  end

  # The subject alternative names of a certificate.
  defp san(der) do
    cert = :public_key.pkix_decode_cert(der, :otp)
    tbs = elem(cert, 1)
    extensions = elem(tbs, 10)
    for {:Extension, {2, 5, 29, 17}, _, names} <- extensions, name <- names, do: name
  end

  # A TLS client of a server with the options of handshake_opts/1 of ca.
  defp tls_client(ca, sni, trusted, extra \\ []) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      _ = :ssl.handshake(socket, :wasm_host_fetch.handshake_opts(ca), 10_000)
      Process.sleep(1000)
    end)

    host_check = [server_name_indication: sni]

    :ssl.connect(
      ~c"localhost",
      port,
      [:binary, active: false, verify: :verify_peer, cacerts: [trusted.cert]] ++
        host_check ++ extra,
      10_000
    )
  end
end
