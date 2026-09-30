# The tests of beam.com. "mix test" runs them with the Erlang/OTP and the
# Elixir on the PATH (in CI: the ones of the build, see build.sh unit).
# The tag :node needs Node.js 22 or later.
exclude = if System.find_executable("node"), do: [], else: [:node]
ExUnit.start(exclude: exclude)
