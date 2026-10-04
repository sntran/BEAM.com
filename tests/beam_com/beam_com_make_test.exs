defmodule BeamComMakeTest do
  @moduledoc """
  The tests of `:beam_com_make`: the make of elixir_make for the packages
  whose NIFs are linked into beam.com, or are NIF libraries in WebAssembly
  in it.

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

  # lazy_html: a NIF library in WebAssembly in beam.com (the env
  # wasm_nifs), with its files in priv/nifs/lazy_html-0.1.13.
  describe "wasm_nif_test_" do
    setup %{tmp_dir: tmp_dir} do
      dir = String.to_charlist(tmp_dir)
      priv = :filename.join(dir, ~c"priv")
      nifs = :filename.join([priv, ~c"nifs", ~c"lazy_html-0.1.13"])
      write(nifs, ~c"liblazy_html.wasm", "wasm")
      write(nifs, ~c"liblazy_html.x86_64.aot", "aot")
      pkg = :filename.join(dir, ~c"lazy_html")

      write(
        pkg,
        ~c"hex_metadata.config",
        "{<<\"name\">>,<<\"lazy_html\">>}.\n{<<\"version\">>,<<\"0.1.13\">>}.\n"
      )

      old = :filename.join(dir, ~c"lazy_html_old")
      write(old, ~c"mix.exs", "@version \"0.1.12\"\n")
      app_path = :filename.join([dir, ~c"_build", ~c"dev", ~c"lib", ~c"lazy_html"])
      %{dir: dir, priv: priv, pkg: pkg, old: old, app_path: app_path}
    end

    test "make copies the files into the priv directory of the package", ctx do
      assert :ok == wasm_run([~c"all"], ctx.pkg, ctx.app_path, ctx.priv)
      priv = :filename.join(ctx.app_path, ~c"priv")
      assert {:ok, "wasm"} == :file.read_file(:filename.join(priv, ~c"liblazy_html.wasm"))
      assert {:ok, "aot"} == :file.read_file(:filename.join(priv, ~c"liblazy_html.x86_64.aot"))
    end

    test "make clean does nothing", ctx do
      assert :ok == wasm_run([~c"clean"], ctx.pkg, ctx.app_path, ctx.priv)
      refute :filelib.is_dir(:filename.join(ctx.app_path, ~c"priv"))
    end

    test "another version of the package", ctx do
      assert ~c"lazy_html 0.1.12 has a NIF, and beam.com has the NIF library in " ++
               ~c"WebAssembly of lazy_html 0.1.13. Use lazy_html 0.1.13 " ++
               ~c"(in the deps of mix.exs: {:lazy_html, \"0.1.13\"})" ==
               error_text(fn ->
                 wasm_run([~c"all"], ctx.old, :filename.join(ctx.dir, ~c"lazy_html"), ctx.priv)
               end)
    end

    test "no files of the library", ctx do
      none = :filename.join(ctx.dir, ~c"none")

      text = error_text(fn -> wasm_run([~c"all"], ctx.pkg, ctx.app_path, none) end)
      assert List.to_string(text) =~ "no NIF library of lazy_html 0.1.13"
    end

    test "wasm_nif_files/3 reads the files, in order", ctx do
      assert [{~c"liblazy_html.wasm", "wasm"}, {~c"liblazy_html.x86_64.aot", "aot"}] ==
               :beam_com_make.wasm_nif_files(:lazy_html, ~c"0.1.13", ctx.priv)

      assert [] == :beam_com_make.wasm_nif_files(:lazy_html, ~c"0.1.12", ctx.priv)
    end

    # The files of priv/nifs of this repository, for the version of the env
    # wasm_nifs only.
    test "wasm_nif_files/2: the files of beam.com" do
      names = for {name, _} <- :beam_com_make.wasm_nif_files(:lazy_html, ~c"0.1.13"), do: name
      assert ~w(liblazy_html.aarch64.aot liblazy_html.wasm liblazy_html.x86_64.aot)c == names
      assert [] == :beam_com_make.wasm_nif_files(:lazy_html, ~c"0.1.12")
      assert [] == :beam_com_make.wasm_nif_files(:other, ~c"0.1.13")
    end

    # The env of elixir_make that the tools of Elixir set at their start.
    test "force_build/1 adds the packages, and keeps the others" do
      :application.unset_env(:elixir_make, :force_build)

      try do
        :ok = :beam_com_make.force_build([{:lazy_html, ~c"0.1.13"}])
        assert {:ok, [lazy_html: true]} == :application.get_env(:elixir_make, :force_build)
        :application.set_env(:elixir_make, :force_build, other: true, lazy_html: false)
        :ok = :beam_com_make.force_build([{:lazy_html, ~c"0.1.13"}])

        assert {:ok, [other: true, lazy_html: false]} ==
                 :application.get_env(:elixir_make, :force_build)
      after
        :application.unset_env(:elixir_make, :force_build)
      end
    end
  end

  defp wasm_run(args, cwd, app_path, priv) do
    :beam_com_make.run(args, %{
      cwd: cwd,
      app_path: app_path,
      nifs: @linked_nifs,
      wasm_nifs: [{:lazy_html, ~c"0.1.13"}],
      priv: priv,
      make: ~c"/nowhere/make"
    })
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
