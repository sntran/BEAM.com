defmodule WasmTcpTest do
  @moduledoc """
  The tests of `:wasm_tcp`, natively: the flow control of a socket, the
  messages to the host, and the differential test (`BeamCom.TcpDiff`): the
  same steps on a socket of `gen_tcp` give the same results and messages.
  A stand-in for the NIF module `:wasm_host` (`BeamCom.HostStandIn`) gives
  each message of the VM for the host to the test, and the test sends the
  events of the host to the process of the socket.

  The module is not async: the stand-in replaces `:wasm_host` in the VM.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  @window 262_144

  alias BeamCom.HostStandIn

  setup_all do
    owner = HostStandIn.load()
    on_exit(fn -> HostStandIn.unload(owner) end)
  end

  setup do
    HostStandIn.take_host()
  end

  alias BeamCom.TcpDiff

  # The steps of the differential test (BeamCom.TcpDiff): the options of
  # the listener, and the steps. The trace of :wasm_tcp must be the trace
  # of gen_tcp on 127.0.0.1.
  @passive [:binary, active: false]
  @scenarios [
    {"the end of the peer comes after the data, and a recv after it gives enotconn", @passive,
     [
       {:peer_send, "abc"},
       :peer_close,
       {:recv, 0, 100},
       {:recv, 0, 100},
       {:recv, 0, 100},
       {:getopts, [:active]},
       :peername,
       {:setopts, [active: :once]},
       {:getopts, [:active]},
       :close,
       :close
     ]},
    {"a send after the end of the peer: ok, then closed, then enotconn", @passive,
     [
       {:peer_send, "data"},
       :peer_close,
       {:send, "1"},
       {:send, "2"},
       {:send, "3"},
       {:recv, 0, 100},
       {:recv, 0, 100},
       {:send, "4"}
     ]},
    {"active once after the end of the peer: the data, then tcp_closed", @passive,
     [
       {:peer_send, "hello"},
       :peer_close,
       {:setopts, [active: :once]},
       {:setopts, [active: :once]},
       {:getopts, [:active]},
       {:send, "x"}
     ]},
    {"active once after a recv of the end", @passive,
     [
       {:peer_send, "abc"},
       :peer_close,
       {:recv, 0, 100},
       {:recv, 0, 100},
       {:setopts, [active: :once]},
       {:recv, 0, 10}
     ]},
    {"a recv of a length gets {:error, :closed} at the end, with the bytes that came", @passive,
     [{:peer_send, "abc"}, :peer_close, {:recv, 10, 100}, {:recv, 0, 100}]},
    {"{active, N} adds N, and {active, 0} gives tcp_passive", @passive,
     [
       {:setopts, [active: 0]},
       {:setopts, [active: 2]},
       {:setopts, [active: 3]},
       {:getopts, [:active]},
       {:peer_send, "1"},
       {:peer_send, "2"},
       {:getopts, [:active]},
       {:setopts, [active: -10]},
       {:getopts, [:active]},
       {:setopts, [active: 32767]},
       {:setopts, [active: 1]},
       {:getopts, [:active]},
       {:setopts, [active: 32768]},
       {:setopts, [active: true]},
       {:setopts, [active: 2]},
       {:peer_send, "3"},
       {:peer_send, "4"},
       {:peer_send, "5"},
       {:getopts, [:active]}
     ]},
    {"setopts sets the options from the last one to the first one", @passive,
     [
       {:setopts, [packet: 2, packet: 4]},
       {:getopts, [:packet]},
       {:setopts, [active: true, active: false]},
       {:getopts, [:active]},
       {:setopts, [:binary, :list]},
       {:getopts, [:mode]},
       {:setopts, [active: 2, active: 3]},
       {:getopts, [:active]}
     ]},
    {"wrong options give einval, and change nothing", @passive,
     [
       {:setopts, [active: :foo]},
       {:setopts, [:foo]},
       {:setopts, [packet: 3]},
       {:setopts, [mode: :foo]},
       {:setopts, [active: :once, bogus: 1]},
       {:getopts, [:foo]},
       {:getopts, [:active, :foo]},
       {:setopts, [packet_size: -1]},
       {:setopts, [nodelay: 1]},
       {:setopts, [send_timeout: -1]},
       {:setopts, [line_length: 4]},
       {:setopts, [ip: {1, 2, 3, 4}]},
       {:getopts, [:line_delimiter]},
       {:getopts, [:read_packets, :active]},
       {:getopts, [:active]}
     ]},
    {"the values of getopts", @passive,
     [
       {:getopts,
        [
          :active,
          :mode,
          :packet,
          :packet_size,
          :header,
          :deliver,
          :exit_on_close,
          :show_econnreset,
          :send_timeout,
          :send_timeout_close,
          :delay_send,
          :nodelay,
          :keepalive,
          :reuseaddr,
          :linger,
          :high_watermark,
          :low_watermark,
          :tos,
          :priority,
          :debug,
          :read_ahead,
          :ttl
        ]},
       {:setopts,
        [
          packet: :ssl,
          header: 3,
          deliver: :port,
          exit_on_close: false,
          send_timeout: 5,
          send_timeout_close: true,
          show_econnreset: true,
          line_delimiter: ?;,
          nodelay: true
        ]},
       {:getopts,
        [
          :packet,
          :header,
          :deliver,
          :exit_on_close,
          :send_timeout,
          :send_timeout_close,
          :show_econnreset,
          :nodelay
        ]},
       {:setopts, [packet: 0]},
       {:getopts, [:packet]}
     ]},
    {"recv: the errors of its arguments", @passive,
     [
       {:setopts, [packet: 2]},
       {:recv, 5, 0},
       {:setopts, [active: true]},
       {:recv, 0, 0},
       {:setopts, [active: false, packet: :raw]},
       {:recv, 0, 0},
       {:recv, 70_000_000, 0}
     ]},
    {"a closed socket: the errors of each call", @passive,
     [
       :close,
       {:recv, 0, 0},
       {:send, "x"},
       {:setopts, [active: true]},
       {:getopts, [:active]},
       :peername,
       {:shutdown, :write},
       {:unrecv, "a"},
       :close
     ]},
    {"close takes the tcp_closed of the socket from the mailbox", [:binary, active: true],
     [{:peer_send, "abc"}, :peer_close, :close]},
    {"http_bin: the packets of a request, and the body as raw",
     [:binary, active: false, packet: :http_bin],
     [
       {:peer_send, "GET /a HTTP/1.1\r\nHost: x\r\nX-Y: z\r\n\r\nBODY"},
       {:recv, 0, 100},
       {:recv, 0, 100},
       {:recv, 0, 100},
       {:recv, 0, 100},
       {:recv, 0, 100},
       {:setopts, [packet: :raw]},
       {:recv, 0, 100}
     ]},
    {"http: the messages of an active socket, as lists", [:list, active: true, packet: :http],
     [
       {:peer_send, "GET /a HTTP/1.1\r\nHost: x\r\n\r\n"},
       {:peer_send, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"}
     ]},
    {"httph: an error, and a header that waits for the next line",
     [:binary, active: true, packet: :httph],
     [{:peer_send, "X-Y z\r\nA: b\r\n"}, {:peer_send, " c\r\n\r\n"}]},
    {"http_bin: an HTTP/0.9 request, then a header that waits", @passive,
     [
       {:setopts, [packet: :http_bin]},
       {:peer_send, "garbage line\r\nX-Y z\r\n"},
       {:recv, 0, 100},
       {:setopts, [packet: :httph_bin]},
       {:recv, 0, 100}
     ]},
    {"http_bin: a line above the buffer gives emsgsize", @passive,
     [
       {:setopts, [packet: :http_bin, buffer: 16]},
       {:peer_send, "GET /0123456789abcdefghijk HTTP/1.1\r\n"},
       {:recv, 0, 100},
       {:recv, 0, 100}
     ]},
    {"packet_size: a passive socket gets emsgsize, and then enotconn", @passive,
     [
       {:setopts, [packet: 4, packet_size: 10]},
       {:peer_send, <<20::32, 0::160>>},
       {:recv, 0, 100},
       {:recv, 0, 100},
       {:send, "x"},
       {:getopts, [:active]}
     ]},
    {"packet_size: an active socket gets tcp_error and tcp_closed", @passive,
     [
       {:setopts, [packet: 4, packet_size: 10, exit_on_close: false, active: true]},
       {:peer_send, <<20::32, 0::160>>},
       {:send, "x"},
       {:getopts, [:active]}
     ]},
    {"packet_size: a line", @passive,
     [
       {:setopts, [packet: :line, packet_size: 10]},
       {:peer_send, "0123456789abcdef\nshort\n"},
       {:recv, 0, 100},
       {:recv, 0, 100}
     ]},
    {"line: a line above the buffer comes in parts", @passive,
     [
       {:setopts, [packet: :line, buffer: 8]},
       {:peer_send, "0123456789abcdef\n"},
       {:recv, 0, 100},
       {:recv, 0, 100},
       {:recv, 0, 100}
     ]},
    {"line: line_delimiter", @passive,
     [
       {:setopts, [packet: :line, line_delimiter: ?;]},
       {:peer_send, "ab;cd\n;"},
       {:recv, 0, 100},
       {:recv, 0, 100}
     ]},
    {"line: the end drops a line that is not complete", [:binary, active: true, packet: :line],
     [{:peer_send, "ab\ncd"}, :peer_close]},
    {"asn1, sunrm, tpkt, cdr and fcgi", @passive,
     [
       {:setopts, [packet: :asn1]},
       {:peer_send, <<0x30, 3, 1, 2, 3>>},
       {:recv, 0, 100},
       {:setopts, [packet: :sunrm]},
       {:peer_send, <<0x80000003::32, "abc">>},
       {:recv, 0, 100},
       {:setopts, [packet: :tpkt]},
       {:peer_send, <<3, 0, 7::16, "abc">>},
       {:recv, 0, 100},
       {:setopts, [packet: :cdr]},
       {:peer_send, <<"GIOP", 1, 0, 0, 0, 3::32, "abc">>},
       {:recv, 0, 100},
       {:setopts, [packet: :fcgi]},
       {:peer_send, <<1, 1, 0, 1, 0, 3, 1, 0, "abc", 0>>},
       {:recv, 0, 100}
     ]},
    {"the header of a send for each packet type", @passive,
     [
       {:setopts, [packet: 2]},
       {:send, "ab"},
       {:setopts, [packet: :line]},
       {:send, "cd"},
       {:setopts, [packet: :http_bin]},
       {:send, "ef"},
       {:setopts, [packet: 4]},
       {:send, "gh"},
       {:setopts, [packet: 1]},
       {:send, :binary.copy("x", 300)},
       :peer_recv
     ]},
    {"header and mode list", [:binary, active: true, header: 2],
     [
       {:peer_send, "abcd"},
       {:setopts, [active: false]},
       {:peer_send, "a"},
       {:recv, 0, 100},
       {:setopts, [:list]},
       {:peer_send, "xyz"},
       {:recv, 0, 100}
     ]},
    {"deliver port", [:binary, active: true, deliver: :port], [{:peer_send, "abc"}, :peer_close]},
    {"unrecv: the bytes come first, and an active socket gets them",
     [:binary, active: false, packet: 2],
     [
       {:unrecv, <<0, 2, "ab">>},
       {:recv, 0, 100},
       {:setopts, [active: :once]},
       {:unrecv, <<0, 1, "c">>}
     ]},
    {"shutdown of write: the peer gets the end, and the socket still reads",
     [:binary, active: true],
     [{:shutdown, :write}, :peer_recv, {:peer_send, "back"}, :peer_shutdown, {:send, "y"}]},
    {"shutdown of write: a send after it closes a passive socket", @passive,
     [
       {:shutdown, :write},
       :peer_recv,
       {:send, "x"},
       {:peer_send, "back"},
       {:recv, 0, 100},
       {:shutdown, :write},
       {:recv, 0, 100},
       {:send, "y"}
     ]},
    {"shutdown of read: an active socket gets tcp_closed", [:binary, active: true],
     [{:shutdown, :read}, :peer_recv, {:send, "x"}, {:getopts, [:active]}]},
    {"shutdown of read: a recv gets the data, then the end", @passive,
     [
       {:peer_send, "late"},
       {:shutdown, :read},
       {:recv, 0, 100},
       {:recv, 0, 100},
       {:send, "x"},
       :peer_recv
     ]},
    {"shutdown of read and write", @passive,
     [
       {:shutdown, :read_write},
       :peer_recv,
       {:send, "x"},
       {:recv, 0, 100},
       {:recv, 0, 100},
       {:shutdown, :write},
       :close
     ]},
    {"exit_on_close false: the socket sends after the end of the peer",
     [:binary, active: true, exit_on_close: false],
     [
       {:peer_send, "a"},
       :peer_shutdown,
       {:send, "x"},
       :peer_recv,
       {:recv, 0, 10},
       {:getopts, [:active, :exit_on_close]},
       {:setopts, [active: :once]},
       :close
     ]},
    {"exit_on_close false: each recv after the end gives closed",
     [:binary, active: false, exit_on_close: false],
     [
       {:peer_send, "a"},
       :peer_shutdown,
       {:recv, 0, 100},
       {:recv, 0, 100},
       {:recv, 0, 100},
       {:send, "x"},
       :peer_recv,
       {:setopts, [active: :once]},
       {:setopts, [active: :once]},
       :close
     ]},
    {"exit_on_close false: an active mode on a closed socket",
     [:binary, active: false, exit_on_close: false],
     [
       :peer_close,
       {:recv, 0, 100},
       {:setopts, [active: true]},
       {:recv, 0, 10},
       {:setopts, [active: false]},
       {:recv, 0, 10}
     ]},
    {"two recv at the same time: the second gets ealready", @passive,
     [{:async_recv, 0, 2000}, {:recv, 0, 100}, {:peer_send, "x"}, :await, {:recv, 0, 0}]},
    {"deliver port: a recv waits on, and the owner gets the data", @passive,
     [{:setopts, [deliver: :port]}, {:peer_send, "abc"}, {:async_recv, 0, 300}, :await]},
    {"controlling_process moves tcp and tcp_closed, and not tcp_passive", @passive,
     [
       {:setopts, [active: 1]},
       {:keep, {:peer_send, "a"}},
       {:keep, {:setopts, [active: 1]}},
       {:keep, {:peer_send, "b"}},
       :give_away,
       {:peer_send, "c"}
     ]},
    {"controlling_process moves the messages of an active socket", [:binary, active: true],
     [
       {:keep, {:peer_send, "a"}},
       {:keep, {:peer_send, "b"}},
       :give_away,
       {:getopts, [:active]},
       :give_back
     ]},
    {"controlling_process of a socket that closed", [:binary, active: true],
     [{:keep, {:peer_send, "a"}}, {:keep, :peer_close}, :give_away]},
    {"controlling_process: a process that stopped, and a caller that is not the owner", @passive,
     [:give_away_dead, :give_back, {:getopts, [:active]}]},
    {"a reset of the peer is an end: the data, then closed", @passive,
     [{:peer_send, "abc"}, :peer_reset, {:recv, 0, 100}, {:recv, 0, 100}, {:recv, 0, 100}]},
    {"show_econnreset: a recv gets econnreset after the data",
     [:binary, active: false, show_econnreset: true],
     [{:peer_send, "abc"}, :peer_reset, {:recv, 0, 100}, {:recv, 0, 100}, {:recv, 0, 100}]},
    {"show_econnreset: an active socket gets tcp_error and tcp_closed",
     [:binary, active: true, show_econnreset: true],
     [{:peer_send, "abc"}, :peer_reset, {:send, "x"}]},
    {"a send after a reset fails, and the next recv gets the error", @passive,
     [:peer_reset, {:send, "x"}, {:send, "y"}, {:recv, 0, 100}, {:recv, 0, 100}]},
    {"show_econnreset: a send after a reset gets econnreset",
     [:binary, active: false, show_econnreset: true],
     [:peer_reset, {:send, "x"}, {:send, "y"}, {:recv, 0, 100}, {:recv, 0, 100}]},
    {"exit_on_close false: the sends after the end of the peer",
     [:binary, active: true, exit_on_close: false],
     [:peer_close, {:send, "1"}, {:send, "2"}, {:send, "3"}, {:recv, 0, 100}]},
    {"the options of the listener go to the connection",
     [
       :list,
       active: 3,
       packet: 2,
       packet_size: 7,
       header: 1,
       exit_on_close: false,
       send_timeout: 5,
       show_econnreset: true,
       nodelay: true
     ],
     [
       {:getopts,
        [
          :active,
          :packet,
          :packet_size,
          :header,
          :mode,
          :exit_on_close,
          :send_timeout,
          :show_econnreset,
          :nodelay
        ]}
     ]}
  ]

  # The steps of a listener (BeamCom.TcpDiff.listener/3).
  @listeners [
    {"accept: a connection, a time limit, and 0", @passive,
     [:connect, {:accept, 1000}, {:accept, 0}, {:accept, 50}, :connect, {:accept, 0}]},
    {"accept: the acceptors that wait get closed at the close, and later ones too", @passive,
     [
       {:async_accept, 5000},
       {:async_accept, :infinity},
       :close,
       :await,
       :await,
       {:accept, 0},
       :close
     ]},
    {"accept: a connection that no accept took ends with the listener", @passive,
     [:connect, :connect, :close, :client_end]},
    {"accept: the listener ends with its owner", @passive,
     [:connect, :owner_stop, :client_end, {:accept, 0}]},
    {"accept: an accepted connection stays after the close of the listener", @passive,
     [:connect, {:accept, 1000}, :close, :client_end]},
    {"a closed listener: the errors of each call", @passive,
     [
       :close,
       {:accept, 0},
       :sockname,
       {:getopts, [:active]},
       {:setopts, [active: true]},
       {:recv, 0, 0},
       {:send, "x"},
       :close
     ]},
    {"a listener: the errors of the calls of a socket, and its options",
     [:binary, active: false, packet: 2],
     [
       {:recv, 0, 0},
       {:send, "x"},
       :peername,
       {:shutdown, :write},
       {:unrecv, "a"},
       {:getopts, [:active, :mode, :packet]},
       :sockname,
       {:setopts, [active: :once, packet: 4]},
       {:getopts, [:active, :packet]},
       {:setopts, [bogus: 1]}
     ]},
    {"the options of a listener at the accept go to the connection", @passive,
     [
       {:setopts, [packet: 4, active: 2, header: 1]},
       :connect,
       {:accept_getopts, [:active, :packet, :header, :mode]}
     ]}
  ]

  describe "a listener, the same as gen_tcp" do
    for {name, listen, steps} <- @listeners do
      @tag listen: listen, steps: steps
      test name, %{listen: listen, steps: steps} do
        assert TcpDiff.listener(:wasm, listen, steps) == TcpDiff.listener(:native, listen, steps)
      end
    end
  end

  describe "the same as gen_tcp" do
    for {name, listen, steps} <- @scenarios do
      @tag listen: listen, steps: steps
      test name, %{listen: listen, steps: steps} do
        {wasm, native} = TcpDiff.diff(listen, steps)
        assert wasm == native
      end
    end
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

  describe "the same as gen_tcp, for random steps" do
    # Each run of the native world waits for its events (40 ms for each
    # step, and more for a step with messages), so 20 runs take about 10 s.
    property "a sequence of calls and events of the peer gives the same trace" do
      check all(
              listen <- member_of([@passive, [:binary, active: true], [:binary, active: :once]]),
              steps <- list_of(step(), max_length: 10),
              max_runs: 20
            ) do
        steps = valid(steps)
        {wasm, native} = TcpDiff.diff(listen, steps)
        assert wasm == native
      end
    end
  end

  describe "the messages to the host" do
    test "unrecv: the bytes that came back do not count again in tcp_read" do
      {socket, pid} = accepted(%{ack: true, sack: false}, active: false)
      send(pid, {:wasm_host, "tcp_data", %{"id" => "c1"}, "abc"})
      assert {:ok, "a"} = :wasm_tcp.recv(socket, 1, 5000)
      assert :ok = :wasm_tcp.unrecv(socket, "a")
      # As inet_drv: first the bytes of unrecv, then the bytes that wait.
      assert {:ok, "a"} = :wasm_tcp.recv(socket, 0, 5000)
      assert {:ok, "bc"} = :wasm_tcp.recv(socket, 0, 5000)
      assert 3 == read_total()
    end

    test "a packet header above packet_size: emsgsize at once, and no read of its bytes" do
      {socket, pid} =
        accepted(%{ack: true, sack: false}, active: false, packet: 4, packet_size: 100)

      send(
        pid,
        {:wasm_host, "tcp_data", %{"id" => "c1"}, <<1_000_000::32, 0::size(70_000)-unit(8)>>}
      )

      assert {:error, :emsgsize} = :wasm_tcp.recv(socket, 0, 5000)
      assert_receive {:host, %{"t" => "tcp_close", "id" => "c1"}, _}, 5000
      assert 0 == read_total()
    end

    test "a packet of more than 64 MiB gives emsgsize" do
      {socket, pid} = accepted(%{ack: true, sack: false}, active: false, packet: 4)
      send(pid, {:wasm_host, "tcp_data", %{"id" => "c1"}, <<0x4000001::32, "x">>})
      assert {:error, :emsgsize} = :wasm_tcp.recv(socket, 0, 5000)
    end

    test "shutdown of write: tcp_shutdown, after the sends that wait" do
      {socket, pid} = accepted(%{ack: false, sack: true})
      assert :ok == :wasm_tcp.send(socket, :binary.copy("x", @window))
      assert_receive {:host, %{"t" => "tcp_send"}, _}, 5000
      waiting = Task.async(fn -> :wasm_tcp.send(socket, "last") end)
      wait_until(fn -> :queue.len(:sys.get_state(pid).sends) == 1 end)
      assert :ok == :wasm_tcp.shutdown(socket, :write)
      refute_receive {:host, %{"t" => "tcp_shutdown"}, _}, 200
      send(pid, {:wasm_host, "tcp_sent", %{"id" => "c1", "n" => @window}, ""})
      assert :ok == Task.await(waiting, 5000)
      assert_receive {:host, %{"t" => "tcp_send"}, "last"}, 5000
      assert_receive {:host, %{"t" => "tcp_shutdown", "id" => "c1", "how" => "write"}, _}, 5000
      assert {:error, :closed} == :wasm_tcp.send(socket, "more")
    end

    test "close: the sends that wait go first, then tcp_close" do
      {socket, pid} = accepted(%{ack: false, sack: true})
      assert :ok == :wasm_tcp.send(socket, :binary.copy("x", @window))
      assert_receive {:host, %{"t" => "tcp_send"}, _}, 5000
      waiting = Task.async(fn -> :wasm_tcp.send(socket, "last") end)
      wait_until(fn -> :queue.len(:sys.get_state(pid).sends) == 1 end)
      assert :ok == :wasm_tcp.close(socket)
      assert :ok == Task.await(waiting, 5000)
      assert_receive {:host, %{"t" => "tcp_send"}, "last"}, 5000
      assert_receive {:host, %{"t" => "tcp_close", "id" => "c1"}, _}, 5000
    end

    test "send_timeout: a send that waits gets timeout, and its data goes later" do
      {socket, pid} = accepted(%{ack: false, sack: true}, send_timeout: 50)
      assert :ok == :wasm_tcp.send(socket, :binary.copy("x", @window))
      assert_receive {:host, %{"t" => "tcp_send"}, _}, 5000
      assert {:error, :timeout} == :wasm_tcp.send(socket, "late")
      send(pid, {:wasm_host, "tcp_sent", %{"id" => "c1", "n" => @window}, ""})
      assert_receive {:host, %{"t" => "tcp_send"}, "late"}, 5000
      assert :ok == :wasm_tcp.send(socket, "next")
    end

    test "send_timeout 0: the answer comes at once" do
      {socket, _pid} = accepted(%{ack: false, sack: true}, send_timeout: 0)
      assert :ok == :wasm_tcp.send(socket, :binary.copy("x", @window))
      assert {:error, :timeout} == :wasm_tcp.send(socket, "late")
    end

    test "send_timeout_close: the socket closes at the timeout" do
      {socket, pid} =
        accepted(%{ack: false, sack: true},
          active: false,
          send_timeout: 50,
          send_timeout_close: true
        )

      assert :ok == :wasm_tcp.send(socket, :binary.copy("x", @window))
      assert {:error, :timeout} == :wasm_tcp.send(socket, "late")
      assert_receive {:host, %{"t" => "tcp_close", "id" => "c1"}, _}, 5000
      assert {:error, :enotconn} == :wasm_tcp.send(socket, "more")
      assert Process.alive?(pid)
    end

    test "send_timeout_close of an active socket: tcp_closed, and the process stops" do
      {socket, pid} =
        accepted(%{ack: false, sack: true},
          active: true,
          send_timeout: 50,
          send_timeout_close: true
        )

      ref = Process.monitor(pid)
      assert :ok == :wasm_tcp.send(socket, :binary.copy("x", @window))
      assert {:error, :timeout} == :wasm_tcp.send(socket, "late")
      assert_receive {:tcp_closed, ^socket}, 5000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5000
    end

    test "a listener: tcp_unlisten at the close, and tcp_close for each connection that waits" do
      {:ok, {_, _, lpid} = l} = listen()
      id = :sys.get_state(lpid).id

      for c <- ["q1", "q2"],
          do: send(lpid, {:wasm_host, "tcp_accept", %{"id" => id, "conn" => c}, ""})

      wait_until(fn -> :queue.len(:sys.get_state(lpid).conns) == 2 end)
      assert :ok == :wasm_tcp.close(l)
      assert_receive {:host, %{"t" => "tcp_unlisten", "id" => ^id}, _}, 5000

      for c <- ["q1", "q2"] do
        assert_receive {:host, %{"t" => "tcp_close", "id" => ^c}, _}, 5000
        wait_until(fn -> :ets.lookup(:wasm_host_server, c) == [] end)
      end
    end

    test "a listener ends with its owner: tcp_unlisten, and accept gives closed" do
      owner = spawn(fn -> receive do: (:stop -> :ok) end)
      {:ok, {_, _, lpid} = l} = listen()
      id = :sys.get_state(lpid).id
      assert :ok == :wasm_tcp.controlling_process(l, owner)
      ref = Process.monitor(lpid)
      send(owner, :stop)
      assert_receive {:host, %{"t" => "tcp_unlisten", "id" => ^id}, _}, 5000
      assert_receive {:DOWN, ^ref, :process, ^lpid, :normal}, 5000
      assert {:error, :closed} == :wasm_tcp.accept(l, 0)
    end

    test "an acceptor that stops waits no more: the connection goes to the next one" do
      {:ok, {_, _, lpid} = l} = listen()
      id = :sys.get_state(lpid).id
      {gone, ref} = spawn_monitor(fn -> :wasm_tcp.accept(l) end)
      wait_until(fn -> :queue.len(:sys.get_state(lpid).acceptors) == 1 end)
      Process.exit(gone, :kill)
      assert_receive {:DOWN, ^ref, :process, ^gone, :killed}, 5000
      wait_until(fn -> :queue.len(:sys.get_state(lpid).acceptors) == 0 end)
      send(lpid, {:wasm_host, "tcp_accept", %{"id" => id, "conn" => "q3"}, ""})
      assert {:ok, {_, _, pid}} = :wasm_tcp.accept(l, 5000)
      assert Process.alive?(pid)
      :wasm_tcp.close(l)
    end

    test "a listener that the host refuses gives the error of the host" do
      task = Task.async(fn -> :wasm_tcp.listen(4000, [:binary]) end)
      assert_receive {:host, %{"t" => "tcp_listen", "id" => id, "port" => 4000}, _}, 5000
      [{^id, lpid}] = :ets.lookup(:wasm_host_server, id)
      send(lpid, {:wasm_host, "tcp_error", %{"id" => id, "reason" => "eaddrinuse"}, ""})
      assert {:error, :eaddrinuse} == Task.await(task, 5000)
    end

    test "wrong options: listen/2 exits with badarg, and connect/4 gives einval" do
      assert catch_exit(:wasm_tcp.listen(0, [{:bogus, 1}])) == :badarg
      assert catch_exit(:wasm_tcp.listen(0, [{:line_delimiter, ?;}])) == :badarg
      assert {:error, :einval} == :wasm_tcp.connect(~c"example.com", 80, [{:packet, 3}], 5000)
      assert {:error, :einval} == :wasm_tcp.connect(~c"example.com", 80, :binary, 5000)
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

  # A step of the property: a call on the socket, or an event of the peer.
  defp step do
    data = string([?a, ?b, ?\n], min_length: 1, max_length: 5)

    one_of([
      map(data, &{:peer_send, &1}),
      map(data, &{:send, &1}),
      map(data, &{:unrecv, &1}),
      map(member_of([0, 1, 3]), &{:recv, &1, 0}),
      map(member_of([false, true, :once, 1, 2, -1]), &{:setopts, [active: &1]}),
      map(member_of([:raw, :line, 1]), &{:setopts, [packet: &1]}),
      map(member_of([:read, :write, :read_write]), &{:shutdown, &1}),
      member_of([
        {:recv, 0, 50},
        {:setopts, [exit_on_close: false]},
        {:getopts, [:active, :packet]},
        :peername,
        :peer_shutdown,
        :peer_close,
        :peer_reset,
        :peer_recv,
        :close
      ])
    ])
  end

  # The steps that the peer and the socket can do: no event of the peer
  # after its end, and nothing after the close. The peer reads all its
  # bytes before it closes, and before the socket closes: else a close
  # gives a reset, and the bytes of the reset depend on the time.
  defp valid(steps), do: valid(steps, %{peer: :open, length: false, unrecv: false, raw: true})

  defp valid([], _), do: []
  defp valid([:close | _], %{peer: :closed}), do: [:close]
  defp valid([:close | _], _), do: [:peer_recv, :close]

  defp valid([step | steps], %{peer: peer} = st) do
    case {step, peer} do
      # After a recv of a length that waits, inet_drv keeps the length for
      # the next reads, also after a change of the packet type: the test
      # changes the packet type only before.
      {{:recv, n, _}, _} when n > 0 ->
        [step | valid(steps, %{st | length: true})]

      # The bytes of unrecv go to a buffer of their size in inet_drv, and
      # that size limits a line: the test gives unrecv only to raw.
      {{:setopts, [packet: _]}, _} when st.length or st.unrecv ->
        valid(steps, st)

      {{:setopts, [packet: p]}, _} ->
        [step | valid(steps, %{st | raw: p == :raw})]

      {{:unrecv, _}, _} when not st.raw ->
        valid(steps, st)

      {{:unrecv, _}, _} ->
        [step | valid(steps, %{st | unrecv: true})]

      {{:peer_send, _}, :open} ->
        [step | valid(steps, st)]

      {:peer_shutdown, :open} ->
        [step | valid(steps, %{st | peer: :half})]

      {:peer_close, p} when p != :closed ->
        [:peer_recv, step | valid(steps, %{st | peer: :closed})]

      {:peer_reset, p} when p != :closed ->
        [step | valid(steps, %{st | peer: :closed})]

      {:peer_recv, p} when p != :closed ->
        [step | valid(steps, st)]

      {{:peer_send, _}, _} ->
        valid(steps, st)

      {:peer_shutdown, _} ->
        valid(steps, st)

      {:peer_close, _} ->
        valid(steps, st)

      {:peer_reset, _} ->
        valid(steps, st)

      {:peer_recv, _} ->
        valid(steps, st)

      _ ->
        [step | valid(steps, st)]
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

  # A listener of the test, which the stand-in of the host answers.
  defp listen(opts \\ [:binary, active: false]) do
    task =
      Task.async(fn ->
        receive do
          {:host, %{"t" => "tcp_listen", "id" => id}, _} ->
            [{^id, lpid}] = :ets.lookup(:wasm_host_server, id)
            send(lpid, {:wasm_host, "tcp_listening", %{"id" => id}, ""})
        end
      end)

    HostStandIn.take_host_for(task.pid)
    result = :wasm_tcp.listen(0, opts)
    Task.await(task, 5000)
    HostStandIn.take_host()
    result
  end

  # A connection of a listener, given to the test (accept/2 of wasm_tcp),
  # with the active mode of the options (true by default, as a listener).
  defp accepted(flags, opts \\ []) do
    init = {:accepted, "c1", {"0.0.0.0", 0}, [:binary | opts], flags, self()}
    {:ok, pid} = :gen_server.start(:wasm_tcp, init, [])
    :ok = :gen_server.call(pid, {:accepted, self(), Keyword.get(opts, :active, true)})
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
end
