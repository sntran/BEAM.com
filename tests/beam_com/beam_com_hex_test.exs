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

    for b <- ["{a", "fun() -> ok end.", "1 + 2.", "<<1>>.", "x"] do
      test "text that is not a term: #{inspect(b)}" do
        assert @not_terms == catch_throw(:beam_com_hex.consult(unquote(b)))
      end
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
end
