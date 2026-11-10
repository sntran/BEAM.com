defmodule BeamComGitSshTest do
  @moduledoc """
  The tests of `:beam_com_git_ssh`, the SSH transport of the git client.
  An SSH daemon of OTP on the loopback address serves the repository
  (`BeamCom.SshFixture`), and each test has its own `~/.ssh`.
  """
  use ExUnit.Case, async: true

  alias BeamCom.{GitFixture, SshFixture}

  @moduletag :tmp_dir
  # The ssh application logs each refused connection.
  @moduletag :capture_log

  describe "the URL and the command" do
    test "parse_url: ssh://, the form of scp, and other URLs" do
      assert {~c"git", ~c"github.com", :none, ~c"org/repo.git"} ==
               :beam_com_git_ssh.parse_url("git@github.com:org/repo.git")

      assert {:none, ~c"host", :none, ~c"repo"} == :beam_com_git_ssh.parse_url("host:repo")

      assert {~c"me", ~c"example.com", 2222, ~c"/srv/repo.git"} ==
               :beam_com_git_ssh.parse_url("ssh://me@example.com:2222/srv/repo.git")

      assert {:none, ~c"example.com", :none, ~c"~me/repo"} ==
               :beam_com_git_ssh.parse_url(~c"git+ssh://example.com/~me/repo")

      for url <- [
            "https://example.com/a.git",
            "git://example.com/a.git",
            "/local/path",
            "./a:b",
            "c:",
            ":path",
            "@host:path"
          ] do
        assert :none == :beam_com_git_ssh.parse_url(url), url
        refute :beam_com_git_ssh.is_ssh(url)
      end

      assert :beam_com_git_ssh.is_ssh("ssh://h/r")

      # SSH has no password in the URL: the user stays, and the password
      # goes.
      assert {~c"git", ~c"h", :none, ~c"/r"} ==
               :beam_com_git_ssh.parse_url("ssh://git:s3cret@h/r")
    end

    test "quote: single quotes, as git quotes the path" do
      assert ~c"'org/repo.git'" == :beam_com_git_ssh.quote(~c"org/repo.git")
      assert ~c"'it'\\''s'" == :beam_com_git_ssh.quote(~c"it's")
    end
  end

  describe "~/.ssh/config" do
    defp config(text, host, includes \\ %{}) do
      read = fn args -> for a <- args, Map.has_key?(includes, a), do: includes[a] end
      :beam_com_git_ssh.config(text, String.to_charlist(host), read)
    end

    test "the first value wins, IdentityFile adds, and Host patterns" do
      text = """
      # a comment
      Host gh github
        HostName github.com
        User=git
        IdentityFile "~/.ssh/my key"
        IdentityFile ~/.ssh/other

      Host *.example.com !secret.example.com
        Port 2222
        User web

      Host *
        User everyone
        IdentityFile ~/.ssh/last
        IdentitiesOnly yes
      """

      assert %{
               ~c"hostname" => [~c"github.com"],
               ~c"user" => [~c"git"],
               ~c"identityfile" => [~c"~/.ssh/my key", ~c"~/.ssh/other", ~c"~/.ssh/last"],
               ~c"identitiesonly" => [~c"yes"]
             } = config(text, "gh")

      assert %{~c"port" => [~c"2222"], ~c"user" => [~c"web"]} = config(text, "www.example.com")
      assert %{~c"user" => [~c"everyone"]} = c = config(text, "secret.example.com")
      refute Map.has_key?(c, ~c"port")
    end

    test "Match all applies, another Match does not, and Include" do
      text = """
      Include extra
      Match host x exec "true"
        User nobody
      Match all
        Port 2200
      """

      assert %{~c"user" => [~c"fromextra"], ~c"port" => [~c"2200"]} =
               config(text, "x", %{~c"extra" => "Host x\n  User fromextra\n"})

      # An Include in an Include, up to a depth.
      loop = %{~c"extra" => "Include extra\nHost y\n User again\n"}
      assert %{~c"user" => [~c"again"]} = config(text, "y", loop)
    end

    test "match_host: wildcards, negation and lists" do
      assert :beam_com_git_ssh.match_host(~c"a.example.com", [~c"*.example.com"])
      assert :beam_com_git_ssh.match_host(~c"HOST1", [~c"host?"])
      assert :beam_com_git_ssh.match_host(~c"b", [~c"a,b"])
      refute :beam_com_git_ssh.match_host(~c"example.com", [~c"*.example.com"])
      refute :beam_com_git_ssh.match_host(~c"x", [~c"!x", ~c"*"])
      refute :beam_com_git_ssh.match_host(~c"x", [~c"!y"])
    end
  end

  describe "known_hosts and the keys" do
    test "known: names, ports, hashed names, revoked keys and markers" do
      salt = :crypto.strong_rand_bytes(20)
      hash = :crypto.mac(:hmac, :sha, salt, "hashed.example.com")
      hashed = "|1|#{Base.encode64(salt)}|#{Base.encode64(hash)}"

      text = """
      # a comment
      a.example.com,b.example.com ssh-ed25519 #{Base.encode64("A")} comment
      [a.example.com]:2222 ssh-ed25519 #{Base.encode64("P")}
      #{hashed}\tssh-ed25519\t#{Base.encode64("H")}
      @revoked * ssh-rsa #{Base.encode64("R")}
      @cert-authority *.example.com ssh-ed25519 #{Base.encode64("C")}
      bad.example.com ssh-ed25519 !!notbase64
      |1|bad hash
      short line
      """

      assert {[~c"A"], [~c"R"]} == known(text, "b.example.com")
      assert {[~c"P"], [~c"R"]} == known(text, "[a.example.com]:2222")
      assert {[~c"H"], [~c"R"]} == known(text, "hashed.example.com")
      assert {[], [~c"R"]} == known(text, "bad.example.com")
    end

    defp known(text, name) do
      {k, r} = :beam_com_git_ssh.known(text, String.to_charlist(name), {[], []})
      {Enum.map(k, &String.to_charlist/1), Enum.map(r, &String.to_charlist/1)}
    end

    test "key_algs and rounds: one key of each algorithm in a round" do
      blob = fn type -> <<byte_size(type)::32, type::binary, 0::32>> end
      ed = blob.("ssh-ed25519")
      rsa = blob.("ssh-rsa")
      ec = blob.("ecdsa-sha2-nistp256")

      assert [:"ssh-ed25519"] == :beam_com_git_ssh.key_algs(ed)
      assert [:"ssh-ed448"] == :beam_com_git_ssh.key_algs(blob.("ssh-ed448"))
      assert [:"rsa-sha2-512", :"rsa-sha2-256", :"ssh-rsa"] == :beam_com_git_ssh.key_algs(rsa)
      assert [:"ecdsa-sha2-nistp256"] == :beam_com_git_ssh.key_algs(ec)
      assert [] == :beam_com_git_ssh.key_algs(blob.("ssh-dss"))
      assert [] == :beam_com_git_ssh.key_algs("x")

      keys = [
        {{:agent, ed}, ed},
        {{:agent, rsa}, rsa},
        {{:file, :k1}, ed},
        {{:file, :k2}, rsa},
        {{:file, :k3}, ec},
        {{:file, :dss}, blob.("ssh-dss")}
      ]

      # OTP asks user_key/2 for ssh-rsa for each of the RSA algorithms.
      assert [r1, r2] = :beam_com_git_ssh.rounds(keys)
      assert %{"ssh-ed25519": {:agent, ^ed}, "ssh-rsa": {:agent, ^rsa}} = r1
      assert %{"ecdsa-sha2-nistp256": {:file, :k3}} = r1
      assert [:"ecdsa-sha2-nistp256", :"ssh-ed25519", :"ssh-rsa"] == Enum.sort(Map.keys(r1))
      assert %{"ssh-ed25519": {:file, :k1}, "ssh-rsa": {:file, :k2}} = r2
      assert [:"ssh-ed25519", :"ssh-rsa"] == Enum.sort(Map.keys(r2))
      assert [] == :beam_com_git_ssh.rounds([])
    end

    test "host_algs: the algorithms of the known keys, in the order of OTP" do
      blob = fn type -> <<byte_size(type)::32, type::binary, 0::32>> end
      supported = :proplists.get_value(:public_key, :ssh.default_algorithms())
      algs = :beam_com_git_ssh.host_algs([blob.("ssh-rsa"), blob.("ssh-ed25519")], supported)
      assert algs == Enum.filter(supported, &(&1 in algs))
      assert :"ssh-ed25519" in algs and :"rsa-sha2-512" in algs

      # Not the alphabetical order, where RSA comes first.
      order = [:"ssh-ed25519", :"rsa-sha2-512", :"rsa-sha2-256", :"ssh-rsa", :other]
      known = [blob.("ssh-rsa"), blob.("ssh-ed25519")]
      assert Enum.take(order, 4) == :beam_com_git_ssh.host_algs(known, order)

      assert [] == :beam_com_git_ssh.host_algs([blob.("ssh-dss")], supported)
    end

    test "sig_alg: the algorithm in the data of a signature" do
      str = fn s -> <<byte_size(s)::32, s::binary>> end

      data =
        str.("session") <>
          <<50>> <>
          str.("git") <>
          str.("ssh-connection") <> str.("publickey") <> <<1>> <> str.("rsa-sha2-512") <> "blob"

      assert "rsa-sha2-512" == :beam_com_git_ssh.sig_alg(data)
      assert :none == :beam_com_git_ssh.sig_alg("other data")
    end

    test "private_key: a key of OpenSSH, a key with a passphrase, and bad text" do
      {key, text} = SshFixture.user_key()
      blob = :ssh_file.encode(SshFixture.public(key), :ssh2_pubkey)
      {:ECPrivateKey, _, priv, curve, pub, _} = key

      assert {:ok, {:ECPrivateKey, _, ^priv, ^curve, ^pub, _}, ^blob} =
               :beam_com_git_ssh.private_key(text)

      {locked_key, pem} = SshFixture.user_key("aes256-ctr")
      locked_blob = :ssh_file.encode(SshFixture.public(locked_key), :ssh2_pubkey)
      assert {:passphrase, ^locked_blob} = :beam_com_git_ssh.private_key(pem)

      assert :error == :beam_com_git_ssh.private_key("not a key")

      assert :error ==
               :beam_com_git_ssh.private_key(
                 "-----BEGIN OPENSSH PRIVATE KEY-----\n!!\n-----END OPENSSH PRIVATE KEY-----\n"
               )
    end
  end

  describe "the agent" do
    test "default_agent: SSH_AUTH_SOCK, else the agent of Windows OpenSSH on Windows" do
      pipe = ~c"\\\\.\\pipe\\openssh-ssh-agent"
      assert pipe == :beam_com_git_ssh.default_agent(%{agent: ~c""}, {:unix, :windows})
      assert ~c"/s" == :beam_com_git_ssh.default_agent(%{agent: ~c"/s"}, {:unix, :windows})
      assert ~c"" == :beam_com_git_ssh.default_agent(%{agent: ~c""}, {:unix, :linux})
    end

    test "agent: a named pipe of Windows goes through ssh_agent_bridge" do
      bridge = ~c"/zip/bin/ssh_agent_bridge"
      assert ~c"" == :beam_com_git_ssh.agent(~c"", %{agent_bridge: ~c"/b"})
      assert ~c"/tmp/s" == :beam_com_git_ssh.agent(~c"/tmp/s", %{})

      for pipe <- [~c"\\\\.\\pipe\\a", ~c"//./PIPE/a"] do
        assert {:bridge, ^bridge, ^pipe} = :beam_com_git_ssh.agent(pipe, %{})
      end

      assert ~c"\\\\.\\pipe/a" == :beam_com_git_ssh.agent(~c"\\\\.\\pipe/a", %{})

      assert {:bridge, ~c"/b", ~c"/tmp/s"} ==
               :beam_com_git_ssh.agent(~c"/tmp/s", %{agent_bridge: ~c"/b"})
    end

    test "identities and signature: the answers of the agent" do
      keys = <<12, 2::32, 1::32, "a", 1::32, "x", 2::32, "bb", 0::32>>
      assert ["a", "bb"] == :beam_com_git_ssh.identities({:ok, keys})
      assert [] == :beam_com_git_ssh.identities({:ok, <<12, 3::32, 1::32, "a", 0::32>>})
      assert [] == :beam_com_git_ssh.identities({:ok, <<5>>})
      assert [] == :beam_com_git_ssh.identities(:error)

      sig = <<11::32, "ssh-ed25519", 3::32, "sig">>

      assert {:ok, "sig"} ==
               :beam_com_git_ssh.signature({:ok, <<14, byte_size(sig)::32, sig::binary>>})

      assert :error == :beam_com_git_ssh.signature({:ok, <<14, 3::32, "sig">>})
      assert :error == :beam_com_git_ssh.signature({:ok, <<5>>})
      assert :error == :beam_com_git_ssh.signature(:error)
    end

    test "agent_call: no agent, a socket with no agent, a bridge that fails", ctx do
      assert :error == :beam_com_git_ssh.agent_call(~c"", <<11>>)
      none = String.to_charlist(Path.join(ctx.tmp_dir, "no_agent"))
      assert :error == :beam_com_git_ssh.agent_call(none, <<11>>)
      missing = String.to_charlist(Path.join(ctx.tmp_dir, "no_program"))
      assert :error == :beam_com_git_ssh.agent_call({:bridge, missing, none}, <<11>>)
      false_ = String.to_charlist(System.find_executable("false"))
      assert :error == :beam_com_git_ssh.agent_call({:bridge, false_, none}, <<11>>)
      assert [] == :beam_com_git_ssh.agent_keys({:bridge, false_, none})
    end

    test "agent_keys and sign: the agent on a socket" do
      {key, _} = SshFixture.user_key()
      sock = agent_socket()
      SshFixture.Agent.start(sock, [key])
      blob = :ssh_file.encode(SshFixture.public(key), :ssh2_pubkey)

      agents =
        [String.to_charlist(sock)] ++
          for b <- [bridge()], b != nil, do: {:bridge, b, String.to_charlist(sock)}

      for agent <- agents do
        assert [blob] == :beam_com_git_ssh.agent_keys(agent)
        sig = :beam_com_git_ssh.sign(blob, "data", key_cb_private: [agent: agent])
        assert :public_key.verify("data", :none, sig, SshFixture.public(key))
      end

      # A refused signature: an empty signature, and a note to the owner.
      ref = make_ref()
      private = [agent: String.to_charlist(sock), owner: self(), ref: ref]
      assert "" == :beam_com_git_ssh.sign("other", "data", key_cb_private: private)
      fp = :ssh.hostkey_fingerprint(:sha256, :ssh_file.decode(blob, :ssh2_pubkey))

      assert "" ==
               :beam_com_git_ssh.sign(blob, "data", key_cb_private: [agent: ~c""] ++ tl(private))

      assert_receive {:beam_com_git_ssh, ^ref, {:sign_failed, _}}, 5_000
      assert_receive {:beam_com_git_ssh, ^ref, {:sign_failed, ^fp}}, 5_000
    end
  end

  # The path of a socket of an agent. A Unix socket has at most 107 bytes,
  # so the path is relative to the directory of the project, in its tmp
  # directory (as the directories of the tmp_dir tag). The runtime of the
  # tests refuses a path of fewer than 14 bytes (einval).
  defp agent_socket do
    File.mkdir_p!("tmp")
    sock = Path.join("tmp", "ssh-agent-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(sock) end)
    sock
  end

  # The program ssh_agent_bridge: BEAM_COM_AGENT_BRIDGE (a build of
  # c_src/cosmo/beam_com_agent.c), else the helper of the beam.com of the
  # tests when the file has one, else nil.
  defp bridge do
    case System.get_env("BEAM_COM_AGENT_BRIDGE") do
      nil ->
        with {:ok, [[exe]]} <- :init.get_argument(:beam_com_exe),
             {:ok, bin} <- File.read(exe),
             {_, _} <- :binary.match(bin, "usage: ssh_agent_bridge AGENT") do
          ~c"/zip/bin/ssh_agent_bridge"
        else
          _ -> nil
        end

      path ->
        String.to_charlist(path)
    end
  end

  describe "the protocol" do
    test "next_pkt: lines, specials, and a part" do
      assert {"ab", "rest"} == :beam_com_git_ssh.next_pkt("0006abrest")
      assert {:flush, ""} == :beam_com_git_ssh.next_pkt("0000")
      assert {:delim, ""} == :beam_com_git_ssh.next_pkt("0001")
      assert {:response_end, ""} == :beam_com_git_ssh.next_pkt("0002")
      assert :more == :beam_com_git_ssh.next_pkt("0009ab")
      assert :more == :beam_com_git_ssh.next_pkt("00")

      assert {:error, ~c"git: a bad pkt-line: ~p", ["zzzz"]} ==
               catch_throw(:beam_com_git_ssh.next_pkt("zzzz"))

      assert {:error, ~c"git: a bad pkt-line: ~p", ["0003"]} ==
               catch_throw(:beam_com_git_ssh.next_pkt("0003"))
    end

    test "v0_refs: the capabilities, and the commits of the tags" do
      adv = [
        "aaa HEAD\0side-band-64k shallow\n",
        "aaa refs/heads/main\n",
        "bbb refs/tags/v1\n",
        "ccc refs/tags/v1^{}\n",
        :flush
      ]

      assert [{"HEAD", "aaa"}, {"refs/heads/main", "aaa"}, {"refs/tags/v1", "ccc"}] ==
               :beam_com_git_ssh.v0_refs(adv)

      assert {:error, ~c"git: ~ts", ["no access"]} ==
               catch_throw(:beam_com_git_ssh.v0_refs(["ERR no access\n"]))
    end
  end

  describe "a server" do
    setup %{tmp_dir: tmp} do
      dir = Path.join(tmp, ".ssh")
      File.mkdir_p!(dir)
      {key, text} = SshFixture.user_key()
      File.write!(Path.join(dir, "id_ed25519"), text)
      repo = GitFixture.repo([{"a.txt", "A\n"}, {"lib/b.ex", "B\n"}])
      opts = %{ssh: %{dir: String.to_charlist(dir), agent: ~c"", global_known_hosts: []}}
      %{dir: dir, key: key, repo: repo, opts: opts}
    end

    defp daemon(ctx, mode, users \\ nil) do
      {daemon, port, host} = SshFixture.start(mode, users || [SshFixture.public(ctx.key)])
      on_exit(fn -> :ssh.stop_daemon(daemon) end)
      File.write!(Path.join(ctx.dir, "known_hosts"), SshFixture.known_line(port, host))
      port
    end

    defp get(url, opts, out) do
      sha = :beam_com_git.resolve(url, {:tag, ~c"v1"}, opts)
      objects = :beam_com_git.fetch(url, sha, opts)
      :ok = :beam_com_git.checkout(objects, sha, String.to_charlist(out), %{url: url})
      sha
    end

    test "version 2: ls-refs, fetch and checkout", ctx do
      port = daemon(ctx, {:v2, ctx.repo, ["refs/tags/v1"]})
      url = "ssh://git@127.0.0.1:#{port}/org/repo.git"
      out = Path.join(ctx.tmp_dir, "out")
      {_pack, commit} = ctx.repo
      assert commit == get(url, ctx.opts, out)
      assert "B\n" == File.read!(Path.join(out, "lib/b.ex"))

      assert_receive {:ssh_fixture, :exec, "git-upload-pack '/org/repo.git'",
                      {"GIT_PROTOCOL", "version=2"}},
                     5_000
    end

    test "version 0: the refs of the advertisement, want, deepen and done", ctx do
      port = daemon(ctx, {:v0, ctx.repo, ["refs/heads/main", "refs/tags/v1"]})
      url = "ssh://git@127.0.0.1:#{port}/org/repo.git"
      {_pack, commit} = ctx.repo
      assert commit == get(url, ctx.opts, Path.join(ctx.tmp_dir, "out"))
      assert_receive {:ssh_fixture, :exec, _, nil}, 5_000

      assert {:error, ~c"~ts: no ~ts", [_, ~c"refs/tags/v2"]} =
               catch_throw(:beam_com_git.resolve(url, {:tag, ~c"v2"}, ctx.opts))
    end

    test "the form of scp, with a Host of ~/.ssh/config", ctx do
      port = daemon(ctx, {:v2, ctx.repo, ["refs/tags/v1"]})
      File.rename!(Path.join(ctx.dir, "id_ed25519"), Path.join(ctx.dir, "deploy"))

      # The Host block is in a file of Include, with a wildcard.
      File.mkdir_p!(Path.join(ctx.dir, "config.d"))
      File.write!(Path.join(ctx.dir, "config"), "Include config.d/*\n")

      File.write!(Path.join(ctx.dir, "config.d/git"), """
      Host gitserver
        HostName 127.0.0.1
        Port #{port}
        User git
        IdentityFile ~/.ssh/deploy
        IdentityAgent none
      """)

      {_pack, commit} = ctx.repo
      assert commit == get("gitserver:org/repo.git", ctx.opts, Path.join(ctx.tmp_dir, "out"))
      assert_receive {:ssh_fixture, :exec, "git-upload-pack 'org/repo.git'", _}, 5_000
    end

    test "a key of the SSH agent, also with IdentitiesOnly", ctx do
      {agent_key, locked_text} = SshFixture.user_key("aes256-ctr")
      sock = agent_socket()
      SshFixture.Agent.start(sock, [agent_key])

      # Only the key of the agent can log in.
      port = daemon(ctx, {:v2, ctx.repo, ["refs/tags/v1"]}, [SshFixture.public(agent_key)])
      url = "ssh://git@127.0.0.1:#{port}/r"
      opts = put_in(ctx.opts, [:ssh, :agent], String.to_charlist(sock))
      {_pack, commit} = ctx.repo
      assert commit == get(url, opts, Path.join(ctx.tmp_dir, "out"))

      # IdentitiesOnly: the agent signs for the key of an IdentityFile,
      # here a file with a passphrase.
      File.write!(Path.join(ctx.dir, "locked"), locked_text)

      File.write!(Path.join(ctx.dir, "config"), """
      IdentitiesOnly yes
      IdentityFile ~/.ssh/locked
      """)

      assert commit == get(url, opts, Path.join(ctx.tmp_dir, "out2"))

      # The same through ssh_agent_bridge, as for the agent of Windows.
      if b = bridge() do
        opts = put_in(opts, [:ssh, :agent_bridge], b)
        assert commit == get(url, opts, Path.join(ctx.tmp_dir, "out3"))
      end
    end

    test "an RSA key and an ECDSA key of the agent", ctx do
      rsa = :public_key.generate_key({:rsa, 2048, 65_537})
      ec = :public_key.generate_key({:namedCurve, :secp256r1})
      {_pack, commit} = ctx.repo

      # The client of OTP tries rsa-sha2-512 first, and the agent follows
      # the flags of the request.
      for {key, alg} <- [{rsa, "rsa-sha2-512"}, {ec, "ecdsa-sha2-nistp256"}] do
        sock = agent_socket()
        SshFixture.Agent.start(sock, [key], owner: self())
        # Only the key of the agent can log in.
        port = daemon(ctx, {:v2, ctx.repo, ["refs/tags/v1"]}, [SshFixture.public(key)])
        opts = put_in(ctx.opts, [:ssh, :agent], String.to_charlist(sock))
        url = "ssh://git@127.0.0.1:#{port}/r"
        assert commit == get(url, opts, Path.join(ctx.tmp_dir, "out-#{port}"))
        assert_receive {:agent_sign, ^alg}, 5_000
      end
    end

    test "the agent refuses to sign with a key: the next key, and the error", ctx do
      {refused, _} = SshFixture.user_key()
      ec = :public_key.generate_key({:namedCurve, :secp256r1})
      File.rm!(Path.join(ctx.dir, "id_ed25519"))
      sock = agent_socket()
      SshFixture.Agent.start(sock, [refused, ec], refuse: [refused], owner: self())
      opts = put_in(ctx.opts, [:ssh, :agent], String.to_charlist(sock))
      {_pack, commit} = ctx.repo

      # The two keys are in one round: the ECDSA key logs in.
      port = daemon(ctx, {:v2, ctx.repo, ["refs/tags/v1"]}, [SshFixture.public(ec)])
      url = "ssh://git@127.0.0.1:#{port}/r"
      assert commit == get(url, opts, Path.join(ctx.tmp_dir, "out"))
      assert_receive {:agent_sign, "ecdsa-sha2-nistp256"}, 5_000

      # Only the refused key can log in: the error names it.
      port = daemon(ctx, {:v2, ctx.repo, []}, [SshFixture.public(refused)])
      url = "ssh://git@127.0.0.1:#{port}/r"

      assert {:error, ~c"~ts: no SSH connection as ~ts: ~ts~ts", [^url, ~c"git", _, extra]} =
               catch_throw(:beam_com_git.resolve(url, :head, opts))

      blob = :ssh_file.encode(SshFixture.public(refused), :ssh2_pubkey)
      fp = List.to_string(:ssh.hostkey_fingerprint(:sha256, :ssh_file.decode(blob, :ssh2_pubkey)))
      assert IO.chardata_to_string(extra) =~ "The SSH agent did not sign with these keys: #{fp}"
    end

    test "an RSA key in ~/.ssh/id_rsa that is also in the agent", ctx do
      rsa = :public_key.generate_key({:rsa, 2048, 65_537})
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, rsa)])
      File.rm!(Path.join(ctx.dir, "id_ed25519"))
      File.write!(Path.join(ctx.dir, "id_rsa"), pem)
      port = daemon(ctx, {:v2, ctx.repo, ["refs/tags/v1"]}, [SshFixture.public(rsa)])
      url = "ssh://git@127.0.0.1:#{port}/r"
      {_pack, commit} = ctx.repo

      # With no agent, the key of the file signs.
      assert commit == get(url, ctx.opts, Path.join(ctx.tmp_dir, "out1"))

      # With the key in the agent, the agent signs.
      sock = agent_socket()
      SshFixture.Agent.start(sock, [rsa], owner: self())
      opts = put_in(ctx.opts, [:ssh, :agent], String.to_charlist(sock))
      assert commit == get(url, opts, Path.join(ctx.tmp_dir, "out2"))
      assert_receive {:agent_sign, "rsa-sha2-" <> _}, 5_000
    end

    test "a host that is not known, or a revoked key", ctx do
      port = daemon(ctx, {:v2, ctx.repo, ["refs/tags/v1"]})
      url = "ssh://git@127.0.0.1:#{port}/r"
      File.write!(Path.join(ctx.dir, "known_hosts"), "")

      assert {:error, msg, [^url, ~c"[127.0.0.1]:" ++ _, _]} =
               catch_throw(:beam_com_git.resolve(url, :head, ctx.opts))

      assert List.to_string(msg) =~ "is not in known_hosts (~ts)"

      # A password of the URL is not in the error.
      secret = "ssh://git:s3cret@127.0.0.1:#{port}/r"

      assert {:error, _, [~c"ssh://git:****@127.0.0.1:" ++ _, _, _]} =
               catch_throw(:beam_com_git.resolve(secret, :head, ctx.opts))

      # Another key for the name: the error gives the fingerprint.
      other = :public_key.generate_key({:namedCurve, :ed25519})
      File.write!(Path.join(ctx.dir, "known_hosts"), SshFixture.known_line(port, other))

      assert {:error,
              ~c"~ts: the key of ~ts (~ts) is not in known_hosts. Check it, and add it to ~ts",
              [^url, _, ~c"SHA256:" ++ _, _]} =
               catch_throw(:beam_com_git.resolve(url, :head, ctx.opts))

      # The same key, revoked.
      port3 = daemon(ctx, {:v2, ctx.repo, []})
      line = File.read!(Path.join(ctx.dir, "known_hosts"))
      [_name, type, key] = String.split(String.trim(line))
      File.write!(Path.join(ctx.dir, "known_hosts"), line <> "@revoked * #{type} #{key}\n")

      assert {:error, ~c"~ts: the key of ~ts (~ts) is revoked in known_hosts", _} =
               catch_throw(
                 :beam_com_git.resolve("ssh://git@127.0.0.1:#{port3}/r", :head, ctx.opts)
               )
    end

    test "no key that the server takes, and a key with a passphrase", ctx do
      port = daemon(ctx, {:v2, ctx.repo, []}, [])
      {_k, locked} = SshFixture.user_key("aes256-ctr")
      File.write!(Path.join(ctx.dir, "id_rsa"), locked)
      url = "ssh://git@127.0.0.1:#{port}/r"

      assert {:error, ~c"~ts: no SSH connection as ~ts: ~ts~ts", [^url, ~c"git", _, extra]} =
               catch_throw(:beam_com_git.resolve(url, :head, ctx.opts))

      assert IO.chardata_to_string(extra) =~ "id_rsa"
    end

    # Five keys of one type in ~/.ssh/config: five rounds.
    defp five_keys(ctx) do
      names = for i <- 1..5, do: "key#{i}"

      for n <- names do
        {_k, text} = SshFixture.user_key()
        File.write!(Path.join(ctx.dir, n), text)
      end

      File.write!(
        Path.join(ctx.dir, "config"),
        Enum.map_join(names, fn n -> "IdentityFile ~/.ssh/#{n}\n" end)
      )
    end

    test "at most 4 rounds of keys: the error says it", ctx do
      five_keys(ctx)
      port = daemon(ctx, {:v2, ctx.repo, []}, [])
      url = "ssh://git@127.0.0.1:#{port}/r"

      assert {:error, _, [^url, ~c"git", _, extra]} =
               catch_throw(:beam_com_git.resolve(url, :head, ctx.opts))

      assert IO.chardata_to_string(extra) =~ "The client tries at most 4 keys of each type"
    end

    test "a new round of keys only after a failed login", ctx do
      five_keys(ctx)
      # A server that closes each connection: one connection, not one for
      # each round.
      {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      {:ok, port} = :inet.port(listen)
      test = self()

      spawn_link(fn ->
        Stream.repeatedly(fn -> :gen_tcp.accept(listen) end)
        |> Enum.each(fn {:ok, c} ->
          send(test, :accepted)
          :gen_tcp.close(c)
        end)
      end)

      host = :public_key.generate_key({:namedCurve, :ed25519})
      File.write!(Path.join(ctx.dir, "known_hosts"), SshFixture.known_line(port, host))
      url = "ssh://git@127.0.0.1:#{port}/r"

      assert {:error, _, [^url, ~c"git", _, extra]} =
               catch_throw(:beam_com_git.resolve(url, :head, ctx.opts))

      refute IO.chardata_to_string(extra) =~ "at most"
      assert_receive :accepted, 5_000
      refute_receive :accepted, 200
    end

    test "ProxyJump, GIT_SSH_COMMAND and a URL that is not SSH", ctx do
      File.write!(Path.join(ctx.dir, "config"), "Host j\n  ProxyJump bastion\n")

      assert {:error, ~c"~ts: ~ts in ~ts needs the ssh program; install git",
              [_, ~c"ProxyJump", _]} =
               catch_throw(:beam_com_git.resolve("j:r", :head, ctx.opts))

      System.put_env("GIT_SSH_COMMAND", "ssh -i key")

      try do
        assert {:error, ~c"~ts: ~ts names a program, and beam.com cannot run it; install git",
                [_, ~c"GIT_SSH_COMMAND"]} =
                 catch_throw(:beam_com_git.resolve("h:r", :head, ctx.opts))
      after
        System.delete_env("GIT_SSH_COMMAND")
      end

      assert {:error, ~c"~ts: not an SSH URL", _} =
               catch_throw(:beam_com_git_ssh.ls_refs("https://h/r", [], 1, ctx.opts))
    end

    @tag :git
    test "the git-upload-pack program, with version 2 and with version 0", ctx do
      git = System.find_executable("git")
      src = Path.join(ctx.tmp_dir, "src")
      File.mkdir_p!(Path.join(src, "lib"))
      File.write!(Path.join(src, "lib/a.ex"), "A\n")
      # The runner of CI has no identity of git: the commit and the tag
      # get one from the environment.
      env = for k <- ~w(AUTHOR COMMITTER), v <- ~w(NAME EMAIL), do: {"GIT_#{k}_#{v}", "t"}

      run = fn args ->
        {_, 0} = System.cmd(git, args, cd: src, env: env, stderr_to_stdout: true)
      end

      run.(["init", "-q", "-b", "main"])
      run.(["add", "."])
      run.(["commit", "-q", "-m", "one"])
      run.(["tag", "-a", "v1", "-m", "v1"])
      {head, 0} = System.cmd(git, ["rev-parse", "HEAD"], cd: src)

      for mode <- [{:git, src}, {:git_v0, src}] do
        port = daemon(ctx, mode)
        url = "ssh://git@127.0.0.1:#{port}/src"
        out = Path.join(ctx.tmp_dir, "out-#{elem(mode, 0)}")
        assert String.trim(head) == get(url, ctx.opts, out)
        assert "A\n" == File.read!(Path.join(out, "lib/a.ex"))
      end
    end
  end
end
