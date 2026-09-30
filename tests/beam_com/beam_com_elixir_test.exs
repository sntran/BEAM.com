defmodule BeamComElixirTest do
  @moduledoc """
  The tests of `:beam_com_elixir`: one-file programs, mix.exs, and
  config/config.exs.

  The module is not async: the tests compile and load modules, capture
  the standard error, and change the environment of Mix.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    # mix_project/1 sets the environment of Mix to prod, as the builder
    # needs. Put back the environment and the project of beam.com.
    env = Mix.env()
    project = Mix.Project.get()
    file = Mix.Project.project_file()

    on_exit(fn ->
      Mix.env(env)
      if project && Mix.Project.get() != project, do: Mix.Project.push(project, file)
    end)

    %{dir: String.to_charlist(dir)}
  end

  test "Elixir is in the code path" do
    assert :beam_com_elixir.available()
  end

  describe "elixir_test_" do
    @tag timeout: 120_000
    test "a one-file program", %{dir: dir} do
      f =
        write(
          dir,
          ~c"two.ex",
          "defmodule Two.Helper do\n  def up(s), do: String.upcase(s)\nend\n" <>
            "defmodule Two do\n  def main(args), do: Enum.map(args, &Two.Helper.up/1)\nend\n"
        )

      %{beams: beams, main: main} = silent(fn -> :beam_com_elixir.script(f) end)
      assert Two == main
      assert [Two, Two.Helper] == Enum.sort(for {m, _} <- beams, do: m)

      try do
        for {m, b} <- beams,
            do: {:module, ^m} = :code.load_binary(m, Atom.to_charlist(m) ++ ~c".beam", b)

        assert ["A", "B"] == apply(main, :main, [["a", "b"]])
      after
        for {m, _} <- beams, do: :code.purge(m) and :code.delete(m)
      end
    end

    @tag timeout: 120_000
    test "one-file errors", %{dir: dir} do
      no_main = write(dir, ~c"nomain.exs", "defmodule NoMain do\n  def f, do: 1\nend\n")

      assert {:error, ~c"~ts: no module exports main/1", [no_main]} ==
               catch_throw(silent(fn -> :beam_com_elixir.script(no_main) end))

      two =
        write(
          dir,
          ~c"mains.ex",
          "defmodule MainA do\n  def main(_), do: :a\nend\n" <>
            "defmodule MainB do\n  def main(_), do: :b\nend\n"
        )

      assert {:error, ~c"~ts: more than one module exports main/1: ~ts", [^two, _]} =
               catch_throw(silent(fn -> :beam_com_elixir.script(two) end))

      bad =
        write(
          dir,
          ~c"bad.ex",
          "defmodule Bad do\n  def main(_), do: undefined_thing()\nend\n"
        )

      assert {:error, ~c"~ts: Elixir compilation failed", [bad]} ==
               catch_throw(silent(fn -> :beam_com_elixir.script(bad) end))

      assert {:error, ~c"~ts: no such file", [~c"none.ex"]} ==
               catch_throw(:beam_com_elixir.script(~c"none.ex"))
    end

    @tag timeout: 120_000
    test "mix.exs", %{dir: dir} do
      d = :filename.join(dir, ~c"proj")

      write(
        d,
        ~c"mix.exs",
        "defmodule Proj.MixProject do\n  use Mix.Project\n" <>
          "  def project, do: [app: :proj, version: \"2.1.0\", deps: deps(),\n" <>
          "                    elixirc_paths: [\"lib\", \"more\"],\n" <>
          "                    escript: [main_module: Proj.CLI],\n" <>
          "                    start_permanent: Mix.env() == :prod]\n" <>
          "  def application, do: [mod: {Proj.App, []}, extra_applications: [:logger]]\n" <>
          "  defp deps, do: [{:jason, \"~> 1.4\"}, {:ex_doc, \">= 0.0.0\", only: :dev}]\n" <>
          "end\n"
      )

      assert :beam_com_elixir.is_mix(d)
      refute :beam_com_elixir.is_mix(dir)
      p = :beam_com_elixir.mix_project(d)

      assert %{
               app: :proj,
               version: ~c"2.1.0",
               elixirc_paths: [~c"lib", ~c"more"],
               erlc_paths: [~c"src"],
               deps: [{:jason, "jason", ~c"~> 1.4"}],
               runtime_deps: [:jason],
               escript: [main_module: Proj.CLI]
             } = p

      %{application: app} = p
      assert {Proj.App, []} == :proplists.get_value(:mod, app)
      # The module of mix.exs is not left loaded; a second read works.
      assert false == :code.is_loaded(Proj.MixProject)
      assert %{app: :proj} = :beam_com_elixir.mix_project(d)
      bad = :filename.join(dir, ~c"badproj")

      write(
        bad,
        ~c"mix.exs",
        "defmodule Bad.MixProject do\n  def project, do: raise \"boom\"\nend\n"
      )

      project = Mix.Project.get()
      assert {:error, ~c"~ts: ~ts", [_, _]} = catch_throw(:beam_com_elixir.mix_project(bad))
      # This mix.exs pushes no project, so the stack of Mix stays.
      assert Mix.Project.get() == project
    end

    test "the deps of mix.exs" do
      d = &:beam_com_elixir.mix_deps/1
      assert [{:a, "a", ~c"~> 1.0", true}] == d.([{:a, "~> 1.0"}])
      assert [{:b, "b", :any, true}] == d.([{:b, []}])

      assert [{:c, "c_pkg", ~c"1.0.0", false}] ==
               d.([{:c, "1.0.0", [hex: :c_pkg, runtime: false]}])

      assert [] ==
               d.([
                 {:t, "~> 1.0", [only: :test]},
                 {:o, "~> 1.0", [optional: true]},
                 {:dt, "~> 1.0", [only: [:dev, :test]]}
               ])

      assert [{:p, "p", ~c"~> 1.0", true}] == d.([{:p, "~> 1.0", [only: [:dev, :prod]]}])

      assert {:error,
              ~c"the dependency ~p is not a Hex package (~p; only Hex packages are supported)",
              [:g, :git]} ==
               catch_throw(d.([{:g, [git: "https://example.com/g.git"]}]))

      assert {:error,
              ~c"the dependency ~p is not a Hex package (~p; only Hex packages are supported)",
              [:l, :path]} ==
               catch_throw(d.([{:l, [path: "../l"]}]))
    end

    @tag timeout: 60_000
    test "config/config.exs", %{dir: dir} do
      d = :filename.join(dir, ~c"cfg")
      assert :none == :beam_com_elixir.sys_config(d)

      write(
        :filename.join(d, ~c"config"),
        ~c"config.exs",
        "import Config\nconfig :cfg, greeting: \"hi\", n: 2\n" <>
          "if config_env() == :prod, do: config(:cfg, env: :prod)\n"
      )

      text = :beam_com_elixir.sys_config(d)
      {:ok, tokens, _} = :erl_scan.string(:lists.flatten(text))
      {:ok, terms} = :erl_parse.parse_term(tokens)

      assert [{:cfg, [env: :prod, greeting: "hi", n: 2]}] ==
               for({a, kv} <- terms, do: {a, :lists.sort(kv)})
    end
  end

  defp write(dir, name, content) do
    :ok = :filelib.ensure_path(dir)
    file = :filename.join(dir, name)
    :ok = :file.write_file(file, content)
    file
  end

  # Run fun with no output: the compiler writes its errors to the
  # standard error.
  defp silent(fun) do
    {{result, _}, _} = with_io(:stderr, fn -> with_io(fun) end)
    result
  end
end
