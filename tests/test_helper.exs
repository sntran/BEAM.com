# The tests of beam.com. "mix test" runs them with the Erlang/OTP and the
# Elixir on the PATH (in CI: the ones of the build, see the step unit of scripts/steps.sh).
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

# The tag :netns needs a user and network namespace (unshare -rn) and
# python3 (tests/elixir_patches_test.exs).
netns? =
  System.find_executable("unshare") != nil and System.find_executable("python3") != nil and
    match?({_, 0}, System.cmd("unshare", ["-rn", "true"], stderr_to_stdout: true))

# BEAM_COM_NETNS=1 (CI) makes the tag required: no silent skip.
if System.get_env("BEAM_COM_NETNS") == "1" and not netns? do
  raise "BEAM_COM_NETNS=1, but unshare -rn does not work here (or python3 is missing)"
end

exclude = if netns?, do: exclude, else: [:netns | exclude]

ExUnit.start(exclude: exclude)
