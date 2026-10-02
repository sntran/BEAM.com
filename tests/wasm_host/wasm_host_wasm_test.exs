defmodule WasmHostWasmTest do
  @moduledoc """
  The tests of `:wasm_host_wasm`, the application `wasm` in the WebAssembly
  runtime: the parts that need no host.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

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
