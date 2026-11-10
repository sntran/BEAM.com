defmodule BeamCom.SshFixture do
  @moduledoc """
  A server of git over SSH for the tests of `:beam_com_git_ssh`: an SSH
  daemon of OTP on the loopback address. Each exec of `git-upload-pack`
  gets one of these:

  - `{:v2, repo, refs}`: the repository of `BeamCom.GitFixture`, with
    version 2 of the git protocol when the client sets `GIT_PROTOCOL`.
  - `{:v0, repo, refs}`: the same repository, with version 0 only (the
    server refuses the variable, as OpenSSH does by default).
  - `{:git, dir}`: the `git-upload-pack` program for the repository
    `dir`, and `{:git_v0, dir}` with no `GIT_PROTOCOL`.
  - `{:v0, repo, refs, caps}`: version 0 with the capabilities `caps`.
  - `{:silent}`: no answer to the exec.
  - `{:stderr, text}`: `text` on the standard error, then the end of the
    channel with the exit status 1.

  The daemon sends `{:ssh_fixture, :exec, command, env}` to the test.
  """
  @behaviour :ssh_server_channel

  @doc """
  Start a daemon: `{daemon, port, host_key}`. `users` are the public
  keys that can log in.
  """
  def start(mode, users, owner \\ self()) do
    host = :public_key.generate_key({:namedCurve, :ed25519})
    {:ok, _} = Application.ensure_all_started(:ssh)

    {:ok, daemon} =
      :ssh.daemon({127, 0, 0, 1}, 0,
        key_cb: {BeamCom.SshFixture.Keys, host: host, users: users},
        ssh_cli: {__MODULE__, [mode, owner]},
        auth_methods: ~c"publickey",
        subsystems: []
      )

    {:ok, info} = :ssh.daemon_info(daemon)
    {daemon, Keyword.fetch!(info, :port), host}
  end

  @doc "A line of known_hosts for the host key at the port."
  def known_line(port, host) do
    blob = :ssh_file.encode(:ssh_file.extract_public_key(host), :ssh2_pubkey)
    "[127.0.0.1]:#{port} ssh-ed25519 #{Base.encode64(blob)}\n"
  end

  @doc """
  A new key of ed25519, and its file in the format of OpenSSH. With a
  cipher other than "none", the file is as a file with a passphrase.
  """
  def user_key(cipher \\ "none") do
    key = :public_key.generate_key({:namedCurve, :ed25519})
    {key, key_file(key, cipher)}
  end

  # The format openssh-key-v1, as ssh-keygen writes it: the private part
  # of ed25519 is the seed and the public key (64 bytes).
  defp key_file({:ECPrivateKey, _, priv, _, pub, _} = key, cipher) do
    check = :crypto.strong_rand_bytes(4)
    plain = check <> check <> str("ssh-ed25519") <> str(pub) <> str(priv <> pub) <> str("test")
    pad = rem(8 - rem(byte_size(plain), 8), 8)
    plain = plain <> :binary.list_to_bin(Enum.take(1..8, pad))
    blob = :ssh_file.encode(public(key), :ssh2_pubkey)

    bin =
      "openssh-key-v1\0" <>
        str(cipher) <> str("none") <> str("") <> <<1::32>> <> str(blob) <> str(plain)

    lines =
      Base.encode64(bin) |> String.codepoints() |> Enum.chunk_every(70) |> Enum.map(&Enum.join/1)

    Enum.join(
      ["-----BEGIN OPENSSH PRIVATE KEY-----"] ++
        lines ++ ["-----END OPENSSH PRIVATE KEY-----", ""],
      "\n"
    )
  end

  defp str(data), do: <<byte_size(data)::32, data::binary>>

  @doc "The public key of a private key."
  def public(key), do: :ssh_file.extract_public_key(key)

  @impl true
  def init([mode, owner]),
    do: {:ok, %{mode: mode, owner: owner, env: nil, buf: "", port: nil, phase: nil}}

  @impl true
  def handle_msg({:ssh_channel_up, ch, conn}, st), do: {:ok, Map.merge(st, %{ch: ch, conn: conn})}

  def handle_msg({port, {:data, data}}, %{port: port} = st) do
    :ssh_connection.send(st.conn, st.ch, data)
    {:ok, st}
  end

  def handle_msg({port, {:exit_status, status}}, %{port: port} = st) do
    finish(st, status)
  end

  def handle_msg(_msg, st), do: {:ok, st}

  @impl true
  def handle_ssh_msg({:ssh_cm, conn, {:env, ch, want, var, value}}, st) do
    accept = elem(st.mode, 0) not in [:v0, :git_v0]
    :ssh_connection.reply_request(conn, want, if(accept, do: :success, else: :failure), ch)
    {:ok, if(accept, do: %{st | env: {to_string(var), to_string(value)}}, else: st)}
  end

  def handle_ssh_msg({:ssh_cm, conn, {:exec, ch, want, cmd}}, st) do
    :ssh_connection.reply_request(conn, want, :success, ch)
    send(st.owner, {:ssh_fixture, :exec, to_string(cmd), st.env})

    case st.mode do
      {:silent} ->
        {:ok, st}

      {:stderr, text} ->
        :ssh_connection.send(conn, ch, 1, text)
        finish(st, 1)

      _ ->
        {:ok, upload_pack(st.mode, %{st | phase: :start})}
    end
  end

  def handle_ssh_msg({:ssh_cm, _conn, {:data, _ch, 0, data}}, %{port: port} = st)
      when is_port(port) do
    Port.command(port, data)
    {:ok, st}
  end

  def handle_ssh_msg({:ssh_cm, _conn, {:data, _ch, 0, data}}, st) do
    serve(%{st | buf: st.buf <> data})
  end

  def handle_ssh_msg({:ssh_cm, _conn, {:eof, _ch}}, %{port: port} = st) when is_port(port) do
    {:ok, st}
  end

  def handle_ssh_msg({:ssh_cm, _conn, {:eof, _ch}}, st), do: finish(st, 0)
  def handle_ssh_msg(_msg, st), do: {:ok, st}

  @impl true
  def terminate(_reason, _st), do: :ok

  defp upload_pack({:git_v0, dir}, st), do: upload_pack({:git, dir}, %{st | env: nil})

  defp upload_pack({:git, dir}, st) do
    env =
      case st.env do
        {"GIT_PROTOCOL", v} -> [{~c"GIT_PROTOCOL", String.to_charlist(v)}]
        _ -> []
      end

    port =
      Port.open({:spawn_executable, System.find_executable("git")}, [
        :binary,
        :exit_status,
        args: ["upload-pack", dir],
        env: env
      ])

    %{st | port: port}
  end

  defp upload_pack({:v0, repo, refs, caps}, st), do: advertise(repo, refs, caps, st)

  defp upload_pack({version, repo, refs}, st) do
    if version == :v2 and st.env == {"GIT_PROTOCOL", "version=2"} do
      reply(st, [pkt("version 2\n"), pkt("ls-refs\n"), pkt("fetch=shallow\n"), "0000"])
      %{st | phase: :v2}
    else
      advertise(repo, refs, "side-band-64k ofs-delta shallow no-progress", st)
    end
  end

  defp advertise({_pack, commit}, refs, caps, st) do
    reply(st, [
      pkt("#{commit} HEAD\0#{caps}\n"),
      for(r <- refs, do: pkt("#{commit} #{r}\n")),
      "0000"
    ])

    %{st | phase: :wants}
  end

  # The requests of the client, after each complete one.
  defp serve(st) do
    case request(st.buf) do
      {:ok, lines, rest} -> answer(lines, %{st | buf: rest})
      :more -> {:ok, st}
    end
  end

  defp answer(lines, %{phase: :v2} = st) do
    {_version, {pack, commit}, refs} = st.mode

    cond do
      lines == [] ->
        finish(st, 0)

      "command=ls-refs\n" in lines ->
        reply(st, [for(r <- refs, do: pkt("#{commit} #{r}\n")), "0000"])
        serve(st)

      true ->
        reply(st, [pkt("packfile\n"), bands(pack), "0000"])
        serve(st)
    end
  end

  defp answer(_lines, %{phase: :wants} = st) do
    {_version, {_pack, commit}, _refs} = st.mode
    reply(st, [pkt("shallow #{commit}\n"), "0000"])
    serve(%{st | phase: :done})
  end

  defp answer(["done\n"], %{phase: :done} = st) do
    {_version, {pack, _commit}, _refs} = st.mode
    reply(st, [pkt("NAK\n"), bands(pack), "0000"])
    finish(st, 0)
  end

  defp answer(_lines, st), do: {:ok, st}

  # A request of version 2 ends with a flush. Version 0 sends "done"
  # with no flush.
  defp request(buf), do: request(buf, [])

  defp request("0000" <> rest, acc), do: {:ok, Enum.reverse(acc), rest}
  defp request("0001" <> rest, acc), do: request(rest, acc)

  defp request(<<hex::binary-size(4), rest::binary>>, acc) do
    len = String.to_integer(hex, 16) - 4

    case rest do
      <<"done\n", after_done::binary>> when len == 5 -> {:ok, ["done\n"], after_done}
      <<data::binary-size(^len), next::binary>> -> request(next, [data | acc])
      _ -> :more
    end
  end

  defp request(_buf, _acc), do: :more

  defp bands(<<chunk::binary-size(60_000), rest::binary>>),
    do: [pkt(<<1>> <> chunk) | bands(rest)]

  defp bands(""), do: []
  defp bands(rest), do: [pkt(<<1>> <> rest)]

  defp reply(st, data), do: :ssh_connection.send(st.conn, st.ch, IO.iodata_to_binary(data))

  defp finish(st, status) do
    :ssh_connection.send_eof(st.conn, st.ch)
    :ssh_connection.exit_status(st.conn, st.ch, status)
    {:stop, st.ch, st}
  end

  defp pkt(data), do: :beam_com_git.pkt(data)
