defmodule WasmHostFetchTest do
  @moduledoc """
  The tests of `:wasm_host_fetch`, the fetch path, natively: the CA and
  its certificates, the TLS server, the HTTP of `serve/3` with a
  stand-in for the host (the function of the call), and the messages of
  `call_host/2` to the host and back, with the stand-in of
  `BeamCom.HostStandIn`.

  The module is not async: the stand-in replaces `:wasm_host` in the VM.
  """
  use ExUnit.Case, async: false

  alias BeamCom.HostStandIn

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:inets)
    owner = HostStandIn.load()
    on_exit(fn -> HostStandIn.unload(owner) end)
    %{ca: :wasm_host_fetch.new_ca()}
  end

  setup do
    HostStandIn.take_host()
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

    # The default client of ssl offers AES-GCM before ChaCha20-Poly1305.
    test "the server chooses ChaCha20-Poly1305 in TLS 1.3 and TLS 1.2", %{ca: ca} do
      for version <- [:"tlsv1.3", :"tlsv1.2"] do
        assert {:ok, tls} = tls_client(ca, ~c"api.cloudflare.com", ca, versions: [version])

        assert {:ok, [protocol: ^version, selected_cipher_suite: %{cipher: :chacha20_poly1305}]} =
                 :ssl.connection_information(tls, [:protocol, :selected_cipher_suite])

        :ssl.close(tls)
      end
    end

    test "a client with no ChaCha20-Poly1305 gets AES-GCM", %{ca: ca} do
      aes =
        for s <- :ssl.cipher_suites(:default, :"tlsv1.3"), s.cipher != :chacha20_poly1305, do: s

      assert {:ok, tls} = tls_client(ca, ~c"api.cloudflare.com", ca, ciphers: aes)

      assert {:ok, [selected_cipher_suite: %{cipher: cipher}]} =
               :ssl.connection_information(tls, [:selected_cipher_suite])

      assert cipher in [:aes_128_gcm, :aes_256_gcm]
      :ssl.close(tls)
    end

    @tag :capture_log
    test "client_opts/2 of a tunnel: the CA of the store and the name of the host", %{ca: ca} do
      for {store, result} <- [{[ca.cert], :ok}, {[:wasm_host_fetch.new_ca().cert], :error}] do
        {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
        {:ok, port} = :inet.port(listen)

        spawn_link(fn ->
          {:ok, socket} = :gen_tcp.accept(listen)
          _ = :ssl.handshake(socket, :wasm_host_fetch.handshake_opts(ca), 10_000)
          Process.sleep(1000)
        end)

        {:ok, tcp} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])

        assert {^result, _} =
                 :ssl.connect(tcp, :wasm_host_fetch.client_opts(store, ~c"chat.example"), 10_000)
      end
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

    test "HEAD has no body, and keeps the content-length of fetch()" do
      {socket, _} =
        serve_plain(fn _req -> {:ok, 200, "", [{"content-length", "5"}], data(["hello"])} end)

      :ok = :gen_tcp.send(socket, "HEAD / HTTP/1.1\r\n\r\n")
      {:ok, head} = recv_until(socket, "\r\n\r\n")
      refute head =~ "transfer-encoding"
      assert head =~ "content-length: 5\r\n"
      # The connection goes on: no body bytes came after the head.
      :ok = :gen_tcp.send(socket, "HEAD / HTTP/1.1\r\n\r\n")
      assert {:ok, ^head} = recv_until(socket, "\r\n\r\n")
    end

    test "304 and a HEAD of an encoded body have no body and no content-length" do
      for {method, status, headers} <- [
            {"GET", 304, [{"content-length", "5"}]},
            {"HEAD", 200, [{"content-encoding", "gzip"}, {"content-length", "5"}]}
          ] do
        {socket, _} = serve_plain(fn _req -> {:ok, status, "", headers, data(["hello"])} end)
        :ok = :gen_tcp.send(socket, "#{method} / HTTP/1.1\r\n\r\n")
        {:ok, head} = recv_until(socket, "\r\n\r\n")
        refute head =~ "transfer-encoding"
        refute head =~ "content-length"
        refute head =~ "content-encoding"
      end
    end

    test "a body with content-length and no content-encoding keeps its length, with no chunks" do
      {socket, calls} =
        serve_plain(fn _req ->
          {:ok, 200, "", [{"content-type", "application/octet-stream"}, {"Content-Length", "5"}],
           data(["hel", "lo"])}
        end)

      :ok = :gen_tcp.send(socket, "GET /file HTTP/1.1\r\n\r\n")
      assert {200, headers, "hello"} = response(socket)
      assert [{"content-length", "5"}] == Enum.filter(headers, &match?({"content-length", _}, &1))
      refute List.keymember?(headers, "transfer-encoding", 0)
      # The connection goes on after the body.
      :ok = :gen_tcp.send(socket, "GET /file HTTP/1.1\r\nConnection: close\r\n\r\n")
      assert {200, _, "hello"} = response(socket)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5000)
      assert 2 == calls.()
    end

    test "an encoded body, or a bad length, goes in chunks with no length" do
      for headers <- [
            [{"content-encoding", "gzip"}, {"content-length", "3"}],
            [{"content-length", "5"}, {"content-length", "6"}],
            [{"content-length", "five"}]
          ] do
        {socket, _} = serve_plain(fn _req -> {:ok, 200, "", headers, data(["hel", "lo"])} end)
        :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\n\r\n")
        assert {200, out, "hello"} = response(socket)
        assert {"transfer-encoding", "chunked"} in out
        refute List.keymember?(out, "content-length", 0)
        refute List.keymember?(out, "content-encoding", 0)
      end
    end

    test "a body that ends before its content-length closes the connection" do
      for next <- [
            data(["hel", "lo"]),
            fn :more -> {:data, "hello", fn :more -> {:error, "reset"} end} end
          ] do
        {socket, _} = serve_plain(fn _req -> {:ok, 200, "", [{"content-length", "10"}], next} end)
        :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\n\r\n")
        assert {:ok, bytes} = recv_all(socket)
        [head, body] = :binary.split(bytes, "\r\n\r\n")
        assert head =~ "content-length: 10\r\n"
        assert body == "hello"
      end
    end

    test "the bytes past the content-length do not go, and the fetch stops" do
      test = self()

      {socket, _} =
        serve_plain(fn _req ->
          {:ok, 200, "", [{"content-length", "3"}],
           fn :more -> {:data, "hello", fn :stop -> send(test, :stopped) end} end}
        end)

      :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\n\r\n")
      assert {:ok, bytes} = recv_all(socket)
      assert [_, "hel"] = :binary.split(bytes, "\r\n\r\n")
      assert_receive :stopped, 5000
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
          {:ok, 200, "", [], fn :more -> {:data, "part", fn :more -> {:error, "reset"} end} end}
        end)

      :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\n\r\n")
      assert {:ok, bytes} = recv_all(socket)
      assert bytes =~ "4\r\npart\r\n"
      refute bytes =~ "0\r\n\r\n"
    end

    test "a client that closes during the body stops the body" do
      test = self()
      {socket, _} = serve_plain(fn _req -> {:ok, 200, "", [], endless(test)} end)
      :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\n\r\n")
      assert {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
      :ok = :gen_tcp.close(socket)
      assert_receive :stopped, 5000
    end

    test "no bad framing, no body over 32 MiB, and no call for them" do
      for {request, status} <- [
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

    test "an upgrade goes through a tunnel: the head, the bytes after it, and both ways" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      test = self()

      # The host behind the tunnel: it gets the head and the bytes after it,
      # answers 101, and then sends back each message.
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, got} = recv_until(socket, "EXTRA")
        send(test, {:upstream, got})

        :ok =
          :gen_tcp.send(socket, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n")

        {:ok, "ping"} = :gen_tcp.recv(socket, 4, 5000)
        :ok = :gen_tcp.send(socket, "pong")
        :gen_tcp.close(socket)
      end)

      head =
        "GET /ws HTTP/1.1\r\nHost: chat.example\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"

      {socket, calls} =
        serve_plain(fn
          %{upgrade: raw} ->
            {:ok, up} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])
            :ok = :gen_tcp.send(up, raw)
            {:tunnel, {:gen_tcp, up}}
        end)

      :ok = :gen_tcp.send(socket, head <> "EXTRA")
      assert_receive {:call, %{upgrade: ^head}}, 5000
      assert_receive {:upstream, got}, 5000
      assert got == head <> "EXTRA"

      assert {:ok, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n"} =
               :gen_tcp.recv(socket, 0, 5000)

      :ok = :gen_tcp.send(socket, "ping")
      assert {:ok, "pong"} = :gen_tcp.recv(socket, 4, 5000)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5000)
      assert 1 == calls.()
    end

    test "an upgrade with no tunnel gives 502" do
      {socket, _} = serve_plain(fn %{upgrade: _} -> {:error, :econnrefused} end)

      :ok =
        :gen_tcp.send(
          socket,
          "GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
        )

      assert {502, _, "beam.com: no tunnel: econnrefused"} = response(socket)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5000)
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

  describe "serve/3 and HTTP/1.0" do
    test "a response to HTTP/1.0 has no chunked coding, and ends with the connection" do
      {socket, _} =
        serve_plain(fn _req ->
          {:ok, 200, "", [{"content-type", "text/plain"}], data(["hel", "lo"])}
        end)

      :ok = :gen_tcp.send(socket, "GET / HTTP/1.0\r\n\r\n")
      assert {:ok, bytes} = recv_all(socket)
      [head, body] = :binary.split(bytes, "\r\n\r\n")
      refute head =~ "transfer-encoding"
      assert head =~ "connection: close"
      assert body == "hello"
    end

    test "a response to HTTP/1.0 keeps the content-length of fetch()" do
      {socket, _} =
        serve_plain(fn _req -> {:ok, 200, "", [{"content-length", "5"}], data(["hel", "lo"])} end)

      :ok = :gen_tcp.send(socket, "GET / HTTP/1.0\r\n\r\n")
      assert {:ok, bytes} = recv_all(socket)
      [head, body] = :binary.split(bytes, "\r\n\r\n")
      assert head =~ "content-length: 5\r\n"
      assert head =~ "connection: close"
      refute head =~ "transfer-encoding"
      assert body == "hello"
    end

    test "an answer of the server has a content-length, also for HTTP/1.0" do
      {socket, _} = serve_plain(fn _req -> {:error, "network down"} end)
      :ok = :gen_tcp.send(socket, "GET / HTTP/1.0\r\n\r\n")
      assert {:ok, bytes} = recv_all(socket)
      [head, body] = :binary.split(bytes, "\r\n\r\n")
      assert head =~ "HTTP/1.1 502 Bad Gateway"
      assert head =~ "content-length: #{byte_size(body)}"
      refute head =~ "transfer-encoding"
      assert body == "beam.com: fetch() failed: network down"
    end

    test "no head from the host in time: 504, and the connection closes" do
      {socket, _} = serve_plain(fn _req -> {:error, :timeout} end)
      :ok = :gen_tcp.send(socket, "POST /pay HTTP/1.1\r\ncontent-length: 0\r\n\r\n")
      assert {:ok, bytes} = recv_all(socket)
      assert bytes =~ "HTTP/1.1 504 Gateway Timeout\r\n"
      assert bytes =~ "The request may have run."
    end
  end

  describe "call_host/2: the messages with the host" do
    @req %{
      conn: "x1",
      tls: false,
      method: "POST",
      path: "/a?b=1",
      headers: [{"x-k", "v"}],
      body: "{}"
    }
    @times %{head: 5000, idle: 5000}

    test "the request, the head, the body with fetch_read, and the end" do
      call = call(@req, @times)
      assert_receive {:host, %{"t" => "fetch", "id" => id} = m, "{}"}, 5000
      assert %{"ack" => true, "conn" => "x1", "tls" => false, "method" => "POST"} = m
      assert %{"path" => "/a?b=1", "headers" => [["x-k", "v"]]} = m
      assert [{^id, _}] = :ets.lookup(:wasm_host_server, id)
      head = %{"id" => id, "status" => 201, "reason" => "Created", "headers" => [["x-r", "1"]]}
      event(id, "fetch_head", head)
      assert_receive {:step, {:ok, 201, "Created", [{"x-r", "1"}]}}, 5000
      send(call, :more)
      event(id, "fetch_data", %{"id" => id}, "abc")
      assert_receive {:step, {:data, "abc"}}, 5000
      # The next part: the host learns that the program took 3 bytes.
      send(call, :more)
      assert_receive {:host, %{"t" => "fetch_read", "id" => ^id, "n" => 3}, _}, 5000
      event(id, "fetch_end", %{"id" => id})
      assert_receive {:step, :done}, 5000
      assert [] == :ets.lookup(:wasm_host_server, id)
    end

    test "the bytes of the headers go as characters, and the bytes of the path as %XX" do
      req = %{@req | path: <<"/caf", 0xE9, "?q=", 0xFF>>, headers: [{"x-n", <<"caf", 0xE9>>}]}
      call = call(req, @times)
      assert_receive {:host, %{"t" => "fetch", "id" => id} = m, _}, 5000
      assert m["path"] == "/caf%E9?q=%FF"
      assert m["headers"] == [["x-n", "café"]]

      head = %{
        "id" => id,
        "status" => 200,
        "reason" => "Fiñe",
        "headers" => [["x-r", "é"], ["x-s", "€"]]
      }

      event(id, "fetch_head", head)

      assert_receive {:step, {:ok, 200, <<"Fi", 0xF1, "e">>, [{"x-r", <<0xE9>>}, {"x-s", "€"}]}},
                     5000

      send(call, :stop)
      assert_receive {:host, %{"t" => "fetch_cancel", "id" => ^id}, _}, 5000
    end

    test "fetch_error before the head: the error, and the id goes" do
      call(@req, @times)
      assert_receive {:host, %{"t" => "fetch", "id" => id}, _}, 5000
      event(id, "fetch_error", %{"id" => id, "message" => "refused"})
      assert_receive {:step, {:error, "refused"}}, 5000
      assert [] == :ets.lookup(:wasm_host_server, id)
    end

    test "no head in time: {:error, :timeout}, fetch_cancel, and the id goes" do
      call(@req, %{@times | head: 50})
      assert_receive {:host, %{"t" => "fetch", "id" => id}, _}, 5000
      assert_receive {:step, {:error, :timeout}}, 5000
      assert_receive {:host, %{"t" => "fetch_cancel", "id" => ^id}, _}, 5000
      assert [] == :ets.lookup(:wasm_host_server, id)
    end

    test "no data of the body in time: an error, and fetch_cancel" do
      call = call(@req, %{@times | idle: 50})
      assert_receive {:host, %{"t" => "fetch", "id" => id}, _}, 5000
      event(id, "fetch_head", %{"id" => id, "status" => 200})
      assert_receive {:step, {:ok, 200, "", []}}, 5000
      send(call, :more)
      assert_receive {:step, {:error, "the host sent no data"}}, 5000
      assert_receive {:host, %{"t" => "fetch_cancel", "id" => ^id}, _}, 5000
      assert [] == :ets.lookup(:wasm_host_server, id)
    end

    test "fetch_error in the body ends it" do
      call = call(@req, @times)
      assert_receive {:host, %{"t" => "fetch", "id" => id}, _}, 5000
      event(id, "fetch_head", %{"id" => id, "status" => 200})
      assert_receive {:step, {:ok, 200, "", []}}, 5000
      send(call, :more)
      event(id, "fetch_error", %{"id" => id, "message" => "reset"})
      assert_receive {:step, {:error, "reset"}}, 5000
      assert [] == :ets.lookup(:wasm_host_server, id)
    end

    test "a process that stops with a fetch: the server removes its id and stops the fetch" do
      call = call(@req, @times)
      assert_receive {:host, %{"t" => "fetch", "id" => id}, _}, 5000
      {:noreply, _} = :wasm_host_fetch.handle_info({:watch, call}, %{})
      Process.exit(call, :kill)
      assert_receive {:DOWN, _, :process, ^call, :killed} = down, 5000
      {:noreply, _} = :wasm_host_fetch.handle_info(down, %{})
      assert_receive {:host, %{"t" => "fetch_cancel", "id" => ^id}, _}, 5000
      assert [] == :ets.lookup(:wasm_host_server, id)
    end
  end

  describe "connection/1: a socket of wasm_tcp" do
    test "TLS, a request to the host, and its response", %{ca: ca} do
      # The client of the program, with TLS, on a native socket; a bridge
      # gives its bytes to a socket of wasm_tcp, as the host does.
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listen)
      test = self()

      client =
        Task.async(fn ->
          opts = [
            :binary,
            active: false,
            verify: :verify_peer,
            cacerts: [ca.cert],
            server_name_indication: ~c"example.com",
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]

          {:ok, tls} = :ssl.connect(~c"127.0.0.1", port, opts, 10_000)
          :ok = :ssl.send(tls, "GET /x HTTP/1.1\r\nHost: example.com\r\n\r\n")
          response = tls_recv(tls, "")
          :ssl.close(tls)
          response
        end)

      {:ok, native} = :gen_tcp.accept(listen, 10_000)
      # The table of the server of the fetch path, with its CA.
      :ets.new(:wasm_host_fetch, [:named_table, :public])
      :ets.insert(:wasm_host_fetch, {:ca, ca})

      init =
        {:accepted, "c9", {"example.com", 443}, [:binary, active: false],
         %{ack: true, sack: false}, test}

      {:ok, pid} = :gen_server.start(:wasm_tcp, init, [])

      conn =
        spawn(fn ->
          receive do: (:go -> :wasm_host_fetch.connection({:"$inet", :wasm_tcp, pid}))
        end)

      :ok = :gen_server.call(pid, {:accepted, conn, false})
      :ok = :inet.setopts(native, active: true)
      send(conn, :go)
      assert bridge(native, pid)
      response = Task.await(client, 10_000)
      assert response =~ "HTTP/1.1 200 OK\r\n"
      assert response =~ "x-r: 1\r\n"
      assert response =~ "5\r\nhello\r\n0\r\n\r\n"
    end
  end

  # call_host/2 in a new process: each step goes to the test as {:step, _}:
  # the result of the call, then each part of the body. The test sends
  # :more for the next part, or :stop to stop the body.
  defp call(req, times) do
    test = self()

    spawn(fn ->
      case :wasm_host_fetch.call_host(req, times) do
        {:ok, status, reason, headers, next} ->
          send(test, {:step, {:ok, status, reason, headers}})
          body(test, next)

        error ->
          send(test, {:step, error})
      end
    end)
  end

  defp body(test, next) do
    receive do
      :stop ->
        next.(:stop)

      :more ->
        case next.(:more) do
          {:data, part, next1} ->
            send(test, {:step, {:data, part}})
            body(test, next1)

          result ->
            send(test, {:step, result})
        end
    end
  end

  # An event of the host for the fetch id.
  defp event(id, type, meta, body \\ "") do
    [{^id, pid}] = :ets.lookup(:wasm_host_server, id)
    send(pid, {:wasm_host, type, meta, body})
  end

  # The bytes between the native socket of the client and the socket of
  # wasm_tcp, as the host gives them, and the answer of the host to the
  # fetch of the request. It ends when the client closes, with true when
  # the fetch came.
  defp bridge(native, pid, called \\ false) do
    receive do
      {:tcp, ^native, data} ->
        send(pid, {:wasm_host, "tcp_data", %{"id" => "c9"}, data})
        bridge(native, pid, called)

      {:host, %{"t" => "tcp_send", "id" => "c9"}, body} ->
        :ok = :gen_tcp.send(native, body)
        bridge(native, pid, called)

      {:host, %{"t" => "fetch", "id" => id, "path" => "/x", "tls" => true}, _} ->
        event(id, "fetch_head", %{"id" => id, "status" => 200, "headers" => [["x-r", "1"]]})
        event(id, "fetch_data", %{"id" => id}, "hello")
        event(id, "fetch_end", %{"id" => id})
        bridge(native, pid, true)

      {:tcp_closed, ^native} ->
        send(pid, {:wasm_host, "tcp_closed", %{"id" => "c9"}, ""})
        called

      {:host, _, _} ->
        bridge(native, pid, called)
    after
      10_000 -> flunk("the bridge got nothing")
    end
  end

  # A chunked response of the TLS client, until its last chunk.
  defp tls_recv(tls, acc) do
    if String.ends_with?(acc, "0\r\n\r\n") do
      acc
    else
      {:ok, data} = :ssl.recv(tls, 0, 10_000)
      tls_recv(tls, acc <> data)
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

  # A body with no end. Its stop sends :stopped to the test.
  defp endless(test) do
    fn
      :more -> {:data, String.duplicate("x", 4096), endless(test)}
      :stop -> send(test, :stopped)
    end
  end

  defp data(parts) do
    Enum.reduce(Enum.reverse(parts), fn :more -> :done end, fn part, next ->
      fn :more -> {:data, part, next} end
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
    length = List.keyfind(headers, "content-length", 0)

    cond do
      length != nil and byte_size(buffer) < String.to_integer(elem(length, 1)) ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
        chunked(socket, buffer <> data, headers)

      true ->
        dechunk(socket, buffer, headers)
    end
  end

  defp dechunk(socket, buffer, headers) do
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

  defp recv_until(socket, suffix, acc \\ "") do
    if String.ends_with?(acc, suffix) do
      {:ok, acc}
    else
      with {:ok, data} <- :gen_tcp.recv(socket, 0, 5000),
           do: recv_until(socket, suffix, acc <> data)
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
