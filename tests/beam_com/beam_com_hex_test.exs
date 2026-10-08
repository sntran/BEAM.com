defmodule BeamComHexTest do
  @moduledoc """
  The tests of `:beam_com_hex`: the versions, the requirements, rebar.config
  and rebar.lock, the tarballs, the resolution, and `fetch/2`. The tests of
  `fetch/2` use a small HTTP server in place of hex.pm (HEX_API_URL,
  HEX_MIRROR).

  The tests of `fetch/2` set environment variables of the OS, so the
  module is not async.
  """
  use ExUnit.Case, async: false

  use ExUnitProperties

  import ExUnit.CaptureIO

  alias BeamCom.HexFixture

  @moduletag :tmp_dir

  defp v(s) do
    {:ok, v} = :beam_com_hex.parse_version(s)
    v
  end

  describe "versions_test_" do
    test "parse_version(\"1.2.3-rc.1+build.5\")" do
      assert {:ok, {1, 2, 3, ["rc", 1]}} ==
               :beam_com_hex.parse_version(~c"1.2.3-rc.1+build.5")
    end

    test "the order of semantic versions" do
      sorted = [
        ~c"0.9.9",
        ~c"1.0.0-1",
        ~c"1.0.0-alpha",
        ~c"1.0.0-alpha.1",
        ~c"1.0.0-rc.1",
        ~c"1.0.0",
        ~c"1.2.0",
        ~c"1.10.0"
      ]

      shuffled = [
        ~c"1.10.0",
        ~c"1.0.0",
        ~c"0.9.9",
        ~c"1.0.0-rc.1",
        ~c"1.2.0",
        ~c"1.0.0-alpha.1",
        ~c"1.0.0-alpha",
        ~c"1.0.0-1"
      ]

      assert sorted ==
               :lists.sort(fn a, b -> :beam_com_hex.compare(v(a), v(b)) != :gt end, shuffled)
    end

    test "the build metadata does not change the order" do
      assert :eq == :beam_com_hex.compare(v(~c"1.0.0+a"), v(~c"1.0.0+b"))
    end

    for s <- ["1.0", "1", "a.b.c", "1.0.0-", "1.0.0-a..b", ""] do
      test "parse_version(#{inspect(s)}) is an error" do
        assert :error == :beam_com_hex.parse_version(unquote(String.to_charlist(s)))
      end
    end
  end

  describe "matches_test_" do
    yes = [
      {"1.2.3", "1.2.3"},
      {"1.2.3", "== 1.2.3"},
      {"1.5.0", "~> 1.2"},
      {"1.2.0", "~> 1.2"},
      {"1.2.9", "~> 1.2.3"},
      {"2.0.0", ">= 1.0.0 and < 3.0.0"},
      {"1.0.0", "~> 0.9 or ~> 1.0"},
      {"1.0.1", "!= 1.0.0"},
      {"1.0.0", "<= 1.0.0"},
      {"2.0.0-rc.1", "~> 2.0.0-rc.0"},
      # The rule of Hex: an upper bound does not stop a pre-release, and
      # "~> 2.1-dev" omits the patch number.
      {"1.0.0-rc", "< 2.0.0"},
      {"1.0.0-rc", "<= 1.0.0"},
      {"2.2.0-dev", "~> 2.1-dev"},
      {"2.2.6-dev", ">= 2.1.0-dev"},
      {"9.9.9", :any}
    ]

    no = [
      {"1.2.4", "1.2.3"},
      {"2.0.0", "~> 1.2"},
      {"1.3.0", "~> 1.2.3"},
      {"1.1.0", "~> 1.2"},
      {"3.0.0", ">= 1.0.0 and < 3.0.0"},
      {"2.0.0-rc.1", "~> 1.0"},
      {"2.0.0-rc.1", ">= 1.0.0"},
      {"1.0.0", "> 1.0.0"},
      {"1.0.0", "!= 1.0.0"},
      # Each ">", ">=" and "~>" clause must name a pre-release.
      {"1.0.0-rc", ">= 1.0.0-beta and > 0.5.0"},
      {"2.1.6-dev", "~> 2.1.2"},
      {"2.2.0-dev", ">= 2.1.0"},
      {"1.0.0-rc.1", :any}
    ]

    charlist = fn
      r when is_binary(r) -> String.to_charlist(r)
      r -> r
    end

    for {vsn, r} <- yes do
      test "#{vsn} matches #{inspect(r)}" do
        assert :beam_com_hex.matches(
                 v(unquote(String.to_charlist(vsn))),
                 unquote(charlist.(r))
               )
      end
    end

    for {vsn, r} <- no do
      test "#{vsn} does not match #{inspect(r)}" do
        refute :beam_com_hex.matches(
                 v(unquote(String.to_charlist(vsn))),
                 unquote(charlist.(r))
               )
      end
    end

    for r <- ["~> 1", ">= x", "1.0", ">= 1.0.0 and"] do
      test "parse_requirement(#{inspect(r)}) is an error" do
        assert :error == :beam_com_hex.parse_requirement(unquote(String.to_charlist(r)))
      end
    end
  end

  describe "rebar_deps_test_" do
    defp rebar_deps(deps), do: :beam_com_hex.rebar_deps([{:deps, deps}])

    test "no deps" do
      assert [] == :beam_com_hex.rebar_deps([{:erl_opts, []}])
    end

    test "the forms of a dep" do
      assert [
               {:jsx, "jsx", :any},
               {:cowboy, "cowboy", ~c"2.13.0"},
               {:x, "x_pkg", :any},
               {:y, "y_pkg", ~c"~> 1.0"}
             ] ==
               rebar_deps([
                 :jsx,
                 {:cowboy, ~c"2.13.0"},
                 {:x, {:pkg, :x_pkg}},
                 {:y, ~c"~> 1.0", {:pkg, "y_pkg"}}
               ])
    end

    test "git is not supported" do
      assert {:error,
              ~c"the dependency ~p is not a Hex package (only Hex packages are supported, not git)",
              [:g]} ==
               catch_throw(
                 rebar_deps([{:g, {:git, ~c"https://example.com/g.git", {:tag, ~c"1.0"}}}])
               )
    end

    test "a bad requirement" do
      assert {:error, ~c"~p: a bad version requirement: ~ts", [:r, ~c"~> x"]} ==
               catch_throw(rebar_deps([{:r, ~c"~> x"}]))
    end
  end

  describe "lock_test_" do
    setup %{tmp_dir: tmp_dir} do
      dir = String.to_charlist(tmp_dir)
      file = :filename.join(dir, ~c"rebar.lock")

      pkgs = [
        %{name: :b, pkg: "b_pkg", vsn: ~c"0.2.0", level: 1, inner: "AA", outer: ~c"BB"},
        %{name: :a, pkg: "a", vsn: ~c"1.1.0", level: 0, inner: "CC", outer: ~c"DD"}
      ]

      :ok = :file.write_file(file, :beam_com_hex.lock_text(pkgs))
      %{dir: dir, lock: file}
    end

    test "read_lock/1 of the file", %{lock: file} do
      assert %{
               a: %{pkg: "a", vsn: ~c"1.1.0", level: 0, inner: "CC", outer: "DD"},
               b: %{pkg: "b_pkg", vsn: ~c"0.2.0", level: 1, inner: "AA", outer: "BB"}
             } == :beam_com_hex.read_lock(file)
    end

    # The format 1.0.0 of rebar3 has no checksums, and the format 1.1.0
    # has only pkg_hash.
    test "read_lock/1 of the older formats of rebar.lock", %{dir: dir} do
      file = :filename.join(dir, ~c"old.lock")

      :ok =
        :file.write_file(
          file,
          "[{<<\"a\">>,{pkg,<<\"a\">>,<<\"1.1.0\">>},0},{<<\"b\">>,{pkg,<<\"b_pkg\">>,<<\"0.2.0\">>},1}].\n"
        )

      assert %{
               a: %{pkg: "a", vsn: ~c"1.1.0", level: 0, inner: :undefined, outer: :undefined},
               b: %{pkg: "b_pkg", vsn: ~c"0.2.0", level: 1, inner: :undefined, outer: :undefined}
             } == :beam_com_hex.read_lock(file)

      :ok =
        :file.write_file(
          file,
          "{\"1.1.0\",[{<<\"a\">>,{pkg,<<\"a\">>,<<\"1.1.0\">>},0}]}.\n[{pkg_hash,[{<<\"a\">>,<<\"CC\">>}]}].\n"
        )

      assert %{a: %{pkg: "a", vsn: ~c"1.1.0", level: 0, inner: "CC", outer: :undefined}} ==
               :beam_com_hex.read_lock(file)
    end

    # Hex reads an element that is not there as nil (Hex.Utils.lock/1).
    test "read_lock/2 of the older entries of mix.lock", %{dir: dir} do
      file = :filename.join(dir, ~c"mix.lock")

      :ok =
        :file.write_file(file, """
        %{
          "a": {:hex, :a, "1.0.0"},
          "b": {:hex, :b, "1.0.0", "BB"},
          "c": {:hex, :c, "1.0.0", "CC", [:mix], []},
          "d": {:hex, :d_pkg, "1.0.0", "DD", [:mix], [], "hexpm"},
          "e": {:hex, :e, "1.0.0", "EE", [:mix], [], "hexpm", nil},
        }
        """)

      none = :undefined

      assert %{
               a: %{pkg: "a", vsn: ~c"1.0.0", inner: none, outer: none},
               b: %{pkg: "b", vsn: ~c"1.0.0", inner: "BB", outer: none},
               c: %{pkg: "c", vsn: ~c"1.0.0", inner: "CC", outer: none},
               d: %{pkg: "d_pkg", vsn: ~c"1.0.0", inner: "DD", outer: none},
               e: %{pkg: "e", vsn: ~c"1.0.0", inner: "EE", outer: none}
             } == :beam_com_hex.read_lock(:mix, file)
    end

    test "read_lock/2: a bad checksum and an entry that is not Hex", %{dir: dir} do
      file = :filename.join(dir, ~c"mix.lock")
      :ok = :file.write_file(file, ~s(%{"a": {:hex, :a, "1.0.0", 12}}\n))

      assert {:error, ~c"mix.lock: ~ts has a bad checksum: ~tp", [:a, 12]} ==
               catch_throw(:beam_com_hex.read_lock(:mix, file))

      :ok = :file.write_file(file, ~s(%{"a": {:git, "https://example.com/a.git", "abc", []}}\n))

      assert {:error, ~c"mix.lock: ~ts is not a Hex package (only Hex packages are supported)",
              [:a]} == catch_throw(:beam_com_hex.read_lock(:mix, file))
    end

    test "the format of rebar3", %{lock: file} do
      assert {:ok,
              [
                {"1.2.0", [{"a", {:pkg, "a", "1.1.0"}, 0}, {"b", {:pkg, "b_pkg", "0.2.0"}, 1}]},
                [{:pkg_hash, [_, _]}, {:pkg_hash_ext, [_, _]}]
              ]} = :file.consult(file)
    end

    test "read_lock/1 of a file that does not exist", %{dir: dir} do
      assert %{} == :beam_com_hex.read_lock(:filename.join(dir, ~c"none.lock"))
    end

    # Mix writes the keys as quoted atoms ("name": ...). Elixir 1.20 gives
    # a warning for each such key, and Mix reads the file with no warnings.
    test "read_lock/2 of a mix.lock that Mix wrote", %{dir: dir} do
      file = :filename.join(dir, ~c"mix.lock")

      :ok =
        :file.write_file(file, """
        %{
          "jason": {:hex, :jason, "1.4.4", "AA", [:mix], [{:decimal, "~> 2.0", [hex: :decimal, repo: "hexpm", optional: true]}], "hexpm", "BB"},
          "my_app": {:hex, :my_pkg, "0.1.0", "CC", [:rebar3], [], "hexpm", "DD"},
        }
        """)

      assert "" ==
               capture_io(:stderr, fn ->
                 assert %{
                          jason: %{pkg: "jason", vsn: ~c"1.4.4", inner: "AA", outer: "BB"},
                          my_app: %{pkg: "my_pkg", vsn: ~c"0.1.0", inner: "CC", outer: "DD"}
                        } == :beam_com_hex.read_lock(:mix, file)
               end)
    end

    # The atoms of the build tools need not exist before: in beam.com,
    # no module names rebar3 or make.
    test "lock_text/2 of Mix, with each build tool", %{dir: dir} do
      file = :filename.join(dir, ~c"mix.lock")

      pkgs = [
        %{
          name: :a,
          pkg: "a_pkg",
          vsn: ~c"1.0.0",
          inner: "AA",
          outer: ~c"BB",
          tools: ["rebar3", "make", "mix", "other"],
          reqs: [{:b, "b", ~c"~> 0.2"}]
        }
      ]

      :ok = :file.write_file(file, :beam_com_hex.lock_text(:mix, pkgs))

      assert {%{
                "a" =>
                  {:hex, :a_pkg, "1.0.0", "aa", [:rebar3, :make, :mix],
                   [{:b, "~> 0.2", [hex: :b, repo: "hexpm", optional: false]}], "hexpm", "bb"}
              }, _} = Code.eval_file(List.to_string(file))

      assert %{a: %{pkg: "a_pkg", vsn: ~c"1.0.0", inner: "aa", outer: "bb"}} ==
               :beam_com_hex.read_lock(:mix, file)
    end
  end

  # The files of an application, for a package.
  defp app_files(name, vsn, deps, code) do
    n = :erlang.binary_to_list(name)

    [
      {~c"src/" ++ n ++ ~c".app.src",
       :io_lib.format(
         ~c"{application, ~s, [{vsn, ~p}, {applications, [kernel, stdlib~s]}]}.~n",
         [n, vsn, for(d <- deps, do: ~c", " ++ :erlang.binary_to_list(d))]
       )},
      {~c"src/" ++ n ++ ~c".erl", [~c"-module(", n, ~c").\n-export([f/0]).\n", code]}
    ]
  end

  describe "unpack_test_" do
    setup %{tmp_dir: tmp_dir} do
      dir = String.to_charlist(tmp_dir)

      tar =
        HexFixture.package(
          "u",
          ~c"1.0.0",
          app_files("u", ~c"1.0.0", [], ~c"f() -> u.\n"),
          [],
          ["rebar3"]
        )

      %{dir: dir, tar: tar, out: :filename.join(dir, ~c"u-1.0.0")}
    end

    test "contents and checksums", %{tar: tar, out: out} do
      %{inner: inner} = :beam_com_hex.unpack(tar, :undefined, out)
      assert :filelib.is_regular(:filename.join([out, ~c"src", ~c"u.erl"]))
      assert %{} = :beam_com_hex.unpack(tar, :string.lowercase(inner), out)
    end

    test "a checksum of rebar.lock that does not match", %{tar: tar, out: out} do
      assert {:error, ~c"~ts: the checksum does not match rebar.lock", [out]} ==
               catch_throw(:beam_com_hex.unpack(tar, "00", out))
    end

    test "a changed file", %{dir: dir, tar: tar, out: out} do
      {:ok, files} = :erl_tar.extract({:binary, tar}, [:memory])

      bad =
        :lists.keystore(
          ~c"metadata.config",
          1,
          files,
          {~c"metadata.config", "{<<\"x\">>, 1}.\n"}
        )

      f = :filename.join(dir, ~c"bad.tar")
      :ok = :erl_tar.create(f, bad, [])
      {:ok, bad_tar} = :file.read_file(f)

      assert {:error, ~c"~ts: the inner checksum does not match", [out]} ==
               catch_throw(:beam_com_hex.unpack(bad_tar, :undefined, out))
    end

    test "not a tarball", %{out: out} do
      assert {:error, ~c"~ts: not a Hex tarball", [out]} ==
               catch_throw(:beam_com_hex.unpack("junk", :undefined, out))
    end

    test "a link in the contents", %{dir: dir, out: out} do
      src = :filename.join(dir, ~c"link-src")
      :ok = :filelib.ensure_path(src)
      :ok = :file.make_symlink(~c"/etc/passwd", :filename.join(src, ~c"evil"))
      c = :filename.join(dir, ~c"link.tar.gz")
      {:ok, t} = :erl_tar.open(c, [:write, :compressed])
      :ok = :erl_tar.add(t, :filename.join(src, ~c"evil"), ~c"evil", [])
      :ok = :erl_tar.close(t)
      {:ok, contents} = :file.read_file(c)
      bad = HexFixture.hex_tar("{<<\"name\">>, <<\"u\">>}.\n", contents)

      assert {:error, ~c"~ts: the package has a file that is not a regular file: ~ts",
              [out, ~c"evil"]} ==
               catch_throw(:beam_com_hex.unpack(bad, :undefined, out))
    end

    # The limit is the size of contents.tar.gz without compression.
    test "unpack/4: the limit of the contents", %{tar: tar, out: out} do
      {:ok, files} = :erl_tar.extract({:binary, tar}, [:memory])
      {_, contents} = :lists.keyfind(~c"contents.tar.gz", 1, files)
      size = byte_size(:zlib.gunzip(contents))
      too_large = ~c"~ts: contents.tar.gz has more than ~b bytes without compression"

      assert {:error, too_large, [out, size - 1]} ==
               catch_throw(:beam_com_hex.unpack(tar, :undefined, out, size - 1))

      refute :filelib.is_file(out)
      assert %{inner: _} = :beam_com_hex.unpack(tar, :undefined, out, size)
      assert :filelib.is_regular(:filename.join([out, ~c"src", ~c"u.erl"]))
    end

    # 300 MiB of zeros are about 300 KB with gzip. unpack/3 refuses them
    # (the limit is 256 MiB) before it writes a file, and it keeps no
    # copy of them in memory.
    test "unpack/3: a small contents.tar.gz with too much data", %{out: out} do
      tar = HexFixture.hex_tar("{<<\"name\">>, <<\"u\">>}.\n", zeros_tar_gz(300 * 1024 * 1024))
      memory = :erlang.memory(:total)

      assert {:error, ~c"~ts: contents.tar.gz has more than ~b bytes without compression",
              [out, 256 * 1024 * 1024]} ==
               catch_throw(:beam_com_hex.unpack(tar, :undefined, out))

      assert :erlang.memory(:total) - memory < 64 * 1024 * 1024
      refute :filelib.is_file(out)
    end

    test "contents.tar.gz that is not gzip", %{out: out} do
      bad = HexFixture.hex_tar("{<<\"name\">>, <<\"u\">>}.\n", "not gzip")

      assert {:error, ~c"~ts: not a Hex tarball (contents)", [out]} ==
               catch_throw(:beam_com_hex.unpack(bad, :undefined, out))
    end

    test "a name out of the package", %{dir: dir, out: out} do
      c = :filename.join(dir, ~c"up.tar.gz")
      {:ok, t} = :erl_tar.open(c, [:write, :compressed])
      :ok = :erl_tar.add(t, "x", ~c"../up", [])
      :ok = :erl_tar.close(t)
      {:ok, contents} = :file.read_file(c)
      bad = HexFixture.hex_tar("{<<\"name\">>, <<\"u\">>}.\n", contents)

      assert {:error, ~c"~ts: the package has an unsafe file name: ~ts", [out, ~c"../up"]} ==
               catch_throw(:beam_com_hex.unpack(bad, :undefined, out))

      refute :filelib.is_file(:filename.join(dir, ~c"up"))
    end
  end

  # metadata.config: the same terms as file:consult/1, with no new atom.
  describe "consult_test_" do
    @not_terms {:error, ~c"metadata.config is not a list of terms", []}

    test "the terms of io_lib:format ~tp" do
      terms = [
        {"name", "pkg"},
        {"description", "Été, \"quoted\" \\ and\ttab"},
        {"build_tools", ["rebar3", "mix"]},
        {"requirements",
         [
           [
             {"name", "jason"},
             {"app", "jason"},
             {"optional", false},
             {"requirement", "~> 1.0"}
           ]
         ]},
        {"files", ["lib", ""]},
        {"count", -12},
        {~c"a string", {:nested, {:tuple, []}}}
      ]

      text = :unicode.characters_to_binary(for t <- terms, do: :io_lib.format(~c"~tp.~n", [t]))
      assert terms == :beam_com_hex.consult(text)
    end

    test "comments, escapes and segments" do
      assert [<<"a\nb", 195, 169, "c">>, [?x, 0xE9, ?y], [true, false]] ==
               :beam_com_hex.consult(
                 "% a comment\n<<\"a\\nb\", \"\\351\"/utf8, \"c\">>.\n\"x\\x{e9}y\" .\n[true,false]."
               )
    end

    test "an atom that does not exist is refused, and not made" do
      name =
        "beam_com_hex_test_no_such_atom_" <>
          Integer.to_string(:erlang.unique_integer([:positive]))

      count = :erlang.system_info(:atom_count)
      assert @not_terms == catch_throw(:beam_com_hex.consult("{<<\"x\">>, " <> name <> "}."))
      assert @not_terms == catch_throw(:beam_com_hex.consult("'" <> name <> " quoted'."))
      assert count == :erlang.system_info(:atom_count)
    end

    test "deep nesting" do
      text = String.duplicate("[", 100) <> String.duplicate("]", 100) <> "."
      assert @not_terms == catch_throw(:beam_com_hex.consult(text))
    end

    # A dot ends a term only before white space, a comment or the end, as
    # in erl_scan. Before, "1.5." gave the terms 1 and 5.
    test "a dot in a number does not end the term" do
      assert [1, 2, 3, :ok] == :beam_com_hex.consult("1.\n2.%c\n3. ok.")

      for b <- ["0.0.", "1.5.", "{a, 1.0}.", "[1.5].", "1.0e3.", "1.2.3.", "ok.x."] do
        assert @not_terms == catch_throw(:beam_com_hex.consult(b)), b
      end
    end

    for b <- ["{a", "fun() -> ok end.", "1 + 2.", "<<256>>.", "<<1:16>>.", "x"] do
      test "text that is not a term: #{inspect(b)}" do
        assert @not_terms == catch_throw(:beam_com_hex.consult(unquote(b)))
      end
    end

    # io_lib:format ~tp writes a binary as bytes when it has a character
    # that it does not print.
    test "the bytes of a binary" do
      assert [<<1, 255>>, <<"a", 0, "b">>, <<243, 191, 167, 157>>] ==
               :beam_com_hex.consult("<<1,255>>.\n<<\"a\",0,\"b\">>.\n<<243,191,167,157>>.")
    end

    test "not UTF-8" do
      assert {:error, ~c"metadata.config is not UTF-8", []} ==
               catch_throw(:beam_com_hex.consult(<<255, 254>>))
    end
  end

  describe "meta_requirements_test_" do
    defp req(app), do: {"p", [{"app", app}, {"requirement", "~> 1.0"}]}

    test "an app name" do
      assert [{:p_app, "p", ~c"~> 1.0"}] ==
               :beam_com_hex.meta_requirements([{"requirements", [req("p_app")]}])
    end

    for a <- ["Elixir.X", "1a", "a-b", "", 42] do
      test "not an app name: #{inspect(a)}" do
        assert {:error, _, _} =
                 catch_throw(
                   :beam_com_hex.meta_requirements([{"requirements", [req(unquote(a))]}])
                 )
      end
    end

    test "too many requirements" do
      assert {:error, ~c"a package has more than ~b requirements", [256]} ==
               catch_throw(
                 :beam_com_hex.meta_requirements([
                   {"requirements", List.duplicate(req("p"), 257)}
                 ])
               )
    end
  end

  # A registry in memory, for the resolution.
  defp registry(packages) do
    %{
      versions: fn p -> for {q, v, _} <- packages, q === p, do: v end,
      release: fn p, v ->
        {_, _, reqs} = :lists.keyfind(v, 2, for({q, _, _} = x <- packages, q === p, do: x))
        %{requirements: for({d, r} <- reqs, do: {String.to_atom(d), d, r})}
      end,
      tarball: fn _, _ -> :erlang.error(:not_used) end
    }
  end

  describe "resolve_test_" do
    setup do
      reg =
        registry([
          {"a", ~c"1.0.0", []},
          {"a", ~c"1.1.0", [{"b", ~c"~> 0.2.0"}]},
          {"a", ~c"2.0.0", []},
          {"a", ~c"2.1.0-rc.1", []},
          {"b", ~c"0.2.0", []},
          {"b", ~c"0.2.5", []},
          {"b", ~c"0.3.0", []},
          {"c", ~c"1.0.0", [{"b", ~c"~> 0.3"}]}
        ])

      resolve = fn deps, lock ->
        Map.new(:beam_com_hex.resolve(deps, lock, reg), fn {k, %{vsn: v}} -> {k, v} end)
      end

      %{resolve: resolve}
    end

    test "the highest version that matches, and its deps", %{resolve: r} do
      assert %{a: ~c"1.1.0", b: ~c"0.2.5"} == r.([{:a, "a", ~c"~> 1.0"}], %{})
    end

    test "no pre-release without a pre-release in the requirement", %{resolve: r} do
      assert %{a: ~c"2.0.0"} == r.([{:a, "a", :any}], %{})
    end

    test "the locked version, when it matches", %{resolve: r} do
      assert %{a: ~c"1.1.0", b: ~c"0.2.0"} ==
               r.([{:a, "a", ~c"~> 1.0"}], %{b: %{pkg: "b", vsn: ~c"0.2.0"}})
    end

    test "a conflict", %{resolve: r} do
      assert {:error,
              ~c"version conflict: ~p ~ts (needed by ~ts) does not match ~ts (needed by ~ts); give a version in rebar.config",
              [:b, ~c"0.2.5", ~c"a 1.1.0", ~c"~> 0.3", ~c"c 1.0.0"]} ==
               catch_throw(r.([{:a, "a", ~c"~> 1.0"}, {:c, "c", :any}], %{}))
    end

    test "no version", %{resolve: r} do
      assert {:error, ~c"no version of the Hex package ~ts matches ~ts (for ~p)",
              ["a", ~c"~> 3.0", :a]} ==
               catch_throw(r.([{:a, "a", ~c"~> 3.0"}], %{}))
    end
  end

  # fetch/2 with a server in place of hex.pm.
  describe "fetch_test_" do
    # The routes of the server: the packages alpha, beta and elixir_only.
    defp fetch_routes do
      b = fn v ->
        HexFixture.package("beta", v, app_files("beta", v, [], ~c"f() -> beta.\n"), [], [
          "rebar3"
        ])
      end

      a11 =
        HexFixture.package(
          "alpha",
          ~c"1.1.0",
          app_files("alpha", ~c"1.1.0", ["beta"], ~c"f() -> beta:f().\n"),
          [{"beta", ~c">= 0.2.0"}],
          ["rebar3"]
        )

      pkgs = [
        {"alpha", ~c"1.0.0", [], b.(~c"9.9.9")},
        {"alpha", ~c"1.1.0", [{"beta", ~c">= 0.2.0"}], a11},
        {"alpha", ~c"2.0.0", [], b.(~c"9.9.9")},
        {"beta", ~c"0.2.0", [], b.(~c"0.2.0")},
        {"beta", ~c"0.3.0-rc.1", [], b.(~c"0.3.0-rc.1")},
        {"elixir_only", ~c"1.0.0", [], b.(~c"1.0.0")}
      ]

      HexFixture.routes(pkgs)
    end

    setup %{tmp_dir: tmp_dir} do
      dir = String.to_charlist(tmp_dir)
      routes = fetch_routes()
      {pid, port} = HexFixture.serve(routes)
      url = "http://127.0.0.1:" <> Integer.to_string(port)

      System.put_env(%{
        "HEX_API_URL" => url <> "/api",
        "HEX_MIRROR" => url <> "/repo",
        "BEAM_COM_CACHE" => List.to_string(:filename.join(dir, ~c"cache"))
      })

      on_exit(fn ->
        HexFixture.stop(pid)
        Enum.each(["HEX_API_URL", "HEX_MIRROR", "BEAM_COM_CACHE"], &System.delete_env/1)
      end)

      app = :filename.join(dir, ~c"app")
      :ok = :filelib.ensure_path(app)

      :ok =
        :file.write_file(
          :filename.join(app, ~c"rebar.config"),
          "{deps, [{alpha, \"~> 1.0\"}]}.\n"
        )

      lib = fn n -> :filename.join(dir, ~c"lib" ++ Integer.to_charlist(n)) end
      %{dir: dir, pid: pid, app: app, lib: lib, routes: routes, url: url}
    end

    # The fetch to lib1 writes rebar.lock and fills the cache. ExUnit runs
    # the tests in a random order, so the tests that need this state call
    # this function first.
    defp fetch_quiet(app, lib) do
      {got, _output} = with_io(fn -> :beam_com_hex.fetch(app, lib) end)
      got
    end

    test "resolve, download, check and unpack; write rebar.lock", %{app: app, lib: lib} do
      got = fetch_quiet(app, lib.(1))

      assert [
               %{name: :beta, vsn: ~c"0.2.0", dir: :filename.join(lib.(1), ~c"beta-0.2.0")},
               %{name: :alpha, vsn: ~c"1.1.0", dir: :filename.join(lib.(1), ~c"alpha-1.1.0")}
             ] == got

      assert :filelib.is_regular(
               :filename.join([lib.(1), ~c"alpha-1.1.0", ~c"src", ~c"alpha.erl"])
             )

      {:ok, [{_, entries}, _]} = :file.consult(:filename.join(app, ~c"rebar.lock"))

      assert [{"alpha", {:pkg, "alpha", "1.1.0"}, 0}, {"beta", {:pkg, "beta", "0.2.0"}, 1}] ==
               entries
    end

    test "with rebar.lock and the cache: no request", %{app: app, lib: lib, pid: pid} do
      _ = fetch_quiet(app, lib.(1))
      before = length(HexFixture.requests(pid))
      got = fetch_quiet(app, lib.(2))
      assert [:beta, :alpha] == for(%{name: n} <- got, do: n)
      assert before == length(HexFixture.requests(pid))
    end

    test "a tarball in the cache that does not match is downloaded again",
         %{dir: dir, app: app, lib: lib, pid: pid} do
      _ = fetch_quiet(app, lib.(1))
      cache = :filename.join([dir, ~c"cache", ~c"hex", ~c"tarballs", ~c"beta-0.2.0.tar"])
      :ok = :file.write_file(cache, "changed")
      _ = fetch_quiet(app, lib.(3))
      assert ~c"/repo/tarballs/beta-0.2.0.tar" == List.last(HexFixture.requests(pid))
    end

    test "a package that is not on the server", %{dir: dir, lib: lib} do
      no_app = :filename.join(dir, ~c"noapp")
      :ok = :filelib.ensure_path(no_app)
      :ok = :file.write_file(:filename.join(no_app, ~c"rebar.config"), "{deps, [nosuch]}.\n")

      assert {:error, ~c"~ts: not found", [_]} =
               catch_throw(fetch_quiet(no_app, lib.(4)))
    end

    # rebar.lock of the format 1.0.0 has the versions and no checksum. The
    # API gives the checksum of each release, the tarballs are checked
    # with it, and rebar.lock gets the checksums and keeps its levels.
    test "rebar.lock with no checksums", %{app: app, lib: lib, pid: pid, routes: routes} do
      lock = :filename.join(app, ~c"rebar.lock")

      :ok =
        :file.write_file(
          lock,
          "[{<<\"alpha\">>,{pkg,<<\"alpha\">>,<<\"1.1.0\">>},0},{<<\"beta\">>,{pkg,<<\"beta\">>,<<\"0.2.0\">>},1}].\n"
        )

      {got, output} = with_io(fn -> :beam_com_hex.fetch(app, lib.(1)) end)
      assert [:beta, :alpha] == for(%{name: n} <- got, do: n)
      assert output =~ "wrote " <> List.to_string(lock)
      requests = HexFixture.requests(pid)
      assert ~c"/api/packages/alpha/releases/1.1.0" in requests
      assert ~c"/api/packages/beta/releases/0.2.0" in requests

      assert %{
               alpha: %{level: 0, outer: alpha_outer, inner: alpha_inner},
               beta: %{level: 1, outer: beta_outer, inner: beta_inner}
             } = :beam_com_hex.read_lock(lock)

      assert alpha_outer == outer_sum(routes, ~c"alpha-1.1.0")
      assert beta_outer == outer_sum(routes, ~c"beta-0.2.0")
      assert alpha_inner == inner_sum(routes, ~c"alpha-1.1.0")
      assert beta_inner == inner_sum(routes, ~c"beta-0.2.0")

      # With the checksums in rebar.lock and the cache: no request.
      before = length(HexFixture.requests(pid))
      _ = fetch_quiet(app, lib.(2))
      assert before == length(HexFixture.requests(pid))
    end

    # The cache can be shared, and its tarballs can change. A lock with no
    # checksum does not make a tarball of the cache trusted.
    test "rebar.lock with no checksums and a changed tarball in the cache",
         %{dir: dir, app: app, lib: lib, pid: pid} do
      lock = :filename.join(app, ~c"rebar.lock")
      :ok = :file.write_file(lock, "[{<<\"beta\">>,{pkg,<<\"beta\">>,<<\"0.2.0\">>},0}].\n")
      :ok = :file.write_file(:filename.join(app, ~c"rebar.config"), "{deps, [beta]}.\n")
      cache = :filename.join([dir, ~c"cache", ~c"hex", ~c"tarballs", ~c"beta-0.2.0.tar"])
      :ok = :filelib.ensure_dir(cache)

      evil =
        HexFixture.package(
          "beta",
          ~c"0.2.0",
          app_files("beta", ~c"0.2.0", [], ~c"f() -> evil.\n"),
          [],
          ["rebar3"]
        )

      :ok = :file.write_file(cache, evil)
      _ = fetch_quiet(app, lib.(1))
      assert ~c"/repo/tarballs/beta-0.2.0.tar" == List.last(HexFixture.requests(pid))

      {:ok, code} =
        :file.read_file(:filename.join([lib.(1), ~c"beta-0.2.0", ~c"src", ~c"beta.erl"]))

      assert code =~ "f() -> beta."
    end

    test "rebar.lock with no checksums, and the API with no checksum",
         %{app: app, lib: lib, routes: routes} do
      release = ~c"/api/packages/beta/releases/0.2.0"
      {pid, port} = HexFixture.serve(Map.put(routes, release, ~s({"requirements": {}})))
      on_exit(fn -> HexFixture.stop(pid) end)
      System.put_env("HEX_API_URL", "http://127.0.0.1:" <> Integer.to_string(port) <> "/api")
      :ok = :file.write_file(:filename.join(app, ~c"rebar.config"), "{deps, [beta]}.\n")

      :ok =
        :file.write_file(
          :filename.join(app, ~c"rebar.lock"),
          "[{<<\"beta\">>,{pkg,<<\"beta\">>,<<\"0.2.0\">>},0}].\n"
        )

      assert {:error, ~c"~ts ~ts: the Hex API gives no checksum", ["beta", ~c"0.2.0"]} ==
               catch_throw(fetch_quiet(app, lib.(1)))
    end

    # rebar.lock of the format 1.1.0 has only pkg_hash: the tarball is
    # checked with the checksum of the API and with pkg_hash.
    test "rebar.lock with pkg_hash only", %{app: app, lib: lib, routes: routes} do
      lock = :filename.join(app, ~c"rebar.lock")
      :ok = :file.write_file(:filename.join(app, ~c"rebar.config"), "{deps, [beta]}.\n")

      write = fn inner ->
        :file.write_file(
          lock,
          "{\"1.1.0\",[{<<\"beta\">>,{pkg,<<\"beta\">>,<<\"0.2.0\">>},0}]}.\n" <>
            "[{pkg_hash,[{<<\"beta\">>,<<\"" <> inner <> "\">>}]}].\n"
        )
      end

      :ok = write.(String.duplicate("0", 64))
      dir = :filename.join(lib.(1), ~c"beta-0.2.0")

      assert {:error, ~c"~ts: the checksum does not match rebar.lock", [dir]} ==
               catch_throw(fetch_quiet(app, lib.(1)))

      :ok = write.(inner_sum(routes, ~c"beta-0.2.0"))
      _ = fetch_quiet(app, lib.(1))
      assert %{beta: %{outer: outer}} = :beam_com_hex.read_lock(lock)
      assert outer == outer_sum(routes, ~c"beta-0.2.0")
    end

    # Older versions of Hex wrote mix.lock with no outer checksum, or with
    # no checksum. Mix writes the keys as quoted atoms.
    test "mix.lock with no outer checksums", %{app: app, lib: lib, pid: pid, routes: routes} do
      lock = :filename.join(app, ~c"mix.lock")
      inner = :string.lowercase(inner_sum(routes, ~c"alpha-1.1.0"))

      :ok =
        :file.write_file(lock, """
        %{
          "alpha": {:hex, :alpha, "1.1.0", "#{inner}", [:rebar3], [], "hexpm"},
          "beta": {:hex, :beta, "0.2.0"},
        }
        """)

      deps = [{:alpha, "alpha", ~c"~> 1.0"}]
      {got, output} = with_io(fn -> :beam_com_hex.fetch(app, lib.(1), deps, :mix) end)
      assert [:beta, :alpha] == for(%{name: n} <- got, do: n)
      assert output =~ "wrote " <> List.to_string(lock)

      assert %{alpha: %{outer: alpha_outer}, beta: %{outer: beta_outer, inner: beta_inner}} =
               :beam_com_hex.read_lock(:mix, lock)

      assert alpha_outer == :string.lowercase(outer_sum(routes, ~c"alpha-1.1.0"))
      assert beta_outer == :string.lowercase(outer_sum(routes, ~c"beta-0.2.0"))
      assert beta_inner == :string.lowercase(inner_sum(routes, ~c"beta-0.2.0"))

      before = length(HexFixture.requests(pid))
      {_, _} = with_io(fn -> :beam_com_hex.fetch(app, lib.(2), deps, :mix) end)
      assert before == length(HexFixture.requests(pid))
    end

    # The repository gives at most 32 MiB for a tarball.
    test "a tarball with no end", %{app: app, lib: lib, routes: routes} do
      endless = {:endless, :binary.copy("x", 65536)}
      {pid, port} = HexFixture.serve(Map.put(routes, ~c"/repo/tarballs/beta-0.2.0.tar", endless))
      on_exit(fn -> HexFixture.stop(pid) end)
      mirror = "http://127.0.0.1:" <> Integer.to_string(port) <> "/repo"
      System.put_env("HEX_MIRROR", mirror)

      assert {:error, ~c"~ts: the response has more than ~b bytes",
              [String.to_charlist(mirror) ++ ~c"/tarballs/beta-0.2.0.tar", 32 * 1024 * 1024]} ==
               catch_throw(fetch_quiet(app, lib.(1)))
    end

    # A file of the cache with more than 32 MiB is not read, also when
    # rebar.lock has its checksum: the tarball is downloaded again.
    test "a tarball in the cache that is too large",
         %{dir: dir, app: app, lib: lib, pid: pid, routes: routes} do
      _ = fetch_quiet(app, lib.(1))
      cache = :filename.join([dir, ~c"cache", ~c"hex", ~c"tarballs", ~c"beta-0.2.0.tar"])
      {:ok, tar} = :file.read_file(cache)
      large = [tar, :binary.copy(<<0>>, 32 * 1024 * 1024)]
      :ok = :file.write_file(cache, large)
      _ = fetch_quiet(app, lib.(2))
      assert ~c"/repo/tarballs/beta-0.2.0.tar" == List.last(HexFixture.requests(pid))
      assert {:ok, ^tar} = :file.read_file(cache)

      lock = Path.join(List.to_string(app), "rebar.lock")
      large_sum = :binary.encode_hex(:crypto.hash(:sha256, large))

      File.write!(
        lock,
        String.replace(File.read!(lock), outer_sum(routes, ~c"beta-0.2.0"), large_sum)
      )

      :ok = :file.write_file(cache, large)

      assert {:error, ~c"~ts ~ts: the checksum of the tarball does not match",
              ["beta", ~c"0.2.0"]} == catch_throw(fetch_quiet(app, lib.(3)))
    end
  end

  # fetch/5 with a registry in memory: the tarballs and the checksums of
  # the API.
  describe "fetch_registry_test_" do
    setup %{tmp_dir: tmp_dir} do
      dir = String.to_charlist(tmp_dir)
      System.put_env("BEAM_COM_CACHE", List.to_string(:filename.join(dir, ~c"cache")))
      on_exit(fn -> System.delete_env("BEAM_COM_CACHE") end)
      app = :filename.join(dir, ~c"app")
      :ok = :filelib.ensure_path(app)

      :ok =
        :file.write_file(
          :filename.join(app, ~c"rebar.lock"),
          "[{<<\"beta\">>,{pkg,<<\"beta\">>,<<\"0.2.0\">>},0}].\n"
        )

      tar =
        HexFixture.package(
          "beta",
          ~c"0.2.0",
          app_files("beta", ~c"0.2.0", [], ~c"f() -> beta.\n"),
          [],
          ["rebar3"]
        )

      sum = :string.lowercase(:binary.encode_hex(:crypto.hash(:sha256, tar)))

      registry = fn checksum, served ->
        %{
          versions: fn _ -> :erlang.error(:not_used) end,
          release: fn "beta", ~c"0.2.0" -> %{checksum: checksum, requirements: []} end,
          tarball: fn "beta", ~c"0.2.0" -> served end
        }
      end

      fetch = fn reg ->
        {got, _} =
          with_io(fn ->
            :beam_com_hex.fetch(
              app,
              :filename.join(dir, ~c"lib"),
              [{:beta, "beta", :any}],
              :rebar,
              reg
            )
          end)

        got
      end

      %{tar: tar, sum: sum, registry: registry, fetch: fetch}
    end

    test "the tarball of the checksum of the API", %{tar: tar, sum: sum, registry: r, fetch: f} do
      assert [%{name: :beta}] = f.(r.(String.to_charlist(sum), tar))
    end

    # HEX_MIRROR can be a server that is not trusted.
    test "a tarball that does not match the API", %{tar: tar, registry: r, fetch: f} do
      other = String.duplicate("0", 64)

      assert {:error, ~c"~ts ~ts: the checksum of the tarball does not match",
              ["beta", ~c"0.2.0"]} == catch_throw(f.(r.(String.to_charlist(other), tar)))
    end

    test "the API gives no checksum", %{tar: tar, registry: r, fetch: f} do
      assert {:error, ~c"~ts ~ts: the Hex API gives no checksum", ["beta", ~c"0.2.0"]} ==
               catch_throw(f.(r.(:undefined, tar)))
    end
  end

  # http_get/2: the limit of the size of a body.
  describe "http_test_" do
    setup do
      routes = %{
        ~c"/1000" => :binary.copy("a", 1000),
        ~c"/chunked" => {:chunked, :binary.copy("c", 1000)},
        ~c"/endless" => {:endless, :binary.copy("e", 65536)}
      }

      {pid, port} = HexFixture.serve(routes)
      on_exit(fn -> HexFixture.stop(pid) end)
      %{url: fn path -> ~c"http://127.0.0.1:" ++ Integer.to_charlist(port) ++ path end}
    end

    @too_large ~c"~ts: the response has more than ~b bytes"

    test "a body of the limit", %{url: url} do
      assert :binary.copy("a", 1000) == :beam_com_hex.http_get(url.(~c"/1000"), 1000)
      assert :binary.copy("c", 1000) == :beam_com_hex.http_get(url.(~c"/chunked"), 1000)
    end

    # httpc stops a body with a length (Content-Length, or a chunk) above
    # the limit before it comes.
    test "a body with a length above the limit", %{url: url} do
      for path <- [~c"/1000", ~c"/chunked"] do
        assert {:error, @too_large, [url.(path), 999]} ==
                 catch_throw(:beam_com_hex.http_get(url.(path), 999))
      end
    end

    # A body with no length comes in parts, and the request stops after
    # the limit. The server sends until the client closes.
    test "a body with no end", %{url: url} do
      assert {:error, @too_large, [url.(~c"/endless"), 1024 * 1024]} ==
               catch_throw(:beam_com_hex.http_get(url.(~c"/endless"), 1024 * 1024))
    end

    test "no server, and a URL that is not valid" do
      {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(listen)
      :ok = :gen_tcp.close(listen)
      url = ~c"http://127.0.0.1:" ++ Integer.to_charlist(port) ++ ~c"/x"

      assert {:error, ~c"~ts: ~p", [^url, {:failed_connect, _}]} =
               catch_throw(:beam_com_hex.http_get(url, 1000))

      assert {:error, ~c"~ts: ~p", [~c"not a URL", :invalid_uri]} ==
               catch_throw(:beam_com_hex.http_get(~c"not a URL", 1000))
    end
  end

  describe "read_limited_test_" do
    test "a file of the limit, a larger file and no file", %{tmp_dir: dir} do
      file = Path.join(dir, "f")
      # More than one part of 1 MiB.
      data = :crypto.strong_rand_bytes(3 * 1024 * 1024)
      File.write!(file, data)
      assert {:ok, data} == :beam_com_hex.read_limited(file, byte_size(data))
      assert {:error, :too_large} == :beam_com_hex.read_limited(file, byte_size(data) - 1)
      assert {:ok, data} == :beam_com_hex.read_limited(file, byte_size(data) + 1)
      assert {:error, :enoent} == :beam_com_hex.read_limited(Path.join(dir, "none"), 10)
    end
  end

  # The properties of the parser of versions and requirements. The oracle
  # is the Version module of Elixir, an independent parser of the same
  # rules (Semantic Versioning 2.0.0, and the requirements of Hex).
  describe "properties of versions and requirements" do
    property "parse_version/1 reads each version that Version.parse/1 reads" do
      check all(version <- version()) do
        text = to_string(version)
        assert {:ok, ^version} = Version.parse(text)
        assert {:ok, tuple} = :beam_com_hex.parse_version(String.to_charlist(text))
        assert tuple == to_tuple(version)
      end
    end

    property "parse_version/1 ignores the build metadata" do
      check all(version <- version(), build <- identifier()) do
        with_build = String.to_charlist(to_string(version) <> "+" <> build)

        assert :beam_com_hex.parse_version(with_build) ==
                 {:ok, to_tuple(version)}
      end
    end

    property "parse_version/1 gives error for a text that is not a version" do
      check all(text <- string(:printable, max_length: 20)) do
        result = :beam_com_hex.parse_version(String.to_charlist(text))

        case Version.parse(text) do
          {:ok, _} -> assert {:ok, _} = result
          :error -> assert result == :error or match?({:ok, _}, result)
        end
      end
    end

    property "compare/2 gives the order of Version.compare/2" do
      check all(a <- version(), b <- version()) do
        assert :beam_com_hex.compare(to_tuple(a), to_tuple(b)) == Version.compare(a, b)
      end
    end

    property "compare/2 is a total order" do
      check all(a <- version(), b <- version(), c <- version()) do
        {ta, tb, tc} = {to_tuple(a), to_tuple(b), to_tuple(c)}
        assert :beam_com_hex.compare(ta, ta) == :eq
        assert :beam_com_hex.compare(ta, tb) == flip(:beam_com_hex.compare(tb, ta))

        if :beam_com_hex.compare(ta, tb) != :gt and :beam_com_hex.compare(tb, tc) != :gt do
          assert :beam_com_hex.compare(ta, tc) != :gt
        end
      end
    end

    property "matches/2 gives the result of Version.match?/3 without pre-releases" do
      check all(version <- version(), requirement <- requirement()) do
        expected = Version.match?(version, requirement, allow_pre: false)

        assert :beam_com_hex.matches(to_tuple(version), String.to_charlist(requirement)) ==
                 expected
      end
    end

    # Version.match?/3 warns that "!=" is deprecated, so this property
    # checks "!=" against its definition.
    property "a \"!=\" requirement matches each other version" do
      check all(a <- version(), b <- version()) do
        expected = :beam_com_hex.compare(to_tuple(a), to_tuple(b)) != :eq
        assert :beam_com_hex.matches(to_tuple(a), String.to_charlist("!= #{b}")) == expected
      end
    end
  end

  # The properties of the reader of metadata.config and of the check of
  # the files of a package. The oracles are io_lib:format/2 and
  # file:consult/1 of OTP, and the rules of filename/1.
  describe "properties of metadata.config and of tarballs" do
    property "consult/1 reads the terms that io_lib:format ~tp writes" do
      check all(terms <- list_of(metadata_term(), max_length: 4)) do
        text = :unicode.characters_to_binary(for t <- terms, do: :io_lib.format(~c"~tp.~n", [t]))
        assert :beam_com_hex.consult(text) == terms
      end
    end

    # A random text gives the terms of file:consult/1, or the error of
    # consult/1. No other exception, and no new atom.
    @tag :tmp_dir
    property "consult/1 of a random text", %{tmp_dir: dir} do
      file = Path.join(dir, "metadata.config")

      check all(text <- term_text()) do
        count = :erlang.system_info(:atom_count)

        result =
          try do
            {:ok, :beam_com_hex.consult(text)}
          catch
            :throw, error -> error
          end

        case result do
          {:error, ~c"metadata.config is not a list of terms", []} ->
            :ok

          {:ok, terms} ->
            File.write!(file, text)
            assert {:ok, terms} == :file.consult(String.to_charlist(file))
        end

        assert count == :erlang.system_info(:atom_count)
      end
    end

    # A package with a name that is absolute or that has ".." is refused
    # before a file is written. A safe package is unpacked in full.
    @tag :tmp_dir
    property "unpack/3 writes no file out of its directory", %{tmp_dir: dir} do
      check all(paths <- uniq_list_of(package_path(), min_length: 1, max_length: 4)) do
        root = Path.join(dir, "p#{System.unique_integer([:positive])}")
        out = Path.join(root, "pkg")
        File.mkdir_p!(root)
        contents = contents_tar(root, paths)
        tar = HexFixture.hex_tar("{<<\"name\">>, <<\"u\">>}.\n", contents)
        {:ok, table} = :erl_tar.table({:binary, contents}, [:compressed])
        safe = Enum.all?(table, &safe_name?/1)

        result =
          try do
            :beam_com_hex.unpack(tar, :undefined, String.to_charlist(out))
          catch
            :throw, error -> error
          end

        case result do
          %{inner: _} ->
            assert safe

            # erl_tar stores "a/./f1.txt" as "a/f1.txt", so two paths can
            # name one file. The data of a file is one of the paths.
            for name <- table,
                do: assert(File.read!(Path.join(out, to_string(name))) in paths)

          {:error, ~c"~ts: the package has an unsafe file name: ~ts", _} ->
            refute safe
            refute File.exists?(out)
        end

        assert root |> File.ls!() |> Enum.sort() == Enum.sort(["contents.tar.gz" | in_out(out)])
      end
    end

    # unpack/4 takes the contents when they have at most Max bytes without
    # compression, and refuses them before it writes a file otherwise. The
    # oracle is zlib:gunzip/1.
    @tag :tmp_dir
    property "unpack/4 and the limit of the contents", %{tmp_dir: dir} do
      check all(
              data <- list_of(binary(max_length: 3000), min_length: 1, max_length: 3),
              delta <- integer(-600..600)
            ) do
        files = Enum.zip(["a", "b/c", "d.txt"], data)
        root = Path.join(dir, "p#{System.unique_integer([:positive])}")
        out = Path.join(root, "pkg")
        File.mkdir_p!(root)
        file = Path.join(root, "contents.tar.gz")

        :ok =
          :erl_tar.create(
            String.to_charlist(file),
            for({name, data} <- files, do: {String.to_charlist(name), data}),
            [:compressed]
          )

        contents = File.read!(file)
        size = byte_size(:zlib.gunzip(contents))
        max = max(size + delta, 1)
        tar = HexFixture.hex_tar("{<<\"name\">>, <<\"u\">>}.\n", contents)

        result =
          try do
            :beam_com_hex.unpack(tar, :undefined, String.to_charlist(out), max)
          catch
            :throw, error -> error
          end

        if size <= max do
          assert %{inner: _} = result
          for {name, data} <- files, do: assert(File.read!(Path.join(out, name)) == data)
        else
          assert {:error, ~c"~ts: contents.tar.gz has more than ~b bytes without compression",
                  [_, ^max]} = result

          refute File.exists?(out)
        end
      end
    end
  end

  # An Erlang term that metadata.config can have: integers, atoms that
  # exist, strings, binaries of UTF-8 text, lists and tuples.
  defp metadata_term do
    leaf =
      one_of([
        integer(),
        member_of([true, false, :ok, :undefined, :nested]),
        map(string(:printable, max_length: 8), &String.to_charlist/1),
        string(:printable, max_length: 8)
      ])

    tree(leaf, fn child ->
      one_of([
        list_of(child, max_length: 3),
        map(list_of(child, max_length: 3), &List.to_tuple/1)
      ])
    end)
  end

  # A text of the characters of terms, with parts of real terms in it.
  defp term_text do
    piece =
      one_of([
        member_of(["{", "}", "[", "]", ",", ".", "<<", ">>", "\"", "'", "/utf8", "-", " ", "\n"]),
        member_of(["true", "ok", "x1", "12", "\\x{41}", "\\n", "% c\n"]),
        map(metadata_term(), &IO.chardata_to_string(:io_lib.format(~c"~tp", [&1])))
      ])

    map(list_of(piece, max_length: 12), &Enum.join/1)
  end

  # A path in a package: names, ".", "..", and an absolute start.
  defp package_path do
    gen all(
          absolute <- boolean(),
          dirs <- list_of(member_of(["a", "b", ".", ".."]), max_length: 3),
          leaf <- member_of(["f1.txt", "f2.txt", "f3.txt"])
        ) do
      path = Enum.join(dirs ++ [leaf], "/")
      if absolute, do: "/" <> path, else: path
    end
  end

  # contents.tar.gz with one file for each path. The data of a file is
  # its name.
  defp contents_tar(root, paths) do
    file = Path.join(root, "contents.tar.gz")
    {:ok, tar} = :erl_tar.open(String.to_charlist(file), [:write, :compressed])

    for path <- paths,
        do: :ok = :erl_tar.add(tar, path, String.to_charlist(path), [])

    :ok = :erl_tar.close(tar)
    File.read!(file)
  end

  # The checksums of the tarball NAME-VSN of the routes, as rebar.lock
  # has them: the SHA-256 of the file, and the CHECKSUM file.
  defp outer_sum(routes, name) do
    :binary.encode_hex(:crypto.hash(:sha256, routes[~c"/repo/tarballs/" ++ name ++ ~c".tar"]))
  end

  defp inner_sum(routes, name) do
    tar = routes[~c"/repo/tarballs/" ++ name ++ ~c".tar"]
    {:ok, files} = :erl_tar.extract({:binary, tar}, [:memory])
    {_, sum} = :lists.keyfind(~c"CHECKSUM", 1, files)
    sum
  end

  # contents.tar.gz with one file of `size` zero bytes. It is made in
  # parts of 1 MiB, so the data is never all in memory.
  defp zeros_tar_gz(size) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, 1, :deflated, 31, 8, :default)
    part = :binary.copy(<<0>>, 1024 * 1024)

    parts =
      Enum.reduce(1..div(size, byte_size(part))//1, [:zlib.deflate(z, tar_header("z", size))], fn
        _, acc -> [acc | :zlib.deflate(z, part)]
      end)

    # The rest of the file, the padding to a block of 512 bytes, and the
    # two empty blocks of the end.
    padding = rem(512 - rem(size, 512), 512)

    last =
      :zlib.deflate(z, :binary.copy(<<0>>, rem(size, byte_size(part)) + padding + 1024), :finish)

    :zlib.close(z)
    IO.iodata_to_binary([parts | last])
  end

  # The ustar header of a regular file.
  defp tar_header(name, size) do
    field = fn value, length -> value <> :binary.copy(<<0>>, length - byte_size(value)) end

    octal = fn n, length ->
      String.pad_leading(Integer.to_string(n, 8), length - 1, "0") <> <<0>>
    end

    header = fn sum ->
      Enum.join([
        field.(name, 100),
        octal.(0o644, 8),
        octal.(0, 8),
        octal.(0, 8),
        octal.(size, 12),
        octal.(0, 12),
        sum,
        "0",
        field.("", 100),
        "ustar\0",
        "00",
        field.("", 32),
        field.("", 32),
        octal.(0, 8),
        octal.(0, 8),
        field.("", 155),
        field.("", 12)
      ])
    end

    sum = header.("        ") |> :binary.bin_to_list() |> Enum.sum()
    header.(String.pad_leading(Integer.to_string(sum, 8), 6, "0") <> <<0, ?\s>>)
  end

  defp safe_name?(name) do
    :filename.pathtype(name) == :relative and ~c".." not in :filename.split(name)
  end

  defp in_out(out), do: if(File.exists?(out), do: [Path.basename(out)], else: [])

  defp version do
    gen all(
          major <- integer(0..20),
          minor <- integer(0..20),
          patch <- integer(0..20),
          pre <- one_of([constant([]), list_of(pre_identifier(), min_length: 1, max_length: 3)])
        ) do
      %Version{major: major, minor: minor, patch: patch, pre: pre}
    end
  end

  # A pre-release identifier: a number with no leading zero, or a word of
  # letters, digits and hyphens with one letter or hyphen at least.
  defp pre_identifier do
    one_of([
      integer(0..30),
      map(identifier(), fn word -> if word =~ ~r/^[0-9]+$/, do: "x" <> word, else: word end)
    ])
  end

  defp identifier do
    string(Enum.concat([?0..?9, ?a..?z, ?A..?Z, [?-]]), min_length: 1, max_length: 6)
  end

  defp requirement do
    clause =
      gen all(
            op <- member_of(["==", ">=", "<=", ">", "<", "~>"]),
            version <- version(),
            short <- boolean()
          ) do
        text =
          if op == "~>" and short,
            do: Enum.join(["#{version.major}.#{version.minor}" | pre_text(version.pre)], "-"),
            else: to_string(version)

        op <> " " <> text
      end

    gen all(
          alternatives <-
            list_of(list_of(clause, min_length: 1, max_length: 3), min_length: 1, max_length: 2)
        ) do
      Enum.map_join(alternatives, " or ", &Enum.join(&1, " and "))
    end
  end

  defp to_tuple(%Version{major: major, minor: minor, patch: patch, pre: pre}) do
    {major, minor, patch,
     Enum.map(pre, fn
       p when is_integer(p) -> p
       p -> p
     end)}
  end

  defp pre_text([]), do: []
  defp pre_text(pre), do: [Enum.join(pre, ".")]

  defp flip(:lt), do: :gt
  defp flip(:gt), do: :lt
  defp flip(:eq), do: :eq
end