end

defmodule BeamCom.SshFixture.Keys do
  @moduledoc "The keys of the daemon of `BeamCom.SshFixture`."
  @behaviour :ssh_server_key_api

  @impl true
  def host_key(:"ssh-ed25519", opts), do: {:ok, private(opts)[:host]}
  def host_key(_alg, _opts), do: {:error, :enoent}

  @impl true
  def is_auth_key(key, _user, opts), do: key in private(opts)[:users]

  defp private(opts), do: Keyword.fetch!(opts, :key_cb_private)
end

defmodule BeamCom.SshFixture.Agent do
  @moduledoc """
  An SSH agent for the tests: it lists its keys and signs with them, on
  a Unix socket. It signs with ed25519, ECDSA and RSA keys, and for an
  RSA key it follows the flags of the request (rsa-sha2-256 or
  rsa-sha2-512), as the agent of OpenSSH does.

  Options: `refuse`, the keys that it does not sign with (it answers
  SSH_AGENT_FAILURE), and `owner`, a process that gets
  `{:agent_sign, algorithm}` for each signature.
  """

  @doc "Start an agent with the private keys at the socket `path`."
  def start(path, keys, opts \\ []) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false])
    pid = spawn(fn -> accept(listen, keys, opts) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    pid
  end

  defp accept(listen, keys, opts) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, keys, opts) end)
        |> then(&:gen_tcp.controlling_process(socket, &1))

        accept(listen, keys, opts)

      {:error, _} ->
        :ok
    end
  end

  defp serve(socket, keys, opts) do
    with {:ok, <<len::32>>} <- :gen_tcp.recv(socket, 4),
         {:ok, msg} <- :gen_tcp.recv(socket, len) do
      :gen_tcp.send(socket, frame(answer(msg, keys, opts)))
      serve(socket, keys, opts)
    end
  end

  # 11: the identities; 13: a signature; 5: SSH_AGENT_FAILURE.
  defp answer(<<11>>, keys, _opts) do
    [<<12, length(keys)::32>>, for(k <- keys, do: [str(blob(k)), str("test")])]
  end

  defp answer(
         <<13, len::32, key_blob::binary-size(len), dlen::32, data::binary-size(dlen),
           flags::32>>,
         keys,
         opts
       ) do
    key = Enum.find(keys, &(blob(&1) == key_blob))

    if key == nil or key in Keyword.get(opts, :refuse, []) do
      <<5>>
    else
      {alg, sig} = sign(key, data, flags)
      if owner = opts[:owner], do: send(owner, {:agent_sign, alg})
      [<<14>>, str([str(alg), str(sig)])]
    end
  end

  defp sign({:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} = key, data, flags) do
    cond do
      Bitwise.band(flags, 2) != 0 -> {"rsa-sha2-256", :public_key.sign(data, :sha256, key)}
      Bitwise.band(flags, 4) != 0 -> {"rsa-sha2-512", :public_key.sign(data, :sha512, key)}
      true -> {"ssh-rsa", :public_key.sign(data, :sha, key)}
    end
  end

  defp sign(key, data, _flags) do
    case type(blob(key)) do
      "ssh-ed25519" ->
        {"ssh-ed25519", :public_key.sign(data, :none, key)}

      "ecdsa-sha2-" <> curve = type ->
        hash = %{"nistp256" => :sha256, "nistp384" => :sha384, "nistp521" => :sha512}[curve]
        der = :public_key.sign(data, hash, key)
        {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
        {type, IO.iodata_to_binary([mpint(r), mpint(s)])}
    end
  end

  defp type(<<len::32, type::binary-size(len), _::binary>>), do: type

  defp mpint(n) do
    bin = :binary.encode_unsigned(n)
    str(if :binary.first(bin) >= 128, do: <<0>> <> bin, else: bin)
  end

  defp blob(key), do: :ssh_file.encode(:ssh_file.extract_public_key(key), :ssh2_pubkey)

  defp str(data) do
    bin = IO.iodata_to_binary(data)
    [<<byte_size(bin)::32>>, bin]
  end

  defp frame(data) do
    bin = IO.iodata_to_binary(data)
    [<<byte_size(bin)::32>>, bin]
  end
end
