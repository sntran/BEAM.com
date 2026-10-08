defmodule WasmHostWasmTest do
  @moduledoc """
  The tests of `:wasm_host_wasm`, the application `wasm` in the WebAssembly
  runtime: the parts that need no host, and the handles of the host with
  the stand-in of `BeamCom.HostStandIn`.

  The module is not async: the stand-in replaces `:wasm_host` in the VM.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias BeamCom.HostStandIn

  @module {:wasm_module, "m1"}
  @instance {:wasm_instance, "i1"}

  describe "wire/1 and unwire/1" do
    for {value, wire} <- [
          {3, 3},
          {-9_007_199_254_740_991, -9_007_199_254_740_991},
          {9_223_372_030_926_249_001, %{i: "9223372030926249001"}},
          {1.5, 1.5},
          {:nan, "nan"},
          {:"-infinity", "-infinity"}
        ] do
      test "wire(#{inspect(value)})" do
        assert :wasm_host_wasm.wire(unquote(Macro.escape(value))) == unquote(Macro.escape(wire))
      end
    end

    test "wire/1 refuses a binary" do
      assert_raise ArgumentError, fn -> :wasm_host_wasm.wire("x") end
    end

    for {wire, value} <- [
          {%{"i" => "9223372030926249001"}, 9_223_372_030_926_249_001},
          {"infinity", :infinity},
          {"nan", :nan},
          {7, 7}
        ] do
      test "unwire(#{inspect(wire)})" do
        assert :wasm_host_wasm.unwire(unquote(Macro.escape(wire))) == unquote(Macro.escape(value))
      end
    end
  end

  describe "the options of instantiate/3" do
    test "no host functions" do
      assert {:badarg, :host_functions_not_supported} ==
               error_of(fn -> :wasm_host_wasm.instantiate(@module, %{"env" => %{}}, %{}) end)
    end

    test "no preopened directories" do
      assert {:badarg, :preopens_not_supported} ==
               error_of(fn ->
                 :wasm_host_wasm.instantiate(@module, %{}, %{preopens: %{~c"/" => ~c"/tmp"}})
               end)
    end

    test "the arguments are a list" do
      assert :badarg ==
               error_of(fn -> :wasm_host_wasm.instantiate(@module, %{}, %{args: :not_a_list}) end)
    end
  end

  # The offsets and the lengths are integers of 0 or more. The checks come
  # before a request to the host.
  describe "the bounds of the memory functions" do
    for {name, call} <- [
          {"read_binary with a negative offset",
           quote(do: :wasm_host_wasm.read_binary(@instance, -1, 4))},
          {"read_binary with a negative length",
           quote(do: :wasm_host_wasm.read_binary(@instance, 0, -4))},
          {"read_binary with a float offset",
           quote(do: :wasm_host_wasm.read_binary(@instance, 1.5, 4))},
          {"write_binary with a negative offset",
           quote(do: :wasm_host_wasm.write_binary(@instance, -1, "x"))},
          {"memory_grow with a negative count",
           quote(do: :wasm_host_wasm.memory_grow(@instance, -1))}
        ] do
      test name do
        assert_raise FunctionClauseError, fn -> unquote(call) end
      end
    end
  end

  describe "the handles of the host" do
    setup do
      owner = HostStandIn.load()
      host = spawn(fn -> responder(%{}) end)
      HostStandIn.take_host_for(host)

      on_exit(fn ->
        Process.exit(host, :kill)
        HostStandIn.unload(owner)
      end)

      %{host: host}
    end

    test "many calls of run/2 leave no process behind", %{host: host} do
      bytes = <<0, ?a, ?s, ?m, 1, 0, 0, 0>>
      assert {:ok, 0} = :wasm_host_wasm.run(bytes, %{})
      before = :erlang.system_info(:process_count)
      for _ <- 1..100, do: assert({:ok, 0} = :wasm_host_wasm.run(bytes, %{}))
      assert :erlang.system_info(:process_count) == before
      assert nil == Process.get({:wasm_host_wasm, :watcher})
      # Each module and each instance was released.
      send(host, {:held, self()})
      assert_receive {:held, held}, 5000
      assert held == %{}
    end

    test "the end of the owner releases its handles, with one watcher", %{host: host} do
      test = self()

      owner =
        spawn(fn ->
          {:ok, m} = :wasm_host_wasm.compile(<<0, ?a, ?s, ?m>>)
          {:ok, i} = :wasm_host_wasm.instantiate(m)
          send(test, {:made, m, i, Process.get({:wasm_host_wasm, :watcher})})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:made, {:wasm_module, m}, {:wasm_instance, i}, watcher}, 5000
      assert is_pid(watcher)
      send(host, {:held, self()})
      assert_receive {:held, held}, 5000
      assert Map.keys(held) |> Enum.sort() == Enum.sort([m, i])
      ref = Process.monitor(watcher)
      send(owner, :stop)
      assert_receive {:DOWN, ^ref, :process, ^watcher, :normal}, 5000
      send(host, {:held, self()})
      assert_receive {:held, %{}}, 5000
    end

    test "a release of one handle keeps the watcher for the other one", %{host: host} do
      {:ok, m} = :wasm_host_wasm.compile(<<0, ?a, ?s, ?m>>)
      {:ok, i} = :wasm_host_wasm.instantiate(m)
      watcher = Process.get({:wasm_host_wasm, :watcher})
      assert :ok == :wasm_host_wasm.release(m)
      assert Process.alive?(watcher)
      assert :ok == :wasm_host_wasm.release(i)
      refute Process.alive?(watcher)
      assert nil == Process.get({:wasm_host_wasm, :watcher})
      send(host, {:held, self()})
      assert_receive {:held, %{}}, 5000
    end
  end

  # The host of the tests: it answers each request, and keeps the modules
  # and the instances that it made until their release.
  defp responder(held) do
    receive do
      {:host, %{"t" => "wasm", "id" => id, "op" => op}, body} ->
        req = :json.decode(body)

        {reply, held} =
          case op do
            "compile" ->
              m = "m#{System.unique_integer([:positive])}"
              {%{ok: m}, Map.put(held, m, true)}

            "instantiate" ->
              i = "i#{System.unique_integer([:positive])}"
              {%{ok: i}, Map.put(held, i, true)}

            "release" ->
              {%{ok: true}, Map.delete(held, req["id"])}

            "call" ->
              {%{ok: []}, held}
          end

        [{^id, pid}] = :ets.lookup(:wasm_host_server, id)

        send(
          pid,
          {:wasm_host, "wasm_reply", %{"id" => id}, IO.iodata_to_binary(:json.encode(reply))}
        )

        responder(held)

      {:held, from} ->
        send(from, {:held, held})
        responder(held)
    end
  end

  # The reason of an Erlang error, as erlang:error/1 gave it.
  defp error_of(fun) do
    fun.()
    flunk("no error")
  catch
    :error, reason -> reason
  end

  # A value goes to the host as JSON. The oracle is the json module of
  # OTP: the value comes back the same after the encode and the decode.
  describe "properties of wire/1 and unwire/1" do
    property "a value comes back from JSON the same" do
      check all(
              value <-
                one_of([
                  integer(),
                  map(integer(), &(&1 * 10_000_000_000_000_000)),
                  float(),
                  member_of([:nan, :infinity, :"-infinity"])
                ])
            ) do
        json = :json.decode(IO.iodata_to_binary(:json.encode(:wasm_host_wasm.wire(value))))
        assert :wasm_host_wasm.unwire(json) === value
      end
    end
  end
end
