# The tests of beam.com. "mix test" runs them with the Erlang/OTP and the
# Elixir on the PATH (in CI: the ones of the build, see build.sh unit).
# The tag :node needs Node.js 22 or later. The tag :wasm_diff also needs
# BEAM_COM_WASM_RUNTIME and Node.js 25 or later (tests/wasm_diff_test.exs).
exclude = if System.find_executable("node"), do: [], else: [:node]

exclude =
  if System.get_env("BEAM_COM_WASM_RUNTIME", "") == "", do: [:wasm_diff | exclude], else: exclude

# The tag :check_format needs BEAM_COM_FORMAT_FILE (tests/check_format_test.exs).
exclude =
  if System.get_env("BEAM_COM_FORMAT_FILE", "") == "",
    do: [:check_format | exclude],
    else: exclude

ExUnit.start(exclude: exclude)
