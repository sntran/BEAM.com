defmodule BeamCom.EunitTest do
  @moduledoc """
  The EUnit tests of tests/eunit, one ExUnit test for each test function
  (NAME_test/0) and each test generator (NAME_test_/0). The modules move
  to ExUnit files one by one; this module runs the ones that are left.

  Each test runs in its own directory, with no project: the commands of
  beam.com look for a project in the current directory.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  for file <- Path.wildcard(Path.join(__DIR__, "eunit/*_tests.erl")) |> Enum.sort(),
      module = file |> Path.basename(".erl") |> String.to_atom(),
      {function, 0} <- module.module_info(:exports),
      name = Atom.to_string(function),
      String.ends_with?(name, ["_test", "_test_"]) do
    spec =
      if String.ends_with?(name, "_test_"),
        do: {:generator, module, function},
        else: {module, function}

    @tag eunit: module
    test "#{module}:#{name}", %{tmp_dir: dir} do
      spec = unquote(Macro.escape(spec))

      output =
        capture_io(:stderr, fn ->
          IO.write(
            :stderr,
            capture_io(fn ->
              send(self(), {:result, File.cd!(dir, fn -> :eunit.test(spec, []) end)})
            end)
          )
        end)

      assert_received {:result, result}
      assert result == :ok, output
    end
  end
end
