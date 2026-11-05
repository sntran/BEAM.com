defmodule BeamComRustlerTest do
  @moduledoc """
  The tests of `:beam_com_rustler` and of the module `Rustler` of beam.com:
  the NIFs of Rust that are linked into beam.com.

  A test changes the env of applications and a persistent term, so the
  module is not async.
  """
  use ExUnit.Case, async: false

  @linked [{:rusty_csv, ~c"0.4.6"}]

  setup do
    old = :persistent_term.get(:beam_com_rustler, :none)
    old_priv = :persistent_term.get({:beam_com_rustler, :priv}, :none)
    old_force = System.get_env("RUSTLER_PRECOMPILED_FORCE_BUILD_ALL")
    old_unlinked = System.get_env("BEAM_COM_UNLINKED_NIFS")
    System.delete_env("BEAM_COM_UNLINKED_NIFS")

    on_exit(fn ->
      :application.unset_env(:rusty_csv, RustyCSV.Native)
      restore_env("RUSTLER_PRECOMPILED_FORCE_BUILD_ALL", old_force)
      restore_env("BEAM_COM_UNLINKED_NIFS", old_unlinked)

      case old do
        :none -> :persistent_term.erase(:beam_com_rustler)
        nifs -> :persistent_term.put(:beam_com_rustler, nifs)
      end

      case old_priv do
        :none -> :persistent_term.erase({:beam_com_rustler, :priv})
        priv -> :persistent_term.put({:beam_com_rustler, :priv}, priv)
      end
    end)
  end

  describe "force_build/1" do
    test "each crate of rustler_precompiled builds, a linked crate with no cargo" do
      :application.set_env(:rusty_csv, RustyCSV.Native, mode: :release)
      :ok = :beam_com_rustler.force_build(@linked ++ [{:vix, ~c"0.42.0"}])
      assert "true" == System.get_env("RUSTLER_PRECOMPILED_FORCE_BUILD_ALL")
      {:ok, env} = :application.get_env(:rusty_csv, RustyCSV.Native)
      assert env[:skip_compilation?] == true
      assert env[:mode] == :release
      assert @linked ++ [{:vix, ~c"0.42.0"}] == :persistent_term.get(:beam_com_rustler)
    end

    # Issue 147: use RustlerPrecompiled reads force_build_all with
    # Application.compile_env/3. A value in the application env is recorded,
    # and a release whose sys.config does not set it stops at boot. A value
    # from the environment variable (the default of compile_env/3) is not.
    test "force_build_all is the environment variable, not the application env" do
      # An older beam.com that runs the test set the key at its start.
      :application.unset_env(:rustler_precompiled, :force_build_all, persistent: true)
      :ok = :beam_com_rustler.force_build(@linked)
      assert :undefined == :application.get_env(:rustler_precompiled, :force_build_all)
      assert "true" == System.get_env("RUSTLER_PRECOMPILED_FORCE_BUILD_ALL")
    end

    test "a crate that is not linked gets no env" do
      :ok = :beam_com_rustler.force_build([{:vix, ~c"0.42.0"}])
      assert :undefined == :application.get_env(:rusty_csv, RustyCSV.Native)
    end

    # Mix removes beam_com from the code path before it compiles.
    test "the modules of the compilation are loaded" do
      :ok = :beam_com_rustler.force_build([])

      for m <- [Rustler, :beam_com_rustler, :beam_com_make, :beam_com] do
        assert {:file, _} = :code.is_loaded(m)
      end
    end

    # The native NIF objects are in the priv directory of beam_com, which
    # is not in the code path while Mix compiles.
    test "the priv directory of beam_com stays" do
      :ok = :beam_com_rustler.force_build([])
      assert :beam_com_make.priv() == :persistent_term.get({:beam_com_rustler, :priv})
    end
  end

  describe "check/3" do
    test "a linked crate, of the same version or of no known version" do
      linked = :beam_com_rustler.linked(@linked)
      assert [{:rusty_csv, RustyCSV.Native, "rustycsv", ~c"0.4.6"}] == linked
      assert :ok == :beam_com_rustler.check("rustycsv", linked, ~c"0.4.6")
      assert :ok == :beam_com_rustler.check("rustycsv", linked, :undefined)
    end

    test "a linked crate of another version" do
      linked = :beam_com_rustler.linked(@linked)
      {:error, message} = :beam_com_rustler.check("rustycsv", linked, ~c"0.4.5")
      message = IO.chardata_to_string(message)
      assert message =~ "rusty_csv 0.4.5 has a NIF of Rust"
      assert message =~ "{:rusty_csv, \"0.4.6\"}"
    end

    test "a crate that is not linked" do
      {:error, message} =
        :beam_com_rustler.check("other", :beam_com_rustler.linked(@linked), :undefined)

      message = IO.chardata_to_string(message)
      assert message =~ "the Rust crate other is not in"
      assert message =~ "The NIFs of Rust in"
      assert message =~ "rusty_csv 0.4.6"
      {:error, none} = :beam_com_rustler.check("other", [], :undefined)
      assert IO.chardata_to_string(none) =~ ": none"
    end
  end

  describe "config/2" do
    setup do
      :persistent_term.put(:beam_com_rustler, @linked)
    end

    test "the arguments of load_nif/2: a path, and the load data" do
      assert {~c"rusty_csv/priv/native/librustycsv", 0} ==
               :beam_com_rustler.config(RustyCSV.Native, otp_app: :rusty_csv, crate: "rustycsv")

      assert {_, {:{}, [], [:a, :b, :c]}} =
               :beam_com_rustler.config(RustyCSV.Native,
                 otp_app: :rusty_csv,
                 crate: :rustycsv,
                 load_data: {:a, :b, :c}
               )

      assert {_, {{:., [], [M, :f]}, [], []}} =
               :beam_com_rustler.config(RustyCSV.Native,
                 otp_app: :rusty_csv,
                 crate: ~c"rustycsv",
                 load_data_fun: {M, :f}
               )
    end

    # Issue 146: BEAM_COM_UNLINKED_NIFS=stub. The module compiles with no
    # on_load function, and a function of the NIF fails at its first call.
    test "a crate that is not linked, with BEAM_COM_UNLINKED_NIFS=stub" do
      System.put_env("BEAM_COM_UNLINKED_NIFS", "stub")
      assert :stub == :beam_com_rustler.unlinked()

      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule BeamComRustlerTest.Unlinked do
            use Rustler, otp_app: :beam_com_unlinked, crate: "unlinked_crate"
            def add(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
          end
          """)
        end)

      assert warning =~ "BeamComRustlerTest.Unlinked: the Rust crate unlinked_crate is not in"
      assert warning =~ "BEAM_COM_UNLINKED_NIFS=stub"
      refute function_exported?(BeamComRustlerTest.Unlinked, :rustler_init, 0)
      # The module comes from the compile above, so the call is an apply.
      module = BeamComRustlerTest.Unlinked
      assert_raise ErlangError, ~r/nif_not_loaded/, fn -> apply(module, :add, [1, 2]) end
    end

    test "a crate that is not linked, without the switch: the error names it" do
      assert :error == :beam_com_rustler.unlinked()

      assert_raise RuntimeError, ~r/set BEAM_COM_UNLINKED_NIFS=stub$/, fn ->
        :beam_com_rustler.config(Unlinked.Native, otp_app: :beam_com_unlinked, crate: "x")
      end
    end

    test "the crate is the name of the application by default" do
      assert_raise RuntimeError, ~r/^RustyCSV.Native: the Rust crate rusty_csv is not in/, fn ->
        :beam_com_rustler.config(RustyCSV.Native, otp_app: :rusty_csv)
      end
    end
  end

  # A crate with native NIF objects in priv/nifs of beam_com (a program
  # assembled from parts): ex_pdfium. rusty_csv is linked, and has an
  # object too.
  describe "config/2 with native NIF objects" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      dir = String.to_charlist(tmp_dir)
      priv = :filename.join(dir, ~c"priv")

      write(
        :filename.join([priv, ~c"nifs", ~c"ex_pdfium-0.6.0", ~c"native"]),
        ~c"libex_pdfium.x86_64.o",
        "pdf"
      )

      write(
        :filename.join([priv, ~c"nifs", ~c"rusty_csv-0.4.6", ~c"native"]),
        ~c"librustycsv.x86_64.o",
        "csv"
      )

      :persistent_term.put(:beam_com_rustler, @linked)
      :persistent_term.put({:beam_com_rustler, :priv}, priv)
      %{dir: dir}
    end

    test "load_nif/2 gets the priv directory of the package at the load" do
      path =
        {{:., [], [:filename, :join]}, [],
         [{{:., [], [:code, :priv_dir]}, [], [:ex_pdfium]}, ~c"native/libex_pdfium"]}

      assert {path, 0} ==
               :beam_com_rustler.config(ExPdfium.Native, otp_app: :ex_pdfium, crate: "ex_pdfium")

      # The code of the path, in the module of the NIF.
      assert Macro.to_string(path) ==
               ":filename.join(:code.priv_dir(:ex_pdfium), ~c\"native/libex_pdfium\")"
    end

    test "the objects go into the priv directory of the package while it compiles", ctx do
      ebin = :filename.join([ctx.dir, ~c"lib", ~c"ex_pdfium-0.6.0", ~c"ebin"])
      :ok = :filelib.ensure_path(ebin)
      true = :code.add_patha(ebin)

      try do
        object =
          :filename.join([
            ctx.dir,
            ~c"lib",
            ~c"ex_pdfium-0.6.0",
            ~c"priv",
            ~c"native",
            ~c"libex_pdfium.x86_64.o"
          ])

        {_, 0} =
          :beam_com_rustler.config(ExPdfium.Native, otp_app: :ex_pdfium, crate: "ex_pdfium")

        assert {:ok, "pdf"} == :file.read_file(object)
        # A file that is there stays.
        :ok = :file.write_file(object, "built")

        {_, 0} =
          :beam_com_rustler.config(ExPdfium.Native, otp_app: :ex_pdfium, crate: "ex_pdfium")

        assert {:ok, "built"} == :file.read_file(object)
      after
        :code.del_path(ebin)
      end
    end

    test "a linked crate wins: ERTS finds the static NIF first" do
      assert {~c"rusty_csv/priv/native/librustycsv", 0} ==
               :beam_com_rustler.config(RustyCSV.Native, otp_app: :rusty_csv, crate: "rustycsv")
    end
  end

  describe "use Rustler" do
    test "the module of the NIF gets an on_load function that loads the NIF" do
      {:__block__, [], [assign | body]} =
        Rustler."MACRO-__using__"(__ENV__, quote(do: [otp_app: :rusty_csv, crate: "rustycsv"]))

      assert {:=, [],
              [{:beam_com_rustler_opts, [], nil}, [otp_app: :rusty_csv, crate: "rustycsv"]]} ==
               assign

      code = Macro.to_string({:__block__, [], body})
      assert code =~ ":beam_com_rustler.config(__MODULE__, beam_com_rustler_opts)"
      assert code =~ "if beam_com_rustler_config != :stub do"
      assert code =~ "@on_load :rustler_init"
      assert code =~ "def rustler_init do"
      assert code =~ ":erlang.load_nif("
      # The function of the module calls no module of beam.com.
      refute Macro.to_string(Enum.at(body, 1)) =~ ":beam_com_rustler."
    end

    test "Rustler has only the macro __using__/1" do
      assert [__using__: 1] == Rustler.__info__(:macros)
      assert [] == Rustler.__info__(:functions)
      assert Rustler == Rustler.__info__(:module)
      assert [] == Rustler.__info__(:deprecated)

      for key <- [:attributes, :compile] do
        assert [] == Rustler.__info__(key)
      end

      for key <- [:md5, :exports_md5] do
        assert :undefined == Rustler.__info__(key)
      end

      assert nil == Rustler.__info__(:struct)
    end
  end

  defp write(dir, name, content) do
    :ok = :filelib.ensure_path(dir)
    :ok = :file.write_file(:filename.join(dir, name), content)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
