defmodule BeamCom.TcpDiff do
  @moduledoc """
  The differential test of `:wasm_tcp`: the same steps on a socket of
  `gen_tcp` (the default backend, `inet_drv`) on 127.0.0.1, and on a
  socket of `:wasm_tcp` with a stand-in for the host. Each step gives its
  result and the messages that the owner got, with `:socket` in place of
  the socket. The two traces must be the same.

  A world is `:native` or `:wasm`. In each one, a listener with the
  options of the test accepts one connection, and a new process (the
  owner of the accepted socket) runs the steps. The peer of the
  connection is a socket of the `socket` module (native): unlike a socket
  of `gen_tcp`, it keeps its bytes after an error of a send. In the wasm
  world, the stand-in host gives the events of the peer to the socket,
  and keeps the bytes of its `tcp_send`.

  The steps:

  - `{:send, data}`, `{:recv, length, timeout}`, `{:unrecv, data}`,
    `{:setopts, opts}`, `{:getopts, names}`, `{:shutdown, how}`,
    `:close`, `:peername`: calls on the socket.
  - `{:async_recv, length, timeout}`: a recv in a new process, whose
    result `:await` gives (or `:none` after 1000 ms).
  - `:give_away`: `controlling_process/2` to a new process, and the
    messages that it then has. `:give_away_dead` gives the socket to a
    process that stopped, and `:give_back` calls `controlling_process/2`
    from a process that is not the owner.
  - `{:peer_send, data}`, `:peer_shutdown` (the end of the data of the
    peer: a `tcp_closed` with `"half"` for the host), `:peer_close` (a
    `tcp_closed`), `:peer_reset` (a reset: `tcp_error` with
    `econnreset`, then `tcp_closed`, as the Node.js host gives them),
    `:peer_recv` (the bytes that the peer got since the last one, and
    true when it got the end).

  The stand-in module `:wasm_host` of `BeamCom.HostStandIn` must be
  loaded: the stand-in host takes its messages.

  The wasm world runs first. Its trace tells the native world what to
  wait for after each step: the count of messages, and the bytes and the
  end that the peer gets. The native world waits for them (5000 ms at
  most), and then @settle ms more for the events that the wasm world did
  not give.
  """

  # The time for more events of a native socket after a step: the
  # loopback gives them in microseconds, and no event of the native world
  # tells that no more come.
  @settle 40

  @doc "The traces of the steps in the two worlds: {wasm, native}."
  def diff(listen_opts, steps) do
    wasm = trace(:wasm, listen_opts, steps, [])
    {wasm, trace(:native, listen_opts, steps, wasm)}
  end

  @doc """
  The trace of the steps in the world kind. hints: the trace of the
  other world, or [].
  """
  def trace(kind, listen_opts, steps, hints) do
    hints = Stream.concat(hints, Stream.repeatedly(fn -> nil end))

    pair(kind, listen_opts, fn w ->
      steps |> Enum.zip(hints) |> Enum.map(fn {step, hint} -> step(w, step, hint) end)
    end)
  end

  @doc """
  Runs `fun.(w)` in a new process, the owner of an accepted socket
  `w.socket` of the world `kind`, and gives its result with `:socket` in
  place of the socket. `listen_opts` are the options of the listener.
  """
  def pair(:native, listen_opts, fun) do
    {:ok, l} = :gen_tcp.listen(0, [{:ip, {127, 0, 0, 1}} | listen_opts])
    {:ok, port} = :inet.port(l)
    # The peer is a passive gen_tcp socket: beam.com has no socket module
    # (--disable-esock), and the tests also run there. With exit_on_close
    # false, the peer stays open after it reads the end of the socket under
    # test, so it can still send (a half close).
    {:ok, peer} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, exit_on_close: false])

    try do
      run(fn ->
        {:ok, s} = :gen_tcp.accept(l, 5000)
        result = fun.(%{kind: :native, socket: s, peer: peer})
        :gen_tcp.close(s)
        normal(result, s)
      end)
    after
      :gen_tcp.close(peer)
      :gen_tcp.close(l)
    end
  end

  def pair(:wasm, listen_opts, fun) do
    host = start_host()

    try do
      run(fn ->
        {:ok, {_, _, lpid} = l} = :wasm_tcp.listen(0, listen_opts)
        conn = "c#{System.unique_integer([:positive])}"
        accept = %{"id" => :sys.get_state(lpid).id, "conn" => conn, "host" => "127.0.0.1"}

        send(
          lpid,
          {:wasm_host, "tcp_accept", Map.merge(accept, %{"ack" => true, "sent" => true}), ""}
        )

        {:ok, {_, _, pid} = s} = :wasm_tcp.accept(l, 5000)
        result = fun.(%{kind: :wasm, socket: s, pid: pid, conn: conn, host: host})
        :wasm_tcp.close(s)
        :wasm_tcp.close(l)
        normal(result, s)
      end)
    after
      send(host, :stop)
    end
  end

  @doc """
  The trace of the steps on a listener in the world kind: {step, result},
  with `:socket` in place of each socket. The steps:

  - `:connect`: a new connection of a client to the listener;
  - `{:accept, timeout}`, `{:async_accept, timeout}` (in a new process,
    whose result `:await` gives), `:close`;
  - `{:accept_getopts, names}`: an accept, and getopts of the socket;
  - `:owner_stop`: the owner of the listener stops;
  - `:client_end`: true when the last client got the end of its
    connection in 1000 ms;
  - calls on the listener: `{:getopts, names}`, `{:setopts, opts}`,
    `:sockname` (`{:ok, :address}`), `:peername`, `{:recv, length,
    timeout}`, `{:send, data}`, `{:shutdown, how}`, `{:unrecv, data}`.
  """
  def listener(kind, listen_opts, steps) do
    host = if kind == :wasm, do: start_host()

    try do
      run(fn ->
        w = open_listener(kind, listen_opts, host)
        {trace, _} = Enum.map_reduce(steps, w, fn step, w -> lstep(w, step) end)
        sockets(trace)
      end)
    after
      host && send(host, :stop)
    end
  end

  defp open_listener(:native, opts, _host) do
    {:ok, l} = :gen_tcp.listen(0, [{:ip, {127, 0, 0, 1}} | opts])
    {:ok, port} = :inet.port(l)
    %{kind: :native, l: l, port: port, clients: []}
  end

  defp open_listener(:wasm, opts, host) do
    {:ok, {_, _, lpid} = l} = :wasm_tcp.listen(0, opts)
    %{kind: :wasm, l: l, lpid: lpid, id: :sys.get_state(lpid).id, host: host, clients: []}
  end

  defp lstep(%{kind: :native} = w, :connect) do
    {:ok, c} = :gen_tcp.connect({127, 0, 0, 1}, w.port, [:binary, active: false])
    {{:connect, :ok}, %{w | clients: [c | w.clients]}}
  end

  defp lstep(%{kind: :wasm} = w, :connect) do
    conn = "c#{System.unique_integer([:positive])}"
    meta = %{"id" => w.id, "conn" => conn, "ack" => true, "sent" => true}
    send(w.lpid, {:wasm_host, "tcp_accept", meta, ""})
    :sys.get_state(w.lpid)
    {{:connect, :ok}, %{w | clients: [conn | w.clients]}}
  end

  defp lstep(w, {:async_accept, t}) do
    owner = self()
    pid = spawn(fn -> send(owner, {:async, lcall(w, {:accept, t})}) end)
    # The accept waits in the listener before the next step.
    poll(fn -> accepting?(w, pid) end, 500) or raise "the accept did not come"
    {{{:async_accept, t}, :ok}, w}
  end

  defp lstep(w, :await) do
    receive do
      {:async, result} -> {{:await, result}, w}
    after
      1000 -> {{:await, :none}, w}
    end
  end

  defp lstep(w, :owner_stop) do
    {pid, ref} = spawn_monitor(fn -> receive do: (:stop -> :ok) end)
    result = lcall(w, {:controlling_process, pid})
    send(pid, :stop)
    receive do: ({:DOWN, ^ref, _, _, _} -> :ok)
    # The listener closes with its owner (a port, or a process).
    gone(w)
    {{:owner_stop, result}, w}
  end

  defp lstep(%{kind: :native, clients: [c | _]} = w, :client_end) do
    ended =
      case :gen_tcp.recv(c, 0, 1000) do
        {:error, :timeout} -> false
        {:error, _} -> true
        {:ok, _} -> false
      end

    {{:client_end, ended}, w}
  end

  defp lstep(%{kind: :wasm, clients: [c | _]} = w, :client_end) do
    ended = fn ->
      send(w.host, {:take, self(), c})
      receive do: ({:took, ^c, _, e} -> e)
    end

    {{:client_end, poll(ended, 100)}, w}
  end

  defp lstep(w, :close) do
    result = lcall(w, :close)
    gone(w)
    {{:close, result}, w}
  end

  defp lstep(w, step), do: {{step, lcall(w, step)}, w}

  defp lcall(%{kind: :native, l: l}, step) do
    case step do
      {:accept, t} -> :gen_tcp.accept(l, t)
      {:accept_getopts, o} -> with {:ok, s} <- :gen_tcp.accept(l, 1000), do: :inet.getopts(s, o)
      :close -> :gen_tcp.close(l)
      {:controlling_process, pid} -> :gen_tcp.controlling_process(l, pid)
      {:getopts, o} -> :inet.getopts(l, o)
      {:setopts, o} -> :inet.setopts(l, o)
      :sockname -> address(:inet.sockname(l))
      :peername -> :inet.peername(l)
      {:recv, n, t} -> :gen_tcp.recv(l, n, t)
      {:send, data} -> :gen_tcp.send(l, data)
      {:shutdown, how} -> :gen_tcp.shutdown(l, how)
      {:unrecv, data} -> :gen_tcp.unrecv(l, data)
    end
  end

  defp lcall(%{kind: :wasm, l: l}, step) do
    case step do
      {:accept, t} ->
        :wasm_tcp.accept(l, t)

      {:accept_getopts, o} ->
        with {:ok, s} <- :wasm_tcp.accept(l, 1000), do: :wasm_tcp.getopts(s, o)

      :close ->
        :wasm_tcp.close(l)

      {:controlling_process, pid} ->
        :wasm_tcp.controlling_process(l, pid)

      {:getopts, o} ->
        :wasm_tcp.getopts(l, o)

      {:setopts, o} ->
        :wasm_tcp.setopts(l, o)

      :sockname ->
        address(:wasm_tcp.sockname(l))

      :peername ->
        :wasm_tcp.peername(l)

      {:recv, n, t} ->
        :wasm_tcp.recv(l, n, t)

      {:send, data} ->
        :wasm_tcp.send(l, data)

      {:shutdown, how} ->
        :wasm_tcp.shutdown(l, how)

      {:unrecv, data} ->
        :wasm_tcp.unrecv(l, data)
    end
  end

  # The process waits in the accept: in prim_inet (native), or in the
  # queue of the acceptors of the listener (wasm). Or it ended at once.
  defp accepting?(%{kind: :native}, pid), do: inet_waits?(pid, :accept0)

  defp accepting?(%{kind: :wasm, lpid: lpid}, pid) do
    acceptors = :queue.to_list(:sys.get_state(lpid).acceptors)
    Enum.any?(acceptors, &match?({_, ^pid, _, _}, &1)) or not Process.alive?(pid)
  end

  # After a close: the port closed (native), or the process stopped.
  defp gone(%{kind: :native}), do: Process.sleep(@settle)

  defp gone(%{kind: :wasm, lpid: lpid}) do
    ref = Process.monitor(lpid)
    receive do: ({:DOWN, ^ref, _, _, _} -> :ok)
  end

  # A poll of fun for true: 10 ms steps, left steps at most.
  defp poll(fun, left) do
    cond do
      fun.() ->
        true

      left == 0 ->
        false

      true ->
        Process.sleep(10)
        poll(fun, left - 1)
    end
  end

  # :socket in place of each socket (a port, or a socket of :wasm_tcp).
  defp sockets(term) when is_port(term), do: :socket
  defp sockets({:"$inet", :wasm_tcp, _}), do: :socket
  defp sockets(t) when is_tuple(t), do: t |> Tuple.to_list() |> sockets() |> List.to_tuple()
  defp sockets([h | t]), do: [sockets(h) | sockets(t)]
  defp sockets(term), do: term

  @doc """
  One step in the world w: {step, result, messages}. hint: the same step
  of the other world, or nil.
  """
  def step(w, {:keep, step}, _hint) do
    # The messages stay in the mailbox, for the next step.
    result = act(w, step, nil)
    sync(w)
    {{:keep, step}, normal(result, w.socket), []}
  end

  def step(w, step, hint) do
    result = act(w, step, hint)

    case hint do
      {_, _, messages} -> sync(w, length(messages))
      nil -> sync(w)
    end

    {step, normal(result, w.socket), normal(flush(), w.socket)}
  end

  @doc "The messages in the mailbox of the caller, in order."
  def flush do
    receive do
      m -> [m | flush()]
    after
      0 -> []
    end
  end

  @doc "Waits for the events of the last step: see @settle."
  def sync(w, count \\ 0)

  def sync(%{kind: :native}, count) do
    wait(fn -> elem(Process.info(self(), :message_queue_len), 1) >= count end)
    Process.sleep(@settle)
  end

  def sync(%{kind: :wasm, pid: pid}, _count) do
    # A call to the socket: the messages of the socket to this process
    # come before its reply.
    try do
      :sys.get_state(pid)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp act(%{kind: :native, peer: p}, :peer_recv, hint) do
    {bytes, ended} =
      case hint do
        {_, {bytes, ended}, _} -> {byte_size(bytes), ended}
        nil -> {0, false}
      end

    peer_recv(p, "", bytes, ended, System.monotonic_time(:millisecond) + 5000)
  end

  defp act(w, step, _hint), do: act(w, step)

  defp act(%{kind: :native, socket: s}, {:send, data}), do: :gen_tcp.send(s, data)
  defp act(%{kind: :wasm, socket: s}, {:send, data}), do: :wasm_tcp.send(s, data)
  defp act(%{kind: :native, socket: s}, {:recv, n, t}), do: :gen_tcp.recv(s, n, t)
  defp act(%{kind: :wasm, socket: s}, {:recv, n, t}), do: :wasm_tcp.recv(s, n, t)
  defp act(%{kind: :native, socket: s}, {:unrecv, data}), do: :gen_tcp.unrecv(s, data)
  defp act(%{kind: :wasm, socket: s}, {:unrecv, data}), do: :wasm_tcp.unrecv(s, data)
  defp act(%{kind: :native, socket: s}, {:setopts, o}), do: :inet.setopts(s, o)
  defp act(%{kind: :wasm, socket: s}, {:setopts, o}), do: :wasm_tcp.setopts(s, o)
  defp act(%{kind: :native, socket: s}, {:getopts, o}), do: :inet.getopts(s, o)
  defp act(%{kind: :wasm, socket: s}, {:getopts, o}), do: :wasm_tcp.getopts(s, o)
  defp act(%{kind: :native, socket: s}, {:shutdown, how}), do: :gen_tcp.shutdown(s, how)
  defp act(%{kind: :wasm, socket: s}, {:shutdown, how}), do: :wasm_tcp.shutdown(s, how)
  defp act(%{kind: :native, socket: s}, :close), do: :gen_tcp.close(s)
  defp act(%{kind: :wasm, socket: s}, :close), do: :wasm_tcp.close(s)
  defp act(%{kind: :native, socket: s}, :peername), do: address(:inet.peername(s))
  defp act(%{kind: :wasm, socket: s}, :peername), do: address(:wasm_tcp.peername(s))

  defp act(w, {:async_recv, n, t}) do
    owner = self()
    pid = spawn(fn -> send(owner, {:async, act(w, {:recv, n, t})}) end)
    # The recv waits in the socket before the next step.
    poll(fn -> receiving?(w, pid) end, 500) or raise "the recv did not come"
    :ok
  end

  defp act(_w, :await) do
    receive do
      {:async, result} -> result
    after
      1000 -> :none
    end
  end

  defp act(w, :give_away) do
    new = spawn(fn -> receive do: ({:go, from} -> send(from, {:moved, flush()})) end)
    result = controlling_process(w, new)
    sync(w)
    send(new, {:go, self()})
    receive do: ({:moved, moved} -> {result, moved})
  end

  defp act(w, :give_away_dead) do
    {dead, ref} = spawn_monitor(fn -> :ok end)
    receive do: ({:DOWN, ^ref, _, _, _} -> :ok)
    controlling_process(w, dead)
  end

  defp act(w, :give_back) do
    owner = self()
    other = spawn(fn -> send(owner, {:other, controlling_process(w, self())}) end)
    receive do: ({:other, result} -> {result, other != owner})
  end

  # The result of a send and of a shutdown of the native peer is the one
  # of its own socket of the OS (for example after a reset), not of the
  # socket under test: the steps give :ok, as the host does.
  defp act(%{kind: :native, peer: p}, {:peer_send, data}) do
    _ = :gen_tcp.send(p, data)
    :ok
  end

  defp act(%{kind: :native, peer: p}, :peer_shutdown) do
    _ = :gen_tcp.shutdown(p, :write)
    :ok
  end

  defp act(%{kind: :native, peer: p}, :peer_close), do: :gen_tcp.close(p)

  # A linger of 0 s: the close sends a reset (RST).
  defp act(%{kind: :native, peer: p}, :peer_reset) do
    :ok = :inet.setopts(p, linger: {true, 0})
    :gen_tcp.close(p)
  end

  defp act(%{kind: :wasm} = w, {:peer_send, data}), do: event(w, "tcp_data", %{}, data)
  defp act(%{kind: :wasm} = w, :peer_shutdown), do: event(w, "tcp_closed", %{"half" => true}, "")
  defp act(%{kind: :wasm} = w, :peer_close), do: event(w, "tcp_closed", %{}, "")

  defp act(%{kind: :wasm} = w, :peer_reset) do
    event(w, "tcp_error", %{"reason" => "econnreset"}, "")
    event(w, "tcp_closed", %{}, "")
  end

  defp act(%{kind: :wasm, conn: c, host: host} = w, :peer_recv) do
    sync(w)
    send(host, {:take, self(), c})

    receive do
      {:took, ^c, bytes, ended} -> {bytes, ended}
    after
      5000 -> raise "the stand-in host did not answer"
    end
  end

  # The process waits in the recv: in prim_inet (native), or in the state
  # of the socket (wasm). Or it ended at once.
  defp receiving?(%{kind: :native}, pid), do: inet_waits?(pid, :recv0)

  defp receiving?(%{pid: socket}, pid) do
    match?(%{recv: {_, _, _}}, :sys.get_state(socket)) or not Process.alive?(pid)
  end

  # The process waits in the function fun of prim_inet (an accept or a
  # recv of gen_tcp), or it stopped. The spawn of the step does not tell
  # when the call starts: on a busy machine, it can start later than the
  # next step.
  defp inet_waits?(pid, fun) do
    case Process.info(pid, [:current_function, :status]) do
      nil -> true
      [current_function: {:prim_inet, ^fun, _}, status: :waiting] -> true
      _ -> false
    end
  end

  # An event of the host for the socket of w.
  defp event(%{pid: pid, conn: c}, type, meta, body) do
    send(pid, {:wasm_host, type, Map.put(meta, "id", c), body})
    :ok
  end

  # The bytes that the native peer got: at least the bytes and the end
  # that the other world gave (until the deadline), then until a pause.
  defp peer_recv(p, acc, bytes, ended, deadline) do
    wait = byte_size(acc) < bytes or ended

    t =
      if wait,
        do: max(deadline - System.monotonic_time(:millisecond), 0),
        else: @settle

    case :gen_tcp.recv(p, 0, t) do
      {:ok, data} -> peer_recv(p, acc <> data, bytes, ended, deadline)
      {:error, :timeout} -> {acc, false}
      {:error, _} -> {acc, true}
    end
  end

  # A poll for a condition: 5000 ms at most, a step of 5 ms.
  defp wait(check, left \\ 1000) do
    cond do
      check.() ->
        :ok

      left == 0 ->
        :ok

      true ->
        Process.sleep(5)
        wait(check, left - 1)
    end
  end

  defp controlling_process(%{kind: :native, socket: s}, pid),
    do: :gen_tcp.controlling_process(s, pid)

  defp controlling_process(%{kind: :wasm, socket: s}, pid),
    do: :wasm_tcp.controlling_process(s, pid)

  defp address({:ok, {_ip, _port}}), do: {:ok, :address}
  defp address(other), do: other

  # Runs fun in a new process, and gives its result.
  defp run(fun) do
    test = self()
    ref = make_ref()

    {pid, mon} =
      spawn_monitor(fn ->
        send(test, {ref, fun.()})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, ^pid, reason} ->
        raise "the owner stopped: #{inspect(reason)}"
    after
      30_000 -> raise "the steps did not end"
    end
  end

  # :socket in place of the socket, in a term.
  defp normal(term, s) when term == s, do: :socket
  defp normal(t, s) when is_tuple(t), do: t |> Tuple.to_list() |> normal(s) |> List.to_tuple()

  defp normal([h | t], s), do: [normal(h, s) | normal(t, s)]
  defp normal(term, _s), do: term

  # The stand-in host: it answers tcp_listen, and keeps the bytes of the
  # sends of each connection and its end (tcp_shutdown, tcp_close).
  defp start_host do
    test = self()

    host =
      spawn(fn ->
        receive do: (:go -> :ok)
        BeamCom.HostStandIn.take_host()
        send(test, :host_ready)
        host_loop(%{})
      end)

    send(host, :go)

    receive do
      :host_ready -> host
    after
      5000 -> raise "the stand-in host did not start"
    end
  end

  defp host_loop(conns) do
    receive do
      {:host, %{"t" => "tcp_listen", "id" => id}, _} ->
        [{^id, pid}] = :ets.lookup(:wasm_host_server, id)
        send(pid, {:wasm_host, "tcp_listening", %{"id" => id}, ""})
        host_loop(conns)

      {:host, %{"t" => "tcp_send", "id" => id}, body} ->
        host_loop(Map.update(conns, id, {body, false}, fn {b, e} -> {b <> body, e} end))

      {:host, %{"t" => t, "id" => id}, _} when t in ["tcp_shutdown", "tcp_close"] ->
        host_loop(Map.update(conns, id, {"", true}, fn {b, _} -> {b, true} end))

      {:take, from, id} ->
        {bytes, ended} = Map.get(conns, id, {"", false})
        send(from, {:took, id, bytes, ended})
        host_loop(Map.put(conns, id, {"", ended}))

      :stop ->
        :ok

      _ ->
        host_loop(conns)
    end
  end
end
