defmodule BeamComGitTest do
  @moduledoc """
  The tests of `:beam_com_git` (the git client over HTTPS) and of
  `:beam_com_git_scm` (its source of Mix). The tests make the packs, the
  trees and the deltas themselves, and a function in place of the
  server: no network and no git program.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @url "https://example.com/org/repo.git"

  # A git object: its name (the SHA-1 of the type, the size and the
  # data, in hex) and its data.
  defp name(type, data) do
    :crypto.hash(:sha, [to_string(type), " ", Integer.to_string(byte_size(data)), 0, data])
    |> Base.encode16(case: :lower)
  end

  defp tree_data(entries) do
    for {mode, n, sha} <- entries,
        into: "",
        do: mode <> " " <> n <> <<0>> <> Base.decode16!(sha, case: :lower)
  end

  defp commit_data(tree), do: "tree #{tree}\nauthor A <a@b> 0 +0000\n\nmessage\n"

  # The header of an object of a pack: the type and the size.
  defp header(type, size) do
    first = Bitwise.bor(Bitwise.bsl(type, 4), Bitwise.band(size, 15))
    rest = Bitwise.bsr(size, 4)
    if rest == 0, do: <<first>>, else: <<Bitwise.bor(first, 0x80)>> <> more(rest)
  end

  defp more(n) when n < 128, do: <<n>>
  defp more(n), do: <<Bitwise.bor(Bitwise.band(n, 127), 0x80)>> <> more(Bitwise.bsr(n, 7))

  # The offset of a delta, as git writes it.
  defp ofs(n), do: ofs(Bitwise.bsr(n, 7), <<Bitwise.band(n, 127)>>)
  defp ofs(0, acc), do: acc

  defp ofs(n, acc),
    do: ofs(Bitwise.bsr(n - 1, 7), <<Bitwise.bor(0x80, Bitwise.band(n - 1, 127))>> <> acc)

  defp varint(n) when n < 128, do: <<n>>
  defp varint(n), do: <<Bitwise.bor(Bitwise.band(n, 127), 0x80)>> <> varint(Bitwise.bsr(n, 7))

  # A delta: the base, then a copy of the first `copy` bytes and new bytes.
  defp delta(base, copy, new) do
    varint(byte_size(base)) <>
      varint(copy + byte_size(new)) <>
      <<0x90, copy>> <>
      <<byte_size(new)>> <> new
  end

  # A pack of the entries {:obj, type, data}, {:ofs, index, delta} or
  # {:ref, name, delta}, with its checksum.
  defp pack(entries) do
    {body, _} =
      Enum.reduce(entries, {"PACK" <> <<2::32, length(entries)::32>>, []}, fn e, {acc, starts} ->
        pos = byte_size(acc)

        part =
          case e do
            {:obj, type, data} ->
              header(type, byte_size(data)) <> :zlib.compress(data)

            {:ofs, i, d} ->
              header(6, byte_size(d)) <> ofs(pos - Enum.at(starts, i)) <> :zlib.compress(d)

            {:ref, n, d} ->
              header(7, byte_size(d)) <> Base.decode16!(n, case: :lower) <> :zlib.compress(d)
          end

        {acc <> part, starts ++ [pos]}
      end)

    body <> :crypto.hash(:sha, body)
  end

  defp pkt(data), do: :beam_com_git.pkt(data)

  # The repository: a.txt, run.sh (executable), l (a link to a.txt),
  # sub/b.txt (a delta of a.txt), and mod (a submodule).
  defp repo do
    a = "hello\n"
    b = "hello\nworld\n"
    run = "#!/bin/sh\n"
    sub = tree_data([{"100644", "b.txt", name(:blob, b)}])
    mod = String.duplicate("ab", 20)

    root =
      tree_data([
        {"100644", "a.txt", name(:blob, a)},
        {"120000", "l", name(:blob, "a.txt")},
        {"160000", "mod", mod},
        {"100755", "run.sh", name(:blob, run)},
        {"40000", "sub", name(:tree, sub)}
      ])

    commit = commit_data(name(:tree, root))

    pack =
      pack([
        {:obj, 3, a},
        {:obj, 3, run},
        {:obj, 3, "a.txt"},
        {:ofs, 0, delta(a, 6, "world\n")},
        {:ref, name(:blob, run), delta(run, 10, "exit 0\n")},
        {:obj, 2, sub},
        {:obj, 2, root},
        {:obj, 1, commit}
      ])

    %{pack: pack, commit: name(:commit, commit), root: name(:tree, root)}
  end

  # A server of git (version 2): the advertisement, ls-refs and fetch.
  defp server(%{pack: pack, commit: commit}, test) do
    fn
      :get, url, headers, :none, _max ->
        send(test, {:get, url, headers})

        IO.iodata_to_binary([
          pkt("# service=git-upload-pack\n"),
          "0000",
          pkt("version 2\n"),
          pkt("fetch\n"),
          "0000"
        ])

      :post, url, _headers, {_type, body}, _max ->
        send(test, {:post, url, body})

        cond do
          body =~ "command=ls-refs" ->
            IO.iodata_to_binary([
              pkt("#{String.duplicate("1", 40)} refs/tags/v1 peeled:#{commit}\n"),
              pkt("#{commit} refs/heads/main\n"),
              pkt("#{commit} HEAD symref-target:refs/heads/main\n"),
              "0000"
            ])

          body =~ "command=fetch" ->
            {p1, p2} = String.split_at(pack, 20)

            IO.iodata_to_binary([
              pkt("packfile\n"),
              pkt(<<1>> <> p1),
              pkt(<<2>> <> "progress\n"),
              pkt(<<1>> <> p2),
              "0000"
            ])
        end
    end
  end

  describe "pkt-lines" do
    test "pkt and pkts" do
      assert "0009hello" == pkt("hello")

      assert ["a\n", :flush, :delim, :response_end, "b"] ==
               :beam_com_git.pkts("0006a\n000000010002" <> "0005b")

      assert [] == :beam_com_git.pkts("")
    end

    test "bad pkt-lines" do
      assert {:error, ~c"git: a bad pkt-line: ~p", ["zzzz"]} ==
               catch_throw(:beam_com_git.pkts("zzzz"))

      assert {:error, ~c"git: a short pkt-line", []} == catch_throw(:beam_com_git.pkts("0009ab"))
      assert {:error, ~c"git: a short pkt-line", []} == catch_throw(:beam_com_git.pkts("0003"))
      assert {:error, ~c"git: a short pkt-line", []} == catch_throw(:beam_com_git.pkts("00"))
    end

    test "advertisement: version 2" do
      assert :beam_com_git.advertisement(["# service=git-upload-pack\n", :flush, "version 2\n"])
      refute :beam_com_git.advertisement(["abc refs/heads/main\0side-band\n"])
    end

    test "refs: the peeled commit of a tag, and an error" do
      assert [{"refs/tags/v1", "c1"}, {"refs/heads/main", "c2"}] ==
               :beam_com_git.refs([
                 "t1 refs/tags/v1 peeled:c1\n",
                 "c2 refs/heads/main\n",
                 "x\n",
                 :flush
               ])

      assert {:error, ~c"git: ~ts", ["no access"]} ==
               catch_throw(:beam_com_git.refs(["ERR no access\n"]))
    end

    test "pack_response: the bands, an error band, ERR, and no pack" do
      assert "ab" ==
               :beam_com_git.pack_response([
                 "shallow-info\n",
                 :delim,
                 "packfile\n",
                 <<1, "a">>,
                 <<2, "p">>,
                 <<1, "b">>,
                 :flush
               ])

      assert {:error, ~c"git: ~ts", ["boom"]} ==
               catch_throw(:beam_com_git.pack_response(["packfile\n", <<3, "boom">>]))

      assert {:error, ~c"git: ~ts", ["no such commit"]} ==
               catch_throw(:beam_com_git.pack_response(["ERR no such commit"]))

      assert {:error, ~c"git: the answer has no pack", []} ==
               catch_throw(:beam_com_git.pack_response([:flush]))
    end
  end

  describe "the pack" do
    test "objects: each object, with the deltas" do
      %{pack: pack, commit: commit, root: root} = repo()
      objects = :beam_com_git.objects(pack)
      assert 8 == map_size(objects)
      assert {:blob, "hello\nworld\n"} == objects[name(:blob, "hello\nworld\n")]
      assert {:blob, "#!/bin/sh\nexit 0\n"} == objects[name(:blob, "#!/bin/sh\nexit 0\n")]
      assert {:tree, _} = objects[root]
      assert {:commit, data} = objects[commit]
      assert root == :beam_com_git.commit_tree(data)
    end

    test "a big object: the header of its size has more bytes" do
      data = :crypto.strong_rand_bytes(70_000)
      objects = :beam_com_git.objects(pack([{:obj, 3, data}]))
      assert %{name(:blob, data) => {:blob, data}} == objects
    end

    test "a bad pack" do
      %{pack: pack} = repo()
      bad = binary_part(pack, 0, byte_size(pack) - 1) <> "x"

      assert {:error, ~c"git: the pack has a bad checksum", []} ==
               catch_throw(:beam_com_git.objects(bad))

      assert {:error, ~c"git: not a pack", []} == catch_throw(:beam_com_git.objects("nope"))

      assert {:error, ~c"git: a short pack", []} ==
               catch_throw(:beam_com_git.objects("PACK" <> <<2::32, 0::32>>))

      no_base = pack([{:ref, String.duplicate("0", 40), delta("x", 1, "y")}])

      assert {:error, ~c"git: a delta has no base", []} ==
               catch_throw(:beam_com_git.objects(no_base))
    end

    test "apply_delta: the sizes and the copies are checked" do
      assert "hello world" == :beam_com_git.apply_delta("hello", delta("hello", 5, " world"))

      assert {:error, ~c"git: a delta of another base", []} ==
               catch_throw(:beam_com_git.apply_delta("hi", delta("hello", 5, "")))

      assert {:error, ~c"git: a delta copies too much", []} ==
               catch_throw(:beam_com_git.apply_delta("hi", <<2, 9, 0x90, 9>>))

      assert {:error, ~c"git: a delta has a bad size", []} ==
               catch_throw(:beam_com_git.apply_delta("hi", <<2, 9, 0x90, 2>>))

      assert {:error, ~c"git: a bad delta", []} ==
               catch_throw(:beam_com_git.apply_delta("hi", <<2, 2, 0>>))

      assert {:error, ~c"git: a short delta", []} ==
               catch_throw(:beam_com_git.apply_delta("hi", <<0x82>>))

      assert {:error, ~c"git: a short delta", []} ==
               catch_throw(:beam_com_git.apply_delta("hi", <<2, 2, 0x91>>))

      # A copy of 0x10000 bytes has the size 0.
      big = :binary.copy("a", 0x10000)
      assert big == :beam_com_git.apply_delta(big, varint(0x10000) <> varint(0x10000) <> <<0x80>>)
    end

    test "zlib_end: the stream ends before the bytes after it" do
      for data <- ["", "a", :crypto.strong_rand_bytes(5000), :binary.copy("ab", 40_000)] do
        z = :zlib.compress(data)
        assert byte_size(z) == :beam_com_git.zlib_end(z <> "trailing bytes", data)
      end

      assert {:error, ~c"git: the end of a zlib stream is not found", []} ==
               catch_throw(:beam_com_git.zlib_end("not zlib", "x"))
    end
  end

  describe "trees" do
    test "tree: the entries, and the names that stay in a directory" do
      sha = String.duplicate("ab", 20)
      assert [{"100644", "a", sha}] == :beam_com_git.tree(tree_data([{"100644", "a", sha}]))
      assert {:error, ~c"git: a bad tree", []} == catch_throw(:beam_com_git.tree("100644 a"))

      assert {:error, ~c"git: a bad tree", []} ==
               catch_throw(:beam_com_git.tree("nospace" <> <<0>> <> :binary.copy(<<1>>, 20)))

      for bad <- ["", ".", "..", "a/b", "a\\b", ".git", ".GIT"] do
        assert {:error, ~c"git: a tree entry with a bad name: ~tp", [^bad]} =
                 catch_throw(:beam_com_git.safe_name(bad))
      end

      assert {:error, ~c"git: a commit with no tree", []} ==
               catch_throw(:beam_com_git.commit_tree("parent x"))
    end

    test "checkout: the files, the modes, the link, a sparse directory, .git", %{tmp_dir: dir} do
      %{pack: pack, commit: commit} = repo()
      objects = :beam_com_git.objects(pack)
      out = Path.join(dir, "all")
      :ok = :beam_com_git.checkout(objects, commit, out, %{url: @url})
      assert "hello\n" == File.read!(Path.join(out, "a.txt"))
      assert "hello\nworld\n" == File.read!(Path.join(out, "sub/b.txt"))

      assert {:ok, "a.txt"} ==
               {:ok, to_string(elem(:file.read_link(String.to_charlist(Path.join(out, "l"))), 1))}

      assert 0o755 == Bitwise.band(File.stat!(Path.join(out, "run.sh")).mode, 0o777)
      refute File.exists?(Path.join(out, "mod"))
      assert commit <> "\n" == File.read!(Path.join(out, ".git/HEAD"))
      assert {@url, commit} == :beam_com_git_scm.checkout_info(out)

      sparse = Path.join(dir, "sparse")
      :ok = :beam_com_git.checkout(objects, commit, sparse, %{url: @url, sparse: ~c"sub"})
      assert ["sub"] == File.ls!(sparse) -- [".git"]
      assert "hello\nworld\n" == File.read!(Path.join(sparse, "sub/b.txt"))

      assert {:error, ~c"git: the tree has no directory ~ts", [~c"none"]} ==
               catch_throw(
                 :beam_com_git.checkout(objects, commit, sparse, %{url: @url, sparse: ~c"none"})
               )

      assert {:error, ~c"git: submodules need the git program", []} ==
               catch_throw(
                 :beam_com_git.checkout(objects, commit, Path.join(dir, "m"), %{
                   url: @url,
                   submodules: true
                 })
               )
    end

    test "checkout: a link out of the checkout, a bad mode, a missing object", %{tmp_dir: dir} do
      for target <- ["/etc/passwd", "../x", ""] do
        root = tree_data([{"120000", "l", name(:blob, target)}])
        commit = commit_data(name(:tree, root))

        objects =
          :beam_com_git.objects(pack([{:obj, 3, target}, {:obj, 2, root}, {:obj, 1, commit}]))

        assert {:error, ~c"git: a link out of the checkout: ~ts", [^target]} =
                 catch_throw(
                   :beam_com_git.checkout(objects, name(:commit, commit), Path.join(dir, "l"), %{
                     url: @url
                   })
                 )
      end

      root = tree_data([{"100600", "f", name(:blob, "x")}])
      commit = commit_data(name(:tree, root))
      objects = :beam_com_git.objects(pack([{:obj, 3, "x"}, {:obj, 2, root}, {:obj, 1, commit}]))

      assert {:error, ~c"git: a tree entry of the mode ~ts", ["100600"]} ==
               catch_throw(
                 :beam_com_git.checkout(objects, name(:commit, commit), Path.join(dir, "m"), %{
                   url: @url
                 })
               )

      assert {:error, ~c"git: the pack has no ~p ~ts", [:commit, "none"]} ==
               catch_throw(:beam_com_git.checkout(objects, "none", dir, %{url: @url}))

      assert {:error, ~c"git: ~ts is a ~p, not a ~p", [_, :tree, :commit]} =
               catch_throw(:beam_com_git.checkout(objects, name(:tree, root), dir, %{url: @url}))
    end
  end

  describe "the server" do
    test "fetch: only the objects of the commit" do
      r = repo()
      # The pack has 8 objects. The result of the ref delta is not in the
      # tree of the commit, so the fetch leaves it out.
      objects = :beam_com_git.fetch(@url, r.commit, %{http: server(r, self())})
      assert 7 == map_size(objects)
      refute Map.has_key?(objects, name(:blob, "#!/bin/sh\nexit 0\n"))

      assert_receive {:get,
                      ~c"https://example.com/org/repo.git/info/refs?service=git-upload-pack",
                      headers},
                     5000

      assert {~c"git-protocol", ~c"version=2"} in headers
      assert_receive {:post, ~c"https://example.com/org/repo.git/git-upload-pack", body}, 5000
      assert body =~ "want #{r.commit}\n"
      assert body =~ "deepen 1\n"
    end

    test "resolve: a tag, a branch, a ref, the head, and a commit" do
      r = repo()
      http = server(r, self())
      assert r.commit == :beam_com_git.resolve(@url, {:tag, ~c"v1"}, %{http: http})
      assert r.commit == :beam_com_git.resolve(@url, {:branch, ~c"main"}, %{http: http})
      assert r.commit == :beam_com_git.resolve(@url, {:ref, ~c"main"}, %{http: http})
      assert r.commit == :beam_com_git.resolve(@url, :head, %{http: http})
      sha = String.duplicate("c", 40)
      assert sha == :beam_com_git.resolve(@url, {:ref, String.to_charlist(sha)}, %{})

      assert {:error, ~c"~ts: no ~ts", [_, ~c"refs/tags/v9"]} =
               catch_throw(:beam_com_git.resolve(@url, {:tag, ~c"v9"}, %{http: http}))

      assert_receive {:post, _, body}, 5000
      assert body =~ "ref-prefix refs/tags/v1\n"
    end

    test "a server of version 1, and a URL that is not https" do
      v1 = fn :get, _, _, _, _ -> "001e# service=git-upload-pack\n0000" end

      assert {:error,
              ~c"~ts: the server does not speak version 2 of the git protocol; install git", [_]} =
               catch_throw(:beam_com_git.resolve(@url, :head, %{http: v1}))

      assert {:error, ~c"~ts: only an https URL works with no git program",
              ["git@example.com:a/b.git"]} ==
               catch_throw(:beam_com_git.url("git@example.com:a/b.git"))

      assert {:error, ~c"~ts: not a commit: ~ts", [_, "main"]} =
               catch_throw(:beam_com_git.fetch(@url, "main", %{}))
    end

    test "a user in the URL: basic authentication, and no user in the request URL" do
      r = repo()

      _ =
        :beam_com_git.fetch("https://me:s%40cret@example.com/r.git/", r.commit, %{
          http: server(r, self())
        })

      assert_receive {:get, ~c"https://example.com/r.git/info/refs?service=git-upload-pack",
                      headers},
                     5000

      basic = ~c"Basic " ++ String.to_charlist(Base.encode64("me:s@cret"))
      assert {~c"authorization", basic} in headers

      assert ~c"https://example.com/r.git" == :beam_com_git.url("https://me:x@example.com/r.git/")
    end
  end

  describe "the source of Mix" do
    test "lock_opts, lock_rev and rev_spec, as Mix.SCM.Git" do
      opts = [git: @url, tag: "v1", sparse: "optimized", depth: 1, dest: "d", checkout: "d"]
      assert [tag: "v1", sparse: "optimized", depth: 1] == :beam_com_git_scm.lock_opts(opts)
      assert [submodules: true] == :beam_com_git_scm.lock_opts(submodules: true)
      lock = {:git, @url, "abc", [tag: "v1", sparse: "optimized", depth: 1]}
      assert "abc" == :beam_com_git_scm.lock_rev(lock, opts)
      assert nil == :beam_com_git_scm.lock_rev({:git, "other", "abc", []}, opts)
      assert nil == :beam_com_git_scm.lock_rev(nil, opts)
      assert {:tag, ~c"v1"} == :beam_com_git_scm.rev_spec(opts)
      assert :head == :beam_com_git_scm.rev_spec(git: @url)
    end

    test "accepts_options: an https URL, also of github; not another URL" do
      assert [_ | _] = opts = :beam_com_git_scm.accepts_options(:a, github: "org/repo", dest: "d")
      assert "https://github.com/org/repo.git" == opts[:git]

      assert nil ==
               :beam_com_git_scm.accepts_options(:a,
                 git: "git@github.com:org/repo.git",
                 dest: "d"
               )

      assert nil == :beam_com_git_scm.accepts_options(:a, path: "x", dest: "d")
    end

    test "checked_out?, lock_status, and the functions of Mix.SCM.Git", %{tmp_dir: dir} do
      opts = [git: @url, dest: dir, checkout: dir]
      refute :beam_com_git_scm.checked_out?(opts)
      assert :mismatch == :beam_com_git_scm.lock_status(opts ++ [lock: nil])
      File.mkdir_p!(Path.join(dir, ".git"))
      File.write!(Path.join(dir, ".git/HEAD"), "abc\n")
      File.write!(Path.join(dir, ".git/config"), "[core]\n[remote \"origin\"]\n\turl = #{@url}\n")
      assert :beam_com_git_scm.checked_out?(opts)
      assert :ok == :beam_com_git_scm.lock_status(opts ++ [lock: {:git, @url, "abc", []}])
      assert :mismatch == :beam_com_git_scm.lock_status(opts ++ [lock: {:git, @url, "def", []}])

      assert :outdated ==
               :beam_com_git_scm.lock_status(opts ++ [lock: {:git, @url, "abc", [tag: "v1"]}])

      File.write!(Path.join(dir, ".git/config"), "[core]\n")
      assert :mismatch == :beam_com_git_scm.lock_status(opts ++ [lock: {:git, @url, "abc", []}])
      assert :beam_com_git_scm.fetchable?()
      assert [] == :beam_com_git_scm.managers(opts)
      assert "#{@url} - v1" == :beam_com_git_scm.format(git: @url, tag: "v1")

      assert "abcdefg (tag: v1)" ==
               :beam_com_git_scm.format_lock(lock: {:git, @url, "abcdefgh", [tag: "v1"]})

      assert :beam_com_git_scm.equal?([git: @url], git: @url)
    end
  end
end
