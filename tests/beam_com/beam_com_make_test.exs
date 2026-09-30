defmodule BeamComMakeTest do
  @moduledoc """
  The tests of `:beam_com_make`: the make of elixir_make for the packages
  whose NIFs are linked into beam.com.

  A test changes the PATH of the OS, so the module is not async.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  @linked_nifs [{:exqlite, ~c"0.41.0"}, {:bcrypt_elixir, ~c"3.3.2"}]

  describe "make_test_" do
    setup %{tmp_dir: tmp_dir} do
      dir = String.to_charlist(tmp_dir)
      hex = :filename.join(dir, ~c"exqlite")

      write(
        hex,
        ~c"hex_metadata.config",
        "{<<\"name\">>,<<\"exqlite\">>}.\n{<<\"version\">>,<<\"0.41.0\">>}.\n"
      )

      write(hex, ~c"mix.exs", "@version \"9.9.9\"\n")
      old = :filename.join(dir, ~c"exqlite_old")
      write(old, ~c"mix.exs", "defmodule M do\n  @version \"0.40.0\"\nend\n")
      git = :filename.join(dir, ~c"bcrypt_elixir")
      write(git, ~c"mix.exs", "[app: :bcrypt_elixir, version: \"3.3.2\"]\n")
      none = :filename.join(dir, ~c"none")
      :ok = :filelib.ensure_path(none)
      other = :filename.join(dir, ~c"other")
      :ok = :filelib.ensure_path(other)
      %{dir: dir, hex: hex, old: old, git: git, none: none, other: other}
    end

    test "the version of a package: hex_metadata.config", %{hex: hex} do
      assert ~c"0.41.0" == :beam_com_make.dep_version(hex)
    end

    test "the version of a package: @version of mix.exs", %{old: old} do
      assert ~c"0.40.0" == :beam_com_make.dep_version(old)
    end

    test "the version of a package: version of mix.exs", %{git: git} do
      assert ~c"3.3.2" == :beam_com_make.dep_version(git)
    end

    test "the version of a package: no version", %{none: none} do
      assert :undefined == :beam_com_make.dep_version(none)
    end

    test "a linked NIF: nothing to do: all", %{hex: hex} do
      assert :ok == run([~c"all"], hex, ~c"/p/_build/dev/lib/exqlite")
    end

    test "a linked NIF: nothing to do: clean", %{hex: hex} do
      assert :ok == run([~c"clean"], hex, ~c"/p/_build/dev/lib/exqlite")
    end

    test "a linked NIF: nothing to do: no arguments", %{git: git} do
      assert :ok == run([], git, ~c"")
    end

    # The version is not known: the NIF is used.
    test "a linked NIF: nothing to do: the version is not known", %{none: none} do
      assert :ok == run([~c"all"], none, ~c"/p/_build/dev/lib/exqlite")
    end

    test "a linked NIF of another version", %{old: old} do
      assert ~c"exqlite 0.40.0 has a NIF, and beam.com has the NIF of exqlite 0.41.0 " ++
               ~c"(which it always uses). Use exqlite 0.41.0 " ++
               ~c"(in the deps of mix.exs: {:exqlite, \"0.41.0\"})" ==
               error_text(fn -> run([~c"all"], old, ~c"/p/_build/dev/lib/exqlite") end)
    end

    test "another package: the make of PATH, else an error", %{dir: dir, other: other} do
      case :os.find_executable(~c"make") do
        false ->
          assert {:error, _, [~c"other" | _]} = catch_throw(run([~c"all"], other, ~c""))

        make ->
          assert {:make, make, [~c"-f", ~c"M", ~c"all"]} ==
                   run([~c"-f", ~c"M", ~c"all"], other, ~c"")
      end

      path = System.get_env("PATH")
      System.put_env("PATH", List.to_string(dir))

      try do
        assert ~c"other has C code (a NIF) that is not in beam.com, and there is no make " ++
                 ~c"in PATH. The NIFs in beam.com: exqlite 0.41.0, bcrypt_elixir 3.3.2" ==
                 error_text(fn -> run([~c"all"], other, ~c"") end)
      after
        System.put_env("PATH", path)
      end
    end
  end

  defp run(args, cwd, app_path) do
    :beam_com_make.run(args, %{
      cwd: cwd,
      app_path: app_path,
      nifs: @linked_nifs,
      make: ~c"/nowhere/make"
    })
  end

  # The text of the error that fun throws, or the result of fun.
  defp error_text(fun) do
    fun.()
  catch
    :throw, {:error, format, args} -> :lists.flatten(:io_lib.format(format, args))
  end

  defp write(dir, name, content) do
    :ok = :filelib.ensure_path(dir)
    :ok = :file.write_file(:filename.join(dir, name), content)
  end
end
