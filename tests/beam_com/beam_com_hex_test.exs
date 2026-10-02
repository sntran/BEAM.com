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
               a: %{pkg: "a", vsn: ~c"1.1.0", inner: "CC", outer: "DD"},
               b: %{pkg: "b_pkg", vsn: ~c"0.2.0", inner: "AA", outer: "BB"}
             } == :beam_com_hex.read_lock(file)
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
      {pid, port} = HexFixture.serve(fetch_routes())
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
      %{dir: dir, pid: pid, app: app, lib: lib}
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
