defmodule BeamCom.ErrnoTest do
  @moduledoc """
  The names of the errors of the VM are the names of the BEAM. In
  beam.com, each errno name of Cosmopolitan is a variable, and the #if
  guards of erl_errno_str.c of ERTS left 13 names out: ELOOP gave
  errno_40 and EALREADY gave errno_114 (C35 of docs/UPSTREAM.md). CI runs
  these tests on beam.com.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "a loop of symbolic links gives eloop", %{tmp_dir: dir} do
    a = Path.join(dir, "a")
    b = Path.join(dir, "b")
    :ok = File.ln_s(b, a)
    :ok = File.ln_s(a, b)
    assert File.read(a) == {:error, :eloop}
  end

  test "a second recv on a socket at the same time gives ealready" do
    {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(l)
    {:ok, c} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    {:ok, s} = :gen_tcp.accept(l, 5000)
    owner = self()
    first = spawn(fn -> send(owner, {:first, :gen_tcp.recv(s, 0, 5000)}) end)
    ref = Process.monitor(first)
    # The first recv starts in the other process. Until then, a second
    # recv gives {:error, :timeout}. A poll of 5000 ms at most, a step of
    # 10 ms.
    assert second_recv(s, 500) == {:error, :ealready}
    :ok = :gen_tcp.send(c, "x")
    assert_receive {:first, {:ok, "x"}}, 5000
    assert_receive {:DOWN, ^ref, :process, ^first, :normal}, 5000
    :ok = :gen_tcp.close(c)
    :ok = :gen_tcp.close(s)
    :ok = :gen_tcp.close(l)
  end

  defp second_recv(s, left) do
    case :gen_tcp.recv(s, 0, 0) do
      {:error, :timeout} when left > 0 ->
        Process.sleep(10)
        second_recv(s, left - 1)

      other ->
        other
    end
  end
end
