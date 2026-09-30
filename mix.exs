defmodule BeamCom.MixProject do
  use Mix.Project

  # beam.com as one Mix project:
  #
  # - src/APP/: the Erlang code of each OTP application of beam.com
  #   (beam_com, beam_com_script, wasm, wasm_host);
  # - c_src/: the C code (cosmo/ for the native file, erts_wasm/ for the
  #   WebAssembly runtime, wasm/ for the NIF of WAMR);
  # - priv/wasm_host/: the JavaScript of the hosts of the WebAssembly runtime;
  # - lib/: the Elixir code: the models of the protocols and the Mix tasks;
  # - tests/: the tests, with ExUnit.
  #
  # Mix compiles all of src/ as one application, for the tests. build.sh
  # builds beam.com: it compiles each directory of src/ as its own
  # application, with the Erlang/OTP of the build.
  @version (fn ->
              {:ok, [{:application, :beam_com, props}]} =
                :file.consult(Path.expand("src/beam_com/beam_com.app.src", __DIR__))

              to_string(props[:vsn])
            end).()

  def project do
    [
      app: :beam_com,
      version: @version,
      elixir: "~> 1.18",
      erlc_paths: erlc_paths(Mix.env()),
      erlc_options: erlc_options(Mix.env()),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: ["tests"],
      test_pattern: "*_test.exs",
      test_coverage: test_coverage(),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: extra_applications(Mix.env())]
  end

  @applications [:logger, :compiler, :sasl, :crypto, :ssl, :inets, :public_key]

  # Mix keeps only the applications of the project in the code path. The
  # tests need eunit (the EUnit modules), parsetools and asn1 (the
  # generators of beam_com_build).
  defp extra_applications(:test), do: @applications ++ [:eunit, :parsetools, :asn1]
  defp extra_applications(_), do: @applications

  # The EUnit test modules (tests/eunit) compile with the code, until each
  # of them has an ExUnit test file.
  defp erlc_paths(:test), do: ["src", "tests/eunit"]
  defp erlc_paths(_), do: ["src"]

  # -DTEST exports the functions that the tests call.
  defp erlc_options(:test), do: [:debug_info, {:d, :TEST}]
  defp erlc_options(_), do: [:debug_info]

  defp elixirc_paths(:test), do: ["lib", "tests/support"]
  defp elixirc_paths(_), do: ["lib"]

  # The coverage of the code, without the test modules. The threshold is
  # the coverage of today, so a change that lowers it fails. Raise it when
  # the coverage increases.
  defp test_coverage do
    [ignore_modules: [~r/_tests$/, :wasm], summary: [threshold: 55]]
  end

  defp deps do
    [
      {:stream_data, "~> 1.2", only: [:dev, :test]}
    ]
  end
end
