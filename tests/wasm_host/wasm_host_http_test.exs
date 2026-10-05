defmodule WasmHostHttpTest do
  @moduledoc """
  The tests of `:wasm_host_http`, the HTTP/1.1 of the fetch path: the head
  of a request, the framing of its body, and the head of a response.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  describe "head/1" do
    test "a request with a path and headers" do
      assert {:ok,
              %{
                method: "POST",
                path: "/client/v4/ips?a=1",
                version: {1, 1},
                headers: [{"host", "api.cloudflare.com"}, {"x-key", "v"}, {"content-length", "2"}]
              }, "{}"} =
               :wasm_host_http.head(
                 "POST /client/v4/ips?a=1 HTTP/1.1\r\nHost: api.cloudflare.com\r\nX-Key: v\r\n" <>
                   "Content-Length: 2\r\n\r\n{}"
               )
    end

    test "more bytes" do
      assert :more == :wasm_host_http.head("GET / HTTP/1.1\r\nHost: a")
      assert :more == :wasm_host_http.head("")
    end

    test "an absolute URI gives its path" do
      assert {:ok, %{path: "/x"}, ""} =
               :wasm_host_http.head("GET http://a.example/x HTTP/1.1\r\n\r\n")
    end

    test "not a path" do
      assert {:error, :bad_target} == :wasm_host_http.head("OPTIONS * HTTP/1.1\r\n\r\n")
    end

    test "not HTTP" do
      assert {:error, :bad_request} == :wasm_host_http.head("\x16\x03\x01\x00\x05hello\r\n\r\n")
    end

    test "a head that is too large" do
      long = "GET / HTTP/1.1\r\nX: " <> String.duplicate("a", 70_000)
      assert {:error, :too_large} == :wasm_host_http.head(long)
    end

    property "a head in pieces parses as the whole" do
      check all(
              method <- member_of(["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD"]),
              path <- path(),
              headers <- list_of(header(), max_length: 8),
              cut <- integer(0..200)
            ) do
        bytes =
          IO.iodata_to_binary([
            method,
            " ",
            path,
            " HTTP/1.1\r\n",
            for({k, v} <- headers, do: [k, ": ", v, "\r\n"]),
            "\r\n"
          ])

        cut = min(cut, byte_size(bytes) - 1)
        assert :more == :wasm_host_http.head(binary_part(bytes, 0, cut))

        assert {:ok, %{method: ^method, path: ^path, headers: parsed}, ""} =
                 :wasm_host_http.head(bytes)

        assert parsed == for({k, v} <- headers, do: {String.downcase(k), v})
      end
    end
  end

  describe "framing/1" do
    test "the framings" do
      assert :none == :wasm_host_http.framing([])
      assert {:length, 12} == :wasm_host_http.framing([{"content-length", " 12 "}])

      assert {:length, 3} ==
               :wasm_host_http.framing([{"content-length", "3"}, {"content-length", "3"}])

      assert :chunked == :wasm_host_http.framing([{"transfer-encoding", "Chunked"}])
    end

    test "a framing that can disagree is refused" do
      for headers <- [
            [{"content-length", "3"}, {"content-length", "4"}],
            [{"content-length", "+3"}],
            [{"content-length", "-1"}],
            [{"content-length", "0x10"}],
            [{"transfer-encoding", "chunked"}, {"content-length", "3"}],
            [{"transfer-encoding", "gzip, chunked"}]
          ] do
        assert {:error, _} = :wasm_host_http.framing(headers), inspect(headers)
      end
    end
  end

  describe "dechunk/2" do
    test "a chunked body with an extension and trailers" do
      assert {:ok, "hello world", "next"} ==
               :wasm_host_http.dechunk(
                 "5;x=1\r\nhello\r\n6\r\n world\r\n0\r\nT: v\r\n\r\nnext",
                 []
               )
    end

    test "bad chunks" do
      for bytes <- ["z\r\n", "-0\r\n\r\n", "5\r\nhelloXX", String.duplicate("1", 2000)] do
        assert {:error, :bad_chunk} == :wasm_host_http.dechunk(bytes, []), inspect(bytes)
      end
    end

    property "a body in chunks, given in pieces, decodes to the body" do
      check all(
              chunks <- list_of(binary(min_length: 1, max_length: 40), max_length: 6),
              cuts <- list_of(integer(1..30), max_length: 10)
            ) do
        encoded =
          IO.iodata_to_binary([
            for(c <- chunks, do: [Integer.to_string(byte_size(c), 16), "\r\n", c, "\r\n"]),
            "0\r\n\r\n"
          ])

        assert {:ok, IO.iodata_to_binary(chunks), ""} == feed(encoded, cuts)
      end
    end
  end

  describe "request_headers/1" do
    test "no headers of the connection, of the framing, host or accept-encoding" do
      assert [{"authorization", "Bearer t"}, {"content-type", "application/json"}] ==
               :wasm_host_http.request_headers([
                 {"host", "api.cloudflare.com"},
                 {"connection", "keep-alive, x-hop"},
                 {"x-hop", "1"},
                 {"authorization", "Bearer t"},
                 {"content-length", "2"},
                 {"transfer-encoding", "chunked"},
                 {"accept-encoding", "gzip"},
                 {"expect", "100-continue"},
                 {"te", "trailers"},
                 {"content-type", "application/json"}
               ])
    end
  end

  describe "response/4" do
    test "no encoding, no length and no framing of the host" do
      head =
        IO.iodata_to_binary(
          :wasm_host_http.response(
            200,
            "",
            [
              {"Content-Type", "application/json"},
              {"content-encoding", "gzip"},
              {"content-length", "307"},
              {"transfer-encoding", "chunked"},
              {"set-cookie", "a=1"},
              {"set-cookie", "b=2"}
            ],
            %{chunked: true, close: false}
          )
        )

      assert head ==
               "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nset-cookie: a=1\r\n" <>
                 "set-cookie: b=2\r\ntransfer-encoding: chunked\r\nconnection: keep-alive\r\n\r\n"
    end

    test "no body, and close" do
      assert "HTTP/1.1 304 Not Modified\r\nconnection: close\r\n\r\n" ==
               IO.iodata_to_binary(
                 :wasm_host_http.response(304, "", [], %{chunked: false, close: true})
               )
    end

    property "a value with CR, LF or NUL does not reach the head" do
      check all(
              value <- string(:printable, max_length: 10),
              bad <- member_of(["\r", "\n", <<0>>]),
              reason <- member_of(["", "Fine", "Bad\r\nX: y"])
            ) do
        head =
          IO.iodata_to_binary(
            :wasm_host_http.response(
              200,
              reason,
              [{"x-a", value <> bad <> value}, {"x-b", "ok"}],
              %{
                chunked: true,
                close: false
              }
            )
          )

        [status | lines] = String.split(head, "\r\n")
        assert status in ["HTTP/1.1 200 OK", "HTTP/1.1 200 Fine"]
        assert "x-b: ok" in lines
        refute Enum.any?(lines, &String.starts_with?(&1, "x-a:"))
        assert String.ends_with?(head, "\r\n\r\n")
      end
    end
  end

  test "chunk/1 and last_chunk/0" do
    assert "5\r\nhello\r\n" == IO.iodata_to_binary(:wasm_host_http.chunk("hello"))
    assert [] == :wasm_host_http.chunk("")
    assert "0\r\n\r\n" == :wasm_host_http.last_chunk()
  end

  test "keep_alive/2, body_allowed/2 and continue/1" do
    assert :wasm_host_http.keep_alive({1, 1}, [])
    refute :wasm_host_http.keep_alive({1, 1}, [{"connection", "keep-alive, Close"}])
    refute :wasm_host_http.keep_alive({1, 0}, [])
    refute :wasm_host_http.body_allowed("HEAD", 200)
    refute :wasm_host_http.body_allowed("GET", 204)
    refute :wasm_host_http.body_allowed("GET", 304)
    refute :wasm_host_http.body_allowed("GET", 101)
    assert :wasm_host_http.body_allowed("GET", 200)
    assert :wasm_host_http.continue([{"expect", "100-Continue"}])
    refute :wasm_host_http.continue([])
  end

  # The bytes in pieces of the sizes of cuts (the rest in one piece), as the
  # server reads them.
  defp feed(bytes, cuts), do: feed(bytes, cuts, "", [])

  defp feed(bytes, [n | cuts], buffer, acc) when byte_size(bytes) > n do
    <<piece::binary-size(^n), rest::binary>> = bytes

    case :wasm_host_http.dechunk(buffer <> piece, acc) do
      {:more, acc, buffer} -> feed(rest, cuts, buffer, acc)
      other -> {other, rest}
    end
  end

  defp feed(bytes, _cuts, buffer, acc) do
    case :wasm_host_http.dechunk(buffer <> bytes, acc) do
      {:ok, body, rest} -> {:ok, body, rest}
      other -> other
    end
  end

  defp path do
    gen all(
          segments <- list_of(string(:alphanumeric, min_length: 1, max_length: 8), max_length: 4)
        ) do
      "/" <> Enum.join(segments, "/")
    end
  end

  defp header do
    gen all(
          name <- string(:alphanumeric, min_length: 1, max_length: 10),
          value <- string(Enum.concat([?a..?z, ?0..?9, [?\s, ?-, ?/, ?=]]), max_length: 20)
        ) do
      {"x-" <> name, String.trim(value)}
    end
  end
end
