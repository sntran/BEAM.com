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

    on_exit(fn ->
      :application.unset_env(:rustler_precompiled, :force_build_all)
      :application.unset_env(:rusty_csv, RustyCSV.Native)

      case old do
        :none -> :persistent_term.erase(:beam_com_rustler)
        nifs -> :persistent_term.put(:beam_com_rustler, nifs)
      end
    end)
  end

  describe "force_build/1" do
    test "each crate of rustler_precompiled builds, a linked crate with no cargo" do
      :application.set_env(:rusty_csv, RustyCSV.Native, mode: :release)
      :ok = :beam_com_rustler.force_build(@linked ++ [{:vix, ~c"0.42.0"}])
      assert {:ok, true} == :application.get_env(:rustler_precompiled, :force_build_all)
      {:ok, env} = :application.get_env(:rusty_csv, RustyCSV.Native)
      assert env[:skip_compilation?] == true
      assert env[:mode] == :release
      assert @linked ++ [{:vix, ~c"0.42.0"}] == :persistent_term.get(:beam_com_rustler)
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

    test "the crate is the name of the application by default" do
      assert_raise RuntimeError, ~r/^RustyCSV.Native: the Rust crate rusty_csv is not in/, fn ->
        :beam_com_rustler.config(RustyCSV.Native, otp_app: :rusty_csv)
      end
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
      assert code =~ "@on_load :rustler_init"
      assert code =~ "def rustler_init do"
      assert code =~ ":erlang.load_nif("
      # The function of the module calls no module of beam.com.
      refute Macro.to_string(Enum.at(body, 3)) =~ "beam_com_rustler."
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
end
