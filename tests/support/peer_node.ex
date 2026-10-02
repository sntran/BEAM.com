defmodule BeamCom.PeerNode do
  @moduledoc """
  Runs code that halts the node (`beam_com:main/0`, the run of a
  `beam_com_script` program) in a new node, a peer of the test node. The
  test node stays alive and gets the exit status and the output.

  The peer has the code path of the project and of its dependencies, and
  the plain arguments `:argv`. It has no node name: its channel is its
  standard I/O. The output of the peer (also its standard error) comes
  back through that channel.

  The code of a peer is not cover-compiled, so a peer run adds nothing to
  the coverage of `mix test --cover`.
  """

  @doc """
  Starts a peer, gives it `:argv`, `:env` and `:cd`, then calls `setup`
  (a function of the peer pid) and casts `{module, function, args}`. It
  waits up to `:timeout` ms (default 30000) for the node to halt, and
  gives `{exit_status, output}`.
  """
  def run({m, f, a}, opts \\ []) do
    argv = Enum.map(Keyword.get(opts, :argv, []), &String.to_charlist/1)
    env = for {k, v} <- Keyword.get(opts, :env, []), do: {~c"#{k}", ~c"#{v}"}
    root = :code.root_dir()

    paths =
      for p <- :code.get_path(), not List.starts_with?(p, root), p != ~c".", do: [~c"-pa", p]

    {status, output} =
      ExUnit.CaptureIO.with_io(fn ->
        {:ok, peer, _node} =
          :peer.start(%{
            connection: :standard_io,
            peer_down: :continue,
            args: Enum.concat(paths),
            # -extra must come last: peer puts its own arguments after these.
            post_process_args: &(&1 ++ [~c"-extra" | argv]),
            env: env,
            wait_boot: 30_000
          })

        if cd = opts[:cd], do: :ok = :peer.call(peer, :file, :set_cwd, [String.to_charlist(cd)])
        if setup = opts[:setup], do: setup.(peer)
        :ok = :peer.cast(peer, m, f, a)
        status = wait_down(peer, Keyword.get(opts, :timeout, 30_000))
        :peer.stop(peer)
        status
      end)

    {status, output}
  end

  # The peer is down when its node halted. The state of the peer then has
  # the exit status of the node.
  defp wait_down(peer, left) when left > 0 do
    case :peer.get_state(peer) do
      {:down, {:exit_status, status}} ->
        status

      {:down, other} ->
        raise "the peer node stopped: #{inspect(other)}"

      _ ->
        Process.sleep(10)
        wait_down(peer, left - 10)
    end
  end

  defp wait_down(_peer, _left), do: raise("the peer node did not halt")
end

defmodule BeamCom.PeerProgram do
  @moduledoc """
  An Elixir program for the tests of `beam_com_script` in a peer node:
  `main/1` prints its arguments, or raises with the argument "raise".
  """
  def main(["raise" | _]), do: raise("boom")
  def main(args), do: IO.puts("args #{inspect(args)}")
end
