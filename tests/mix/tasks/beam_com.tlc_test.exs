defmodule Mix.Tasks.BeamCom.TlcTest do
  @moduledoc """
  The tests of `mix beam_com.tlc`: the toolchain, the models of `specs/`,
  and the output of TLC. The CI job "Check the models" runs TLC itself.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.BeamCom.Tlc

  @moduletag :tmp_dir

  test "no Java" do
    assert {:error, :no_java} == Tlc.status(nil, ["tla2tools.jar"])
  end

  test "no jar", %{tmp_dir: dir} do
    assert {:error, :no_jar} == Tlc.status("/usr/bin/java", [Path.join(dir, "no.jar")])
  end

  test "the first jar that exists", %{tmp_dir: dir} do
    jar = Path.join(dir, "tla2tools.jar")
    File.write!(jar, "")
    assert {:ok, ^jar} = Tlc.status("/usr/bin/java", [Path.join(dir, "no.jar"), jar])
  end

  test "each model of specs/, with its module" do
    configs = Tlc.configs("specs")
    assert {"KvBlocks", "specs/KvBlocks.cfg"} in configs
    assert {"MC_Admission", "specs/MC_Admission.max1.cfg"} in configs
    assert [{"GreenThreads", "specs/GreenThreads.cfg"}] == Tlc.configs("specs", "GreenThreads")

    for {module, _} <- configs, do: assert(File.regular?(Path.join("specs", module <> ".tla")))
  end

  test "the output of TLC" do
    assert Tlc.passed?("...\nModel checking completed. No error has been found.\n")
    refute Tlc.passed?("Error: Invariant ReadsAreRight is violated.\n")
  end
end
