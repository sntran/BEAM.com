defmodule BeamCom.HostTest do
  @moduledoc "The tests of the JavaScript of the hosts (tests/host), with the test runner of Node.js."
  use ExUnit.Case, async: true

  @moduletag :node
  @moduletag timeout: 300_000

  test "node --test tests/host" do
    files = Path.wildcard(Path.join(__DIR__, "host/*.test.mjs"))
    {output, status} = System.cmd("node", ["--test" | files], stderr_to_stdout: true)
    assert status == 0, output
  end
end
