defmodule BeamComMixTest do
  @moduledoc """
  The tests of `:beam_com_mix`: when a Mix project needs Mix itself, and
  the release that a child beam.com makes with Mix.

  The module is not async: the tests read mix.exs with Mix, and they
  change the environment of Mix (see BeamComElixirTest).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    env = Mix.env()
    project = Mix.Project.get()
    file = Mix.Project.project_file()

    on_exit(fn ->
      Mix.env(env)
      if project && Mix.Project.get() != project, do: Mix.Project.push(project, file)
    end)

    %{dir: String.to_charlist(dir)}
  end

  describe "reasons" do
    test "a project of Hex deps and no config/runtime.exs needs no Mix", %{dir: dir} do
      config = [app: :a, deps: [{:jason, "~> 1.4"}, {:credo, git: "x", only: :dev}]]
      assert [] == :beam_com_mix.reasons(dir, config)
    end

    test "config/runtime.exs, deps that are not Hex packages, compilers, assets.deploy",
         %{dir: dir} do
      write(:filename.join(dir, ~c"config"), ~c"runtime.exs", "import Config\n")

      config = [
        app: :a,
        compilers: [:phoenix_live_view],
        aliases: ["assets.deploy": ["tailwind a --minify"], setup: ["deps.get"]],
        deps: [
          {:phoenix, "~> 1.8"},
          {:heroicons, github: "tailwindlabs/heroicons", app: false, compile: false},
          {:local, path: "../local"},
          {:tool, git: "https://example.com/tool.git", only: [:dev, :prod]},
          {:dev_only, git: "https://example.com/dev.git", only: :dev}
        ]
      ]

      assert [:runtime_exs, {:deps, [:heroicons, :local, :tool]}, :compilers, :"assets.deploy"] ==
               :beam_com_mix.reasons(dir, config)
    end

    test "reasons/1 reads mix.exs", %{dir: dir} do
      write(
        dir,
        ~c"mix.exs",
        "defmodule R.MixProject do\n  use Mix.Project\n" <>
          "  def project, do: [app: :r, version: \"0.1.0\", deps: [{:d, git: \"x\"}]]\nend\n"
      )

      assert [{:deps, [:d]}] == :beam_com_mix.reasons(dir)
    end
  end

  test "hex_deps and has_alias" do
    assert :beam_com_mix.hex_deps(deps: [{:jason, "~> 1.4"}])
    assert :beam_com_mix.hex_deps(deps: [{:jason, ">= 0.0.0", hex: :jason}])
    refute :beam_com_mix.hex_deps(deps: [{:a, git: "x"}, {:b, "~> 1.0", only: :test}])
    refute :beam_com_mix.hex_deps([])
    assert :beam_com_mix.has_alias([aliases: ["assets.deploy": []]], :"assets.deploy")
    refute :beam_com_mix.has_alias([aliases: [setup: []]], :"assets.deploy")
    refute :beam_com_mix.has_alias([], :"assets.deploy")
  end

  test "releases: include_erts false and a directory in Out, for each release" do
    assert [app: [include_erts: false, path: "/out/app"]] ==
             :beam_com_mix.releases(:app, [], ~c"/out")

    assert [
             one: [applications: [x: :permanent], include_erts: false, path: "/out/one"],
             two: [path: "/out/two", include_erts: false]
           ] ==
             :beam_com_mix.releases(
               :app,
               [one: [applications: [x: :permanent], include_erts: true], two: [path: "/p"]],
               ~c"/out"
             )
  end

  test "child_env: MIX_ENV of the user, else prod" do
    base = [{~c"BEAM_COM_MIX_DIR", ~c"/d"}, {~c"BEAM_COM_MIX_OUT", ~c"/o"}]
    assert base ++ [{~c"MIX_ENV", ~c"prod"}] == :beam_com_mix.child_env(~c"/d", ~c"/o", false)
    assert base ++ [{~c"MIX_ENV", ~c"prod"}] == :beam_com_mix.child_env(~c"/d", ~c"/o", ~c"")
    assert base == :beam_com_mix.child_env(~c"/d", ~c"/o", ~c"staging")
  end

  test "no_input: the output goes to the leader, and each read gets eof" do
    {:ok, out} = StringIO.open("an answer that nobody reads\n")
    leader = :beam_com_mix.no_input(out)

    IO.write(leader, "a line\n")
    assert :eof == IO.gets(leader, "Shall I install Hex? [Yn] ")
    assert :eof == IO.read(leader, 3)
    assert :eof == :io.get_password(leader)
    assert :eof == :io.request(leader, {:get_until, :unicode, :prompt, :erl_scan, :tokens, [1]})
    assert :ok == :io.requests(leader, [{:put_chars, :unicode, "x"}, {:put_chars, :unicode, "y"}])
    assert :eof == :io.requests(leader, [{:get_line, :unicode, "?"}, {:put_chars, :unicode, "z"}])

    assert {"an answer that nobody reads\n", "a line\nShall I install Hex? [Yn] promptxy?"} ==
             StringIO.contents(out)
  end

  describe "the choice of the builder" do
    test "Mix makes the release only for a Mix project that needs it", %{dir: dir} do
      assert :none == :beam_com_build.mix_release(dir, %{})

      assert {:error, ~c"~ts: --tool mix-release needs a Mix project (mix.exs)", [^dir]} =
               catch_throw(:beam_com_build.mix_release(dir, %{tool: :mix_release}))

      write(
        dir,
        ~c"mix.exs",
        "defmodule C.MixProject do\n  use Mix.Project\n" <>
          "  def project, do: [app: :c, version: \"0.1.0\", deps: []]\nend\n"
      )

      assert :none == :beam_com_build.mix_release(dir, %{})
      write(:filename.join(dir, ~c"config"), ~c"runtime.exs", "import Config\n")
      assert :none == :beam_com_build.mix_release(dir, %{tool: :mix})
      assert :none == :beam_com_build.mix_release(dir, %{tool: :rebar})
      # A directory with rebar.config and mix.exs is a rebar3 project.
      write(dir, ~c"rebar.config", "{deps, []}.\n")
      assert :none == :beam_com_build.mix_release(dir, %{})
    end

    test "why: the reasons in the line of the build" do
      assert "config/runtime.exs, deps that are not Hex packages: a b, " <>
               "the compilers of mix.exs, the alias assets.deploy, --tool mix-release" ==
               IO.iodata_to_binary(
                 :beam_com_build.why([
                   :runtime_exs,
                   {:deps, [:a, :b]},
                   :compilers,
                   :"assets.deploy",
                   :tool
                 ])
               )
    end
  end

  # The child is this beam.com (the init argument beam_com_exe of
  # beam_com.c), with the code of this commit only in the beam.com of
  # the build (scripts/steps.sh unit).
  describe "release" do
    @describetag timeout: 600_000

    setup do
      case :init.get_argument(:beam_com_exe) do
        {:ok, [[exe]]} -> %{exe: exe}
        :error -> :ok
      end
    end

    test "Mix makes a release with include_erts false and config/runtime.exs",
         %{dir: dir} = context do
      if exe = context[:exe] do
        project = copy_project(dir)
        out = :filename.join(dir, ~c"out")
        :ok = :file.make_dir(out)

        # A relative path, as in "beam.com . -o FILE": the child starts
        # in the project.
        relative = project |> Path.relative_to_cwd() |> String.to_charlist()
        assert relative != project

        {rel, output} =
          own_mix_paths(fn ->
            with_io(fn -> :beam_com_mix.release(relative, %{out: out, exe: exe}) end)
          end)

        assert rel == :filename.join(out, ~c"runtime_check")
        assert File.exists?(Path.join([rel, "releases", "0.1.0", "runtime.exs"]))
        assert File.exists?(Path.join([rel, "lib", "runtime_check-0.1.0", "ebin"]))
        assert [] == Path.wildcard(Path.join(rel, "erts-*"))
        # Mix writes _build in the project, as "mix release" does.
        assert File.dir?(Path.join([project, "_build", "prod"]))
        refute output =~ "Hex"
      end
    end

    test "an error of Mix: the exit status of the child", %{dir: dir} = context do
      if exe = context[:exe] do
        project = :filename.join(dir, ~c"bad")

        write(
          project,
          ~c"mix.exs",
          "defmodule Bad.MixProject do\n  use Mix.Project\n" <>
            "  def project, do: [app: :bad, version: \"0.1.0\", deps: [{:none, path: \"none\"}]]\nend\n"
        )

        {{:error, format, [^project, status]}, output} =
          own_mix_paths(fn ->
            with_io(fn -> catch_throw(:beam_com_mix.release(project, %{out: dir, exe: exe})) end)
          end)

        assert format == ~c"~ts: Mix did not make a release (exit status ~p)"
        assert status != 0
        assert output =~ "beam.com: "
      end
    end
  end

  # The child uses the environment of the builder. The tests run with
  # MIX_BUILD_ROOT, MIX_DEPS_PATH and MIX_ENV of the test build
  # (scripts/steps.sh unit): without them, Mix uses _build and deps of
  # the project, and the environment prod.
  defp own_mix_paths(fun) do
    saved = for v <- ["MIX_BUILD_ROOT", "MIX_DEPS_PATH", "MIX_ENV"], do: {v, System.get_env(v)}

    try do
      Enum.each(saved, fn {v, _} -> System.delete_env(v) end)
      fun.()
    after
      Enum.each(saved, fn
        {v, nil} -> System.delete_env(v)
        {v, value} -> System.put_env(v, value)
      end)
    end
  end

  defp copy_project(dir) do
    project = :filename.join(dir, ~c"runtime_check")
    File.cp_r!(Path.expand("../programs/runtime_check", __DIR__), to_string(project))
    project
  end

  defp write(dir, name, content) do
    :ok = :filelib.ensure_path(dir)
    file = :filename.join(dir, name)
    :ok = :file.write_file(file, content)
    file
  end
end
