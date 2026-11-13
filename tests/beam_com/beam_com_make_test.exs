defmodule BeamComMakeTest do
  @moduledoc """
  The tests of `:beam_com_make`: the make of elixir_make for the packages
  whose NIFs are linked into beam.com, or whose NIF files are in it (a NIF
  library in WebAssembly, or native NIF objects).

  A test changes the PATH of the OS, so the module is not async.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

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

  # lazy_html: a NIF library in WebAssembly in beam.com, with its files in
  # priv/nifs/lazy_html-0.1.13. vix: native NIF objects, in two versions.
  # rusty_csv: an object in the subdirectory native/.
  describe "nif_files_test_" do
    setup %{tmp_dir: tmp_dir} do
      dir = String.to_charlist(tmp_dir)
      priv = :filename.join(dir, ~c"priv")
      nifs = :filename.join([priv, ~c"nifs", ~c"lazy_html-0.1.13"])
      write(nifs, ~c"liblazy_html.wasm", "wasm")
      write(nifs, ~c"liblazy_html.x86_64.aot", "aot")
      vix = :filename.join([priv, ~c"nifs", ~c"vix-0.42.0"])
      write(vix, ~c"vix.x86_64.o", "x86_64")
      write(vix, ~c"vix.aarch64.o", "aarch64")
      write(:filename.join([priv, ~c"nifs", ~c"vix-0.41.0"]), ~c"vix.x86_64.o", "old")

      write(
        :filename.join([priv, ~c"nifs", ~c"rusty_csv-0.4.6", ~c"native"]),
        ~c"librustycsv.x86_64.o",
        "csv"
      )

      # Not a package: a file, and names with no version.
      write(:filename.join(priv, ~c"nifs"), ~c"README", "text")
      :ok = :filelib.ensure_path(:filename.join([priv, ~c"nifs", ~c"noversion"]))
      :ok = :filelib.ensure_path(:filename.join([priv, ~c"nifs", ~c"-1.0"]))
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
      assert :ok == files_run([~c"all"], ctx.pkg, ctx.app_path, ctx.priv)
      priv = :filename.join(ctx.app_path, ~c"priv")
      assert {:ok, "wasm"} == :file.read_file(:filename.join(priv, ~c"liblazy_html.wasm"))
      assert {:ok, "aot"} == :file.read_file(:filename.join(priv, ~c"liblazy_html.x86_64.aot"))
    end

    test "make clean does nothing", ctx do
      assert :ok == files_run([~c"clean"], ctx.pkg, ctx.app_path, ctx.priv)
      refute :filelib.is_dir(:filename.join(ctx.app_path, ~c"priv"))
    end

    test "another version of the package", ctx do
      assert ~c"lazy_html 0.1.12 has a NIF, and beam.com has the NIF of " ++
               ~c"lazy_html 0.1.13. Use lazy_html 0.1.13 " ++
               ~c"(in the deps of mix.exs: {:lazy_html, \"0.1.13\"})" ==
               error_text(fn ->
                 files_run([~c"all"], ctx.old, :filename.join(ctx.dir, ~c"lazy_html"), ctx.priv)
               end)
    end

    test "no files of the library: an empty directory", ctx do
      none = :filename.join(ctx.dir, ~c"none")
      :ok = :filelib.ensure_path(:filename.join([none, ~c"nifs", ~c"lazy_html-0.1.13"]))

      text = error_text(fn -> files_run([~c"all"], ctx.pkg, ctx.app_path, none) end)
      assert List.to_string(text) =~ "no NIF files of lazy_html 0.1.13"
    end

    test "native objects: the files of the version of the package", ctx do
      pkg = :filename.join(ctx.dir, ~c"vix")
      write(pkg, ~c"mix.exs", "@version \"0.42.0\"\n")
      app_path = :filename.join([ctx.dir, ~c"_build", ~c"dev", ~c"lib", ~c"vix"])
      assert :ok == files_run([], pkg, app_path, ctx.priv)
      priv = :filename.join(app_path, ~c"priv")
      assert {:ok, "x86_64"} == :file.read_file(:filename.join(priv, ~c"vix.x86_64.o"))
      assert {:ok, "aarch64"} == :file.read_file(:filename.join(priv, ~c"vix.aarch64.o"))
      # The other version, and a version that beam.com does not have.
      write(pkg, ~c"mix.exs", "@version \"0.41.0\"\n")
      assert :ok == files_run([~c"all"], pkg, app_path, ctx.priv)
      assert {:ok, "old"} == :file.read_file(:filename.join(priv, ~c"vix.x86_64.o"))
      write(pkg, ~c"mix.exs", "@version \"0.40.0\"\n")
      text = error_text(fn -> files_run([~c"all"], pkg, app_path, ctx.priv) end)

      assert List.to_string(text) =~
               "vix 0.40.0 has a NIF, and beam.com has the NIF of vix 0.41.0"
    end

    test "native objects: no version is known, a file in a subdirectory", ctx do
      pkg = :filename.join(ctx.dir, ~c"rusty_csv")
      :ok = :filelib.ensure_path(pkg)
      assert :ok == files_run([], pkg, ~c"", ctx.priv)

      assert {:ok, "csv"} ==
               :file.read_file(
                 :filename.join([pkg, ~c"priv", ~c"native", ~c"librustycsv.x86_64.o"])
               )
    end

    test "nif_files/3 reads the files, in order, also in subdirectories", ctx do
      assert [{~c"liblazy_html.wasm", "wasm"}, {~c"liblazy_html.x86_64.aot", "aot"}] ==
               :beam_com_make.nif_files(:lazy_html, ~c"0.1.13", ctx.priv)

      assert [{~c"native/librustycsv.x86_64.o", "csv"}] ==
               :beam_com_make.nif_files(:rusty_csv, ~c"0.4.6", ctx.priv)

      assert [] == :beam_com_make.nif_files(:lazy_html, ~c"0.1.12", ctx.priv)
    end

    test "file_nifs/1: the packages of the directories of priv/nifs", ctx do
      assert [
               {:lazy_html, ~c"0.1.13"},
               {:rusty_csv, ~c"0.4.6"},
               {:vix, ~c"0.41.0"},
               {:vix, ~c"0.42.0"}
             ] == :beam_com_make.file_nifs(ctx.priv)

      assert [] == :beam_com_make.file_nifs(:filename.join(ctx.dir, ~c"none"))
    end

    # The files of priv/nifs of this repository.
    test "nif_files/2 and file_nifs/0: the files of beam.com" do
      names = for {name, _} <- :beam_com_make.nif_files(:lazy_html, ~c"0.1.13"), do: name
      assert ~w(liblazy_html.aarch64.aot liblazy_html.wasm liblazy_html.x86_64.aot)c == names
      assert [] == :beam_com_make.nif_files(:lazy_html, ~c"0.1.12")
      assert [] == :beam_com_make.nif_files(:other, ~c"0.1.13")
      assert {:lazy_html, ~c"0.1.13"} in :beam_com_make.file_nifs()
      assert :beam_com_make.priv() == :filename.join(:code.lib_dir(:beam_com), ~c"priv")
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

    # A package with a linked NIF and a precompiled NIF (vix) gets a
    # download of that NIF without force_build. Mix loaded beam_com, so
    # force_build/0 reads the env of the application.
    test "force_build/0 adds the linked NIFs too" do
      true = List.keymember?(:application.loaded_applications(), :beam_com, 0)
      old = :application.get_env(:beam_com, :nifs)
      :application.unset_env(:elixir_make, :force_build)

      try do
        :application.set_env(:beam_com, :nifs, [{:vix, ~c"0.42.0"}])
        :ok = :beam_com_make.force_build()
        {:ok, list} = :application.get_env(:elixir_make, :force_build)
        assert list[:vix] == true
        assert list[:lazy_html] == true
      after
        :application.unset_env(:elixir_make, :force_build)

        case old do
          {:ok, nifs} -> :application.set_env(:beam_com, :nifs, nifs)
          :undefined -> :application.unset_env(:beam_com, :nifs)
        end
      end
    end
  end

  # At the start of a tool of Elixir, beam_com is not loaded: the linked
  # NIFs come from the .app file, with no load of the application.
  describe "app_file_nifs/1" do
    test "the env nifs of the .app file", %{tmp_dir: dir} do
      file = Path.join(dir, "beam_com.app")

      File.write!(file, """
      {application, beam_com, [{vsn, "1.0.0"}, {env, [{nifs, [{vix, "0.42.0"}]}]}]}.
      """)

      assert [{:vix, ~c"0.42.0"}] == :beam_com_make.app_file_nifs(String.to_charlist(file))
    end

    test "no env nifs, a bad file, no file", %{tmp_dir: dir} do
      file = Path.join(dir, "beam_com.app")
      File.write!(file, "{application, beam_com, [{vsn, \"1.0.0\"}]}.\n")
      assert [] == :beam_com_make.app_file_nifs(String.to_charlist(file))
      File.write!(file, "{application, beam_com, [{env, [{nifs, none}]}]}.\n")
      assert [] == :beam_com_make.app_file_nifs(String.to_charlist(file))
      File.write!(file, "not a term")
      assert [] == :beam_com_make.app_file_nifs(String.to_charlist(file))
      assert [] == :beam_com_make.app_file_nifs(:non_existing)
    end
  end

  defp files_run(args, cwd, app_path, priv) do
    :beam_com_make.run(args, %{
      cwd: cwd,
      app_path: app_path,
      nifs: @linked_nifs,
      file_nifs: :beam_com_make.file_nifs(priv),
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

  # The file SOURCE of a directory of priv/nifs names the package of its
  # files: the Hex package of the name (no file), a git repository, or a
  # commit or a tag of it.
  describe "sources" do
    setup %{tmp_dir: dir} do
      priv = Path.join(dir, "priv")

      put = fn name, source, files ->
        d = Path.join([priv, "nifs", name])
        File.mkdir_p!(d)
        if source, do: File.write!(Path.join(d, "SOURCE"), source)
        for {f, data} <- files, do: File.write!(Path.join(d, f), data)
      end

      put.("tailwind-0.5.2", nil, [{"hex.o", "hex"}])
      put.("tailwind-0.2.0", "git https://github.com/sntran/tailwind.com\n", [{"any.o", "any"}])

      put.(
        "tailwind-c0be553",
        "# The objects of the commit c0be553.\ngit https://GitHub.com/sntran/tailwind.com.git/ commit=C0BE553 tag=v0.3.0\n",
        [{"commit.o", "commit"}]
      )

      put.("vix-0.42.0", "hex\n", [{"vix.o", "vix"}])
      put.("rename-1.0.0", "hex rename_ex\n", [{"r.o", "r"}])
      put.("bad-1.0.0", "svn https://example.com/x\n", [{"bad.o", "bad"}])
      %{priv: String.to_charlist(priv)}
    end

    test "source/1: the forms of SOURCE", %{priv: priv} do
      dir = fn name -> :filename.join([priv, ~c"nifs", name]) end
      assert :hex == :beam_com_make.source(dir.(~c"tailwind-0.5.2"))
      assert :hex == :beam_com_make.source(dir.(~c"vix-0.42.0"))
      assert {:hex, ~c"rename_ex"} == :beam_com_make.source(dir.(~c"rename-1.0.0"))

      assert {:git, ~c"https://github.com/sntran/tailwind.com", []} ==
               :beam_com_make.source(dir.(~c"tailwind-0.2.0"))

      assert {:git, ~c"https://github.com/sntran/tailwind.com",
              [{:commit, ~c"c0be553"}, {:tag, ~c"v0.3.0"}]} ==
               :beam_com_make.source(dir.(~c"tailwind-c0be553"))

      assert :invalid == :beam_com_make.source(dir.(~c"bad-1.0.0"))

      for text <- [
            "git\n",
            "git not-a-url\n",
            "git https://h/x commit=abc\n",
            "git https://h/x commit=#{String.duplicate("a", 41)}\n",
            "git https://h/x commit=xyz1234\n",
            "git https://h/x tag=\n",
            "git https://h/x branch=main\n",
            "hex a b\n",
            "git https://h/x\ngit https://h/y\n",
            "",
            <<0xFF, 0xFE>>
          ] do
        File.write!(:filename.join(dir.(~c"bad-1.0.0"), ~c"SOURCE"), text)
        assert :invalid == :beam_com_make.source(dir.(~c"bad-1.0.0")), text
      end
    end

    test "the hooks and the plain builder see only the Hex packages, and no SOURCE",
         %{priv: priv} do
      # The hooks know the application, not its Hex package: the files
      # of "hex rename_ex" are not for them.
      assert [{:tailwind, ~c"0.5.2"}, {:vix, ~c"0.42.0"}] ==
               Enum.sort(:beam_com_make.file_nifs(priv))

      assert [{~c"vix.o", "vix"}] == :beam_com_make.nif_files(:vix, ~c"0.42.0", priv)
      assert [{~c"hex.o", "hex"}] == :beam_com_make.nif_files(:tailwind, ~c"0.5.2", priv)
      assert [] == :beam_com_make.nif_files(:tailwind, ~c"0.2.0", priv)
      assert [] == :beam_com_make.nif_files(:tailwind, ~c"c0be553", priv)
      assert [] == :beam_com_make.nif_files(:bad, ~c"1.0.0", priv)
      # "hex rename_ex" is the package rename_ex, not rename.
      assert [] == :beam_com_make.nif_files(:rename, ~c"1.0.0", priv)
    end

    test "match_nifs/2: the source and the version of each dep", %{priv: priv} do
      url = "https://github.com/sntran/tailwind.com.git"
      commit = ~c"c0be5530906454fbd3ff5b9dca9af32fb87b24af"
      other = ~c"1111111111111111111111111111111111111111"

      files = fn deps -> :beam_com_make.match_nifs(priv, deps) end

      # The Hex package tailwind 0.5.2 gets the Hex files, and the Hex
      # package tailwind 0.2.0 gets none: the git files of 0.2.0 are not
      # for it.
      assert [{:tailwind, ~c"0.5.2", [{~c"hex.o", "hex"}]}] ==
               files.([{:tailwind, ~c"0.5.2", {:hex, ~c"tailwind"}}])

      assert [{:tailwind, :nomatch, _}] = files.([{:tailwind, ~c"0.2.0", {:hex, ~c"tailwind"}}])

      # The git dep at the commit gets the files of the commit, before
      # the files of its version.
      assert [{:tailwind, ~c"c0be553", [{~c"commit.o", "commit"}]}] ==
               files.([{:tailwind, ~c"0.2.0", {:git, url, commit, [branch: ~c"main"]}}])

      # At another commit: the files of the version 0.2.0 of the
      # repository, else none.
      assert [{:tailwind, ~c"0.2.0", [{~c"any.o", "any"}]}] ==
               files.([{:tailwind, ~c"0.2.0", {:git, url, other, [branch: ~c"main"]}}])

      assert [{:tailwind, :nomatch, _}] =
               files.([{:tailwind, ~c"0.4.0", {:git, url, other, [branch: ~c"main"]}}])

      # The tag of mix.exs, at any commit.
      assert [{:tailwind, ~c"c0be553", _}] =
               files.([{:tailwind, ~c"0.9.0", {:git, url, other, [tag: ~c"v0.3.0"]}}])

      # Another repository, a path dep, a package of another name.
      fork = {:git, "https://github.com/fork/tailwind.com", commit, []}
      assert [{:tailwind, :nomatch, _}] = files.([{:tailwind, ~c"0.2.0", fork}])
      assert [{:tailwind, :nomatch, _}] = files.([{:tailwind, ~c"0.2.0", :other}])
      assert [{:rename, ~c"1.0.0", _}] = files.([{:rename, ~c"1.0.0", {:hex, ~c"rename_ex"}}])
      assert [{:rename, :nomatch, _}] = files.([{:rename, ~c"1.0.0", {:hex, ~c"rename"}}])
      assert [{:bad, :nomatch, _}] = files.([{:bad, ~c"1.0.0", {:hex, ~c"bad"}}])
      # A dep with no NIF files.
      assert [] == files.([{:jason, ~c"1.4.4", {:hex, ~c"jason"}}])
    end

    test "nif_dirs/1 and source_text/1", %{priv: priv} do
      texts =
        for {app, vsn, source} <- :beam_com_make.nif_dirs(priv),
            do: {app, vsn, IO.iodata_to_binary(:beam_com_make.source_text(source))}

      assert {:tailwind, ~c"c0be553",
              "git https://github.com/sntran/tailwind.com commit=c0be553 tag=v0.3.0"} in texts

      assert {:tailwind, ~c"0.5.2", "hex"} in texts
      assert {:rename, ~c"1.0.0", "hex rename_ex"} in texts
      assert {:bad, ~c"1.0.0", "an invalid SOURCE"} in texts
    end

    # The URL of a repository has one form: the forms of Mix (github:
    # gives a URL with .git) compare equal.
    property "url/1: case of the scheme and the host, and / and .git at the end" do
      check all(
              host <- string(:alphanumeric, min_length: 1),
              path <- list_of(string(:alphanumeric, min_length: 1), min_length: 1),
              suffix <- member_of(["", "/", ".git", ".git/"])
            ) do
        base = "https://#{host}/#{Enum.join(path, "/")}"
        url = :beam_com_make.url(String.to_charlist(base <> suffix))

        assert url ==
                 :beam_com_make.url(
                   String.to_charlist(
                     String.upcase("https://#{host}") <> "/" <> Enum.join(path, "/")
                   )
                 )

        assert url == :beam_com_make.url(url)
        refute :lists.suffix(~c".git", url)
      end
    end
  end
end
