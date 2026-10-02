defmodule BeamCom.ElixirPatchesTest do
  @moduledoc """
  The tests of the patches of Elixir (patches/elixir), with the `elixir`
  on the PATH: in CI, the Elixir of the build, with the patches.

  0001-mix-lock-port-file.patch: two build locks of Mix, one after the
  other, in one OS process. Without the patch, the second lock can get
  the port of the first one, write its port file through the hard link
  of lock_0, and then wait for itself. The test makes that port likely:
  it runs in a new user and network namespace (`unshare -rn`), with two
  ephemeral ports only. It needs `unshare` and `python3` (to set the
  loopback interface up). Without them, ExUnit skips it (the tag netns).
  """
  use ExUnit.Case, async: true

  @moduletag :netns
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @script ~S"""
  Mix.start()
  key = "/tmp/beam-com-lock-test-" <> Base.encode16(:crypto.strong_rand_bytes(8))

  for i <- 1..2 do
    task =
      Task.async(fn ->
        Mix.Sync.Lock.with_lock(key, fn -> IO.puts("got lock #{i}") end,
          on_taken: fn pid -> IO.puts("waiting for lock (held by #{pid}, I am #{System.pid()})") end
        )
      end)

    # The second lock waits for itself without the patch: 10 s is enough
    # for a lock that nothing holds.
    if Task.yield(task, 10_000) == nil, do: (IO.puts("stuck"); System.halt(1))
  end
  """

  # Sets the loopback interface up (SIOCSIFFLAGS: IFF_UP, IFF_LOOPBACK,
  # IFF_RUNNING), in the network namespace of the process.
  @loopback_up ~S"""
  import fcntl, socket, struct
  s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
  fcntl.ioctl(s, 0x8914, struct.pack('16sh14x', b'lo', 0x1 | 0x8 | 0x40))
  """

  test "a second build lock with the port of the first one", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "locks.exs"), @script)
    File.write!(Path.join(dir, "loopback_up.py"), @loopback_up)

    command =
      "python3 loopback_up.py && " <>
        "echo '40000 40001' > /proc/sys/net/ipv4/ip_local_port_range && " <>
        "elixir locks.exs"

    # Each run has its own lock directory. With two ports, the second lock
    # gets the port of the first one about one time in two.
    for _ <- 1..4 do
      {out, status} =
        System.cmd("unshare", ["-rn", "sh", "-c", command], cd: dir, stderr_to_stdout: true)

      assert status == 0, out
      assert out =~ "got lock 1\ngot lock 2\n"
      refute out =~ "waiting for lock"
    end
  end
end
