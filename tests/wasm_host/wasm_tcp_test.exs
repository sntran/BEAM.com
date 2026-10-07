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

  describe "a read with the flag ack of the host" do
    test "a recv of more than the window gets its bytes: the buffer counts as read" do
      {socket, pid} = accepted(%{ack: true, sack: false}, active: false)
      size = 600_000
      reading = Task.async(fn -> :wasm_tcp.recv(socket, size, 5000) end)
      wait_until(fn -> match?({_, ^size, _}, :sys.get_state(pid).recv) end)
      # The recv tells the host the bytes that it waits for.
      assert_receive {:host, %{"t" => "tcp_read", "n" => 0, "want" => ^size, "got" => 0}, _}, 5000
      part = :binary.copy("x", 60_000)

      # As the host: 300 KB, more than the window, and then nothing until
      # a tcp_read comes.
      for _ <- 1..5, do: send(pid, {:wasm_host, "tcp_data", %{"id" => "c1"}, part})
      assert_receive {:host, %{"t" => "tcp_read", "n" => first}, _}, 5000
      for _ <- 1..5, do: send(pid, {:wasm_host, "tcp_data", %{"id" => "c1"}, part})

      assert {:ok, data} = Task.await(reading, 5000)
      assert byte_size(data) == size
      assert first + read_total() == size
    end

    test "a packet that is not complete counts as read, so the rest comes" do
      {socket, pid} = accepted(%{ack: true, sack: false}, active: :once, packet: 4)
      size = 300_000
      payload = :binary.copy("y", size)
      <<first::binary-size(100_000), rest::binary>> = <<size::32, payload::binary>>
      send(pid, {:wasm_host, "tcp_data", %{"id" => "c1"}, first})
      assert_receive {:host, %{"t" => "tcp_read", "n" => n}, _}, 5000
      assert n == 100_000
      send(pid, {:wasm_host, "tcp_data", %{"id" => "c1"}, rest})
      assert_receive {:tcp, ^socket, ^payload}, 5000
    end

    test "a tcp_read gives the bytes that a recv waits for (want), and the bytes that came (got)" do
      {socket, pid} = accepted(%{ack: true, sack: false}, active: false)
      reading = Task.async(fn -> :wasm_tcp.recv(socket, 300_000, 5000) end)

      assert_receive {:host, %{"t" => "tcp_read", "n" => 0, "want" => 300_000, "got" => 0}, _},
                     5000

      send(pid, {:wasm_host, "tcp_data", %{"id" => "c1"}, :binary.copy("w", 100_000)})

      assert_receive {:host,
                      %{"t" => "tcp_read", "n" => 100_000, "want" => 200_000, "got" => 100_000},
                      _},
                     5000

      send(pid, {:wasm_host, "tcp_data", %{"id" => "c1"}, :binary.copy("w", 200_000)})
      assert {:ok, data} = Task.await(reading, 5000)
      assert byte_size(data) == 300_000

      assert_receive {:host, %{"t" => "tcp_read", "n" => 200_000, "want" => 0, "got" => 300_000},
                      _},
                     5000
    end

    test "a recv that parts complete gets one binary of its length, not of twice its length" do
      {socket, pid} = accepted(%{ack: true, sack: false}, active: false)
      reading = Task.async(fn -> :wasm_tcp.recv(socket, 300_000, 5000) end)
      wait_until(fn -> match?({_, 300_000, _}, :sys.get_state(pid).recv) end)

      for _ <- 1..3,
          do: send(pid, {:wasm_host, "tcp_data", %{"id" => "c1"}, :binary.copy("v", 100_000)})

      assert {:ok, data} = Task.await(reading, 5000)
      assert byte_size(data) == 300_000
      assert :binary.referenced_byte_size(data) == 300_000
    end

    test "data to an empty buffer is the buffer, with no copy" do
      {socket, pid} = accepted(%{ack: true, sack: false}, active: false)
      part = :binary.copy("u", 100_000)
      send(pid, {:wasm_host, "tcp_data", %{"id" => "c1"}, part})
      wait_until(fn -> byte_size(:sys.get_state(pid).buf) == 100_000 end)
      assert {:ok, data} = :wasm_tcp.recv(socket, 0, 5000)
      assert data == part
      assert :binary.referenced_byte_size(data) == 100_000
    end

    test "a recv of fewer bytes than ACK_BYTES sends no tcp_read before its bytes come" do
      {socket, pid} = accepted(%{ack: true, sack: false}, active: false)
      Task.start(fn -> :wasm_tcp.recv(socket, 1000, 5000) end)
      wait_until(fn -> match?({_, 1000, _}, :sys.get_state(pid).recv) end)
      refute_receive {:host, %{"t" => "tcp_read"}, _}, 200
    end

    test "the bytes that no one waits for do not count as read" do
      {_socket, pid} = accepted(%{ack: true, sack: false}, active: false)
      send(pid, {:wasm_host, "tcp_data", %{"id" => "c1"}, :binary.copy("z", 300_000)})
      wait_until(fn -> byte_size(:sys.get_state(pid).buf) == 300_000 end)
      refute_receive {:host, %{"t" => "tcp_read"}, _}, 200
    end
  end

  describe "the pump" do
    test "the events of a new connection wait for its process, and keep their order" do
      :ets.insert(:wasm_host_server, {"l9", self()})
      event = fn header, body -> [JSON.encode!(header), "\n", body] |> IO.iodata_to_binary() end

      w =
        :wasm_host_server.handle_event(event.(%{t: "tcp_accept", id: "l9", conn: "c9"}, ""), %{})

      assert_receive {:wasm_host, "tcp_accept", %{"conn" => "c9"}, ""}, 5000

      w =
        :wasm_host_server.handle_event(
          event.(%{t: "tcp_data", id: "c9"}, "POST / HTTP/1.1\r\n"),
          w
        )

      w = :wasm_host_server.handle_event(event.(%{t: "tcp_data", id: "c9"}, "x"), w)
      refute_receive {:wasm_host, "tcp_data", _, _}, 200
      w = :wasm_host_server.handle_message({:claim, "c9", self()}, w)
      assert w == %{}
      w = :wasm_host_server.handle_event(event.(%{t: "tcp_data", id: "c9"}, "y"), w)
      assert w == %{}

      got =
        for _ <- 1..3 do
          assert_receive {:wasm_host, "tcp_data", %{"id" => "c9"}, body}, 5000
          body
        end

      assert got == ["POST / HTTP/1.1\r\n", "x", "y"]
      :ets.delete(:wasm_host_server, "l9")
      :ets.delete(:wasm_host_server, "c9")
    end

    test "a listener that stops before a claim: the host closes its connections" do
      listener = spawn(fn -> receive do: (:stop -> :ok) end)
      :ets.insert(:wasm_host_server, {"l8", listener})
      header = JSON.encode!(%{t: "tcp_accept", id: "l8", conn: "c8"})
      w = :wasm_host_server.handle_event(header <> "\n", %{})
      assert Map.has_key?(w, "c8")
      ref = Process.monitor(listener)
      send(listener, :stop)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5000
      {mon, _} = w["c8"]
      assert %{} == :wasm_host_server.handle_message({:DOWN, mon, :process, listener, :normal}, w)
      assert_receive {:host, %{"t" => "tcp_close", "id" => "c8"}, _}, 5000
      :ets.delete(:wasm_host_server, "l8")
    end
  end

  # The bytes of the tcp_read messages to the host, until none comes.
  defp read_total(total \\ 0) do
    receive do
      {:host, %{"t" => "tcp_read", "n" => n}, _} -> read_total(total + n)
    after
      200 -> total
    end
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
