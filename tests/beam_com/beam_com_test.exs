defmodule BeamComTest do
  @moduledoc """
  The tests of `:beam_com`, the command line of beam.com.

  Each test runs in its own directory, with no project: the commands of
  beam.com look for a project in the current directory. The current
  directory and the application environment are global state, so the tests
  do not run async.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    cwd = File.cwd!()
    File.cd!(dir)
    on_exit(fn -> File.cd!(cwd) end)
  end

  defp opts(args), do: :beam_com.build_options(args, %{apps: []})

  describe "build_options_test_" do
    for {name, args, expected} <- [
          {nil, [~c"a.erl"], %{input: ~c"a.erl", apps: []}},
          {nil, [~c"a.erl", ~c"-o", ~c"b.com"], %{input: ~c"a.erl", output: ~c"b.com", apps: []}},
          {nil, [~c"-o", ~c"b.com", ~c"a.erl"], %{input: ~c"a.erl", output: ~c"b.com", apps: []}},
          {nil, [~c"-a", ~c"crypto", ~c"dir", ~c"-a", ~c"ssl"],
           %{input: ~c"dir", apps: [:crypto, :ssl]}},
          {nil, [~c"a.erl", ~c"--target", ~c"x86_64-unknown-linux-gnu"],
           %{input: ~c"a.erl", target: ~c"x86_64-unknown-linux-gnu", apps: []}},
          {nil, [~c"a.erl", ~c"--target", ~c"aarch64-linux"],
           %{input: ~c"a.erl", target: ~c"aarch64-unknown-linux-gnu", apps: []}},
          {"the last -o wins", [~c"-o", ~c"1", ~c"a", ~c"-o", ~c"2"],
           %{input: ~c"a", output: ~c"2", apps: []}},
          {"the arguments of the program after --", [~c"a.erl", ~c"--", ~c"x", ~c"-o", ~c"--"],
           %{input: ~c"a.erl", apps: [], args: [~c"x", ~c"-o", ~c"--"]}},
          {"flags before and after the input",
           [~c"-a", ~c"crypto", ~c"a.erl", ~c"-o", ~c"b.com", ~c"--"],
           %{input: ~c"a.erl", output: ~c"b.com", apps: [:crypto], args: []}}
        ] do
      test name || "build_options(#{inspect(args)})" do
        assert opts(unquote(Macro.escape(args))) == unquote(Macro.escape(expected))
      end
    end
  end

  describe "build_errors_test_" do
    # The tests run in a directory without a project: no input is an error.
    setup do
      usage = catch_throw(opts([]))
      assert {:error, ~c"usage: " ++ _, [~c"beam.com"]} = usage
      %{usage: usage}
    end

    test "no input", %{usage: usage} do
      assert catch_throw(opts([])) == usage
    end

    test "only options", %{usage: usage} do
      assert catch_throw(opts([~c"-o", ~c"x.com"])) == usage
    end

    for {name, args, thrown} <- [
          {"two inputs", [~c"a.erl", ~c"b.erl"],
           {:error, ~c"~ts: the arguments of the program come after \"--\" (see ~ts --help)",
            [~c"b.erl", ~c"beam.com"]}},
          {"-o without a value", [~c"a.erl", ~c"-o"],
           {:error, ~c"option ~ts needs a value", [~c"-o"]}},
          {"-a without a value", [~c"a.erl", ~c"-a"],
           {:error, ~c"option ~ts needs a value", [~c"-a"]}},
          {"--target without a value", [~c"a.erl", ~c"--target"],
           {:error, ~c"option ~ts needs a value", [~c"--target"]}},
          {"--native is --target now", [~c"a.erl", ~c"--native", ~c"x86_64-linux"],
           {:error, ~c"unknown option ~ts", [~c"--native"]}},
          {"an unknown option", [~c"a.erl", ~c"-z"], {:error, ~c"unknown option ~ts", [~c"-z"]}},
          {"--allow-net with hosts", [~c"a", ~c"--allow-net=example.com"],
           {:error, ~c"--allow-net takes no hosts: the sandbox cannot filter the network by host",
            []}},
          {"an unknown --allow- flag", [~c"a", ~c"--allow-bogus"],
           {:error, ~c"unknown option ~ts", [~c"--allow-bogus"]}},
          {"an empty list", [~c"a", ~c"--allow-read="],
           {:error, ~c"~ts needs a list after \"=\"", [~c"--allow-read="]}},
          {"--pledge is --allow-* now", [~c"a", ~c"--pledge", ~c"inet"],
           {:error, ~c"unknown option ~ts", [~c"--pledge"]}},
          {"an unknown tool", [~c"d", ~c"--tool", ~c"make"],
           {:error, ~c"--tool is rebar or mix, not ~ts", [~c"make"]}}
        ] do
      test name do
        assert catch_throw(opts(unquote(Macro.escape(args)))) == unquote(Macro.escape(thrown))
      end
    end

    test "--allow-* flags" do
      assert opts([
               ~c"--allow-read=/etc",
               ~c"a.erl",
               ~c"-W",
               ~c"--allow-net",
               ~c"--allow-read=/srv,/etc"
             ]) ==
               %{
                 input: ~c"a.erl",
                 apps: [],
                 allow: %{read: [~c"/etc", ~c"/srv"], write: :all, net: true}
               }
    end

    test "-A and --allow-all (-A)" do
      assert opts([~c"-A", ~c"a"]) == %{input: ~c"a", apps: [], allow: %{all: true}}
    end

    test "-A and --allow-all (--allow-all)" do
      assert opts([~c"a", ~c"--allow-all", ~c"--allow-run=git"]) ==
               %{input: ~c"a", apps: [], allow: %{all: true, run: [~c"git"]}}
    end

    for flag <- [
          ~c"--allow-env",
          ~c"--allow-env=HOME",
          ~c"--allow-sys",
          ~c"--allow-ffi",
          ~c"--deny-read=/etc"
        ] do
      test "flags of Deno that the sandbox cannot enforce (#{flag})" do
        flag = unquote(flag)

        assert catch_throw(opts([~c"a", flag])) ==
                 {:error,
                  ~c"~ts is not supported: the sandbox cannot enforce it (see beam.com --help)",
                  [flag]}
      end
    end

    test "--main, --tool and --extract-priv" do
      assert opts([
               ~c"d",
               ~c"--main",
               ~c"m",
               ~c"--tool",
               ~c"mix",
               ~c"--extract-priv",
               ~c"a",
               ~c"--extract-priv",
               ~c"b"
             ]) == %{input: ~c"d", apps: [], main: :m, tool: :mix, extract_priv: [:a, :b]}
    end

    test "--tool rebar" do
      assert %{tool: :rebar} = opts([~c"d", ~c"--tool", ~c"rebar"])
    end

    for option <- [~c"--main", ~c"--tool", ~c"--extract-priv", ~c"--cacerts"] do
      test "#{option} without a value" do
        option = unquote(option)

        assert catch_throw(opts([~c"d", option])) ==
                 {:error, ~c"option ~ts needs a value", [option]}
      end
    end

    test "--cacerts" do
      assert %{cacerts: ~c"roots.pem"} = opts([~c"d", ~c"--cacerts", ~c"roots.pem"])
    end

    test "--no-edge: no WebAssembly part" do
      assert %{edge: false} = opts([~c"d", ~c"-o", ~c"d.com", ~c"--no-edge"])
      refute Map.has_key?(opts([~c"d", ~c"-o", ~c"d.com"]), :edge)
    end

    test "--page: a site" do
      assert %{page: true} = opts([~c"d", ~c"-o", ~c"site", ~c"--page"])
      refute Map.has_key?(opts([~c"d", ~c"-o", ~c"d.com"]), :page)
    end

    test "the commands before 0.2: a hint (build)" do
      assert catch_throw(opts([~c"build", ~c"a.erl"])) ==
               {:error, ~c"there is no command ~ts: use \"~ts INPUT -o OUTPUT\"",
                [~c"build", ~c"beam.com"]}
    end

    test "the commands before 0.2: a hint (help)" do
      assert catch_throw(:beam_com.command([~c"help"])) ==
               {:error, ~c"there is no command ~ts: use \"~ts --help\"", [~c"help", ~c"beam.com"]}
    end

    test "the commands before 0.2: a hint (version)" do
      assert catch_throw(:beam_com.command([~c"version", ~c"x"])) ==
               {:error, ~c"there is no command ~ts: use \"~ts --version\"",
                [~c"version", ~c"beam.com"]}
    end

    test "an old command with a directory of that name: still the hint", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "beam_com_old_command")
      File.mkdir_p!(Path.join(dir, "build"))

      File.cd!(dir, fn ->
        assert catch_throw(opts([~c"build", ~c"a.erl"])) ==
                 {:error, ~c"there is no command ~ts: use \"~ts INPUT -o OUTPUT\"",
                  [~c"build", ~c"beam.com"]}

        assert %{input: ~c"build"} = opts([~c"build"])
      end)
    end

    test "--target is only for -o" do
      assert catch_throw(:beam_com.command([~c"a.erl", ~c"--target", ~c"x86_64-linux"])) ==
               {:error, ~c"--target makes a file for another system: use it with -o", []}
    end
  end

  describe "run_file_test_" do
    setup do
      %{run_file: :beam_com.run_file(~c"dir/app.erl", %{apps: []})}
    end

    test "the extension is .com", %{run_file: a} do
      assert ~c".com" == :filename.extension(a)
    end

    test "the name starts with app-", %{run_file: a} do
      assert ~c"app-" ++ _ = :filename.basename(a)
    end

    test "the directory is run", %{run_file: a} do
      assert ~c"run" == :filename.basename(:filename.dirname(a))
    end

    test "the same input and options: the same file", %{run_file: a} do
      assert a == :beam_com.run_file(~c"dir/app.erl", %{apps: []})
    end

    test "other options (the sandbox): another file", %{run_file: a} do
      assert a != :beam_com.run_file(~c"dir/app.erl", %{apps: [], allow: %{net: true}})
    end

    test "BEAM_COM_CACHE" do
      old = System.get_env("BEAM_COM_CACHE")
      System.put_env("BEAM_COM_CACHE", "/tmp/c")

      try do
        assert ~c"/tmp/c/run/app-" ++ _ = :beam_com.run_file(~c"app.erl", %{})
      after
        if old,
          do: System.put_env("BEAM_COM_CACHE", old),
          else: System.delete_env("BEAM_COM_CACHE")
      end
    end
  end

  # fresh/3: the executable of a run in the cache, and FILE.inputs. A test
  # makes the "build" itself: it writes the executable and FILE.inputs.
  describe "fresh_test_" do
    setup %{tmp_dir: dir} do
      input = Path.join(dir, "app.erl")
      File.write!(input, "-module(app).\n")
      exe = Path.join(dir, "beam.com")
      File.write!(exe, "beam.com 1")

      %{
        input: String.to_charlist(input),
        out: String.to_charlist(Path.join(dir, "app-0.com")),
        exe: String.to_charlist(exe),
        now: System.os_time(:second)
      }
    end

    # The build of a run: the executable and FILE.inputs.
    defp build(out, inputs) do
      File.write!(out, "app")
      :ok = :beam_com.write_inputs(out, inputs)
    end

    # Write a file, and give it a time of change (POSIX).
    defp change(path, data, time) do
      File.write!(path, data)
      File.touch!(path, time)
    end

    defp keys({:beam_com_inputs_1, entries}), do: for({key, _, _, _} <- entries, do: key)

    test "no executable: not fresh", %{input: input, out: out, exe: exe} do
      assert {false, inputs} = :beam_com.fresh(out, input, exe)
      assert [[], [{:self, exe}]] == keys(inputs)
    end

    # A file with the same size and time is not read again, when that time
    # is 2 s or more before the time of its hash. So this change, which
    # keeps the size and an old time, is not seen.
    test "the same inputs: fresh, and no file is read",
         %{input: input, out: out, exe: exe, now: now} do
      File.touch!(input, now - 100)
      {false, inputs} = :beam_com.fresh(out, input, exe)
      build(out, inputs)
      assert :beam_com.fresh(out, input, exe)
      change(input, "-module(xyz).\n", now - 100)
      assert :beam_com.fresh(out, input, exe)
    end

    # The change of a script in the same second as the run, with the same
    # size: a time with a resolution of 1 s cannot show it, the data can.
    test "a change in the same second", %{input: input, out: out, exe: exe, now: now} do
      File.touch!(input, now)
      {false, inputs} = :beam_com.fresh(out, input, exe)
      build(out, inputs)
      change(input, "-module(xyz).\n", now)
      assert {false, _} = :beam_com.fresh(out, input, exe)
    end

    # In the hour that the end of DST repeats, the local time of a change
    # can be before the local time of the build. The data shows the change.
    test "a change with an older time", %{input: input, out: out, exe: exe, now: now} do
      File.touch!(input, now - 100)
      {false, inputs} = :beam_com.fresh(out, input, exe)
      build(out, inputs)
      File.touch!(out, now + 3600)
      change(input, "-module(xyz).\n", now - 3700)
      assert {false, _} = :beam_com.fresh(out, input, exe)
    end

    # A file with a new time and the same data: no build, and FILE.inputs
    # gets the new time. After that, the file is not read again.
    test "a new time with the same data", %{input: input, out: out, exe: exe, now: now} do
      File.touch!(input, now)
      {false, inputs} = :beam_com.fresh(out, input, exe)
      build(out, inputs)
      File.touch!(input, now - 100)
      assert :beam_com.fresh(out, input, exe)
      record = :erlang.binary_to_term(File.read!(List.to_string(out) <> ".inputs"))
      assert {:beam_com_inputs_1, [{[], {14, time}, _, _} | _]} = record
      assert time == now - 100
      change(input, "-module(xyz).\n", now - 100)
      assert :beam_com.fresh(out, input, exe)
    end

    test "a change of beam.com", %{input: input, out: out, exe: exe, tmp_dir: dir} do
      {false, inputs} = :beam_com.fresh(out, input, exe)
      build(out, inputs)
      assert :beam_com.fresh(out, input, exe)
      File.write!(exe, "beam.com 2")
      assert {false, _} = :beam_com.fresh(out, input, exe)
      other = Path.join(dir, "beam-emu.com")
      File.write!(other, "beam.com 1")
      assert {false, _} = :beam_com.fresh(out, input, String.to_charlist(other))
    end

    test "no executable, or no FILE.inputs that reads", %{input: input, out: out, exe: exe} do
      {false, inputs} = :beam_com.fresh(out, input, exe)
      build(out, inputs)
      File.rm!(out)
      assert {false, _} = :beam_com.fresh(out, input, exe)
      build(out, inputs)
      record = List.to_string(out) <> ".inputs"

      for bad <- [
            "junk",
            :erlang.term_to_binary({:other, []}),
            :erlang.term_to_binary({:beam_com_inputs_1, [:a | :b]})
          ] do
        File.write!(record, bad)
        assert {false, _} = :beam_com.fresh(out, input, exe)
      end
    end

    test "a directory: new files, removed files and the names left out",
         %{tmp_dir: dir, out: out} do
      app = Path.join(dir, "app")
      File.mkdir_p!(Path.join(app, "src"))
      File.write!(Path.join(app, "src/a.erl"), "-module(a).\n")
      input = String.to_charlist(app)
      {false, inputs} = :beam_com.fresh(out, input, :none)
      assert [[~c"src", ~c"a.erl"]] == keys(inputs)
      build(out, inputs)

      for name <- ["_build", "deps", ".git", ".elixir_ls"] do
        File.mkdir_p!(Path.join([app, "src", name]))
        File.write!(Path.join([app, "src", name, "x"]), "x")
      end

      assert :beam_com.fresh(out, input, :none)
      File.write!(Path.join(app, "src/b.erl"), "-module(b).\n")
      assert {false, inputs} = :beam_com.fresh(out, input, :none)
      build(out, inputs)
      assert :beam_com.fresh(out, input, :none)
      File.rm!(Path.join(app, "src/b.erl"))
      assert {false, _} = :beam_com.fresh(out, input, :none)
    end

    # A file that cannot be read, as a link to no file, is an input too:
    # its entry has the error.
    test "a link to no file", %{tmp_dir: dir, out: out} do
      app = Path.join(dir, "app")
      File.mkdir_p!(app)
      File.ln_s!(Path.join(dir, "none"), Path.join(app, "link"))
      input = String.to_charlist(app)
      {false, inputs} = :beam_com.fresh(out, input, :none)
      assert {:beam_com_inputs_1, [{[~c"link"], :error, {:error, :enoent}, _}]} = inputs
      build(out, inputs)
      assert :beam_com.fresh(out, input, :none)
      File.write!(Path.join(dir, "none"), "x")
      assert {false, _} = :beam_com.fresh(out, input, :none)
    end

    # The open of a FIFO waits for a writer, so fresh/3 does not read a
    # file that is not a regular file. Its type is its entry.
    @tag skip: if(System.find_executable("mkfifo"), do: false, else: "no mkfifo")
    test "a FIFO in a directory", %{tmp_dir: dir, out: out} do
      app = Path.join(dir, "app")
      File.mkdir_p!(app)
      {_, 0} = System.cmd("mkfifo", [Path.join(app, "fifo")])
      input = String.to_charlist(app)
      {false, inputs} = :beam_com.fresh(out, input, :none)
      assert {:beam_com_inputs_1, [{[~c"fifo"], :other, :other, _}]} = inputs
      build(out, inputs)
      assert :beam_com.fresh(out, input, :none)
    end

    # The build writes rebar.lock when it resolves the versions of the Hex
    # packages. after_build/2 takes the entries of the lock files from
    # after the build, so the next run does not build again.
    test "after_build/2: the lock files of the build", %{tmp_dir: dir, out: out} do
      app = Path.join(dir, "app")
      File.mkdir_p!(app)
      File.write!(Path.join(app, "rebar.config"), "{deps, [jsx]}.\n")
      input = String.to_charlist(app)
      {false, inputs} = :beam_com.fresh(out, input, :none)
      File.write!(Path.join(app, "rebar.lock"), "[].\n")
      build(out, inputs)
      assert {false, _} = :beam_com.fresh(out, input, :none)
      build(out, :beam_com.after_build(inputs, input))
      assert [[~c"rebar.config"], [~c"rebar.lock"]] == keys(:beam_com.after_build(inputs, input))
      assert :beam_com.fresh(out, input, :none)
      File.write!(Path.join(app, "rebar.lock"), "[{x}].\n")
      assert {false, _} = :beam_com.fresh(out, input, :none)
    end

    test "after_build/2 of a file", %{input: input, exe: exe, out: out} do
      {false, inputs} = :beam_com.fresh(out, input, exe)
      assert inputs == :beam_com.after_build(inputs, input)
    end
  end

  test "is_project_test_", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "beam_com_is_project")
    File.mkdir!(dir)
    refute :beam_com.is_project(String.to_charlist(dir))
    File.write!(Path.join(dir, "mix.exs"), "")
    assert :beam_com.is_project(String.to_charlist(dir))
  end

  # The output of a command, and its result.
  defp output(args) do
    {result, text} = with_io(fn -> :beam_com.command(args) end)
    {result, text}
  end

  describe "commands_test_" do
    test "no command prints the help (not in a project)" do
      {:ok, text} = output([])
      assert text =~ "usage: beam.com [FLAGS] [INPUT] [-- ARGUMENTS]"
      assert text =~ "beam.com [FLAGS] INPUT -o OUTPUT"
      assert text =~ "--help | --version"
      assert text =~ "BEAM_COM_ALLOW"
      refute text =~ "~n"
      assert output([~c"--help"]) == {:ok, text}
      assert output([~c"-h"]) == {:ok, text}
    end

    test "version shows the versions and the platform" do
      {:ok, text} = output([~c"--version"])
      erts = List.to_string(:erlang.system_info(:version))
      assert text =~ "  ERTS        : " <> erts <> "\n"
      assert text =~ "  Erlang/OTP  : " <> List.to_string(:erlang.system_info(:otp_release))
      assert text =~ "  Emulator    : "

      assert text =~
               "  Architecture: " <> List.to_string(:erlang.system_info(:system_architecture))

      {:ok, vsn} = :application.get_key(:stdlib, :vsn)
      stdlib = "stdlib-" <> List.to_string(vsn)
      assert text =~ stdlib
      assert 1 == length(String.split(text, stdlib)) - 1
    end

    test "the full OTP version from the .app file" do
      :ok = :application.set_env(:beam_com, :otp_version, ~c"29.1.1")

      try do
        {:ok, text} = output([~c"--version"])
        assert text =~ "  Erlang/OTP  : 29.1.1\n"
        {:ok, help} = output([])
        # "and Elixir VSN" when the root has Elixir (a beam.com).
        assert help =~ ~r"Erlang/OTP 29\.1\.1( and Elixir [0-9.]+)? in one"
      after
        :application.unset_env(:beam_com, :otp_version)
      end
    end

    test "the linked NIFs of Elixir packages from the .app file" do
      {:ok, without} = output([~c"--version"])
      refute without =~ "Linked NIFs"

      :ok =
        :application.set_env(:beam_com, :nifs, [
          {:exqlite, ~c"0.41.0"},
          {:bcrypt_elixir, ~c"3.3.2"}
        ])

      try do
        {:ok, text} = output([~c"--version"])
        assert text =~ "  Linked NIFs : exqlite-0.41.0 bcrypt_elixir-3.3.2\n"
      after
        :application.set_env(:beam_com, :nifs, [])
      end
    end

    test "--version with arguments" do
      assert catch_throw(:beam_com.command([~c"--version", ~c"x"])) ==
               {:error, ~c"usage: ~ts --version", [~c"beam.com"]}
    end

    test "--nif-include: a copy of priv/include of the wasm application", %{tmp_dir: dir} do
      # A wasm application first in the code path, and a cache of its own.
      ebin = Path.join(dir, "lib/wasm-9.9.9/ebin")
      include = Path.join(dir, "lib/wasm-9.9.9/priv/include")
      File.mkdir_p!(ebin)
      File.mkdir_p!(include)
      File.write!(Path.join(include, "erl_nif.h"), "first")
      cache = Path.join(dir, "cache")
      true = :code.add_patha(String.to_charlist(ebin))
      System.put_env("BEAM_COM_CACHE", cache)

      try do
        {:ok, out} = output([~c"--nif-include"])
        copy = Path.join(cache, "nif-include-#{:beam_com.otp_version()}")
        assert out == copy <> "\n"
        assert File.read!(Path.join(copy, "erl_nif.h")) == "first"
        # A file that differs is written again.
        File.write!(Path.join(include, "erl_nif.h"), "second")
        {:ok, ^out} = output([~c"--nif-include"])
        assert File.read!(Path.join(copy, "erl_nif.h")) == "second"
      after
        System.delete_env("BEAM_COM_CACHE")
        :code.del_path(String.to_charlist(ebin))
      end
    end

    test "--nif-modules with other arguments" do
      assert catch_throw(:beam_com.command([~c"--nif-modules", ~c"app.com"])) ==
               {:error, ~c"usage: ~ts --nif-modules APP.com DIR", [:beam_com.name()]}
    end

    test "--nif-include with arguments" do
      assert catch_throw(:beam_com.command([~c"--nif-include", ~c"x"])) ==
               {:error, ~c"usage: ~ts --nif-include", [:beam_com.name()]}
    end

    test "the name of the file: name()" do
      assert ~c"beam.com" == :beam_com.name()
    end

    for {path, name} <- [
          {~c"/opt/bin/beam-emu.com", ~c"beam-emu.com"},
          {~c"C:/tools/beam.exe", ~c"beam.com"},
          {~c"C:\\tools\\tool.exe", ~c"tool.com"},
          {~c"beam", ~c"beam.com"}
        ] do
      test "the name of the file: name(#{inspect(path)})" do
        assert unquote(name) == :beam_com.name(unquote(path))
      end
    end
  end

  # main/0 halts the node, so it runs in a peer node (BeamCom.PeerNode).
  describe "main/0 in a peer node" do
    test "--version: the text of version/0 and the status 0", %{tmp_dir: dir} do
      {status, out} = BeamCom.PeerNode.run({:beam_com, :main, []}, argv: ["--version"], cd: dir)
      assert status == 0
      # The line "Applications" has the applications of the code path, and
      # the test node has more of them.
      [head, _] = String.split(IO.chardata_to_string(:beam_com.version()), "  Applications: ")
      assert String.starts_with?(out, head <> "  Applications: ")
      # A version can have a "-" (0.1.0-rc.1).
      assert out =~ ~r/ beam_com-[0-9][0-9A-Za-z.+-]* .*stdlib-[0-9.]+\s/
    end

    test "no argument out of a project: the help and the status 0", %{tmp_dir: dir} do
      {status, out} = BeamCom.PeerNode.run({:beam_com, :main, []}, cd: dir)
      assert status == 0
      assert out == IO.chardata_to_string(:beam_com.help([]))
    end

    test "an error: the message on standard error and the status 1", %{tmp_dir: dir} do
      {status, out} =
        BeamCom.PeerNode.run({:beam_com, :main, []}, argv: ["--version", "x"], cd: dir)

      assert status == 1
      assert out == "beam.com: usage: beam.com --version\n"
    end

    # A run with a fresh executable in the cache does not build: it gives
    # the path of the executable to beam_com.c in BEAM_COM_RUN_FILE. (A
    # build cannot run here: the test node has no /zip.)
    test "a run with a fresh executable in the cache", %{tmp_dir: dir} do
      input = Path.join(dir, "app.erl")
      File.write!(input, "-module(app).\n")
      cache = Path.join(dir, "cache")
      run = Path.join(dir, "run-file")
      env = [BEAM_COM_CACHE: cache, BEAM_COM_RUN_FILE: run]
      System.put_env("BEAM_COM_CACHE", cache)

      out =
        try do
          :beam_com.run_file(String.to_charlist(input), %{apps: []})
        after
          System.delete_env("BEAM_COM_CACHE")
        end

      File.mkdir_p!(Path.dirname(List.to_string(out)))
      File.write!(out, "app")

      # The peer node writes the inputs with its own beam.com: in CI, the
      # tests run on beam.com, and beam.com is an input of the cache.
      setup = fn peer ->
        self = :peer.call(peer, :beam_com, :self_file, [])

        {false, inputs} =
          :peer.call(peer, :beam_com, :fresh, [out, String.to_charlist(input), self])

        :ok = :peer.call(peer, :beam_com, :write_inputs, [out, inputs])
      end

      {status, ""} =
        BeamCom.PeerNode.run({:beam_com, :main, []},
          argv: ["app.erl"],
          env: env,
          cd: dir,
          setup: setup
        )

      assert status == 0
      assert File.read!(run) == List.to_string(out)
      assert File.read!(out) == "app"
    end

    test "--target with no -o: the status 1", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "x.erl"), "-module(x).\n")

      {status, out} =
        BeamCom.PeerNode.run({:beam_com, :main, []},
          argv: ["x.erl", "--target", "wasm32"],
          cd: dir
        )

      assert status == 1
      assert out =~ "beam.com: --target makes a file for another system: use it with -o"
    end
  end
end
