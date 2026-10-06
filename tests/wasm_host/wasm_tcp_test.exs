defmodule WasmTcpTest do
  @moduledoc """
  The tests of `:wasm_tcp`, natively: the flow control of a socket. A
  stand-in for the NIF module `:wasm_host` gives each message of the VM
  for the host to the test, and the test sends the events of the host to
  the process of the socket.

  The module is not async: the stand-in replaces `:wasm_host` in the VM.
  """
  use ExUnit.Case, async: false

  @window 262_144

  setup_all do
    owner =
      spawn(fn ->
        :ets.new(:wasm_host_server, [:named_table, :public])
        receive do: (:stop -> :ok)
      end)

    load_stand_in()

    on_exit(fn ->
      send(owner, :stop)
      :code.purge(:wasm_host)
      :code.delete(:wasm_host)
    end)
  end

  setup do
    Process.register(self(), :wasm_tcp_test_host)
    :ok
  end

  describe "a send with the flag sent of the host" do
    test "waits while the host holds the window, and goes on after tcp_sent" do
      {socket, pid} = accepted(%{ack: false, sack: true})
      half = :binary.copy("x", div(@window, 2))
      assert :ok == :wasm_tcp.send(socket, half)
      assert :ok == :wasm_tcp.send(socket, half)
      assert_receive {:host, %{"t" => "tcp_send"}, _}, 5000
      assert_receive {:host, %{"t" => "tcp_send"}, _}, 5000

      waiting = Task.async(fn -> :wasm_tcp.send(socket, "next") end)
      refute_receive {:host, %{"t" => "tcp_send"}, _}, 200
      assert nil == Task.yield(waiting, 0)

      send(pid, {:wasm_host, "tcp_sent", %{"id" => "c1", "n" => @window}, ""})
      assert :ok == Task.await(waiting, 5000)
      assert_receive {:host, %{"t" => "tcp_send"}, "next"}, 5000
    end

    test "the sends that wait keep their order" do
      {socket, pid} = accepted(%{ack: false, sack: true})
      assert :ok == :wasm_tcp.send(socket, :binary.copy("x", @window))
      assert_receive {:host, %{"t" => "tcp_send"}, _}, 5000

      for part <- ["a", "b", "c"] do
        Task.start(fn -> :wasm_tcp.send(socket, part) end)

        wait_until(fn ->
          :queue.len(:sys.get_state(pid).sends) == :binary.first(part) - ?a + 1
        end)
      end

      send(pid, {:wasm_host, "tcp_sent", %{"id" => "c1", "n" => @window}, ""})
      for part <- ["a", "b", "c"], do: assert_receive({:host, _, ^part}, 5000)
    end

    test "a close of the peer gives {:error, :closed} to a send that waits, and to later sends" do
      {socket, pid} = accepted(%{ack: false, sack: true})
      assert :ok == :wasm_tcp.send(socket, :binary.copy("x", @window))
      waiting = Task.async(fn -> :wasm_tcp.send(socket, "next") end)
      wait_until(fn -> :queue.len(:sys.get_state(pid).sends) == 1 end)
      send(pid, {:wasm_host, "tcp_closed", %{"id" => "c1"}, ""})
      assert {:error, :closed} == Task.await(waiting, 5000)
      assert {:error, :closed} == :wasm_tcp.send(socket, "later")
    end

    test "the header of a packet counts in the window" do
      {socket, pid} = accepted(%{ack: false, sack: true}, packet: 4)
      assert :ok == :wasm_tcp.send(socket, "abc")
      assert 7 == :sys.get_state(pid).inflight
    end
  end

  test "with no flag sent, a send never waits" do
    {socket, pid} = accepted(%{ack: false, sack: false})
    for _ <- 1..3, do: assert(:ok == :wasm_tcp.send(socket, :binary.copy("x", @window)))
    assert 0 == :sys.get_state(pid).inflight
  end

  test "connect/4 takes the flags of tcp_open" do
    test = self()

    connect =
      Task.async(fn ->
        {:ok, socket} = :wasm_tcp.connect(~c"example.com", 5432, [:binary], 5000)
        :ok = :wasm_tcp.controlling_process(socket, test)
        {:ok, socket}
      end)

    assert_receive {:host, %{"t" => "tcp_connect", "id" => id}, _}, 5000
    [{^id, pid}] = :ets.lookup(:wasm_host_server, id)
    send(pid, {:wasm_host, "tcp_open", %{"id" => id, "ack" => true, "sent" => true}, ""})
    assert {:ok, _} = Task.await(connect, 5000)
    assert %{ack: true, sack: true} = :sys.get_state(pid)
  end

  # A connection of a listener, given to the test (accept/2 of wasm_tcp).
  defp accepted(flags, opts \\ []) do
    {:ok, pid} =
      :gen_server.start(:wasm_tcp, {:accepted, "c1", {"0.0.0.0", 0}, [:binary | opts], flags}, [])

    :ok = :gen_server.call(pid, {:accepted, self()})
    {{:"$inet", :wasm_tcp, pid}, pid}
  end

  # A poll for a state of the socket: at most 5000 ms, a step of 10 ms.
  defp wait_until(check, left \\ 500) do
    cond do
      check.() -> :ok
      left == 0 -> flunk("the state did not come")
      true -> Process.sleep(10) && wait_until(check, left - 1)
    end
  end

  # wasm_host: send/1 gives the message (a JSON header, a line feed and the
  # body) to the process :wasm_tcp_test_host, when a test runs.
  defp load_stand_in do
    source = """
    -module(wasm_host).
    -export([send/1]).
    send(Data) ->
        [Header, Body] = binary:split(iolist_to_binary(Data), <<"\\n">>),
        case whereis(wasm_tcp_test_host) of
            undefined -> ok;
            Test -> Test ! {host, json:decode(Header), Body}, ok
        end.
    """

    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(source))
    forms = for f <- split_forms(tokens), do: elem(:erl_parse.parse_form(f), 1)
    {:ok, :wasm_host, bin} = :compile.forms(forms, [:binary])
    :code.purge(:wasm_host)
    {:module, :wasm_host} = :code.load_binary(:wasm_host, ~c"wasm_host_stand_in.erl", bin)
  end

  defp split_forms(tokens) do
    {forms, []} =
      Enum.reduce(tokens, {[], []}, fn
        {:dot, _} = dot, {forms, form} -> {[Enum.reverse([dot | form]) | forms], []}
        token, {forms, form} -> {forms, [token | form]}
      end)

    Enum.reverse(forms)
  end
end
