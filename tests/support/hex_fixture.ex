defmodule BeamCom.HexFixture do
  @moduledoc """
  Hex packages and a small HTTP server in place of hex.pm, for the tests
  of `:beam_com_hex` and of the builds with the deps of rebar.config.

  The functions use the terms of Erlang: charlists for the versions, the
  requirements and the file names, and binaries for the package names.
  The environment variables HEX_API_URL and HEX_MIRROR give the address
  of the server to `:beam_com_hex.fetch/2`.
  """

  @doc """
  A Hex tarball (version 3) of the package `name` at the version `vsn`.
  The tarball has `files` in contents.tar.gz, and `reqs` as the
  requirements `[{dep, requirement}]`. `tools` are the build tools.
  """
  def package(name, vsn, files, reqs, tools) do
    in_tmp(fn tmp ->
      contents_file = :filename.join(tmp, ~c"contents.tar.gz")

      :ok =
        :erl_tar.create(
          contents_file,
          for({f, c} <- files, do: {f, :erlang.iolist_to_binary(c)}),
          [:compressed]
        )

      {:ok, contents} = :file.read_file(contents_file)

      requirements =
        for {d, r} <- reqs do
          {d,
           [
             {"app", d},
             {"optional", false},
             {"requirement", :erlang.list_to_binary(r)},
             {"repository", "hexpm"}
           ]}
        end

      meta =
        :erlang.iolist_to_binary(
          for t <- [
                {"name", name},
                {"version", :erlang.list_to_binary(vsn)},
                {"app", name},
                {"build_tools", tools},
                {"requirements", requirements}
              ] do
            :io_lib.format(~c"~tp.~n", [t])
          end
        )

      hex_tar(meta, contents)
    end)
  end

  @doc """
  A Hex tarball of the metadata `meta` and the contents `contents`, with
  its checksum.
  """
  def hex_tar(meta, contents) do
    in_tmp(fn tmp ->
      version = "3"
      sum = :binary.encode_hex(:crypto.hash(:sha256, [version, meta, contents]))
      tar_file = :filename.join(tmp, ~c"p.tar")

      :ok =
        :erl_tar.create(
          tar_file,
          [
            {~c"VERSION", version},
            {~c"CHECKSUM", sum},
            {~c"metadata.config", meta},
            {~c"contents.tar.gz", contents}
          ],
          []
        )

      {:ok, tar} = :file.read_file(tar_file)
      tar
    end)
  end

  @doc """
  The routes of the server for the packages `[{name, vsn, reqs, tar}]`.
  The API gives rebar3 as the build tool of each release.
  """
  def routes(packages) do
    names = :lists.usort(for {n, _, _, _} <- packages, do: n)

    versions =
      for n <- names do
        releases =
          for {m, v, _, _} <- packages, m === n, do: %{"version" => :erlang.list_to_binary(v)}

        {~c"/api/packages/" ++ :erlang.binary_to_list(n), :json.encode(%{"releases" => releases})}
      end

    releases =
      for {n, v, reqs, tar} <- packages do
        requirements =
          Map.new(reqs, fn {d, r} ->
            {d, %{"app" => d, "optional" => false, "requirement" => :erlang.list_to_binary(r)}}
          end)

        {~c"/api/packages/" ++ :erlang.binary_to_list(n) ++ ~c"/releases/" ++ v,
         :json.encode(%{
           "checksum" => :string.lowercase(:binary.encode_hex(:crypto.hash(:sha256, tar))),
           "meta" => %{"build_tools" => ["rebar3"]},
           "requirements" => requirements
         })}
      end

    tarballs =
      for {n, v, _, tar} <- packages do
        {~c"/repo/tarballs/" ++ :erlang.binary_to_list(n) ++ ~c"-" ++ v ++ ~c".tar", tar}
      end

    Map.new(versions ++ releases ++ tarballs)
  end

  @doc """
  Starts a small HTTP/1.1 server on the loopback address. The server
  answers a GET of each path of `routes`, with one request for each
  connection. The result is `{pid, port}`.
  """
  def serve(routes) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, listen} =
          :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

        {:ok, port} = :inet.port(listen)
        send(parent, {self(), port})
        server = self()
        spawn_link(fn -> accept(listen, routes, server) end)
        server_loop([])
      end)

    receive do
      {^pid, port} -> {pid, port}
    end
  end

  @doc "The paths of the requests to the server `pid`, in the order of arrival."
  def requests(pid) do
    send(pid, {:requests, self()})

    receive do
      {^pid, log} -> log
    end
  end

  @doc "Stops the server `pid`."
  def stop(pid), do: send(pid, :stop)

  defp server_loop(log) do
    receive do
      {:request, path} ->
        server_loop([path | log])

      {:requests, from} ->
        send(from, {self(), :lists.reverse(log)})
        server_loop(log)

      :stop ->
        exit(:normal)
    end
  end

  defp accept(listen, routes, server) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> answer(socket, routes, server) end)
        accept(listen, routes, server)

      {:error, _} ->
        :ok
    end
  end

  defp answer(socket, routes, server) do
    {:ok, request} = read_head(socket, <<>>)
    [line | _] = :binary.split(request, "\r\n")
    ["GET", path | _] = :binary.split(line, " ", [:global])
    p = :erlang.binary_to_list(path)
    send(server, {:request, p})

    {status, body} =
      case routes do
        %{^p => b} -> {"200 OK", :erlang.iolist_to_binary(b)}
        _ -> {"404 Not Found", "not found"}
      end

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 ",
        status,
        "\r\nContent-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\nConnection: close\r\n\r\n",
        body
      ])

    :gen_tcp.close(socket)
  end

  defp read_head(socket, acc) do
    case :binary.match(acc, "\r\n\r\n") do
      :nomatch ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 5000)
        read_head(socket, acc <> more)

      _ ->
        {:ok, acc}
    end
  end

  # Runs fun with a new temporary directory, and removes the directory
  # after fun.
  defp in_tmp(fun) do
    dir =
      :filename.join(
        String.to_charlist(System.tmp_dir!()),
        ~c"beam_com_hex_fixture." ++ Integer.to_charlist(:erlang.unique_integer([:positive]))
      )

    :ok = :filelib.ensure_path(dir)

    try do
      fun.(dir)
    after
      :file.del_dir_r(dir)
    end
  end
end
