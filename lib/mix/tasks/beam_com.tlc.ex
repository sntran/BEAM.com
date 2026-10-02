defmodule Mix.Tasks.BeamCom.Tlc do
  @shortdoc "Checks the models of beam.com with TLC"

  @moduledoc """
  Checks the models of beam.com with the TLC model checker:

  * the Accord contracts of `lib/beam_com/protocol`, with `mix accord.check`;
  * the TLA+ specifications of `specs/`. Each file `NAME.cfg` or
    `NAME.SUFFIX.cfg` is one model of the module `NAME.tla`.

  TLC needs Java and `tla2tools.jar`. The task looks for the jar in the
  variable `TLA2TOOLS_JAR`, then in `~/.tla/tla2tools.jar`, then in the
  root of the project. A set `TLA2TOOLS_JAR` is the only place that the
  task looks. See `docs/TESTING.md` for the pinned release of the jar.

      mix beam_com.tlc                  # all the models
      mix beam_com.tlc --skip-missing   # no error with no Java or no jar
      mix beam_com.tlc --only KvBlocks  # the models of one module of specs/

  The task fails when a model has an error.
  """
  use Mix.Task

  @specs "specs"

  @impl Mix.Task
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: [skip_missing: :boolean, only: :string])

    case status(System.find_executable("java"), jar_candidates()) do
      {:ok, jar} ->
        if opts[:only] == nil, do: Mix.Task.run("accord.check", [])
        failed = for cfg <- configs(@specs, opts[:only]), not check(jar, cfg), do: cfg
        if failed != [], do: Mix.raise("TLC found an error in: #{Enum.join(failed, ", ")}")

      {:error, reason} ->
        if opts[:skip_missing],
          do: Mix.shell().info(message(reason)),
          else: Mix.raise(message(reason))
    end
  end

  @doc "Gives the jar, or the reason that TLC cannot run."
  def status(nil, _jars), do: {:error, :no_java}

  def status(_java, jars) do
    case Enum.find(jars, &File.exists?/1) do
      nil -> {:error, :no_jar}
      jar -> {:ok, jar}
    end
  end

  @doc "The places of the jar, in order."
  def jar_candidates do
    case System.get_env("TLA2TOOLS_JAR") do
      nil -> [Path.expand("~/.tla/tla2tools.jar"), Path.expand("tla2tools.jar")]
      jar -> [jar]
    end
  end

  @doc "The models of `dir`: `[{module, cfg}]`, sorted. `only` keeps one module."
  def configs(dir, only \\ nil) do
    for cfg <- dir |> Path.join("*.cfg") |> Path.wildcard() |> Enum.sort(),
        module = cfg |> Path.basename() |> String.split(".") |> hd(),
        only == nil or module == only,
        do: {module, cfg}
  end

  @doc "True when the output of TLC tells that the model has no error."
  def passed?(output), do: output =~ "Model checking completed. No error has been found."

  defp check(jar, {module, cfg}) do
    Mix.shell().info("TLC: #{Path.basename(cfg)}")
    meta = Path.join(System.tmp_dir!(), "beam_com_tlc_#{System.unique_integer([:positive])}")

    args =
      ~w(-XX:+UseParallelGC -cp #{jar} tlc2.TLC -workers auto -deadlock) ++
        ["-metadir", meta, "-config", Path.basename(cfg), module]

    {output, _} = System.cmd("java", args, cd: Path.dirname(cfg), stderr_to_stdout: true)
    File.rm_rf(meta)

    if passed?(output) do
      Mix.shell().info(
        output
        |> String.split("\n")
        |> Enum.find("", &(&1 =~ "distinct states found, 0 states left"))
      )

      true
    else
      Mix.shell().error(output)
      false
    end
  end

  defp message(:no_java), do: "TLC needs Java: no java on the PATH."
  defp message(:no_jar), do: "TLC needs tla2tools.jar: set TLA2TOOLS_JAR (see docs/TESTING.md)."
end
