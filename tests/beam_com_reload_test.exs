defmodule BeamComReloadTest.App do
  @moduledoc """
  The application module of an application of the tests: config_change/3
  tells the test process (the application env `test`).
  """
  use Application

  def start(_type, _args), do: Supervisor.start_link([], strategy: :one_for_one)

  # OTP calls it from another process (release_handler; here
  # beam_com_reload), so the name of the application is fixed.
  def config_change(changed, new, removed) do
    send(
      Application.fetch_env!(:beam_com_reload_tp, :test),
      {:config_change, changed, new, removed}
    )

    :ok
  end
end

defmodule BeamComReloadTest do
  @moduledoc """
  The tests of `:beam_com_reload`, the reload of new code from the file of
  a running program (docs/PROGRAMS.md, "New code in a running program").

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

  defp compile(source, opts \\ []) do
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

    {:ok, _mod, bin} = :compile.forms(forms, [:binary | opts])
    bin
  end

  # A module with v/0, and a process whose loop calls itself with a local
  # call: it stays in its code until the message move.
  defp beam(mod, version, opts \\ []) do
    compile(
      """
      -module(#{mod}).
      -export([v/0, start/0, loop/0]).
      v() -> #{version}.
      start() -> spawn(fun loop/0).
      loop() ->
          receive
              {v, From} -> From ! {v, v()}, loop();
              {move, From} -> From ! moved, #{mod}:loop()
          end.
      """,
      opts
    )
  end

  # A gen_server: version 1 keeps a count, version 2 a map, and its
  # code_change/3 changes the state with Extra.
  defp server(mod, 1) do
    compile("""
    -module(#{mod}).
    -behaviour(gen_server).
    -export([init/1, handle_call/3, handle_cast/2]).
    init(N) -> {ok, N}.
    handle_call(get, _From, N) -> {reply, {v1, N}, N}.
    handle_cast(_, N) -> {noreply, N}.
    """)
  end

  defp server(mod, 2) do
    compile("""
    -module(#{mod}).
    -behaviour(gen_server).
    -export([init/1, handle_call/3, handle_cast/2, code_change/3]).
    init(N) -> {ok, \#{count => N}}.
    handle_call(get, _From, S) -> {reply, {v2, S}, S}.
    handle_cast(_, S) -> {noreply, S}.
    code_change(OldVsn, N, Extra) when is_integer(N) -> {ok, \#{count => N, extra => Extra, old => OldVsn}}.
    """)
  end

  defp entry(mod, bin, app \\ "t-1.0.0"), do: {~c"lib/#{app}/ebin/#{mod}.beam", bin}

  @code_path [~c"/zip/lib/t-1.0.0/ebin", ~c"/zip/lib/a-1.0.0/ebin/"]

  defp start(path, opts \\ %{}) do
    opts =
      Map.merge(
        %{
          path: String.to_charlist(path),
          interval: 3_600_000,
          code_path: fn -> @code_path end,
          cache: String.to_charlist(Path.join(Path.dirname(path), "cache"))
        },
        opts
      )

    {:ok, pid} = :gen_server.start(:beam_com_reload, opts, [])
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
    put(path, file([entry(a, beam(a, 1))]))
    pid = start(path)
    assert check(pid) == :none

    put(
      path,
      file([
        entry(a, beam(a, 2)),
        entry(:beam_com_reload_t_b, beam(:beam_com_reload_t_b, 1)),
        {~c"lib/t-1.0.0/priv/static/app.css", "body {}"}
      ])
    )

    assert check(pid) == {:ok, [a, :beam_com_reload_t_b]}
    assert apply(a, :v, []) == 2
    assert :code.which(a) == ~c"/zip/lib/t-1.0.0/ebin/beam_com_reload_t_a.beam"
    # The same code, with other chunks (its debug information): no load.
    put(
      path,
      file([
        entry(a, beam(a, 2, [:debug_info])),
        entry(:beam_com_reload_t_b, beam(:beam_com_reload_t_b, 1))
      ])
    )

    assert check(pid) == {:ok, []}
    assert :gen_server.call(pid, :status) == %{last: {:ok, []}, pending: []}
  end

  @tag :tmp_dir
  test "a beam outside the code path does not load", %{tmp_dir: dir} do
    mod = :beam_com_reload_t_e
    forget([mod])
    path = Path.join(dir, "app.com")
    put(path, file([]))
    pid = start(path)
    # lib/t/ebin is not lib/t-1.0.0/ebin: a restart would not read it.
    put(path, file([{~c"lib/t/ebin/#{mod}.beam", beam(mod, 1)}]))
    assert check(pid) == {:ok, []}
    refute :code.is_loaded(mod)
    # A code path with a "/" at the end is the same directory.
    put(path, file([entry(mod, beam(mod, 2), "a-1.0.0")]))
    assert check(pid) == {:ok, [mod]}
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

  # A loaded application with the version 1.0.0, for the appup.
  defp load_app(app, env \\ []) do
    spec =
      {:application, app,
       [
         vsn: ~c"1.0.0",
         modules: [],
         registered: [],
         applications: [:kernel, :stdlib],
         env: env
       ]}

    :ok = :application.load(spec)
    on_exit(fn -> :application.unload(app) end)
  end

  defp appup(app, instructions) do
    {~c"lib/#{app}-1.0.0/ebin/#{app}.appup",
     :io_lib.format(~c"~p.~n", [{~c"1.0.0", [{~c"1.0.0", instructions}], []}])
     |> IO.iodata_to_binary()}
  end

  @tag :tmp_dir
  test "an appup with {update, Mod, {advanced, Extra}}: code_change/3 of each process",
       %{tmp_dir: dir} do
    app = :beam_com_reload_ta
    mod = :beam_com_reload_t_s
    forget([mod])
    load_app(app)
    path = Path.join(dir, "app.com")
    put(path, file([]))

    pid =
      start(path, %{code_path: fn -> [~c"/zip/lib/beam_com_reload_ta-1.0.0/ebin"] end})

    put(path, file([entry(mod, server(mod, 1), "beam_com_reload_ta-1.0.0")]))
    assert check(pid) == {:ok, [mod]}
    {:ok, server} = :gen_server.start(mod, 5, [])
    on_exit(fn -> Process.exit(server, :kill) end)
    assert :gen_server.call(server, :get) == {:v1, 5}
    old = :proplists.get_value(:vsn, mod.module_info(:attributes))

    put(
      path,
      file([
        entry(mod, server(mod, 2), "beam_com_reload_ta-1.0.0"),
        appup(app, [{:update, mod, {:advanced, :to_map}}, {:apply, {:erlang, :put, [:t, 1]}}])
      ])
    )

    assert check(pid) == {:ok, [mod]}
    assert :gen_server.call(server, :get) == {:v2, %{count: 5, extra: :to_map, old: old}}
  end

  @tag :tmp_dir
  test "an appup with an instruction that a reload cannot do: no load", %{tmp_dir: dir} do
    app = :beam_com_reload_tb
    mod = :beam_com_reload_t_f
    forget([mod])
    load_app(app)
    path = Path.join(dir, "app.com")
    put(path, file([]))
    pid = start(path, %{code_path: fn -> [~c"/zip/lib/beam_com_reload_tb-1.0.0/ebin"] end})

    put(
      path,
      file([
        entry(mod, beam(mod, 1), "beam_com_reload_tb-1.0.0"),
        appup(app, [{:add_application, :x}])
      ])
    )

    assert check(pid) == {:error, {:not_supported, {:add_application, :x}}}
    refute :code.is_loaded(mod)
  end

  test "instructions: the forms of OTP that a reload can do" do
    acc = {%{}, []}

    assert :beam_com_reload.instructions(
             [
               {:update, :a},
               {:update, :b, :soft},
               {:update, :c, {:advanced, 1}},
               {:update, :d, :supervisor},
               {:update, :e, {:advanced, 2}, [:x]},
               {:update, :f, 5000, :soft, :soft_purge, :soft_purge, []},
               {:update, :g, :dynamic, :default, {:advanced, 3}, :brutal_purge, :soft_purge, []},
               {:load_module, :h},
               {:load_module, :i, [:x]},
               {:load_module, :j, :soft_purge, :soft_purge, []},
               {:add_module, :k},
               {:add_module, :l, []},
               {:apply, {:m, :f, [1]}}
             ],
             acc
           ) ==
             {:ok,
              {%{
                 a: :soft,
                 b: :soft,
                 c: {:advanced, 1},
                 d: :supervisor,
                 e: {:advanced, 2},
                 f: :soft,
                 g: {:advanced, 3}
               }, [{:m, :f, [1]}]}}

    for bad <- [
          {:update, :a, :hard},
          {:delete_module, :a},
          :restart_new_emulator,
          {:restart_application, :a},
          {:apply, {:m, :f, :x}}
        ] do
      assert :beam_com_reload.instructions([bad], acc) == {:error, {:not_supported, bad}}
    end
  end

  test "appup: the entry of the running version, or a regular expression" do
    up = fn entries ->
      :io_lib.format(~c"~p.", [{~c"2", entries, []}]) |> IO.iodata_to_binary()
    end

    i = [{:load_module, :a}]
    assert :beam_com_reload.appup(:x, up.([{~c"1.0.0", i}]), ~c"1.0.0") == {:ok, i}
    assert :beam_com_reload.appup(:x, up.([{"1\\.0\\..*", i}]), ~c"1.0.7") == {:ok, i}
    assert :beam_com_reload.appup(:x, up.([{"1\\.0", i}]), ~c"1.0.7") == :none
    assert :beam_com_reload.appup(:x, up.([{~c"0.9", i}]), ~c"1.0.0") == :none
    assert :beam_com_reload.appup(:x, up.([]), :undefined) == :none
    assert {:error, {:appup, :x, _}} = :beam_com_reload.appup(:x, "not a term", ~c"1")
    assert {:error, {:appup, :x, _}} = :beam_com_reload.appup(:x, "{1, 2}.", ~c"1")
    assert {:error, {:appup, :x, _}} = :beam_com_reload.appup(:x, up.([{~c"1", :x}]), ~c"1")
  end

  @tag :tmp_dir
  test "new files in priv/: a copy in the cache, the code path, and config_change/3",
       %{tmp_dir: dir} do
    app = :beam_com_reload_tp
    root = Path.join(dir, "zip")
    ebin = Path.join(root, "lib/beam_com_reload_tp-1.0.0/ebin")
    File.mkdir_p!(ebin)
    true = :code.add_patha(String.to_charlist(ebin))
    on_exit(fn -> :code.del_path(app) end)

    spec =
      {:application, app,
       [
         vsn: ~c"1.0.0",
         modules: [],
         registered: [],
         applications: [:kernel, :stdlib],
         mod: {BeamComReloadTest.App, []},
         env: [test: self()]
       ]}

    :ok = :application.load(spec)
    :ok = :application.start(app)

    on_exit(fn ->
      :application.stop(app)
      :application.unload(app)
    end)

    priv = ~c"lib/beam_com_reload_tp-1.0.0/priv/static/app.css"
    path = Path.join(dir, "app.com")
    put(path, file([{priv, "v1"}]))
    cache = Path.join(dir, "cache")

    pid =
      start(path, %{
        root: String.to_charlist(root),
        code_path: &:code.get_path/0,
        cache: String.to_charlist(cache)
      })

    put(path, file([{priv, "v2"}]))
    assert check(pid) == {:ok, []}
    assert_receive {:config_change, [], [], []}, 5000
    lib = to_string(:code.lib_dir(app))
    assert String.starts_with?(lib, cache)
    assert File.read!(Path.join(:code.priv_dir(app), "static/app.css")) == "v2"
    # A second new file moves the application again, and removes the
    # copy before.
    put(path, file([{priv, "v3"}]))
    assert check(pid) == {:ok, []}
    assert_receive {:config_change, [], [], []}, 5000
    assert File.read!(Path.join(:code.priv_dir(app), "static/app.css")) == "v3"
    refute File.exists?(lib)
    # The stop of the process removes its copies.
    GenServer.stop(pid)
    refute File.exists?(to_string(:code.lib_dir(app)))
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

  test "boot starts nothing without the arguments of beam.com" do
    assert :beam_com_reload.boot() == :ok
    assert Process.whereis(:beam_com_reload) == nil
  end

  test "interval: the last -beam_com_reload, and 0 for a bad value" do
    assert :beam_com_reload.interval({:ok, [[~c"1000"], [~c"250"]]}) == 250
    assert :beam_com_reload.interval({:ok, [[~c"x"]]}) == 0
    assert :beam_com_reload.interval({:ok, [[~c"-5"]]}) == 0
    assert :beam_com_reload.interval(:error) == 0
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
