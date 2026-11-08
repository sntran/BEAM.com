defmodule BeamComReloadTest do
  @moduledoc """
  The tests of `:beam_com_reload`, the reload of new code from the file of
  a running program (patches/otp/0005-reload.patch). The module is in the
  kernel of the Erlang/OTP of the build.

  Each test writes a file as beam.com makes one: bytes before a zip whose
  offsets count from the start of the file (`:beam_com_zip`). A new
  version of the file is a new file that a rename puts in place, as zip
  does. Then a check of the process loads the changed modules.
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log

  @end_record 0x06054B50

  # A fake executable: some bytes, then an empty zip whose offsets count
  # from the start of the file.
  defp exe(prefix) do
    size = byte_size(prefix)

    <<prefix::binary, @end_record::32-little, 0::16, 0::16, 0::16, 0::16, 0::32, size::32-little,
      0::16>>
  end

  defp file(entries, prefix \\ "MZqFpD='\nthe runtime\n") do
    IO.iodata_to_binary(:beam_com_zip.write(exe(prefix), fn _ -> true end, entries))
  end

  # A new file in the place of PATH, as zip writes it: a new name, then a
  # rename.
  defp put(path, data) do
    File.write!(path <> ".new", data)
    File.rename!(path <> ".new", path)
  end

  # A module with v/0, and a process whose loop calls itself with a local
  # call: it stays in its code until the message move.
  defp beam(mod, version, opts \\ []) do
    source = """
    -module(#{mod}).
    -export([v/0, start/0, loop/0]).
    v() -> #{version}.
    start() -> spawn(fun loop/0).
    loop() ->
        receive
            {v, From} -> From ! {v, v()}, loop();
            {move, From} -> From ! moved, #{mod}:loop()
        end.
    """

    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(source))

    forms =
      tokens
      |> Enum.chunk_while(
        [],
        fn
          {:dot, _} = dot, acc -> {:cont, Enum.reverse([dot | acc]), []}
          token, acc -> {:cont, [token | acc]}
        end,
        fn acc -> {:cont, acc} end
      )
      |> Enum.reject(&(&1 == []))
      |> Enum.map(fn form ->
        {:ok, parsed} = :erl_parse.parse_form(form)
        parsed
      end)

    {:ok, ^mod, bin} = :compile.forms(forms, [:binary | opts])
    bin
  end

  defp entry(mod, bin), do: {~c"lib/t-1.0.0/ebin/#{mod}.beam", bin}

  defp start(path) do
    {:ok, pid} = :gen_server.start(:beam_com_reload, {String.to_charlist(path), 3_600_000}, [])
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp check(pid), do: :gen_server.call(pid, :check)

  defp forget(mods) do
    on_exit(fn ->
      for mod <- mods do
        :code.purge(mod)
        :code.delete(mod)
        :code.purge(mod)
      end
    end)
  end

  defp v(pid) do
    send(pid, {:v, self()})
    assert_receive {:v, version}, 5000
    version
  end

  @tag :tmp_dir
  test "a new file loads each changed module, and a check with no change loads none",
       %{tmp_dir: dir} do
    a = :beam_com_reload_t_a
    forget([a, :beam_com_reload_t_b])
    path = Path.join(dir, "app.com")
    put(path, file([entry(:beam_com_reload_t_a, beam(:beam_com_reload_t_a, 1))]))
    pid = start(path)
    assert check(pid) == :none

    put(
      path,
      file([
        entry(:beam_com_reload_t_a, beam(:beam_com_reload_t_a, 2)),
        entry(:beam_com_reload_t_b, beam(:beam_com_reload_t_b, 1)),
        {~c"lib/t-1.0.0/priv/static/app.css", "body {}"}
      ])
    )

    assert check(pid) == {:ok, [:beam_com_reload_t_a, :beam_com_reload_t_b]}
    assert apply(a, :v, []) == 2
    assert :code.which(:beam_com_reload_t_a) == ~c"/zip/lib/t-1.0.0/ebin/beam_com_reload_t_a.beam"
    # The same code, with other chunks (its debug information): no load.
    put(
      path,
      file([
        entry(:beam_com_reload_t_a, beam(:beam_com_reload_t_a, 2, [:debug_info])),
        entry(:beam_com_reload_t_b, beam(:beam_com_reload_t_b, 1))
      ])
    )

    assert check(pid) == {:ok, []}
    assert :gen_server.call(pid, :status) == %{last: {:ok, []}, pending: []}
  end

  @tag :tmp_dir
  test "a module waits while a process runs its old code, and loads after", %{tmp_dir: dir} do
    mod = :beam_com_reload_t_c
    forget([mod])
    path = Path.join(dir, "app.com")
    put(path, file([]))
    pid = start(path)
    put(path, file([entry(mod, beam(mod, 1))]))
    assert check(pid) == {:ok, [mod]}
    looper = apply(mod, :start, [])
    on_exit(fn -> Process.exit(looper, :kill) end)
    # Version 2 loads: version 1 becomes the old code, and the loop runs it.
    put(path, file([entry(mod, beam(mod, 2))]))
    assert check(pid) == {:ok, [mod]}
    assert v(looper) == 1
    # Version 3 waits: the old code still runs.
    put(path, file([entry(mod, beam(mod, 3))]))
    assert check(pid) == {:waiting, [mod]}
    assert :gen_server.call(pid, :status) == %{last: {:waiting, [mod]}, pending: [mod]}
    assert Process.alive?(looper)
    send(looper, {:move, self()})
    assert_receive :moved, 5000
    assert check(pid) == {:ok, [mod]}
    assert apply(mod, :v, []) == 3
    assert v(looper) == 2
  end

  @tag :tmp_dir
  test "another runtime loads no module", %{tmp_dir: dir} do
    mod = :beam_com_reload_t_d
    forget([mod])
    path = Path.join(dir, "app.com")
    put(path, file([entry(mod, beam(mod, 1))]))
    pid = start(path)
    put(path, file([entry(mod, beam(mod, 2))], "MZqFpD='\nanother runtime\n"))
    assert check(pid) == {:error, :runtime_changed}
    refute :code.is_loaded(mod)
  end

  @tag :tmp_dir
  test "a file that is not a zip: no reload, and the process goes on", %{tmp_dir: dir} do
    path = Path.join(dir, "app.com")
    File.write!(path, "not a zip")
    pid = start(path)
    assert check(pid) == :none
    put(path, "still not a zip")
    assert check(pid) == :none
    assert Process.alive?(pid)
  end

  test "start_link gives ignore without the arguments of beam.com" do
    assert :beam_com_reload.start_link() == :ignore
  end

  test "classify: the offset and a directory are not changes, a new file is" do
    old = %{
      ~c"lib/a-1/ebin/a.beam" => {1, 10, 20, 8, 100},
      ~c"lib/a-1/priv/x.txt" => {2, 5, 5, 0, 200}
    }

    new = %{
      ~c"lib/a-1/ebin/a.beam" => {1, 10, 20, 8, 300},
      ~c"lib/a-1/ebin/" => {0, 0, 0, 0, 50},
      ~c"lib/a-1/priv/x.txt" => {3, 5, 5, 0, 400},
      ~c"lib/a-1/ebin/b.beam" => {4, 10, 20, 8, 500},
      ~c"releases/1/consolidated/Elixir.Enumerable.beam" => {5, 1, 1, 0, 600},
      ~c"releases/1/start.boot" => {6, 1, 1, 0, 700}
    }

    assert :beam_com_reload.classify(old, new) ==
             {[~c"lib/a-1/ebin/b.beam", ~c"releases/1/consolidated/Elixir.Enumerable.beam"],
              [~c"lib/a-1/priv/x.txt", ~c"releases/1/start.boot"]}
  end

  @tag :tmp_dir
  test "index and read_entry: the data of each entry, checked with its CRC-32",
       %{tmp_dir: dir} do
    data = :binary.copy("some text ", 1000)
    path = Path.join(dir, "app.com")
    File.write!(path, file([{~c"a.txt", data}, {~c"b/c.bin", <<1, 2, 3>>}]))
    {:ok, fd} = :file.open(String.to_charlist(path), [:read, :raw, :binary])
    {:ok, index} = :beam_com_reload.index(fd)
    assert :beam_com_reload.read_entry(fd, index[~c"a.txt"]) == {:ok, data}
    assert :beam_com_reload.read_entry(fd, index[~c"b/c.bin"]) == {:ok, <<1, 2, 3>>}
    {crc, comp, size, method, offset} = index[~c"a.txt"]

    assert :beam_com_reload.read_entry(fd, {crc + 1, comp, size, method, offset}) ==
             {:error, :bad_crc}

    assert :beam_com_reload.read_entry(fd, {crc, comp, size, method, offset + 1}) ==
             {:error, :bad_local_header}

    :file.close(fd)
  end

  @tag :tmp_dir
  test "index reads a zip64 file of Info-ZIP", %{tmp_dir: dir} do
    zip = System.find_executable("zip")

    if zip do
      File.write!(Path.join(dir, "a.txt"), "zip64")
      {_, 0} = System.cmd(zip, ["-q", "-fz", "z.zip", "a.txt"], cd: dir)
      {:ok, fd} = :file.open(String.to_charlist(Path.join(dir, "z.zip")), [:read, :raw, :binary])
      {:ok, index} = :beam_com_reload.index(fd)
      assert :beam_com_reload.read_entry(fd, index[~c"a.txt"]) == {:ok, "zip64"}
      :file.close(fd)
    end
  end
end
