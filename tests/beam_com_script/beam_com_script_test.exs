defmodule BeamComScriptTest do
  @moduledoc """
  The tests of `:beam_com_script`: the copy of a priv directory to real
  files (`extract/2`).

  The module is not async: the tests add a fake application to the code
  path of the VM.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  describe "extract_test_" do
    # A fake application xapp-1.2 in the code path, with priv/run.sh and
    # priv/sub/data.txt.
    setup %{tmp_dir: tmp} do
      dir = String.to_charlist(tmp)
      lib = :filename.join([dir, ~c"lib", ~c"xapp-1.2"])
      ebin = :filename.join(lib, ~c"ebin")
      :ok = :filelib.ensure_path(ebin)

      :ok =
        :file.write_file(
          :filename.join(ebin, ~c"xapp.app"),
          "{application, xapp, [{vsn, \"1.2\"}, {modules, []}]}.\n"
        )

      :ok = :filelib.ensure_path(:filename.join([lib, ~c"priv", ~c"sub"]))
      :ok = :file.write_file(:filename.join([lib, ~c"priv", ~c"run.sh"]), "#!/bin/sh\necho run\n")
      :ok = :file.write_file(:filename.join([lib, ~c"priv", ~c"sub", ~c"data.txt"]), "data")
      true = :code.add_pathz(ebin)

      on_exit(fn ->
        for p <- :code.get_path(), :lists.prefix(dir, p), do: :code.del_path(p)
        # The copies are read-only: make them writable to remove them.
        for f <- :filelib.wildcard(:filename.join(dir, ~c"**")), do: :file.change_mode(f, 0o755)
        :file.del_dir_r(dir)
      end)

      %{dir: dir}
    end

    test "a copy of priv, with the modes", %{dir: dir} do
      cache = :filename.join(dir, ~c"cache")
      zip_ebin = :code.lib_dir(:xapp) ++ ~c"/ebin"
      :ok = :beam_com_script.extract({:xapp, ~c"1.2", ~c"abc", [~c"run.sh"]}, cache)
      priv = :filename.join([cache, ~c"priv", ~c"abc", ~c"xapp-1.2", ~c"priv"])
      assert priv == :code.priv_dir(:xapp)

      assert {:ok, "#!/bin/sh\necho run\n"} ==
               :file.read_file(:filename.join(priv, ~c"run.sh"))

      assert {:ok, "data"} == :file.read_file(:filename.join([priv, ~c"sub", ~c"data.txt"]))

      case :os.type() do
        {:win32, _} ->
          :ok

        _ ->
          assert 0o555 == mode(:filename.join(priv, ~c"run.sh"))
          assert 0o444 == mode(:filename.join([priv, ~c"sub", ~c"data.txt"]))
      end

      # The original ebin stays in the code path (for the code).
      assert zip_ebin in :code.get_path()
      # No temporary directory is left.
      assert [] == :filelib.wildcard(:filename.join([cache, ~c"priv", ~c"abc", ~c"*.tmp.*"]))
      # A second start uses the copy: a change to the source is not seen.
      :ok = :file.write_file(:filename.join([zip_ebin, ~c"..", ~c"priv", ~c"run.sh"]), "changed")
      :ok = :beam_com_script.extract({:xapp, ~c"1.2", ~c"abc", [~c"run.sh"]}, cache)

      assert {:ok, "#!/bin/sh\necho run\n"} ==
               :file.read_file(:filename.join(priv, ~c"run.sh"))
    end
  end

  defp mode(file) do
    {:ok, info} = :file.read_file_info(file)
    Bitwise.band(elem(info, 7), 0o777)
  end

  # The run of a program halts the node, so it runs in a peer node
  # (BeamCom.PeerNode). start(Type, Module) runs Module:main/1 with the
  # plain arguments.
  describe "the run of a program in a peer node" do
    # An Erlang module peer_prog in the peer: main/1 prints its arguments,
    # or raises, or halts, by its first argument.
    defp erlang_program(peer) do
      source = ~c"""
      -module(peer_prog).
      -export([main/1]).
      main(["raise" | _]) -> error(boom);
      main(["halt", N]) -> erlang:halt(list_to_integer(N));
      main(Args) -> io:format("args ~p~n", [Args]).
      """

      {:ok, tokens, _} = :erl_scan.string(source)
      forms = split_forms(tokens, [], [])
      {:ok, :peer_prog, beam} = :compile.forms(forms)

      {:module, :peer_prog} =
        :peer.call(peer, :code, :load_binary, [:peer_prog, ~c"peer_prog.erl", beam])
    end

    defp split_forms([], [], acc), do: acc |> Enum.reverse() |> Enum.map(&parse/1)

    defp split_forms([{:dot, _} = dot | rest], form, acc),
      do: split_forms(rest, [], [Enum.reverse([dot | form]) | acc])

    defp split_forms([token | rest], form, acc), do: split_forms(rest, [token | form], acc)

    defp parse(tokens) do
      {:ok, form} = :erl_parse.parse_form(tokens)
      form
    end

    defp run(module, argv, setup) do
      BeamCom.PeerNode.run({:beam_com_script, :start, [:normal, module]},
        argv: argv,
        setup: setup
      )
    end

    test "main/1 returns: the status 0, and the arguments are strings" do
      assert run(:peer_prog, ["a", "b c"], &erlang_program/1) ==
               {0, "args [\"a\",\"b c\"]\n"}
    end

    test "main/1 raises: the status 127 and the error" do
      {status, out} = run(:peer_prog, ["raise"], &erlang_program/1)
      assert status == 127
      assert out =~ "beam.com: exception error: boom"
    end

    test "main/1 halts: its own status" do
      assert run(:peer_prog, ["halt", "3"], &erlang_program/1) == {3, ""}
    end

    test "an Elixir module gets binaries, and its errors are Elixir errors" do
      assert run(BeamCom.PeerProgram, ["a", "é"], nil) == {0, "args [\"a\", \"é\"]\n"}
      {status, out} = run(BeamCom.PeerProgram, ["raise"], nil)
      assert status == 127
      assert out =~ "beam.com: ** (RuntimeError) boom"
    end
  end
end
