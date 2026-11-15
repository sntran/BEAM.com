defmodule BeamComFdTest do
  @moduledoc """
  The tests of `:beam_com_fd`. With the static NIF (the OTP of a build of
  beam.com), a descriptor goes over a Unix socket. Without it, the module
  loads, and each call gives `{:error, :enotsup}`. The check
  `fd_check.b.com` of tests/run.sh also sends a descriptor in beam.com.
  """
  use ExUnit.Case, async: true

  setup do
    path = Path.join(System.tmp_dir!(), "fd-#{System.unique_integer([:positive])}.sock")
    File.rm(path)
    on_exit(fn -> File.rm(path) end)
    path_chars = String.to_charlist(path)

    {:ok, unix} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, path_chars}])

    {:ok, here} =
      :gen_tcp.connect({:local, path_chars}, 0, [:local, :binary, active: false], 5000)

    {:ok, there} = :gen_tcp.accept(unix, 5000)
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    # Without the NIF, each call gives enotsup. With it, nothing waits.
    nif = :beam_com_fd.recv(there, 0) != {:error, :enotsup}
    %{here: here, there: there, listen: listen, nif: nif}
  end

  test "a listener goes over a Unix socket, and its copy accepts", ctx do
    {:ok, port} = :inet.port(ctx.listen)

    if ctx.nif do
      assert :beam_com_fd.send(ctx.here, ctx.listen) == :ok
      assert {:ok, fd} = :beam_com_fd.recv(ctx.there, 5000)
      :ok = :gen_tcp.close(ctx.listen)
      {:ok, copy} = :gen_tcp.listen(0, [:binary, fd: fd, active: false])
      assert :inet.port(copy) == {:ok, port}
      {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 5000)
      assert {:ok, accepted} = :gen_tcp.accept(copy, 5000)
      :ok = :gen_tcp.send(client, "ping")
      assert :gen_tcp.recv(accepted, 4, 5000) == {:ok, "ping"}
    else
      assert :beam_com_fd.send(ctx.here, ctx.listen) == {:error, :enotsup}
      assert :beam_com_fd.send(ctx.here, 0) == {:error, :enotsup}
      assert :beam_com_fd.recv(ctx.there, :infinity) == {:error, :enotsup}
    end
  end

  test "a receive with no message, and a closed peer", ctx do
    if ctx.nif do
      assert :beam_com_fd.recv(ctx.there, 50) == {:error, :timeout}
      :ok = :gen_tcp.close(ctx.here)
      assert :beam_com_fd.recv(ctx.there, 5000) == {:error, :closed}
    else
      assert :beam_com_fd.recv(ctx.there, 50) == {:error, :enotsup}
    end
  end

  test "a closed socket gives its error", ctx do
    :ok = :gen_tcp.close(ctx.listen)
    assert {:error, _} = :beam_com_fd.send(ctx.here, ctx.listen)
    :ok = :gen_tcp.close(ctx.here)
    assert {:error, _} = :beam_com_fd.send(ctx.here, 0)
    assert {:error, _} = :beam_com_fd.recv(ctx.here, 100)
  end

  test "a bad timeout has no clause", ctx do
    assert_raise FunctionClauseError, fn -> :beam_com_fd.recv(ctx.there, -1) end
    assert_raise FunctionClauseError, fn -> :beam_com_fd.recv(ctx.there, :soon) end
  end
end
