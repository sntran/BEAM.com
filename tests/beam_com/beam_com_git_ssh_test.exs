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

      assert [r1, r2] = :beam_com_git_ssh.rounds(keys)
      assert %{"ssh-ed25519": {:agent, ^ed}, "rsa-sha2-256": {:agent, ^rsa}} = r1
      assert %{"ecdsa-sha2-nistp256": {:file, :k3}} = r1
      refute Map.has_key?(r1, :"rsa-sha2-512")
      assert %{"ssh-ed25519": {:file, :k1}, "rsa-sha2-512": {:file, :k2}} = r2
      assert [] == :beam_com_git_ssh.rounds([])
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
      sock = Path.join(System.tmp_dir!(), "beam_com_agent_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(sock) end)
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
    end

    test "a host that is not known, or a revoked key", ctx do
      port = daemon(ctx, {:v2, ctx.repo, ["refs/tags/v1"]})
      url = "ssh://git@127.0.0.1:#{port}/r"
      File.write!(Path.join(ctx.dir, "known_hosts"), "")

      assert {:error, msg, [^url, ~c"[127.0.0.1]:" ++ _, _]} =
               catch_throw(:beam_com_git.resolve(url, :head, ctx.opts))

      assert List.to_string(msg) =~ "is not in known_hosts (~ts)"

      # Another key for the name: the error gives the fingerprint.
      {_d, _p, other} = SshFixture.start({:v0, ctx.repo, []}, [])
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
      run = fn args -> {_, 0} = System.cmd(git, args, cd: src, stderr_to_stdout: true) end
      run.(["init", "-q", "-b", "main"])
      run.(["add", "."])
      run.(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-q", "-m", "one"])
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
