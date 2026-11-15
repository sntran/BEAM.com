defmodule BeamComFdTest do
  @moduledoc """
  The tests of `:beam_com_fd` outside of beam.com: the module loads without
  its static NIF, and each call gives `{:error, :enotsup}`. The check
  `fd_check.b.com` of tests/run.sh sends a descriptor in beam.com.
  """
  use ExUnit.Case, async: true

  setup do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 5000)
    %{listen: listen, client: client}
  end

  test "each call gives enotsup without the NIF", %{listen: listen, client: client} do
    assert :beam_com_fd.send(client, listen) == {:error, :enotsup}
    assert :beam_com_fd.send(client, 0) == {:error, :enotsup}
    assert :beam_com_fd.recv(client, 0) == {:error, :enotsup}
    assert :beam_com_fd.recv(client, :infinity) == {:error, :enotsup}
  end

  test "a closed socket gives its error", %{listen: listen, client: client} do
    :ok = :gen_tcp.close(listen)
    assert {:error, _} = :beam_com_fd.send(client, listen)
    :ok = :gen_tcp.close(client)
    assert {:error, _} = :beam_com_fd.send(client, 0)
    assert {:error, _} = :beam_com_fd.recv(client, 100)
  end

  test "a bad timeout has no clause", %{client: client} do
    assert_raise FunctionClauseError, fn -> :beam_com_fd.recv(client, -1) end
    assert_raise FunctionClauseError, fn -> :beam_com_fd.recv(client, :soon) end
  end
end
