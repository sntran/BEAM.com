defmodule BeamComBuildTest do
  @moduledoc """
  The tests of `:beam_com_build` (beam.com INPUT -o OUTPUT).

  The tests use the real OTP applications of the Erlang that runs them.
  A temporary lib directory has links to them, so systools works on real
  application files. The tests of run/1 go from end to end with a fake
  executable.

  Each test runs in its own directory, with no project. The module
  changes the current directory, so it does not run with other modules.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Bitwise
  import ExUnit.CaptureIO

  alias BeamCom.HexFixture

  # The tests compile and load these modules while they run.
  @compile {:no_warn_undefined, [:ls, :lp, :Pair, :full_app, :web, :aa_user, :m_withdocs]}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    old = File.cwd!()
    File.cd!(tmp_dir)
    on_exit(fn -> File.cd!(old) end)
    {:ok, dir: String.to_charlist(tmp_dir)}
  end

  # The signature of the end of the central directory of a zip file.
  @zip_end 0x06054B50

  describe "small functions" do
    test "split_dir_test" do
      assert {:kernel, ~c"11.0.4"} == :beam_com_build.split_dir(~c"kernel-11.0.4")
      assert {:beam_com, :none} == :beam_com_build.split_dir(~c"beam_com")
      assert {:"my-app", ~c"1.0"} == :beam_com_build.split_dir(~c"my-app-1.0")
      # A version with "-": a pre-release, or a Mix dependency from Git.
      assert {:phoenix, ~c"1.9.0-dev"} == :beam_com_build.split_dir(~c"phoenix-1.9.0-dev")
      assert {:ecto, ~c"3.0.0-rc.1"} == :beam_com_build.split_dir(~c"ecto-3.0.0-rc.1")
      assert {:"my-app", ~c"1.0-rc"} == :beam_com_build.split_dir(~c"my-app-1.0-rc")
      assert {:foo, ~c"main"} == :beam_com_build.split_dir(~c"foo-main")
    end

    test "default_output_test" do
      assert ~c"hello.com" == :beam_com_build.default_output(~c"src/hello.erl")
      assert ~c"myapp.com" == :beam_com_build.default_output(~c"apps/myapp")
      assert ~c"x.com" == :beam_com_build.default_output(~c"x")
    end

    test "parents_test" do
      assert [] == :beam_com_build.parents(~c"file")
      assert [~c"a/"] == :beam_com_build.parents(~c"a/file")
      assert [~c"a/", ~c"a/b/", ~c"a/b/c/"] == :beam_com_build.parents(~c"a/b/c/file")
    end

    test "with_dirs_test" do
      files = [
        {~c"lib/a-1/ebin/a.beam", "1"},
        {~c"lib/a-1/ebin/b.beam", "2"},
        {~c"releases/1/start.boot", "3"},
        {~c"top", "4"}
      ]

      assert [
               {~c"lib/", ""},
               {~c"lib/a-1/", ""},
               {~c"lib/a-1/ebin/", ""},
               {~c"releases/", ""},
               {~c"releases/1/", ""}
             ] ++ files == :beam_com_build.with_dirs(files)
    end

    test "relocate_test" do
      tmp = ~c"/tmp/x.tmp"

      script =
        {:script, {~c"n", ~c"1"},
         [
           {:path, [~c"$ROOT/lib/kernel-1/ebin", ~c"/tmp/x.tmp/lib/app-1/ebin"]},
           {:primLoad, [:app]},
           {:apply, {:application, :load, [{:application, :app, []}]}},
           {:other, ~c"/tmp/x.tmpfoo/not/this", 42, :atom}
         ]}

      assert {:script, {~c"n", ~c"1"},
              [
                {:path, [~c"$ROOT/lib/kernel-1/ebin", ~c"$ROOT/lib/app-1/ebin"]},
                {:primLoad, [:app]},
                {:apply, {:application, :load, [{:application, :app, []}]}},
                {:other, ~c"/tmp/x.tmpfoo/not/this", 42, :atom}
              ]} == :beam_com_build.relocate(script, tmp)
    end

    test "keep_test" do
      base = %{kernel: %{vsn: ~c"11.0.4"}, ssl: %{vsn: ~c"11.7.7"}}
      keep = :beam_com_build.keep([:kernel, :ssl], base)

      yes = [
        ~c"lib/",
        ~c"lib/kernel-11.0.4/",
        ~c"lib/kernel-11.0.4/ebin/",
        ~c"lib/kernel-11.0.4/ebin/kernel.app",
        ~c"lib/ssl-11.7.7/priv/x/y",
        ~c"bin/start_clean.boot",
        ~c"usr/share/zoneinfo/UTC",
        ~c".cosmo",
        ~c".symtab.amd64",
        ~c"licenses/NOTICE",
        ~c"licenses/otp/MIT.txt"
      ]

      no = [
        ~c"lib/kernel-11.0.4/include/file.hrl",
        ~c"lib/kernel-11.0.4/src/x.erl",
        ~c"lib/kernel-11.0.40/ebin/kernel.app",
        ~c"lib/stdlib-8.1/ebin/lists.beam",
        ~c"lib/beam_com/ebin/beam_com.beam",
        ~c"releases/",
        ~c"releases/start_erl.data",
        ~c".args"
      ]

      for n <- yes, do: assert(keep.(n), "#{n}")
      for n <- no, do: refute(keep.(n), "#{n}")
    end

    test "executable_test" do
      assert {:error, _, _} = catch_throw(:beam_com_build.executable())
    end
  end

  describe "script_test_" do
    test "not a .erl file", %{dir: dir} do
      assert {:error, ~c"~ts: not a .erl, .ex or .exs file, or a directory", _} =
               catch_throw(:beam_com_build.script(:filename.join(dir, ~c"x.txt")))
    end

    test "missing file", %{dir: dir} do
      assert {:error, ~c"~ts: no such file", _} =
               catch_throw(:beam_com_build.script(:filename.join(dir, ~c"none.erl")))
    end

    test "no main/1", %{dir: dir} do
      f = write(dir, ~c"nomain.erl", ~c"-module(nomain).\n-export([f/0]).\nf() -> ok.\n")

      assert {:error, ~c"~ts: main/1 is not exported", _} =
               catch_throw(:beam_com_build.script(f))
    end

    test "compile error", %{dir: dir} do
      f = write(dir, ~c"bad.erl", ~c"-module(bad).\nmain(_) -> x = .\n")

      assert {:error, ~c"~ts: compilation failed", _} =
               silent(fn -> catch_throw(:beam_com_build.script(f)) end)
    end

    test "a program", %{dir: dir} do
      f =
        write(
          dir,
          ~c"prog.erl",
          ~c"-module(prog).\n-export([main/1]).\nmain(A) -> crypto:hash(sha256, A).\n"
        )

      app = :beam_com_build.script(f)

      assert %{
               name: :prog,
               vsn: ~c"0.1.0",
               script: true,
               beams: [{:prog, _}],
               priv: [],
               config: []
             } = app

      props = Map.fetch!(app, :props)
      assert {:beam_com_script, :prog} == :proplists.get_value(:mod, props)

      assert [:kernel, :stdlib, :beam_com_script] ==
               :proplists.get_value(:applications, props)

      assert [:prog] == :proplists.get_value(:modules, props)
    end
  end

  describe "slashes_test_" do
    test "Windows: backslashes are separators" do
      assert ~c"bin/x.com" == :beam_com_build.slashes(~c"bin\\x.com", {:unix, :windows})
    end

    for {input, output} <- [
          {~c"C:\\a\\b/c", ~c"/C/a/b/c"},
          {~c"d:/x.com", ~c"/d/x.com"},
          {~c"D:", ~c"/D"},
          {~c"D:x", ~c"D:x"}
        ] do
      test "Windows: a drive becomes /C/: #{input}" do
        assert unquote(output) ==
                 :beam_com_build.slashes(unquote(input), {:unix, :windows})
      end
    end

    test "other systems: no change" do
      assert ~c"a\\b" == :beam_com_build.slashes(~c"a\\b", {:unix, :linux})
    end
  end

  # The .yrl, .xrl and ASN.1 files: the builder makes the .erl files.
  @yrl ~c"Nonterminals list elems.\nTerminals '[' ']' int.\nRootsymbol list.\n" ++
         ~c"list -> '[' ']' : [].\nlist -> '[' elems ']' : '$2'.\n" ++
         ~c"elems -> int : [v('$1')].\nelems -> int elems : [v('$1') | '$2'].\n" ++
         ~c"Erlang code.\nv({int, _, V}) -> V.\n"
  @xrl ~c"Definitions.\nD = [0-9]\nRules.\n{D}+ : {token, {int, TokenLine, " ++
         ~c"list_to_integer(TokenChars)}}.\n[\\[\\]] : {token, {list_to_atom(TokenChars), " ++
         ~c"TokenLine}}.\n[\\s]+ : skip_token.\nErlang code.\n"
  @asn1 ~c"Pair DEFINITIONS AUTOMATIC TAGS ::= BEGIN\n" ++
          ~c"P ::= SEQUENCE { a INTEGER, b INTEGER }\nEND\n"

  describe "generate_test_" do
    test "a parser, a scanner and an ASN.1 module", %{dir: dir} do
      d = :filename.join(dir, ~c"gen1")
      write(:filename.join(d, ~c"src"), ~c"lp.yrl", @yrl)
      write(:filename.join(d, ~c"src"), ~c"ls.xrl", @xrl)
      write(:filename.join(d, ~c"asn1"), ~c"pair.asn1", @asn1)
      gen = :filename.join(dir, ~c"gen1out")
      files = :beam_com_build.generate(d, gen)

      assert [~c"Pair.erl", ~c"lp.erl", ~c"ls.erl"] ==
               Enum.sort(for f <- files, do: :filename.basename(f))

      assert :filelib.is_regular(:filename.join(gen, ~c"Pair.hrl"))

      silent(fn ->
        for f <- files do
          {:ok, _} = :compile.file(f, [{:outdir, gen}, {:i, gen}, :report])
        end
      end)

      true = :code.add_patha(gen)
      on_exit(fn -> :code.del_path(gen) end)
      {:ok, tokens, _} = :ls.string(~c"[1 2 3]")
      assert {:ok, [1, 2, 3]} == :lp.parse(tokens)
      {:ok, ber} = :Pair.encode(:P, {:P, 1, 2})
      assert {:ok, {:P, 1, 2}} == :Pair.decode(:P, ber)
    end

    test "an .erl file next to the .yrl or .xrl file is used", %{dir: dir} do
      d = :filename.join(dir, ~c"gen2")
      write(:filename.join(d, ~c"src"), ~c"made.yrl", @yrl)
      write(:filename.join(d, ~c"src"), ~c"made.erl", ~c"-module(made).\n")
      write(:filename.join(d, ~c"src"), ~c"scan.xrl", @xrl)
      write(:filename.join(d, ~c"src"), ~c"scan.erl", ~c"-module(scan).\n")
      assert [] == :beam_com_build.generate(d, :filename.join(dir, ~c"gen2out"))
    end

    test "an application with generated code", %{dir: dir} do
      d = :filename.join(dir, ~c"genapp")

      write(
        :filename.join(d, ~c"src"),
        ~c"genapp.app.src",
        ~c"{application, genapp, [{vsn, \"1.0\"}, {modules, []}]}.\n"
      )

      write(:filename.join(d, ~c"src"), ~c"lp.yrl", @yrl)
      write(:filename.join(d, ~c"src"), ~c"ls.xrl", @xrl)
      write(:filename.join(d, ~c"src"), ~c"pair.asn", @asn1)

      write(
        :filename.join(d, ~c"src"),
        ~c"genapp.erl",
        ~c"-module(genapp).\n-export([f/0]).\n-include(\"Pair.hrl\").\n" ++
          ~c"f() -> #'P'{a = 1, b = 2}.\n"
      )

      before = temp_dirs()
      %{beams: beams, props: props} = silent(fn -> :beam_com_build.app_dir(d) end)
      mods = Enum.sort(for {m, _} <- beams, do: m)
      assert [:Pair, :genapp, :lp, :ls] == mods
      assert mods == Enum.sort(:proplists.get_value(:modules, props))
      # The build removes the temporary directory.
      assert before == temp_dirs()
    end

    test "errors", %{dir: dir} do
      bad = fn name, file, content, error ->
        d = :filename.join(dir, name)
        path = write(:filename.join(d, ~c"src"), file, content)

        assert {:error, ^error, [^path]} =
                 silent(fn ->
                   catch_throw(:beam_com_build.generate(d, :filename.join(d, ~c"out")))
                 end)
      end

      bad.(~c"bady", ~c"bad.yrl", ~c"Nonterminals x.\nRootsymbol y.\n", ~c"~ts: yecc failed")
      bad.(~c"badx", ~c"bad.xrl", ~c"Rules.\n[ : nothing.\n", ~c"~ts: leex failed")

      bad.(
        ~c"bada",
        ~c"bad.asn1",
        ~c"Bad DEFINITIONS ::= BEGIN\nX ::= NOTHING\nEND\n",
        ~c"~ts: the ASN.1 compiler failed"
      )
    end
  end

  describe "app_dir_test_" do
    test "a full application", %{dir: dir} do
      d = :filename.join(dir, ~c"full")

      write(
        :filename.join(d, ~c"src"),
        ~c"full.app.src",
        ~c"{application, full, [{vsn, \"2.3.4\"}, {modules, []},\n" ++
          ~c" {applications, [kernel, stdlib, crypto]}, {mod, {full_app, []}}]}.\n"
      )

      write(
        :filename.join(d, ~c"src"),
        ~c"full_app.erl",
        ~c"-module(full_app).\n-export([value/0]).\n-include(\"full.hrl\").\n" ++
          ~c"value() -> {?FROM_INCLUDE, ?FROM_REBAR, full_sub:v()}.\n"
      )

      write(
        :filename.join([d, ~c"src", ~c"sub"]),
        ~c"full_sub.erl",
        ~c"-module(full_sub).\n-export([v/0]).\n-include(\"local.hrl\").\n" ++
          ~c"v() -> ?LOCAL.\n"
      )

      write(:filename.join(d, ~c"src"), ~c"local.hrl", ~c"-define(LOCAL, local).\n")

      write(
        :filename.join(d, ~c"include"),
        ~c"full.hrl",
        ~c"-define(FROM_INCLUDE, include).\n"
      )

      write(d, ~c"rebar.config", ~c"{erl_opts, [{d, 'FROM_REBAR', rebar}]}.\n")
      write(:filename.join([d, ~c"priv", ~c"data"]), ~c"file.txt", ~c"priv data")
      write(:filename.join(d, ~c"config"), ~c"sys.config", ~c"[{full, [{k, v}]}].")
      write(:filename.join(d, ~c"config"), ~c"vm.args", ~c"-noshell\n+S 1\n")
      app = :beam_com_build.app_dir(d)
      assert %{name: :full, vsn: ~c"2.3.4", script: false} = app
      beams = Map.fetch!(app, :beams)
      assert [:full_app, :full_sub] == Enum.sort(for {m, _} <- beams, do: m)

      for {m, b} <- beams do
        {:module, _} = :code.load_binary(m, ~c"#{m}.beam", b)
      end

      assert {:include, :rebar, :local} == :full_app.value()
      props = Map.fetch!(app, :props)
      assert [:full_app, :full_sub] == Enum.sort(:proplists.get_value(:modules, props))
      assert {:full_app, []} == :proplists.get_value(:mod, props)
      assert [{~c"data/file.txt", "priv data"}] == Map.fetch!(app, :priv)

      assert [{~c"sys.config", "[{full, [{k, v}]}]."}, {~c"vm.args", "-noshell\n+S 1\n"}] ==
               Map.fetch!(app, :config)

      # The files of the application in the zip.
      files = :beam_com_build.app_files(app)
      names = for {n, _} <- files, do: n

      assert [
               ~c"lib/full-2.3.4/ebin/full.app",
               ~c"lib/full-2.3.4/ebin/full_app.beam",
               ~c"lib/full-2.3.4/ebin/full_sub.beam",
               ~c"lib/full-2.3.4/priv/data/file.txt"
             ] == Enum.sort(names)

      {_, app_text} = List.keyfind(files, ~c"lib/full-2.3.4/ebin/full.app", 0)

      {:ok, [{:application, :full, app_props}], _} =
        erl_scan_parse(:erlang.iolist_to_binary(app_text))

      assert ~c"2.3.4" == :proplists.get_value(:vsn, app_props)
    end

    test "ebin/NAME.app", %{dir: dir} do
      d = :filename.join(dir, ~c"ebinapp")

      write(
        :filename.join(d, ~c"ebin"),
        ~c"ebinapp.app",
        ~c"{application, ebinapp, [{vsn, \"1.0\"}, {modules, [old]}]}.\n"
      )

      write(:filename.join(d, ~c"src"), ~c"ebinapp_m.erl", ~c"-module(ebinapp_m).\n")
      app = :beam_com_build.app_dir(d)
      assert %{name: :ebinapp, vsn: ~c"1.0"} = app
      # The module list is the one of the compiled code.
      assert [:ebinapp_m] == :proplists.get_value(:modules, Map.fetch!(app, :props))
    end

    test "no application file", %{dir: dir} do
      d = :filename.join(dir, ~c"noapp")
      :ok = :filelib.ensure_path(:filename.join(d, ~c"src"))

      assert {:error, ~c"~ts: no src/*.app.src or ebin/*.app", _} =
               catch_throw(:beam_com_build.app_dir(d))
    end

    test "bad application file", %{dir: dir} do
      d = :filename.join(dir, ~c"badapp")
      write(:filename.join(d, ~c"src"), ~c"badapp.app.src", ~c"not a term")

      assert {:error, ~c"~ts: not an application file", _} =
               catch_throw(:beam_com_build.app_dir(d))
    end

    test "version from git", %{dir: dir} do
      d = :filename.join(dir, ~c"gitvsn")

      write(
        :filename.join(d, ~c"src"),
        ~c"gitvsn.app.src",
        ~c"{application, gitvsn, [{vsn, git}, {modules, []}]}.\n"
      )

      assert %{vsn: ~c"0.1.0"} = :beam_com_build.app_dir(d)
      props = Map.fetch!(:beam_com_build.app_dir(d), :props)
      assert ~c"0.1.0" == :proplists.get_value(:vsn, props)
    end
  end

  describe "select_apps_test_" do
    test "only kernel and stdlib" do
      assert [:kernel, :stdlib] ==
               select(
                 program(:p, ~c"-module(p). -export([f/0]). f() -> lists:reverse([]).\n"),
                 []
               )
    end

    test "a called module adds its application and what it needs" do
      assert [:asn1, :crypto, :kernel, :public_key, :ssl, :stdlib] ==
               select(program(:p, ~c"-module(p). -export([f/0]). f() -> ssl:start().\n"), [])
    end

    test "-a adds an application" do
      assert [:crypto, :kernel, :stdlib] ==
               select(program(:p, ~c"-module(p). -export([f/0]). f() -> ok.\n"), [:crypto])
    end

    test "included applications" do
      assert [:incl, :inner, :kernel, :stdlib] ==
               select(program(:p, ~c"-module(p). -export([f/0]). f() -> incl:x().\n"), [])
    end

    test "a call to an own module does not add another application" do
      {:ok, m1, b1} =
        :compile.forms(forms(~c"-module(helper). -export([x/0]). x() -> 1.\n"), [:binary])

      {:ok, m2, b2} =
        :compile.forms(forms(~c"-module(p). -export([f/0]). f() -> helper:x().\n"), [:binary])

      app = %{name: :p, props: [], beams: [{m1, b1}, {m2, b2}]}
      assert [:kernel, :stdlib] == select(app, [])
    end

    test "an application with the name of the program is not selected" do
      app = program(:hello, ~c"-module(p). -export([f/0]). f() -> hello:x().\n")

      capture_io(:stderr, fn ->
        assert [:kernel, :stdlib] == select(app, [])
      end)
    end

    test "an unknown application" do
      assert {:error, ~c"the application ~p is not in beam.com", [:nosuch]} ==
               catch_throw(
                 select(program(:p, ~c"-module(p). -export([f/0]). f() -> ok.\n"), [:nosuch])
               )
    end

    test "an unknown application in the .app file" do
      app = %{
        program(:p, ~c"-module(p). -export([f/0]). f() -> ok.\n")
        | props: [{:applications, [:kernel, :missing]}]
      }

      assert {:error, _, [:missing]} = catch_throw(select(app, []))
    end

    test "a call to a module of no application: a warning" do
      {apps, err} =
        with_io(:stderr, fn ->
          select(
            program(
              :p,
              ~c"-module(p). -export([f/0]). " ++
                ~c"f() -> unknown_mod:x(), erlang:self(), prim_file:get_cwd().\n"
            ),
            []
          )
        end)

      assert [:kernel, :stdlib] == apps
      assert "beam.com: warning: p calls unknown_mod, which is not in beam.com\n" == err
    end
  end

  describe "release_test_" do
    test "release files", %{dir: dir} do
      root = fake_root(dir)
      base = :beam_com_build.base_apps(root)
      assert [:crypto, :kernel, :sasl, :stdlib] == Enum.sort(Map.keys(base))

      f =
        write(dir, ~c"relprog.erl", ~c"-module(relprog).\n-export([main/1]).\nmain(_) -> ok.\n")

      app = :beam_com_build.script(f)
      # beam_com_script is not in this fake root: give the release a
      # program application without it.
      app1 = %{
        app
        | props:
            :lists.keystore(
              :applications,
              1,
              Map.fetch!(app, :props),
              {:applications, [:kernel, :stdlib]}
            )
      }

      tmp = :filename.join(dir, ~c"rel.tmp")
      files = :beam_com_build.release(app1, [:kernel, :stdlib], base, tmp, root)
      names = for {n, _} <- files, do: n

      assert [
               ~c"releases/0.1.0/relprog.rel",
               ~c"releases/0.1.0/start.boot",
               ~c"releases/0.1.0/vm.args",
               ~c"releases/start_erl.data"
             ] == Enum.sort(names)

      {_, boot} = List.keyfind(files, ~c"releases/0.1.0/start.boot", 0)
      {:script, {~c"relprog", ~c"0.1.0"}, cmds} = :erlang.binary_to_term(boot)
      paths = Enum.concat(for {:path, p} <- cmds, do: p)
      assert length(paths) >= 3
      for p <- paths, do: assert(~c"$ROOT/lib/" ++ _ = p)
      assert Enum.member?(paths, ~c"$ROOT/lib/relprog-0.1.0/ebin")
      {_, data} = List.keyfind(files, ~c"releases/start_erl.data", 0)

      assert :erlang.system_info(:version) ++ ~c" 0.1.0\n" ==
               :erlang.binary_to_list(:erlang.iolist_to_binary(data))

      {_, vm_args} = List.keyfind(files, ~c"releases/0.1.0/vm.args", 0)
      assert "-noshell\n" == :erlang.iolist_to_binary(vm_args)
      {_, rel_text} = List.keyfind(files, ~c"releases/0.1.0/relprog.rel", 0)

      {:ok, [{:release, {~c"relprog", ~c"0.1.0"}, {:erts, _}, rel_apps}], _} =
        erl_scan_parse(:erlang.iolist_to_binary(rel_text))

      assert [:kernel, :stdlib, :relprog] == for({a, _} <- rel_apps, do: a)
    end

    @tag timeout: 120_000
    test "run/1 from end to end", %{dir: dir} do
      {root, exe} = prepare(dir)

      f =
        write(
          dir,
          ~c"hasher.erl",
          ~c"-module(hasher).\n-export([main/1]).\nmain(A) -> crypto:hash(sha256, A).\n"
        )

      out = :filename.join(dir, ~c"hasher.com")

      :ok =
        silent(fn ->
          :beam_com_build.run(%{input: f, apps: [], output: out, root: root, exe: exe})
        end)

      {:ok, bin} = :file.read_file(out)
      names = :beam_com_zip.entries(bin)
      crypto = ~c"lib/crypto-" ++ app_vsn(:crypto) ++ ~c"/"
      kernel = ~c"lib/kernel-" ++ app_vsn(:kernel) ++ ~c"/"
      has = fn prefix -> Enum.any?(names, &:lists.prefix(prefix, &1)) end

      for p <- [
            crypto ++ ~c"ebin/",
            kernel ++ ~c"ebin/",
            ~c"lib/beam_com_script-0.1.0/ebin/",
            ~c"lib/hasher-0.1.0/ebin/hasher.beam",
            ~c"releases/0.1.0/start.boot",
            ~c"releases/start_erl.data",
            ~c"bin/start_clean.boot",
            ~c"usr/share/zoneinfo/UTC",
            ~c".symtab.amd64"
          ] do
        assert has.(p), "#{p}"
      end

      # No edge part: this fake root has no wasm_host.
      for p <- [
            ~c"lib/beam_com/",
            ~c"lib/sasl-",
            crypto ++ ~c"include/",
            ~c".args",
            ~c".allow",
            ~c".wasm/"
          ] do
        refute has.(p), "#{p}"
      end

      # The build replaced the old release, and stdlib reads the new file.
      {:ok, files} = :zip.unzip(bin, [:memory])

      assert <<:erlang.list_to_binary(:erlang.system_info(:version))::binary, " 0.1.0\n">> ==
               :proplists.get_value(~c"releases/start_erl.data", files)

      assert "MZqFpD image bytes" == :binary.part(bin, 0, 18)
      {:ok, info} = :file.read_file_info(out)
      assert 0o755 == (elem(info, 7) &&& 0o777)
      # No temporary directory is left.
      assert [] == :filelib.wildcard(:filename.join(dir, ~c".*.tmp"))
    end

    @tag timeout: 120_000
    test "run/1 with an application directory", %{dir: dir} do
      {root, exe} = prepare(dir)
      d = :filename.join(dir, ~c"svc")

      # A minimal .app.src: no description, registered or applications.
      write(
        :filename.join(d, ~c"src"),
        ~c"svc.app.src",
        ~c"{application, svc, [{vsn, \"1.2.0\"}]}.\n"
      )

      write(:filename.join(d, ~c"src"), ~c"svc.erl", ~c"-module(svc).\n")
      write(:filename.join(d, ~c"config"), ~c"sys.config", ~c"[].")
      out = :filename.join(dir, ~c"svc.com")

      :ok =
        silent(fn ->
          :beam_com_build.run(%{input: d ++ ~c"/", apps: [], output: out, root: root, exe: exe})
        end)

      {:ok, bin} = :file.read_file(out)
      {:ok, files} = :zip.unzip(bin, [:memory])
      assert "[]." == :proplists.get_value(~c"releases/1.2.0/sys.config", files)
      assert "-noshell\n" == :proplists.get_value(~c"releases/1.2.0/vm.args", files)

      refute :lists.keymember(
               ~c"lib/crypto-" ++ app_vsn(:crypto) ++ ~c"/ebin/crypto.app",
               1,
               files
             )
    end

    # An application with the deps of rebar.config, from a server in place
    # of hex.pm: alpha needs beta, and the application uses a header of
    # alpha with include_lib.
    @tag timeout: 120_000
    test "run/1 with Hex packages", %{dir: dir} do
      {root, exe} = prepare(dir)

      app = fn n, v, deps ->
        :io_lib.format(
          ~c"{application, ~s, [{description, \"\"}, {vsn, ~p}," ++
            ~c" {registered, []}, {applications, [kernel, stdlib~s]}]}.~n",
          [n, v, for(d <- deps, do: ~c", " ++ d)]
        )
      end

      beta =
        HexFixture.package(
          "beta",
          ~c"0.2.0",
          [
            {~c"src/beta.app.src", app.(~c"beta", ~c"0.2.0", [])},
            {~c"src/beta.erl", ~c"-module(beta).\n-export([f/0]).\nf() -> beta.\n"}
          ],
          [],
          ["rebar3"]
        )

      alpha =
        HexFixture.package(
          "alpha",
          ~c"1.1.0",
          [
            {~c"src/alpha.app.src", app.(~c"alpha", ~c"1.1.0", [~c"beta"])},
            {~c"src/alpha.erl", ~c"-module(alpha).\n-export([f/0]).\nf() -> beta:f().\n"},
            {~c"include/alpha.hrl", ~c"-define(ALPHA, alpha_macro).\n"},
            # The rebar3 options of the package: warnings are not errors.
            {~c"rebar.config", ~c"{erl_opts, [warnings_as_errors]}.\n"},
            {~c"src/alpha_warn.erl", ~c"-module(alpha_warn).\nf() -> ok.\n"}
          ],
          [{"beta", ~c"~> 0.2.0"}],
          ["rebar3"]
        )

      {pid, port} =
        HexFixture.serve(
          HexFixture.routes([
            {"alpha", ~c"1.1.0", [{"beta", ~c"~> 0.2.0"}], alpha},
            {"beta", ~c"0.2.0", [], beta}
          ])
        )

      url = ~c"http://127.0.0.1:" ++ :erlang.integer_to_list(port)

      env = [
        {~c"HEX_API_URL", url ++ ~c"/api"},
        {~c"HEX_MIRROR", url ++ ~c"/repo"},
        {~c"BEAM_COM_CACHE", :filename.join(dir, ~c"hexcache")}
      ]

      for {k, v} <- env, do: :os.putenv(k, v)

      try do
        d = :filename.join(dir, ~c"web")
        write(d, ~c"rebar.config", ~c"{deps, [{alpha, \"~> 1.0\"}]}.\n")
        write(:filename.join(d, ~c"src"), ~c"web.app.src", app.(~c"web", ~c"1.0.0", [~c"alpha"]))

        write(
          :filename.join(d, ~c"src"),
          ~c"web.erl",
          ~c"-module(web).\n-export([f/0]).\n-include_lib(\"alpha/include/alpha.hrl\").\n" ++
            ~c"f() -> {?ALPHA, alpha:f()}.\n"
        )

        out = :filename.join(dir, ~c"web.com")

        :ok =
          silent(fn ->
            :beam_com_build.run(%{input: d, apps: [], output: out, root: root, exe: exe})
          end)

        {:ok, files} = :zip.unzip(elem(:file.read_file(out), 1), [:memory])
        beam = fn p -> :proplists.get_value(p, files) end

        for p <- [
              ~c"lib/alpha-1.1.0/ebin/alpha.beam",
              ~c"lib/alpha-1.1.0/ebin/alpha.app",
              ~c"lib/alpha-1.1.0/ebin/alpha_warn.beam",
              ~c"lib/beta-0.2.0/ebin/beta.beam",
              ~c"lib/web-1.0.0/ebin/web.beam"
            ] do
          assert is_binary(beam.(p)), "#{p}"
        end

        {:ok, [{:release, _, _, rel}], _} =
          erl_scan_parse(:proplists.get_value(~c"releases/1.0.0/web.rel", files))

        assert {:alpha, ~c"1.1.0"} == List.keyfind(rel, :alpha, 0)
        assert {:beta, ~c"0.2.0"} == List.keyfind(rel, :beta, 0)
        # The code works: web uses the macro of alpha, and alpha calls beta.
        for {m, p} <- [
              {:beta, ~c"lib/beta-0.2.0/ebin/beta.beam"},
              {:alpha, ~c"lib/alpha-1.1.0/ebin/alpha.beam"},
              {:web, ~c"lib/web-1.0.0/ebin/web.beam"}
            ] do
          {:module, ^m} = :code.load_binary(m, ~c"#{m}.beam", beam.(p))
        end

        assert {:alpha_macro, :beta} == :web.f()
        assert :filelib.is_regular(:filename.join(d, ~c"rebar.lock"))
        # No package is left in the code path.
        assert [] ==
                 for(
                   p <- :code.get_path(),
                   :string.find(p, ~c"beam_com_deps_") != :nomatch,
                   do: p
                 )
      after
        for m <- [:web, :alpha, :beta], do: :code.purge(m) and :code.delete(m)
        for {k, _} <- env, do: :os.unsetenv(k)
        HexFixture.stop(pid)
      end
    end

    test "run/1 with an error", %{dir: dir} do
      {root, exe} = prepare(dir)

      f =
        write(
          dir,
          ~c"needs.erl",
          ~c"-module(needs).\n-export([main/1]).\nmain(_) -> ssl:start().\n"
        )

      out = :filename.join(dir, ~c"needs.com")

      assert {:error, ~c"the application ~p is not in beam.com", [:nosuch]} ==
               quiet(fn ->
                 catch_throw(
                   :beam_com_build.run(%{
                     input: f,
                     apps: [:nosuch],
                     output: out,
                     root: root,
                     exe: exe
                   })
                 )
               end)

      refute :filelib.is_file(out)
      assert [] == :filelib.wildcard(:filename.join(dir, ~c".*.tmp"))

      ok_erl = write(dir, ~c"ok.erl", ~c"-module(ok).\n-export([main/1]).\nmain(_) -> 1.\n")

      assert {:error, ~c"~ts: ~ts", _} =
               quiet(fn ->
                 catch_throw(
                   :beam_com_build.run(%{
                     input: ok_erl,
                     apps: [],
                     output: out,
                     root: root,
                     exe: :filename.join(dir, ~c"missing.com")
                   })
                 )
               end)

      # A native file (assimilated) as the base, without --target: an
      # error before the compilation, and no output.
      {:ok, ape} = :file.read_file(exe)
      elf = :filename.join(dir, ~c"beam-elf.com")

      :ok =
        :file.write_file(
          elf,
          <<127, "ELF", 2, 1, 1, 0, 0::64, 2::little-16, 0x3E::little-16,
            :binary.part(ape, 20, byte_size(ape) - 20)::binary>>
        )

      assert {:error,
              ~c"this is a native file (~ts), not an APE file: a program built " ++
                ~c"from it runs only on this system." ++ _, [_]} =
               quiet(fn ->
                 catch_throw(
                   :beam_com_build.run(%{input: f, apps: [], output: out, root: root, exe: elf})
                 )
               end)

      assert {:error,
              ~c"this is a native file (~ts), not an APE file: it cannot make " ++
                ~c"a file for ~ts." ++ _, [_, ~c"aarch64-unknown-linux-gnu"]} =
               quiet(fn ->
                 catch_throw(
                   :beam_com_build.run(%{
                     input: f,
                     apps: [],
                     output: out,
                     root: root,
                     exe: elf,
                     target: ~c"aarch64-unknown-linux-gnu"
                   })
                 )
               end)

      refute :filelib.is_file(out)
    end

    # The --allow-* flags write /zip/.allow, which beam_com.c reads at
    # start.
    @tag timeout: 120_000
    test "run/1 with a sandbox", %{dir: dir} do
      {root, exe} = prepare(dir)
      f = write(dir, ~c"boxed.erl", ~c"-module(boxed).\n-export([main/1]).\nmain(_) -> ok.\n")
      out = :filename.join(dir, ~c"boxed.com")

      build = fn allow ->
        :ok =
          silent(fn ->
            :beam_com_build.run(%{
              input: f,
              apps: [],
              output: out,
              root: root,
              exe: exe,
              allow: allow
            })
          end)

        {:ok, files} = :zip.unzip(elem(:file.read_file(out), 1), [:memory])
        :proplists.get_value(~c".allow", files)
      end

      assert "read=/etc,/srv\nwrite\nnet\nrun=git\n" ==
               build.(%{run: [~c"git"], net: true, write: :all, read: [~c"/etc", ~c"/srv"]})

      assert "net\n" == build.(%{net: true})
      # --allow-all wins over the others.
      assert "all\n" == build.(%{all: true, net: true})
      # Without flags, no file (no sandbox).
      :ok =
        silent(fn ->
          :beam_com_build.run(%{input: f, apps: [], output: out, root: root, exe: exe})
        end)

      {:ok, files2} = :zip.unzip(elem(:file.read_file(out), 1), [:memory])
      assert :undefined == :proplists.get_value(~c".allow", files2)
    end

    @tag timeout: 120_000
    test "run/1 errors and warnings", %{dir: dir} do
      {root, exe} = prepare(dir)
      ok_erl = write(dir, ~c"edge.erl", ~c"-module(edge).\n-export([main/1]).\nmain(_) -> ok.\n")
      # Without the path of the executable (it comes from beam_com.c).
      assert {:error, ~c"the path of beam.com is not known", []} ==
               catch_throw(
                 :beam_com_build.run(%{
                   input: ok_erl,
                   apps: [],
                   root: root,
                   output: :filename.join(dir, ~c"edge.com")
                 })
               )

      # The output is a directory.
      out_dir = :filename.join(dir, ~c"outdir")
      :ok = :filelib.ensure_path(out_dir)

      assert {:error, ~c"~ts: ~ts", [^out_dir, _]} =
               silent(fn ->
                 catch_throw(
                   :beam_com_build.run(%{
                     input: ok_erl,
                     apps: [],
                     output: out_dir,
                     root: root,
                     exe: exe
                   })
                 )
               end)

      # A module with the name of an OTP module: systools refuses it.
      clash = :filename.join(dir, ~c"clash")

      write(
        :filename.join(clash, ~c"src"),
        ~c"clash.app.src",
        ~c"{application, clash, [{vsn, \"1\"}]}.\n"
      )

      write(:filename.join(clash, ~c"src"), ~c"lists.erl", ~c"-module(lists).\n")

      assert {:error, ~c"systools: ~ts", _} =
               silent(fn ->
                 catch_throw(
                   :beam_com_build.run(%{
                     input: clash,
                     apps: [],
                     output: :filename.join(dir, ~c"clash.com"),
                     root: root,
                     exe: exe
                   })
                 )
               end)

      # Compiler warnings, returned (return_warnings in rebar.config).
      warn = :filename.join(dir, ~c"warn")

      write(
        :filename.join(warn, ~c"src"),
        ~c"warn.app.src",
        ~c"{application, warn, [{vsn, \"1\"}]}.\n"
      )

      write(
        :filename.join(warn, ~c"src"),
        ~c"warn.erl",
        ~c"-module(warn).\n-export([f/0]).\nf() -> X = 1, ok.\n"
      )

      write(warn, ~c"rebar.config", ~c"{erl_opts, [return_warnings]}.\n")
      app = silent(fn -> :beam_com_build.app_dir(warn) end)
      assert %{beams: [{:warn, _}]} = app
    end
  end

  # The edge part of a native file (.wasm/ in its zip): what the
  # WebAssembly runtime needs beyond the native release.
  describe "edge_test_" do
    @tag timeout: 120_000
    test "run/1: the edge part, at the end of the zip", %{dir: dir} do
      {root, exe} = edge_prepare(dir)
      out = edge_build(dir, root, exe, %{})
      {:ok, bin} = :file.read_file(out)
      names = :beam_com_zip.entries(bin)
      edge = Enum.filter(names, &:lists.prefix(~c".wasm/", &1))

      # The edge part is the last part of the central directory, so a
      # reader gets both with one read at the end of the file.
      assert edge == Enum.take(names, -length(edge))

      for p <- [
            ~c".wasm/.release.json",
            ~c".wasm/releases/0.1.0/start.boot",
            ~c".wasm/lib/wasm_host-0.1.0/ebin/wasm_host.app",
            ~c".wasm/lib/wasm_host-0.1.0/ebin/wasm_tcp.beam",
            ~c".wasm/lib/wasm_host-0.1.0/ebin/wasm.beam"
          ] do
        assert p in edge, "#{p}"
      end

      # The files of the native release that the runtime reads as they
      # are: not in the edge part.
      for p <- edge do
        refute :lists.prefix(~c".wasm/lib/kernel-", p) or :lists.prefix(~c".wasm/lib/hasher-", p),
               "#{p}"
      end

      {:ok, files} = :zip.unzip(bin, [:memory])
      meta = :json.decode(:proplists.get_value(~c".wasm/.release.json", files))
      assert %{"name" => "hasher", "vsn" => "0.1.0", "sql" => false} = meta
      assert meta["runtime"] == Base.encode16(:crypto.hash(:sha256, "the runtime"), case: :lower)
      assert meta["snapshot_key"] =~ ~r/\A[0-9a-f]{64}\z/
      assert meta["otp"] == to_string(:beam_com.otp_version())
      assert ["-mode", "interactive", "-boot", "/app/releases/0.1.0/start" | _] = meta["args"]

      # The boot script of the runtime starts wasm_host; the native one
      # does not change.
      started = fn boot ->
        {:script, _, cmds} = :erlang.binary_to_term(boot)
        for {:apply, {:application, :start_boot, [a | _]}} <- cmds, do: a
      end

      assert :wasm_host in started.(
               :proplists.get_value(~c".wasm/releases/0.1.0/start.boot", files)
             )

      refute :wasm_host in started.(:proplists.get_value(~c"releases/0.1.0/start.boot", files))
    end

    @tag timeout: 120_000
    test "run/1 with --no-edge: no edge part", %{dir: dir} do
      {root, exe} = edge_prepare(dir)
      out = edge_build(dir, root, exe, %{edge: false})
      {:ok, bin} = :file.read_file(out)
      assert [] == Enum.filter(:beam_com_zip.entries(bin), &:lists.prefix(~c".wasm/", &1))

      assert {:error, ~c"--no-edge is for native files, not for --target wasm32", []} ==
               catch_throw(
                 :beam_com_build.run(%{
                   input: ~c"x.erl",
                   apps: [],
                   output: ~c"x",
                   root: root,
                   exe: exe,
                   edge: false,
                   target: ~c"wasm32-unknown-emscripten"
                 })
               )
    end

    # wasm_host with no runtime (no beam.wasm in the zip, the cache or
    # BEAM_COM_WASM_RUNTIME): the native file has no edge part.
    @tag timeout: 120_000
    test "run/1 with no runtime: no edge part", %{dir: dir} do
      {root, exe} = edge_prepare(dir)

      :ok =
        :file.del_dir_r(
          :filename.join([root, ~c"lib", ~c"wasm_host-0.1.0", ~c"priv", ~c"runtime"])
        )

      old = System.get_env("BEAM_COM_CACHE")
      System.put_env("BEAM_COM_CACHE", Path.join(List.to_string(dir), "empty-cache"))

      try do
        out = edge_build(dir, root, exe, %{})
        {:ok, bin} = :file.read_file(out)
        assert [] == Enum.filter(:beam_com_zip.entries(bin), &:lists.prefix(~c".wasm/", &1))
      after
        if old,
          do: System.put_env("BEAM_COM_CACHE", old),
          else: System.delete_env("BEAM_COM_CACHE")
      end
    end

    # A release directory of "mix release": its applications, the
    # applications of the zip that it names, and the variables of its
    # start script.
    @tag timeout: 120_000
    test "run/1 with a Mix release directory", %{dir: dir} do
      {root, exe} = edge_prepare(dir)
      rel = mix_release(dir, [{:kernel, app_vsn(:kernel)}, {:stdlib, app_vsn(:stdlib)}])
      out = :filename.join(dir, ~c"myrel.com")

      :ok =
        silent(fn ->
          :beam_com_build.run(%{input: rel, apps: [], output: out, root: root, exe: exe})
        end)

      {:ok, bin} = :file.read_file(out)
      {:ok, files} = :zip.unzip(bin, [:memory])
      names = :beam_com_zip.entries(bin)
      has = fn prefix -> Enum.any?(names, &:lists.prefix(prefix, &1)) end

      for p <- [
            ~c"lib/myapp-1.0.0/ebin/myapp.beam",
            ~c"lib/myapp-1.0.0/priv/data.txt",
            ~c"lib/kernel-" ++ app_vsn(:kernel) ++ ~c"/ebin/",
            ~c"releases/1.0.0/runtime.exs",
            ~c"releases/1.0.0/consolidated/Elixir.Proto.beam",
            ~c"releases/1.0.0/myrel.rel",
            ~c"releases/start_erl.data"
          ] do
        assert has.(p), "#{p}"
      end

      for p <- [
            ~c"releases/1.0.0/env.sh",
            ~c"releases/1.0.0/start.script",
            ~c"bin/myrel",
            ~c"tmp/"
          ] do
        refute has.(p), "#{p}"
      end

      # The variables of the start script, before the config providers.
      {:script, _, cmds} =
        :erlang.binary_to_term(:proplists.get_value(~c"releases/1.0.0/start.boot", files))

      provider = Enum.find_index(cmds, &(&1 == {:apply, {:"Elixir.Config.Provider", :boot, []}}))

      assert [
               {:apply, {:os, :putenv, [~c"RELEASE_ROOT", ~c"/zip"]}},
               {:apply, {:os, :putenv, [~c"RELEASE_NAME", ~c"myrel"]}},
               {:apply, {:os, :putenv, [~c"RELEASE_VSN", ~c"1.0.0"]}},
               {:apply, {:os, :putenv, [~c"RELEASE_PROG", ~c"myrel"]}},
               {:apply, {:os, :putenv, [~c"RELEASE_MODE", ~c"interactive"]}},
               {:apply, {:os, :putenv, [~c"RELEASE_SYS_CONFIG", ~c"/zip/releases/1.0.0/sys"]}}
             ] == Enum.slice(cmds, provider - 6, 6)

      assert "## the vm.args of the release\n\n-noshell\n-boot_var RELEASE_LIB /zip/lib\n" ==
               :proplists.get_value(~c"releases/1.0.0/vm.args", files)

      # The runtime gets the files of the release as they are.
      assert "## the vm.args of the release\n" ==
               :proplists.get_value(~c".wasm/releases/1.0.0/vm.args", files)

      assert "[]." == :proplists.get_value(~c".wasm/tmp/run.runtime.config", files)

      {:script, _, edge_cmds} =
        :erlang.binary_to_term(:proplists.get_value(~c".wasm/releases/1.0.0/start.boot", files))

      assert [] == for({:apply, {:os, :putenv, _}} = c <- edge_cmds, do: c)
      assert {:apply, {:application, :start_boot, [:wasm_host, :permanent]}} in edge_cmds

      meta = :json.decode(:proplists.get_value(~c".wasm/.release.json", files))
      assert %{"name" => "myrel", "vsn" => "1.0.0"} = meta
      assert "/app/tmp/run.runtime" in meta["args"]
    end

    # A rebar3 release (no env.sh): its files do not change.
    @tag timeout: 120_000
    test "run/1 with a rebar3 release directory", %{dir: dir} do
      {root, exe} = edge_prepare(dir)
      rel = mix_release(dir, [{:kernel, app_vsn(:kernel)}, {:stdlib, app_vsn(:stdlib)}])
      :ok = :file.delete(:filename.join([rel, ~c"releases", ~c"1.0.0", ~c"env.sh"]))
      out = :filename.join(dir, ~c"myrel.com")

      :ok =
        silent(fn ->
          :beam_com_build.run(%{input: rel, apps: [], output: out, root: root, exe: exe})
        end)

      {:ok, bin} = :file.read_file(out)
      {:ok, files} = :zip.unzip(bin, [:memory])

      assert "## the vm.args of the release\n" ==
               :proplists.get_value(~c"releases/1.0.0/vm.args", files)

      {:script, _, cmds} =
        :erlang.binary_to_term(:proplists.get_value(~c"releases/1.0.0/start.boot", files))

      assert [] == for({:apply, {:os, :putenv, _}} = c <- cmds, do: c)
      refute :lists.keymember(~c".wasm/tmp/run.runtime.config", 1, files)
      refute :lists.keymember(~c".wasm/releases/1.0.0/vm.args", 1, files)
    end

    test "run/1 with a release that names an application that is nowhere", %{dir: dir} do
      {root, exe} = edge_prepare(dir)
      rel = mix_release(dir, [{:kernel, app_vsn(:kernel)}, {:stdlib, ~c"0.0.0-none"}])
      out = :filename.join(dir, ~c"myrel.com")

      assert {:error, ~c"~ts is not in the release or in ~ts", [~c"stdlib-0.0.0-none", _]} =
               catch_throw(
                 :beam_com_build.run(%{input: rel, apps: [], output: out, root: root, exe: exe})
               )

      refute :filelib.is_regular(out)
    end
  end

  describe "allow_test_" do
    for {flags, allow} <- [
          {[~c"--allow-read"], %{read: :all}},
          {[~c"-R"], %{read: :all}}
        ] do
      test "#{Enum.join(flags, " ")}" do
        assert unquote(Macro.escape(allow)) == allow(unquote(flags))
      end
    end

    test "a list, then all" do
      assert %{read: :all} == allow([~c"--allow-read=/a", ~c"-R"])
    end

    test "all, then a list" do
      assert %{read: :all} == allow([~c"-R", ~c"--allow-read=/a"])
    end

    test "lists add up, without duplicates" do
      assert %{write: [~c"/a", ~c"/b"]} == allow([~c"--allow-write=/a", ~c"--allow-write=/b,/a"])
    end

    for {flags, allow} <- [
          {[~c"-N"], %{net: true}},
          {[~c"--allow-run=git,/bin/sh"], %{run: [~c"git", ~c"/bin/sh"]}},
          {[~c"-A"], %{all: true}}
        ] do
      test "#{Enum.join(flags, " ")}" do
        assert unquote(Macro.escape(allow)) == allow(unquote(flags))
      end
    end

    test "--allow-all= is unknown" do
      assert {:error, ~c"unknown option ~ts", [~c"--allow-all=x"]} ==
               catch_throw(allow([~c"--allow-all=x"]))
    end
  end

  # --target: a small APE-like file with the parts of the shell script that
  # assimilate reads (tests/run.sh compares with real files).
  describe "target_test_" do
    test "x86_64 Linux: the ELF header with OS ABI 0, the rest the same" do
      assert <<elf(0x3E, 0)::binary, rest(ape(), 64)::binary>> ==
               native(~c"x86_64-unknown-linux-gnu")
    end

    test "aarch64 Linux" do
      assert <<elf(0xB7, 0)::binary, rest(ape(), 64)::binary>> ==
               native(~c"aarch64-unknown-linux-gnu")
    end

    test "FreeBSD keeps OS ABI 9" do
      assert <<elf(0x3E, 9)::binary, rest(ape(), 64)::binary>> ==
               native(~c"x86_64-unknown-freebsd")
    end

    test "macOS x86_64: the Mach-O header from the dd command" do
      assert <<macho()::binary, rest(ape(), byte_size(macho()))::binary>> ==
               native(~c"x86_64-apple-darwin")
    end

    test "the same size: the offsets of the zip do not change" do
      assert byte_size(ape()) == byte_size(native(~c"x86_64-apple-darwin"))
    end

    test "no header for the CPU" do
      assert {:error, ~c"no ELF header for this CPU in the APE file", []} ==
               catch_throw(:beam_com_build.native(~c"x86_64-unknown-linux-gnu", "MZqFpD='\n'\n"))
    end

    test "no Mach-O header" do
      assert {:error, ~c"no Mach-O header for this CPU in the APE file", []} ==
               catch_throw(:beam_com_build.native(~c"x86_64-apple-darwin", script()))
    end

    test "the format of the base: the APE file" do
      assert :ape == :beam_com_build.base_kind(ape())
    end

    test "the format of the base: the jartsr prefix" do
      assert :ape == :beam_com_build.base_kind("jartsr='\n")
    end

    test "the format of the base: ELF x86_64" do
      assert {:elf, 0x3E, 0} == :beam_com_build.base_kind(elf(0x3E, 0))
    end

    test "the format of the base: ELF aarch64 with OS ABI 9" do
      assert {:elf, 0xB7, 9} == :beam_com_build.base_kind(elf(0xB7, 9))
    end

    test "the format of the base: Mach-O" do
      assert {:macho, 0x01000007} == :beam_com_build.base_kind(macho())
    end

    test "the format of the base: a zip file" do
      assert :unknown == :beam_com_build.base_kind("PK zip")
    end

    test "the format of the base: no bytes" do
      assert :unknown == :beam_com_build.base_kind("")
    end

    test "a native base of the CPU of the target: the same file: ELF for Linux" do
      assert <<elf(0x3E, 0)::binary, tail()::binary>> ==
               :beam_com_build.native(
                 ~c"x86_64-unknown-linux-gnu",
                 <<elf(0x3E, 0)::binary, tail()::binary>>
               )
    end

    test "a native base of the CPU of the target: the same file: OS ABI 9 for Linux" do
      assert <<elf(0x3E, 0)::binary, tail()::binary>> ==
               :beam_com_build.native(
                 ~c"x86_64-unknown-linux-gnu",
                 <<elf(0x3E, 9)::binary, tail()::binary>>
               )
    end

    test "a native base of the CPU of the target: the same file: OS ABI 0 for FreeBSD" do
      assert <<elf(0x3E, 9)::binary, tail()::binary>> ==
               :beam_com_build.native(
                 ~c"x86_64-unknown-freebsd",
                 <<elf(0x3E, 0)::binary, tail()::binary>>
               )
    end

    test "a native base of the CPU of the target: the same file: Mach-O for macOS" do
      assert <<macho()::binary, tail()::binary>> ==
               :beam_com_build.native(
                 ~c"x86_64-apple-darwin",
                 <<macho()::binary, tail()::binary>>
               )
    end

    test "a native base: an error without --target, or for another CPU: APE, no target" do
      assert :ok == :beam_com_build.check_base(ape(), :none)
    end

    test "a native base: an error without --target, or for another CPU: APE, macOS" do
      assert :ok == :beam_com_build.check_base(ape(), ~c"x86_64-apple-darwin")
    end

    test "a native base: an error without --target, or for another CPU: zip, no target" do
      assert :ok == :beam_com_build.check_base("PK zip", :none)
    end

    test "a native base: an error without --target, or for another CPU: ELF, Linux" do
      assert :ok == :beam_com_build.check_base(elf(0x3E, 0), ~c"x86_64-unknown-linux-gnu")
    end

    test "a native base: an error without --target, or for another CPU: ELF, FreeBSD" do
      assert :ok == :beam_com_build.check_base(elf(0x3E, 0), ~c"x86_64-unknown-freebsd")
    end

    test "a native base: an error without --target, or for another CPU: Mach-O, macOS" do
      assert :ok == :beam_com_build.check_base(macho(), ~c"x86_64-apple-darwin")
    end

    test "a native base: an error without --target, or for another CPU: ELF, no target" do
      assert {:error,
              ~c"this is a native file (~ts), not an APE file: a program built " ++
                ~c"from it runs only on this system. Build with the APE file of " ++
                ~c"beam.com, or give --target to make a native file", [[~c"ELF, ", ~c"x86_64"]]} ==
               catch_throw(:beam_com_build.check_base(elf(0x3E, 0), :none))
    end

    test "a native base: an error without --target, or for another CPU: Mach-O, no target" do
      assert {:error, _, [[~c"Mach-O, ", ~c"x86_64"]]} =
               catch_throw(:beam_com_build.check_base(macho(), :none))
    end

    test "a native base: an error without --target, or for another CPU: ELF, aarch64 Linux" do
      assert {:error,
              ~c"this is a native file (~ts), not an APE file: it cannot make " ++
                ~c"a file for ~ts. Build with the APE file of beam.com",
              [[~c"ELF, ", ~c"x86_64"], ~c"aarch64-unknown-linux-gnu"]} ==
               catch_throw(
                 :beam_com_build.check_base(elf(0x3E, 0), ~c"aarch64-unknown-linux-gnu")
               )
    end

    test "a native base: an error without --target, or for another CPU: ELF aarch64, macOS" do
      assert {:error, _, [[~c"ELF, ", ~c"aarch64"], ~c"x86_64-apple-darwin"]} =
               catch_throw(:beam_com_build.check_base(elf(0xB7, 0), ~c"x86_64-apple-darwin"))
    end

    test "a native base: an error without --target, or for another CPU: Mach-O, Linux" do
      assert {:error, _, [[~c"Mach-O, ", ~c"x86_64"], ~c"x86_64-unknown-linux-gnu"]} =
               catch_throw(:beam_com_build.check_base(macho(), ~c"x86_64-unknown-linux-gnu"))
    end

    for {name, triple} <- [
          {~c"x86_64-unknown-linux-gnu", ~c"x86_64-unknown-linux-gnu"},
          {~c"x86_64-linux", ~c"x86_64-unknown-linux-gnu"},
          {~c"aarch64-linux", ~c"aarch64-unknown-linux-gnu"},
          {~c"x86_64-freebsd", ~c"x86_64-unknown-freebsd"},
          {~c"x86_64-macos", ~c"x86_64-apple-darwin"},
          {~c"x86_64-apple-darwin", ~c"x86_64-apple-darwin"}
        ] do
      test "the triples, and the short names: #{name}" do
        assert unquote(triple) == :beam_com_build.check_target(unquote(name))
      end
    end

    test "Apple Silicon" do
      assert {:error, ~c"~ts: Apple Silicon has no native form" ++ _, [~c"aarch64-apple-darwin"]} =
               catch_throw(:beam_com_build.check_target(~c"aarch64-apple-darwin"))
    end

    test "an unknown target" do
      assert {:error, ~c"unknown target ~ts (one of: ~ts)", [~c"linux-x86_64", _]} =
               catch_throw(:beam_com_build.check_target(~c"linux-x86_64"))
    end
  end

  # The entry of an application program (--main, rebar.config, mix.exs),
  # the priv directories that the program copies at start, and the order
  # of compilation.
  describe "entry_test_" do
    test "the tool of a directory", %{dir: dir} do
      rebar = :filename.join(dir, ~c"t_rebar")
      write(rebar, ~c"rebar.config", ~c"{erl_opts, []}.\n")
      assert :rebar == :beam_com_build.tool(rebar, %{})
      src = :filename.join(dir, ~c"t_src")
      write(:filename.join(src, ~c"src"), ~c"t.app.src", ~c"{application, t, []}.\n")
      assert :rebar == :beam_com_build.tool(src, %{})
      mix = :filename.join(dir, ~c"t_mix")
      write(mix, ~c"mix.exs", ~c"defmodule T.MixProject do\nend\n")
      assert :mix == :beam_com_build.tool(mix, %{})
      # Both: rebar, unless --tool mix.
      write(rebar, ~c"mix.exs", ~c"defmodule T.MixProject do\nend\n")
      assert :rebar == :beam_com_build.tool(rebar, %{})
      assert :mix == :beam_com_build.tool(rebar, %{tool: :mix})
      assert :rebar == :beam_com_build.tool(:filename.join(dir, ~c"none"), %{})
    end

    test "the escript of rebar.config", %{dir: dir} do
      main = fn config ->
        d =
          :filename.join(
            dir,
            ~c"e" ++ :erlang.integer_to_list(System.unique_integer([:positive]))
          )

        write(d, ~c"rebar.config", config)
        :beam_com_build.main(d, %{}, %{beams: [{:m, beam(:m, true)}, {:app, beam(:app, true)}]})
      end

      assert :m == main.(~c"{escript_emu_args, \"%%! +sbtu -escript main m\\n\"}.\n")
      assert :app == main.(~c"{escript_main_app, app}.\n")
      # escript_emu_args wins over escript_main_app, as in rebar3.
      assert :m == main.(~c"{escript_main_app, app}.\n{escript_emu_args, \"-escript main m\"}.\n")
      assert :none == main.(~c"{erl_opts, []}.\n")

      assert {:error, ~c"the main module ~p is not in ~ts", [:other, _]} =
               catch_throw(main.(~c"{escript_main_app, other}.\n"))
    end

    test "the main module" do
      beams = %{beams: [{:m, beam(:m, true)}, {:n, beam(:n, false)}]}
      assert :m == :beam_com_build.main(~c"d", %{main: :m}, beams)

      assert {:error, ~c"~p does not export main/1", [:n]} ==
               catch_throw(:beam_com_build.main(~c"d", %{main: :n}, beams))

      assert {:error, ~c"the main module ~p is not in ~ts", [:o, ~c"d"]} ==
               catch_throw(:beam_com_build.main(~c"d", %{main: :o}, beams))

      assert :none == :beam_com_build.main(~c"a.erl", %{}, %{script: true})

      assert {:error, ~c"~ts: --main is for application directories", [~c"a.erl"]} ==
               catch_throw(:beam_com_build.main(~c"a.erl", %{main: :m}, %{script: true}))
    end

    test "vm.args runs main/1" do
      vm_args = fn app -> :proplists.get_value(~c"vm.args", Map.fetch!(app, :config)) end

      assert "-noshell\n-s beam_com_script main m\n" ==
               vm_args.(:beam_com_build.with_main(%{config: []}, :m))

      assert "+S 1\n-noshell\n-s beam_com_script main m\n" ==
               vm_args.(
                 :beam_com_build.with_main(%{config: [{~c"vm.args", "+S 1\n-noshell\n\n"}]}, :m)
               )
    end

    test "priv files and executables", %{dir: dir} do
      priv = :filename.join(dir, ~c"priv")
      write(priv, ~c"data.txt", ~c"data")
      run = write(:filename.join(priv, ~c"bin"), ~c"run.sh", ~c"#!/bin/sh\n")
      :ok = :file.change_mode(run, 0o755)
      {files, exec} = :beam_com_build.priv_files(priv)
      assert [{~c"bin/run.sh", "#!/bin/sh\n"}, {~c"data.txt", "data"}] == Enum.sort(files)

      case :os.type() do
        {:win32, _} -> :ok
        _ -> assert [~c"bin/run.sh"] == exec
      end

      assert {[], []} == :beam_com_build.priv_files(:filename.join(dir, ~c"nopriv"))
    end

    test "the priv directories to copy" do
      p1 = [{~c"run.sh", "x"}]
      p2 = [{~c"data.txt", "y"}]
      app = %{name: :a, vsn: ~c"1.0", priv: p1, priv_exec: [~c"run.sh"]}

      deps = [
        %{name: :b, vsn: ~c"2.0", priv: p2, priv_exec: []},
        %{name: :c, vsn: ~c"3.0", priv: [], priv_exec: []}
      ]

      h1 = :beam_com_build.hash(p1)
      h2 = :beam_com_build.hash(p2)
      assert [{:a, ~c"1.0", h1, [~c"run.sh"]}] == :beam_com_build.extract(app, deps, [])

      assert [{:a, ~c"1.0", h1, [~c"run.sh"]}, {:b, ~c"2.0", h2, []}] ==
               :beam_com_build.extract(app, deps, [:b])

      assert {:error,
              ~c"--extract-priv ~p: the program has no application ~p with a " ++
                ~c"priv directory", [:c, :c]} ==
               catch_throw(:beam_com_build.extract(app, deps, [:c]))

      assert {:error, _, [:z, :z]} = catch_throw(:beam_com_build.extract(app, deps, [:z]))
      # The hash: 16 hex digits. It changes with a name or the content.
      assert {:match, _} = :re.run(h1, ~c"^[0-9a-f]{16}$")
      assert h1 == :beam_com_build.hash([{~c"run.sh", "x"}])
      assert h1 != :beam_com_build.hash([{~c"run.sh", "z"}])
      assert h1 != :beam_com_build.hash([{~c"run2.sh", "x"}])

      assert :beam_com_build.hash([{~c"a", "1"}, {~c"b", "2"}]) ==
               :beam_com_build.hash([{~c"b", "2"}, {~c"a", "1"}])
    end

    test "sys.config for beam_com_script" do
      x = [{:a, ~c"1.0", ~c"0123456789abcdef", [~c"run.sh"]}]

      config = fn app ->
        text = :proplists.get_value(~c"sys.config", Map.fetch!(app, :config))
        {:ok, [terms], _} = erl_scan_parse(:erlang.iolist_to_binary(text))
        terms
      end

      assert %{config: []} == :beam_com_build.with_extract(%{config: []}, [])

      assert [{:beam_com_script, [{:extract, x}]}] ==
               config.(:beam_com_build.with_extract(%{config: []}, x))

      assert [{:app, [{:k, :v}]}, {:beam_com_script, [{:extract, x}]}] ==
               config.(
                 :beam_com_build.with_extract(
                   %{config: [{~c"sys.config", "[{app, [{k, v}]}].\n"}]},
                   x
                 )
               )
    end

    # A module that uses a behaviour and a parse transform of the same
    # application: with warnings_as_errors, the build fails when the
    # behaviour compiles after it, and the parse transform must exist.
    @tag timeout: 60_000
    test "behaviours and parse transforms first", %{dir: dir} do
      src = :filename.join(dir, ~c"order")

      user =
        write(
          src,
          ~c"aa_user.erl",
          ~c"-module(aa_user).\n-behaviour(zz_beh).\n" ++
            ~c"-compile({parse_transform, zz_pt}).\n-export([cb/0, f/0]).\n" ++
            ~c"cb() -> ok.\nf() -> replaced_by_pt.\n"
        )

      beh = write(src, ~c"zz_beh.erl", ~c"-module(zz_beh).\n-callback cb() -> ok.\n")

      pt =
        write(
          src,
          ~c"zz_pt.erl",
          ~c"-module(zz_pt).\n-export([parse_transform/2]).\n" ++
            ~c"parse_transform(Forms, _) ->\n" ++
            ~c"    [case F of {function, L, f, 0, _} ->\n" ++
            ~c"         {function, L, f, 0, [{clause, L, [], [], [{atom, L, transformed}]}]};\n" ++
            ~c"     _ -> F end || F <- Forms].\n"
        )

      assert [~c"zz_beh", ~c"zz_pt"] == Enum.sort(:beam_com_build.first_names(user))
      assert [] == :beam_com_build.first_names(beh)
      beams = :beam_com_build.compile_all([user, beh, pt], [:warnings_as_errors])
      assert [:aa_user, :zz_beh, :zz_pt] == Enum.sort(for {m, _} <- beams, do: m)
      {:aa_user, b} = List.keyfind(beams, :aa_user, 0)
      {:module, :aa_user} = :code.load_binary(:aa_user, ~c"aa_user.beam", b)
      assert :transformed == :aa_user.f()
      :code.purge(:aa_user)
      :code.delete(:aa_user)
      # The temporary directory is not left in the code path.
      assert :non_existing == :code.which(:zz_beh)

      assert [~c"mod_a"] ==
               :beam_com_build.first_names(
                 write(src, ~c"q.erl", ~c"-module(q).\n-behavior('mod_a').\n")
               )
    end

    # An application whose code has docs (as the Elixir applications in
    # beam.com), and one without them.
    test "the docs are not in a program", %{dir: dir} do
      root = :filename.join(dir, ~c"docroot")

      beam = fn app, src ->
        ebin = :filename.join([root, ~c"lib", app ++ ~c"-1.0", ~c"ebin"])
        file = write(dir, ~c"m_" ++ app ++ ~c".erl", src)
        {:ok, _, b} = :compile.file(file, [:binary])
        write(ebin, ~c"m_" ++ app ++ ~c".beam", b)
      end

      beam.(
        ~c"withdocs",
        ~c"-module(m_withdocs).\n-moduledoc \"Docs.\".\n-vsn(\"7\").\n" ++
          ~c"-export([f/0]).\n-doc \"F.\".\nf() -> ok.\n"
      )

      beam.(~c"plain", ~c"-module(m_plain).\n-export([f/0]).\nf() -> ok.\n")
      base = %{withdocs: %{vsn: ~c"1.0"}, plain: %{vsn: ~c"1.0"}}
      assert [] == :beam_com_build.without_docs([:plain], base, root)
      [{name, stripped}] = :beam_com_build.without_docs([:plain, :withdocs], base, root)
      assert ~c"lib/withdocs-1.0/ebin/m_withdocs.beam" == name

      assert {:ok, {:m_withdocs, [{~c"Docs", :missing_chunk}]}} =
               :beam_lib.chunks(stripped, [~c"Docs"], [:allow_missing_chunks])

      # No debug information. The attributes and the line numbers stay.
      assert {:ok, {:m_withdocs, [{:debug_info, _}]}} =
               :beam_lib.chunks(stripped, [:debug_info], [:allow_missing_chunks])

      assert {:ok, {:m_withdocs, [{~c"Dbgi", :missing_chunk}, {~c"Line", <<_::binary>>}]}} =
               :beam_lib.chunks(stripped, [~c"Dbgi", ~c"Line"], [:allow_missing_chunks])

      {:module, :m_withdocs} = :code.load_binary(:m_withdocs, ~c"m_withdocs.beam", stripped)
      assert :ok == :m_withdocs.f()
      assert ~c"7" == :proplists.get_value(:vsn, :m_withdocs.module_info(:attributes))
      :code.purge(:m_withdocs)
      :code.delete(:m_withdocs)
    end
  end

  ## The selection of the applications

  defp base do
    app = fn mods, deps ->
      %{vsn: ~c"1", dir: ~c"/nowhere", props: [{:modules, mods}, {:applications, deps}]}
    end

    %{
      kernel: app.([:application, :file], []),
      stdlib: app.([:lists, :io], [:kernel]),
      crypto: app.([:crypto], [:kernel, :stdlib]),
      asn1: app.([:asn1rt_nif], [:kernel, :stdlib]),
      public_key: app.([:public_key], [:asn1, :crypto]),
      ssl: app.([:ssl], [:crypto, :public_key]),
      other: app.([:helper], [:kernel]),
      hello: app.([:hello], [:kernel]),
      incl: %{
        vsn: ~c"1",
        dir: ~c"/",
        props: [{:modules, [:incl]}, {:included_applications, [:inner]}]
      },
      inner: app.([:inner], [])
    }
  end

  defp select(app, extra), do: Enum.sort(:beam_com_build.select_apps(app, extra, base()))

  defp program(name, code) do
    {:ok, mod, beam} = :compile.forms(forms(code), [:binary])
    %{name: name, props: [{:applications, [:kernel, :stdlib]}], beams: [{mod, beam}]}
  end

  # The abstract forms of the Erlang source `code`.
  defp forms(code) do
    {:ok, tokens, _} = :erl_scan.string(code)

    tokens
    |> Enum.chunk_while(
      [],
      fn
        {:dot, _} = dot, acc -> {:cont, Enum.reverse([dot | acc]), []}
        token, acc -> {:cont, [token | acc]}
      end,
      fn [] -> {:cont, []} end
    )
    |> Enum.map(fn form_tokens ->
      {:ok, form} = :erl_parse.parse_form(form_tokens)
      form
    end)
  end

  # A module `module`, compiled. It exports main/1 when `main` is true.
  defp beam(module, main) do
    exports =
      if main,
        do: ~c"-export([main/1]).\nmain(_) -> ok.\n",
        else: ~c"-export([f/0]).\nf() -> ok.\n"

    {:ok, ^module, beam} =
      :compile.forms(forms(~c"-module(#{module}).\n" ++ exports), [:binary])

    beam
  end

  ## Releases and run/1, with the real OTP applications

  # A lib directory with links to the real kernel, stdlib, sasl and crypto.
  defp fake_root(dir) do
    root = :filename.join(dir, ~c"root")
    lib = :filename.join(root, ~c"lib")
    :ok = :filelib.ensure_path(lib)

    for a <- [:kernel, :stdlib, :sasl, :crypto] do
      link = :filename.join(lib, ~c"#{a}-" ++ app_vsn(a))
      _ = :file.make_symlink(:code.lib_dir(a), link)
    end

    # The tool itself, which the build does not copy.
    write(
      :filename.join([lib, ~c"beam_com", ~c"ebin"]),
      ~c"beam_com.app",
      ~c"{application, beam_com, [{vsn, \"0.1.0\"}, {modules, []}]}.\n"
    )

    root
  end

  # The fake root with beam_com_script, and a fake executable of it. The
  # programs of one file need beam_com_script.
  defp prepare(dir) do
    root = fake_root(dir)

    write(
      :filename.join([root, ~c"lib", ~c"beam_com_script-0.1.0", ~c"ebin"]),
      ~c"beam_com_script.app",
      ~c"{application, beam_com_script, [{description, \"\"}, {vsn, \"0.1.0\"}," ++
        ~c" {modules, []}, {registered, []}, {applications, [kernel, stdlib]}]}.\n"
    )

    {root, fake_exe(dir, root)}
  end

  defp app_vsn(app) do
    {:ok, [{:application, ^app, props}]} =
      :file.consult(:filename.join([:code.lib_dir(app), ~c"ebin", ~c"#{app}.app"]))

    :proplists.get_value(:vsn, props)
  end

  # A fake executable with the zip of a beam.com: the files of the fake
  # root, a release, the tool, include files and the entries of the
  # emulator image.
  defp fake_exe(dir, root) do
    lib = :filename.join(root, ~c"lib")
    {:ok, dirs} = :file.list_dir(lib)

    lib_files =
      Enum.flat_map(dirs, fn d ->
        for(
          f <- ebin_names(:filename.join([lib, d, ~c"ebin"])),
          do: {~c"lib/" ++ d ++ ~c"/ebin/" ++ f, "beam"}
        ) ++ [{~c"lib/" ++ d ++ ~c"/include/x.hrl", "hrl"}]
      end)

    seed = exe("MZqFpD image bytes")

    image =
      :erlang.iolist_to_binary(
        :beam_com_zip.write(seed, fn _ -> true end, [
          {~c".symtab.amd64", "sym"},
          {~c"usr/share/zoneinfo/UTC", "tz"}
        ])
      )

    bin =
      :erlang.iolist_to_binary(
        :beam_com_zip.write(
          image,
          fn _ -> true end,
          [
            {~c"bin/start_clean.boot", "boot"},
            {~c"releases/start_erl.data", "old"},
            {~c"releases/0.1.0/start.boot", "old"},
            {~c".args", "-x"},
            {~c".allow", "all"}
            | lib_files
          ]
        )
      )

    file = :filename.join(dir, ~c"beam.com")
    :ok = :file.write_file(file, bin)
    file
  end

  defp ebin_names(dir) do
    {:ok, names} = :file.list_dir(dir)
    Enum.sort(names)
  end

  defp exe(prefix) do
    size = byte_size(prefix)

    <<prefix::binary, @zip_end::little-32, 0::16, 0::16, 0::16, 0::16, 0::32, size::little-32,
      0::16>>
  end

  ## The flags --allow-*

  defp allow(flags), do: Enum.reduce(flags, %{}, &:beam_com_build.allow/2)

  ## --target

  defp elf(machine, abi) do
    <<127, "ELF", 2, 1, 1, abi, 0::64, 2::little-16, machine::little-16, 1::little-32,
      0x401000::little-64, 0::64, 64::little-64, 0::32, 64::little-16, 56::little-16,
      1::little-16, 0::48>>
  end

  defp octal(bin), do: for(<<b <- bin>>, do: :io_lib.format(~c"\\~.8b", [b]))

  defp macho do
    <<0xFEEDFACF::little-32, 0x01000007::little-32, 3::little-32, 2::little-32, 0::128>>
  end

  defp script do
    :erlang.iolist_to_binary([
      "MZqFpD='\n'\n",
      "printf '",
      octal(elf(0x3E, 9)),
      "' >&7\n",
      "printf '",
      octal(elf(0xB7, 9)),
      "' >&7\n",
      "dd if=\"$o\" of=\"$o\" bs=1 skip=1024 count=",
      Integer.to_string(byte_size(macho())),
      " conv=notrunc\n"
    ])
  end

  defp tail, do: "PK zip data"

  defp ape do
    script = script()
    pad = :binary.copy("#", 1024 - byte_size(script))
    <<script::binary, pad::binary, macho()::binary, tail()::binary>>
  end

  defp native(target), do: :beam_com_build.native(target, ape())

  defp rest(bin, n), do: :binary.part(bin, n, byte_size(bin) - n)

  ## Helpers

  # The directories that the generation of code makes in TMPDIR.
  defp temp_dirs do
    base =
      hd(
        for(
          v <- [~c"TMPDIR", ~c"TMP", ~c"TEMP"],
          t <- [:os.getenv(v)],
          t != false and t != ~c"",
          do: t
        ) ++ [~c"/tmp"]
      )

    Enum.sort(:filelib.wildcard(:filename.join(base, ~c"beam_com_gen_*")))
  end

  # The fake root of prepare/1 with wasm_host: its application (wasm_tcp,
  # with debug information), worker.js, and a runtime ("the runtime" in
  # beam.wasm). The fake executable has the new application too.
  defp edge_prepare(dir) do
    {root, _} = prepare(dir)
    host = :filename.join([root, ~c"lib", ~c"wasm_host-0.1.0"])

    write(
      :filename.join(host, ~c"ebin"),
      ~c"wasm_host.app",
      :io_lib.format(~c"~p.~n", [
        {:application, :wasm_host,
         [vsn: ~c"0.1.0", modules: [:wasm_tcp], applications: [:kernel, :stdlib]]}
      ])
    )

    {:ok, :wasm_tcp, beam} =
      :compile.forms([{:attribute, 1, :module, :wasm_tcp}], [:binary, :debug_info])

    write(:filename.join(host, ~c"ebin"), ~c"wasm_tcp.beam", beam)
    write(:filename.join([host, ~c"priv", ~c"worker"]), ~c"worker.js", "the worker")
    write(:filename.join([host, ~c"priv", ~c"runtime"]), ~c"beam.wasm", "the runtime")
    write(:filename.join([host, ~c"priv", ~c"runtime"]), ~c"beam.mjs", "the loader")
    {root, fake_exe(dir, root)}
  end

  # hasher.erl (with crypto) as a native file, with more options.
  defp edge_build(dir, root, exe, opts) do
    f =
      write(
        dir,
        ~c"hasher.erl",
        ~c"-module(hasher).\n-export([main/1]).\nmain(A) -> crypto:hash(sha256, A).\n"
      )

    out = :filename.join(dir, ~c"hasher.com")
    run = Map.merge(%{input: f, apps: [], output: out, root: root, exe: exe}, opts)
    :ok = silent(fn -> :beam_com_build.run(run) end)
    out
  end

  # A release directory as "mix release" writes it (env.sh tells), with
  # the application myapp and the applications otp of the zip.
  defp mix_release(dir, otp) do
    rel = :filename.join(dir, ~c"rel")
    vsn_dir = :filename.join([rel, ~c"releases", ~c"1.0.0"])
    lib = :filename.join([rel, ~c"lib", ~c"myapp-1.0.0"])
    {:ok, :myapp, beam} = :compile.forms([{:attribute, 1, :module, :myapp}], [:binary])
    write(:filename.join(lib, ~c"ebin"), ~c"myapp.beam", beam)

    write(
      :filename.join(lib, ~c"ebin"),
      ~c"myapp.app",
      :io_lib.format(~c"~p.~n", [
        {:application, :myapp,
         [vsn: ~c"1.0.0", modules: [:myapp], applications: [:kernel, :stdlib]]}
      ])
    )

    write(:filename.join(lib, ~c"priv"), ~c"data.txt", "data")

    write(
      :filename.join(rel, ~c"releases"),
      ~c"start_erl.data",
      :erlang.system_info(:version) ++ ~c" 1.0.0\n"
    )

    write(
      vsn_dir,
      ~c"myrel.rel",
      :io_lib.format(~c"~p.~n", [
        {:release, {~c"myrel", ~c"1.0.0"}, {:erts, :erlang.system_info(:version)},
         otp ++ [{:myapp, ~c"1.0.0"}]}
      ])
    )

    cmds = [
      {:progress, :preloaded},
      {:path, [~c"$ROOT/lib/kernel-" ++ app_vsn(:kernel) ++ ~c"/ebin"]},
      {:apply, {:application, :start_boot, [:kernel, :permanent]}},
      {:apply, {:application, :start_boot, [:stdlib, :permanent]}},
      {:apply, {:"Elixir.Config.Provider", :boot, []}},
      {:apply, {:application, :start_boot, [:myapp, :permanent]}},
      {:progress, :started}
    ]

    write(
      vsn_dir,
      ~c"start.boot",
      :erlang.term_to_binary({:script, {~c"myrel", ~c"1.0.0"}, cmds})
    )

    write(vsn_dir, ~c"start.script", ~c"%% the script of the boot\n")
    write(vsn_dir, ~c"sys.config", ~c"[].")
    write(vsn_dir, ~c"vm.args", ~c"## the vm.args of the release\n")
    write(vsn_dir, ~c"env.sh", ~c"#!/bin/sh\n")
    write(vsn_dir, ~c"runtime.exs", ~c"import Config\n")

    {:ok, :"Elixir.Proto", proto} =
      :compile.forms([{:attribute, 1, :module, :"Elixir.Proto"}], [:binary])

    write(:filename.join(vsn_dir, ~c"consolidated"), ~c"Elixir.Proto.beam", proto)
    write(:filename.join(rel, ~c"bin"), ~c"myrel", ~c"#!/bin/sh\n")
    rel
  end

  defp write(dir, name, content) do
    :ok = :filelib.ensure_path(dir)
    file = :filename.join(dir, name)
    :ok = :file.write_file(file, content)
    file
  end

  defp erl_scan_parse(bin) do
    {:ok, tokens, end_location} = :erl_scan.string(:erlang.binary_to_list(bin))
    {:ok, term} = :erl_parse.parse_term(tokens)
    {:ok, [term], end_location}
  end

  # Runs `fun` without its standard output (the summary of run/1), and
  # gives its result.
  defp silent(fun) do
    {result, _output} = with_io(fun)
    result
  end

  # Runs `fun` without its standard output and its standard error, and
  # gives its result.
  defp quiet(fun) do
    {result, _output} = with_io(:stderr, fn -> silent(fun) end)
    result
  end

  describe "properties of the names and the paths" do
    # The version starts at the first "-" before a digit, so a version can
    # have a "-" ("ecto-3.0.0-rc.1").
    property "split_dir/1 gives the name and the version of NAME-VSN" do
      check all(name <- app_name(), vsn <- app_version()) do
        assert :beam_com_build.split_dir(String.to_charlist(name <> "-" <> vsn)) ==
                 {String.to_atom(name), String.to_charlist(vsn)}
      end
    end

    property "slashes/2 on Windows gives a path with no backslash" do
      check all(path <- windows_path()) do
        out = :beam_com_build.slashes(String.to_charlist(path), {:win32, :windows})
        refute ?\\ in out
        assert :beam_com_build.slashes(out, {:win32, :windows}) == out
        assert length(out) == String.length(path)

        # A drive becomes the form of Cosmopolitan: "C:\\x" is "/C/x".
        case String.to_charlist(path) do
          [letter, ?: | _] -> assert [?/, ^letter | _] = out
          _ -> :ok
        end
      end
    end

    property "slashes/2 on Unix does not change a path" do
      check all(path <- windows_path()) do
        path = String.to_charlist(path)
        assert :beam_com_build.slashes(path, {:unix, :linux}) == path
      end
    end
  end

  # An application name: words of letters, digits and "_", joined by "-"
  # and a letter, so no "-" comes before a digit.
  defp app_name do
    word = string(Enum.concat([?a..?z, ?0..?9, [?_]]), min_length: 1, max_length: 6)

    gen all(
          first <- string(?a..?z, length: 1),
          words <- list_of(word, max_length: 2),
          tail <- list_of(map(string(?a..?z, length: 1), &("-" <> &1)), max_length: 1)
        ) do
      first <> Enum.join(words, "_") <> Enum.join(tail)
    end
  end

  defp app_version do
    gen all(
          parts <- list_of(integer(0..30), min_length: 1, max_length: 3),
          pre <-
            one_of([
              constant(""),
              map(string(?a..?z, min_length: 1, max_length: 4), &("-" <> &1 <> ".1"))
            ])
        ) do
      Enum.join(parts, ".") <> pre
    end
  end

  defp windows_path do
    gen all(
          drive <-
            one_of([
              constant(""),
              map(string(Enum.concat(?A..?Z, ?a..?z), length: 1), &(&1 <> ":"))
            ]),
          parts <-
            list_of(string(Enum.concat([?a..?z, [?., ?_, ?\s]]), max_length: 5), max_length: 4),
          separators <- list_of(member_of(["\\", "/"]), length: max(length(parts), 1))
        ) do
      drive <>
        (Enum.zip_with(separators, parts ++ [""], &(&1 <> &2))
         |> Enum.take(max(length(parts), 1))
         |> Enum.join())
    end
  end
end
