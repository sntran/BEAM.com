defmodule BeamComScriptTest do
  @moduledoc """
  The tests of `:beam_com_script`: the copy of a priv directory to real
  files (`extract/2`).

  The module is not async: the tests add a fake application to the code
  path of the VM.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  describe "extract_test_" do
    # A fake application xapp-1.2 in the code path, with priv/run.sh and
    # priv/sub/data.txt.
    setup %{tmp_dir: tmp} do
      dir = String.to_charlist(tmp)
      lib = :filename.join([dir, ~c"lib", ~c"xapp-1.2"])
      ebin = :filename.join(lib, ~c"ebin")
      :ok = :filelib.ensure_path(ebin)

      :ok =
        :file.write_file(
          :filename.join(ebin, ~c"xapp.app"),
          "{application, xapp, [{vsn, \"1.2\"}, {modules, []}]}.\n"
        )

      :ok = :filelib.ensure_path(:filename.join([lib, ~c"priv", ~c"sub"]))
      :ok = :file.write_file(:filename.join([lib, ~c"priv", ~c"run.sh"]), "#!/bin/sh\necho run\n")
      :ok = :file.write_file(:filename.join([lib, ~c"priv", ~c"sub", ~c"data.txt"]), "data")
      true = :code.add_pathz(ebin)

      on_exit(fn ->
        for p <- :code.get_path(), :lists.prefix(dir, p), do: :code.del_path(p)
        # The copies are read-only: make them writable to remove them.
        for f <- :filelib.wildcard(:filename.join(dir, ~c"**")), do: :file.change_mode(f, 0o755)
        :file.del_dir_r(dir)
      end)

      %{dir: dir}
    end

    test "a copy of priv, with the modes", %{dir: dir} do
      cache = :filename.join(dir, ~c"cache")
      zip_ebin = :code.lib_dir(:xapp) ++ ~c"/ebin"
      :ok = :beam_com_script.extract({:xapp, ~c"1.2", ~c"abc", [~c"run.sh"]}, cache)
      priv = :filename.join([cache, ~c"priv", ~c"abc", ~c"xapp-1.2", ~c"priv"])
      assert priv == :code.priv_dir(:xapp)

      assert {:ok, "#!/bin/sh\necho run\n"} ==
               :file.read_file(:filename.join(priv, ~c"run.sh"))

      assert {:ok, "data"} == :file.read_file(:filename.join([priv, ~c"sub", ~c"data.txt"]))

      case :os.type() do
        {:win32, _} ->
          :ok

        _ ->
          assert 0o555 == mode(:filename.join(priv, ~c"run.sh"))
          assert 0o444 == mode(:filename.join([priv, ~c"sub", ~c"data.txt"]))
      end

      # The original ebin stays in the code path (for the code).
      assert zip_ebin in :code.get_path()
      # No temporary directory is left.
      assert [] == :filelib.wildcard(:filename.join([cache, ~c"priv", ~c"abc", ~c"*.tmp.*"]))
      # A second start uses the copy: a change to the source is not seen.
      :ok = :file.write_file(:filename.join([zip_ebin, ~c"..", ~c"priv", ~c"run.sh"]), "changed")
      :ok = :beam_com_script.extract({:xapp, ~c"1.2", ~c"abc", [~c"run.sh"]}, cache)

      assert {:ok, "#!/bin/sh\necho run\n"} ==
               :file.read_file(:filename.join(priv, ~c"run.sh"))
    end
  end

  defp mode(file) do
    {:ok, info} = :file.read_file_info(file)
    Bitwise.band(elem(info, 7), 0o777)
  end
end
