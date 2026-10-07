%% TCP sockets through the JavaScript host. After
%% inet_db:set_tcp_module(wasm_tcp), gen_tcp and inet dispatch to this
%% module ({'$inet', wasm_tcp, Pid}, as for the socket backend):
%%
%% - gen_tcp:connect/3,4: node:net in each host (in Workers, with
%%   nodejs_compat, the default from the compatibility date 2026-08-04);
%% - gen_tcp:listen/2 and accept/1,2: a server of node:net in Node.js; in
%%   Workers (which get no TCP connections), each WebSocket to
%%   /.tcp/PORT is a connection to the listener of PORT.
%%
%% Each socket and each listener is a process. It gets the events of the
%% host (tcp_open, tcp_data, tcp_closed, tcp_error, tcp_listening,
%% tcp_accept) from the pump (wasm_host_server) and sends
%% tcp_connect, tcp_send, tcp_close, tcp_listen and tcp_unlisten. Packets:
%% raw (0), 1, 2, 4 and line.
%%
%% Flow control, in the two directions. The tcp_accept or tcp_open of a
%% socket gives the flags of the host:
%%
%% - "ack": true: the socket tells the host how many bytes its owner took
%%   from the buffer (tcp_read, after each ?ACK_BYTES and when the buffer
%%   is empty). The host sends more data only while little is unread, so
%%   the buffer of a socket stays small (a request body in chunks). While
%%   the owner waits for more bytes than the buffer holds (a recv of a
%%   length, as Bandit reads a body, or a packet that is not complete),
%%   the bytes of the buffer count as taken: else a recv of more than the
%%   window of the host never gets its bytes. Each tcp_read also gives
%%   "want", the bytes that a waiting recv of a length needs beyond the
%%   buffer, and "got", the bytes that the socket got from the host. With
%%   them, the host sends larger parts while a long recv waits.
%% - "sent": true: the host tells the socket how many bytes of tcp_send it
%%   gave to the peer (tcp_sent). While ?SEND_WINDOW bytes or more wait in
%%   the host, a send waits for tcp_sent, so a slow peer slows the sender
%%   and the host holds little.
-module(wasm_tcp).
-behaviour(gen_server).

-export([getaddrs/2, getserv/1, connect/4, listen/2, accept/1, accept/2, splice/2, host_info/1,
         send/2, sendfile/4, recv/2, recv/3, unrecv/2,
         close/1, shutdown/2, controlling_process/2, setopts/2, getopts/2,
         peername/1, sockname/1, getstat/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SOCKET(Pid), {'$inet', ?MODULE, Pid}).
-define(HOST, wasm_host_server).
-define(ACK_BYTES, 65536).
-define(SEND_WINDOW, 262144).

%% The host resolves the names.
getaddrs(Address, _Timer) -> {ok, [Address]}.
getserv(Port) when is_integer(Port) -> {ok, Port};
getserv(_) -> {error, einval}.

connect(Address, Port, Opts, Timeout) ->
    {ok, Pid} = gen_server:start(?MODULE, {self(), Opts}, []),
    case gen_server:call(Pid, {connect, host(Address), Port, Timeout}, infinity) of
        ok -> {ok, ?SOCKET(Pid)};
        Error -> Error
    end.

%% As inet_tcp: a {port, P} option wins over the argument (Ranch listens
%% with 0 and the option).
listen(Port0, Opts) ->
    Port = proplists:get_value(port, Opts, Port0),
    {ok, Pid} = gen_server:start(?MODULE, {listen, self(), Port, Opts}, []),
    case gen_server:call(Pid, listen, infinity) of
        ok -> {ok, ?SOCKET(Pid)};
        Error -> Error
    end.

accept(Socket) -> accept(Socket, infinity).

%% The id of the socket in the host, and the host and the port of its peer
%% as the host gave them (a name stays a name). wasm_host_fetch gives the
%% id with each request of the connection, and opens a tunnel to the peer.
host_info(?SOCKET(Pid)) -> call(Pid, host_info).

%% The data of each socket goes to the other one in the host (as a proxy),
%% no longer through Erlang: for example a connection that a listener
%% accepted, and one to the server behind it. The data in the buffers goes
%% first. The sockets end together.
splice(?SOCKET(A), ?SOCKET(B)) ->
    {ok, IdA} = call(A, id),
    {ok, IdB} = call(B, id),
    ok = call(A, {splice, IdB}),
    ok = call(B, {splice, IdA}),
    ?HOST:send_host(#{t => tcp_splice, a => IdA, b => IdB}).

accept(?SOCKET(Pid), Timeout) -> call(Pid, {accept, self(), Timeout}).

send(?SOCKET(Pid), Data) -> call(Pid, {send, Data}).

%% file:sendfile/5 on a socket of this module: the file in parts of 64 KB.
%% Bytes 0: to the end of the file.
sendfile(Socket, Fd, Offset, Bytes) -> sendfile(Socket, Fd, Offset, Bytes, 0).

sendfile(Socket, Fd, Offset, Bytes, Sent) ->
    Size = case Bytes of 0 -> 65536; _ -> min(65536, Bytes - Sent) end,
    case Size > 0 andalso file:pread(Fd, Offset + Sent, Size) of
        false -> {ok, Sent};
        eof -> {ok, Sent};
        {ok, Data} ->
            case send(Socket, Data) of
                ok -> sendfile(Socket, Fd, Offset, Bytes, Sent + byte_size(Data));
                Error -> Error
            end;
        Error -> Error
    end.
recv(Socket, Length) -> recv(Socket, Length, infinity).
recv(?SOCKET(Pid), Length, Timeout) -> call(Pid, {recv, Length, Timeout}).
unrecv(?SOCKET(Pid), Data) -> call(Pid, {unrecv, Data}).
close(?SOCKET(Pid)) -> _ = call(Pid, close), ok.
shutdown(?SOCKET(Pid), _How) -> call(Pid, close).
controlling_process(?SOCKET(Pid), NewOwner) -> call(Pid, {controlling_process, self(), NewOwner}).
setopts(?SOCKET(Pid), Opts) -> call(Pid, {setopts, Opts}).
getopts(?SOCKET(Pid), Opts) -> call(Pid, {getopts, Opts}).
peername(?SOCKET(Pid)) -> call(Pid, peername).
sockname(?SOCKET(Pid)) -> call(Pid, sockname).
getstat(?SOCKET(Pid), Opts) -> call(Pid, {getstat, Opts}).

call(Pid, Request) ->
    try gen_server:call(Pid, Request, infinity)
    catch exit:{noproc, _} -> {error, closed};
          exit:{normal, _} -> {error, closed}
    end.

host(A) when is_tuple(A) -> list_to_binary(inet:ntoa(A));
host(A) when is_atom(A) -> atom_to_binary(A);
host(A) when is_list(A) -> list_to_binary(A);
host(A) when is_binary(A) -> A.

%% --- the process of a socket ----------------------------------------------

init({listen, Owner, Port, Opts}) ->
    Id = new_id(<<"l">>),
    ?HOST:register(Id),
    {ok, #{kind => listen, id => Id, owner => Owner, ref => monitor(process, Owner),
           port => Port, opts => Opts, listen => undefined,
           conns => queue:new(), acceptors => queue:new()}};
init({Owner, Opts}) ->
    Id = new_id(<<"t">>),
    ?HOST:register(Id),
    {ok, options(Opts, socket(Id, Owner))};
%% A connection of a listener: open, and passive until accept/2 gives it
%% to its owner (with the options of the listener).
init({accepted, Id, Peer, Opts, Flags}) ->
    %% The pump gives this process the events that came before it, first.
    ?HOST:claim(Id),
    S = options(Opts, maps:merge((socket(Id, self()))#{peer := Peer}, Flags)),
    {ok, S#{active := false, later => maps:get(active, S)}}.

new_id(Prefix) ->
    <<Prefix/binary, (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

socket(Id, Owner) ->
    #{kind => socket, id => Id, owner => Owner, ref => monitor(process, Owner),
      active => true, mode => list, packet => raw, other => #{}, buf => <<>>, recv => undefined,
      connect => undefined, peer => undefined, closed => false,
      recv_cnt => 0, recv_oct => 0, send_cnt => 0, send_oct => 0,
      ack => false, unacked => 0, ahead => 0, sack => false, inflight => 0, sends => queue:new()}.

%% The flow control of the host for a socket (tcp_accept, tcp_open).
flags(Meta) ->
    #{ack => maps:get(<<"ack">>, Meta, false) =:= true,
      sack => maps:get(<<"sent">>, Meta, false) =:= true}.

options(Opts, S) -> lists:foldl(fun option/2, S, Opts).

option(binary, S) -> S#{mode := binary};
option(list, S) -> S#{mode := list};
option({mode, M}, S) -> S#{mode := M};
option({active, A}, S) -> S#{active := A};
option({packet, P}, S) when P =:= raw; P =:= 0 -> S#{packet := raw};
option({packet, P}, S) when P =:= 1; P =:= 2; P =:= 4; P =:= line -> S#{packet := P};
%% Other options: kept for getopts (the host does not use them).
option({K, V}, #{other := O} = S) -> S#{other := O#{K => V}};
option(_, S) -> S.

%% The values that getopts gives for the options that were not set.
-define(DEFAULTS, #{buffer => 65536, recbuf => 65536, sndbuf => 65536, nodelay => false,
                    keepalive => false, reuseaddr => false, packet_size => 0, delay_send => false,
                    send_timeout => infinity, send_timeout_close => false, exit_on_close => true,
                    high_watermark => 8192, low_watermark => 4096, linger => {false, 0},
                    tos => 0, priority => 0, show_econnreset => false, deliver => term}).

%% --- a listener -------------------------------------------------------------
%% {wasm_fetch, true}: the listener of wasm_host_fetch, which the host
%% keeps apart from the listeners of the program. {wasm_fetch_tls, true}:
%% the trust store of the VM holds the CA of that server.
handle_call(listen, From, #{kind := listen, id := Id, port := Port, opts := Opts} = S) ->
    Fetch = [{fetch, true} || proplists:get_bool(wasm_fetch, Opts)]
        ++ [{tls, true} || proplists:get_bool(wasm_fetch_tls, Opts)],
    ?HOST:send_host(maps:from_list([{t, tcp_listen}, {id, Id}, {port, Port} | Fetch])),
    {noreply, S#{listen := From}};
handle_call({accept, Pid, Timeout}, From, #{kind := listen, conns := Conns, acceptors := As} = S) ->
    case queue:out(Conns) of
        {{value, Conn}, Rest} ->
            {noreply, hand(Conn, {From, Pid, undefined}, S#{conns := Rest})};
        {empty, _} ->
            TRef = case Timeout of
                infinity -> undefined;
                _ -> erlang:send_after(Timeout, self(), {accept_timeout, From})
            end,
            {noreply, S#{acceptors := queue:in({From, Pid, TRef}, As)}}
    end;
handle_call(sockname, _From, #{kind := listen, port := Port} = S) ->
    {reply, {ok, {{0, 0, 0, 0}, Port}}, S};
handle_call(close, _From, #{kind := listen, id := Id} = S) ->
    ?HOST:send_host(#{t => tcp_unlisten, id => Id}),
    {stop, normal, ok, S};
handle_call({setopts, _}, _From, #{kind := listen} = S) ->
    {reply, ok, S};
handle_call({getopts, _}, _From, #{kind := listen} = S) ->
    {reply, {ok, []}, S};
handle_call({controlling_process, Caller, New}, _From, #{kind := listen, owner := Caller, ref := Ref} = S) ->
    demonitor(Ref, [flush]),
    {reply, ok, S#{owner := New, ref := monitor(process, New)}};
handle_call(_, _From, #{kind := listen} = S) ->
    {reply, {error, enotconn}, S};
%% --- a socket ----------------------------------------------------------------
handle_call({accepted, Owner}, _From, #{ref := Ref, later := A} = S) ->
    demonitor(Ref, [flush]),
    S1 = maps:remove(later, S#{owner := Owner, ref := monitor(process, Owner), active := A}),
    {reply, ok, wanted(serve_recv(flush_active(S1)))};
handle_call(sockname, _From, S) ->
    {reply, {ok, {{0, 0, 0, 0}, 0}}, S};
handle_call(host_info, _From, #{id := Id, peer := {Host, Port}} = S) ->
    {reply, {ok, #{id => Id, host => Host, port => Port}}, S};
handle_call({splice, Peer}, _From, #{buf := Buf} = S) ->
    Buf =/= <<>> andalso ?HOST:send_host(#{t => tcp_send, id => Peer}, Buf),
    {reply, ok, taken(<<>>, S#{spliced => Peer, active := false})};
%% {wasm_direct, true}: connect() of the host, never the fetch path (the
%% tunnel of wasm_host_fetch).
handle_call({connect, Host, Port, Timeout}, From, #{id := Id, other := O} = S) ->
    Direct = [{direct, true} || maps:get(wasm_direct, O, false) =:= true],
    ?HOST:send_host(maps:from_list([{t, tcp_connect}, {id, Id}, {host, Host}, {port, Port} | Direct])),
    TRef = case Timeout of
        infinity -> undefined;
        _ -> erlang:send_after(Timeout, self(), connect_timeout)
    end,
    {noreply, S#{connect := {From, TRef}, peer := {Host, Port}}};
handle_call({send, _}, _From, #{closed := true} = S) ->
    {reply, {error, closed}, S};
%% The host holds ?SEND_WINDOW bytes or more of this socket: the send waits
%% for tcp_sent (drain/1).
handle_call({send, Data}, From, #{sack := true, inflight := F, sends := Q} = S)
  when F >= ?SEND_WINDOW ->
    {noreply, S#{sends := queue:in({From, Data}, Q)}};
handle_call({send, Data}, _From, S) ->
    {reply, ok, send_data(Data, S)};
%% The counters (the distribution checks them to see traffic).
handle_call({getstat, Opts}, _From, S) ->
    Stat = fun(send_pend) -> 0; (K) -> maps:get(K, S, 0) end,
    {reply, {ok, [{K, Stat(K)} || K <- Opts]}, S};
handle_call({recv, _, _}, _From, #{active := A} = S) when A =/= false ->
    {reply, {error, einval}, S};
handle_call({recv, Length, Timeout}, From, S) ->
    TRef = case Timeout of
        infinity -> undefined;
        _ -> erlang:send_after(Timeout, self(), recv_timeout)
    end,
    {noreply, hint(wanted(serve_recv(S#{recv := {From, Length, TRef}})))};
handle_call({unrecv, Data}, _From, #{buf := Buf} = S) ->
    {reply, ok, S#{buf := <<(iolist_to_binary(Data))/binary, Buf/binary>>}};
handle_call(close, _From, S) ->
    {stop, normal, ok, close_host(S)};
handle_call({controlling_process, Caller, New}, _From, #{owner := Caller, ref := Ref} = S) ->
    demonitor(Ref, [flush]),
    {reply, ok, S#{owner := New, ref := monitor(process, New)}};
handle_call({controlling_process, _, _}, _From, S) ->
    {reply, {error, not_owner}, S};
handle_call({setopts, Opts}, _From, S) ->
    {reply, ok, wanted(flush_active(options(Opts, S)))};
handle_call({getopts, Opts}, _From, #{active := A, mode := M, packet := P, other := O} = S) ->
    Known = maps:merge(maps:merge(?DEFAULTS, O), #{active => A, mode => M, packet => P, header => 0}),
    {reply, {ok, [{K, V} || K <- Opts, {ok, V} <- [maps:find(K, Known)]]}, S};
handle_call(peername, _From, #{peer := undefined} = S) ->
    {reply, {error, enotconn}, S};
handle_call(peername, _From, #{peer := {Host, Port}} = S) ->
    Addr = case inet:parse_address(binary_to_list(Host)) of
        {ok, IP} -> IP;
        _ -> {0, 0, 0, 0}
    end,
    {reply, {ok, {Addr, Port}}, S}.

handle_cast(_, S) -> {noreply, S}.

%% --- a listener -------------------------------------------------------------
handle_info({wasm_host, <<"tcp_listening">>, _, _}, #{kind := listen, listen := From} = S) ->
    gen_server:reply(From, ok),
    {noreply, S#{listen := undefined}};
handle_info({wasm_host, <<"tcp_error">>, Meta, _}, #{kind := listen, listen := From} = S)
  when From =/= undefined ->
    gen_server:reply(From, {error, reason(Meta)}),
    {stop, normal, S};
handle_info({wasm_host, <<"tcp_accept">>, Meta, _}, #{kind := listen, opts := Opts} = S) ->
    #{<<"conn">> := Id} = Meta,
    Peer = {maps:get(<<"host">>, Meta, <<"0.0.0.0">>), maps:get(<<"port">>, Meta, 0)},
    {ok, Pid} = gen_server:start(?MODULE, {accepted, Id, Peer, Opts, flags(Meta)}, []),
    case queue:out(maps:get(acceptors, S)) of
        {{value, A}, Rest} -> {noreply, hand({Id, Pid}, A, S#{acceptors := Rest})};
        {empty, _} -> {noreply, S#{conns := queue:in({Id, Pid}, maps:get(conns, S))}}
    end;
handle_info({accept_timeout, From}, #{kind := listen, acceptors := As} = S) ->
    case lists:keytake(From, 1, queue:to_list(As)) of
        {value, _, Rest} ->
            gen_server:reply(From, {error, timeout}),
            {noreply, S#{acceptors := queue:from_list(Rest)}};
        false -> {noreply, S}
    end;
handle_info({'DOWN', Ref, process, _, _}, #{kind := listen, ref := Ref, id := Id} = S) ->
    ?HOST:send_host(#{t => tcp_unlisten, id => Id}),
    {stop, normal, S};
handle_info(_, #{kind := listen} = S) ->
    {noreply, S};
%% --- a socket ----------------------------------------------------------------
handle_info({wasm_host, <<"tcp_open">>, Meta, _}, #{connect := {From, TRef}} = S) ->
    cancel(TRef),
    gen_server:reply(From, ok),
    {noreply, maps:merge(S#{connect := undefined}, flags(Meta))};
%% The host gave N bytes of tcp_send to the peer: the sends that wait go.
handle_info({wasm_host, <<"tcp_sent">>, #{<<"n">> := N}, _}, #{inflight := F} = S) ->
    {noreply, drain(S#{inflight := max(F - N, 0)})};
handle_info({wasm_host, <<"tcp_error">>, Meta, _}, #{connect := {From, TRef}} = S) ->
    cancel(TRef),
    gen_server:reply(From, {error, reason(Meta)}),
    {stop, normal, S};
handle_info({wasm_host, <<"tcp_error">>, Meta, _}, #{owner := Owner} = S) ->
    Owner ! {tcp_error, ?SOCKET(self()), reason(Meta)},
    {noreply, S};
%% Data that came before the host joined the sockets: to the peer.
handle_info({wasm_host, <<"tcp_data">>, _, Data}, #{spliced := Peer, unacked := U} = S) ->
    ?HOST:send_host(#{t => tcp_send, id => Peer}, Data),
    {noreply, ack(S#{unacked := U + byte_size(Data)})};
handle_info({wasm_host, <<"tcp_closed">>, _, _}, #{spliced := _} = S) ->
    {stop, normal, S};
handle_info({wasm_host, <<"tcp_data">>, _, Data}, #{recv_cnt := C, recv_oct := O} = S) ->
    {noreply, deliver(Data, S#{recv_cnt := C + 1, recv_oct := O + byte_size(Data)})};
handle_info({wasm_host, <<"tcp_closed">>, _, _}, S) ->
    closed(S);
handle_info(connect_timeout, #{connect := {From, _}} = S) ->
    gen_server:reply(From, {error, timeout}),
    {stop, normal, close_host(S)};
handle_info(recv_timeout, #{recv := {From, _, _}} = S) ->
    gen_server:reply(From, {error, timeout}),
    {noreply, S#{recv := undefined}};
handle_info({'DOWN', Ref, process, _, _}, #{ref := Ref} = S) ->
    {stop, normal, close_host(S)};
handle_info(_, S) ->
    {noreply, S}.

terminate(_, #{id := Id}) ->
    ?HOST:unregister(Id).

reason(Meta) -> binary_to_atom(maps:get(<<"reason">>, Meta, <<"econnrefused">>)).

%% Gives the connection {Id, Pid} to the acceptor {From, Pid, TRef}.
hand({_Id, Pid}, {From, Owner, TRef}, S) ->
    cancel(TRef),
    ok = gen_server:call(Pid, {accepted, Owner}),
    gen_server:reply(From, {ok, ?SOCKET(Pid)}),
    S.

%% The data of a send to the host, with the header of the packet.
send_data(Data, #{id := Id, packet := P, sack := Sack, inflight := F,
                  send_cnt := C, send_oct := O} = S) ->
    Size = iolist_size(Data),
    Header = header(P, Size),
    ?HOST:send_host(#{t => tcp_send, id => Id}, [Header, Data]),
    Held = case Sack of
        true -> F + byte_size(Header) + Size;
        false -> F
    end,
    S#{send_cnt := C + 1, send_oct := O + Size, inflight := Held}.

%% The sends that wait, in order, while the host holds less than
%% ?SEND_WINDOW bytes.
drain(#{inflight := F, sends := Q} = S) when F < ?SEND_WINDOW ->
    case queue:out(Q) of
        {{value, {From, Data}}, Rest} ->
            gen_server:reply(From, ok),
            drain(send_data(Data, S#{sends := Rest}));
        {empty, _} -> S
    end;
drain(S) -> S.

%% The sends that wait get {error, closed}: no tcp_sent comes now.
refuse_sends(#{sends := Q} = S) ->
    [gen_server:reply(From, {error, closed}) || {From, _} <- queue:to_list(Q)],
    S#{sends := queue:new()}.

cancel(undefined) -> ok;
cancel(TRef) -> erlang:cancel_timer(TRef).

close_host(#{id := Id} = S) ->
    ?HOST:send_host(#{t => tcp_close, id => Id}),
    S.

data(Bin, #{mode := binary}) -> Bin;
data(Bin, #{mode := list}) -> binary_to_list(Bin).

header(raw, _) -> <<>>;
header(line, _) -> <<>>;
header(N, Size) -> <<Size:(N * 8)>>.

%% The next packet in the buffer: {Packet, Rest}, or none.
next_packet(#{buf := <<>>}) -> none;
next_packet(#{packet := raw, buf := Buf}) -> {Buf, <<>>};
next_packet(#{packet := P, buf := Buf}) ->
    case erlang:decode_packet(P, Buf, []) of
        {ok, Packet, Rest} -> {Packet, Rest};
        _ -> none
    end.

%% Data from the host: to the buffer, then to the owner (active modes) or
%% to a waiting recv. An append to a binary that is not writable allocates
%% twice the new size, so a large recv held a binary of twice its length.
%% Data to an empty buffer is the buffer, and the data that completes a
%% waiting recv makes one binary of the exact size.
deliver(Data, #{buf := Buf} = S) ->
    Next = if
        Buf =:= <<>> -> Data;
        true ->
            case S of
                #{recv := {_, Len, _}} when Len > 0, byte_size(Buf) + byte_size(Data) >= Len ->
                    iolist_to_binary([Buf, Data]);
                _ -> <<Buf/binary, Data/binary>>
            end
    end,
    wanted(serve_recv(push(S#{buf := Next}))).

%% The owner waits, and the buffer does not have what it waits for: the
%% bytes of the buffer that tcp_read did not count yet count now (ahead).
wanted(#{ack := true, buf := Buf, ahead := A, unacked := U} = S)
  when byte_size(Buf) > A ->
    case waits(S) of
        true -> ack(S#{ahead := byte_size(Buf), unacked := U + byte_size(Buf) - A});
        false -> S
    end;
wanted(S) -> S.

waits(#{recv := {_, _, _}}) -> true;
waits(#{active := A}) -> A =/= false.

%% In an active mode: the packets of the buffer to the owner.
push(#{active := false} = S) -> S;
push(#{owner := Owner, active := A} = S) ->
    case next_packet(S) of
        none -> S;
        {Packet, Rest} ->
            Socket = ?SOCKET(self()),
            Owner ! {tcp, Socket, data(Packet, S)},
            S1 = taken(Rest, S),
            case A of
                true -> push(S1);
                once -> S1#{active := false};
                1 -> Owner ! {tcp_passive, Socket}, S1#{active := false};
                N when is_integer(N) -> push(S1#{active := N - 1})
            end
    end.

flush_active(S) -> push(S).

%% The owner took the start of the buffer: Rest stays. The bytes that
%% wanted/1 counted (ahead) do not count again.
taken(Rest, #{buf := Buf, unacked := U, ahead := A} = S) ->
    T = byte_size(Buf) - byte_size(Rest),
    C = min(T, A),
    ack(S#{buf := Rest, unacked := U + T - C, ahead := A - C}).

%% tcp_read to the host (with "ack": true), after ?ACK_BYTES taken bytes,
%% and when the buffer is empty.
ack(#{ack := true, unacked := U, buf := Buf} = S)
  when U >= ?ACK_BYTES; U > 0, Buf =:= <<>> ->
    read_host(S);
ack(S) -> S.

%% A new recv that waits for ?ACK_BYTES or more beyond the buffer: the
%% host learns it at once, not at the next tcp_read.
hint(#{ack := true} = S) ->
    case want(S) >= ?ACK_BYTES of
        true -> read_host(S);
        false -> S
    end;
hint(S) -> S.

%% tcp_read: n, the bytes that the owner took since the last tcp_read;
%% want and got (see the start of this module).
read_host(#{id := Id, unacked := U, recv_oct := Got} = S) ->
    ?HOST:send_host(#{t => tcp_read, id => Id, n => U, want => want(S), got => Got}),
    S#{unacked := 0}.

%% The bytes that a waiting recv of a length needs beyond the buffer.
want(#{recv := {_, Len, _}, buf := Buf}) when Len > byte_size(Buf) -> Len - byte_size(Buf);
want(_) -> 0.

serve_recv(#{recv := {From, 0, TRef}} = S) ->
    case next_packet(S) of
        none -> serve_closed(S);
        {Packet, Rest} ->
            cancel(TRef),
            gen_server:reply(From, {ok, data(Packet, S)}),
            taken(Rest, S#{recv := undefined})
    end;
serve_recv(#{recv := {From, Len, TRef}, buf := Buf} = S)
  when Len > 0, byte_size(Buf) >= Len ->
    cancel(TRef),
    <<Part:Len/binary, Rest/binary>> = Buf,
    gen_server:reply(From, {ok, data(Part, S)}),
    taken(Rest, S#{recv := undefined});
serve_recv(S) -> serve_closed(S).

serve_closed(#{recv := {From, _, TRef}, closed := true} = S) ->
    cancel(TRef),
    gen_server:reply(From, {error, closed}),
    S#{recv := undefined};
serve_closed(S) -> S.

closed(#{recv := {From, _, TRef}} = S) ->
    cancel(TRef),
    gen_server:reply(From, {error, closed}),
    closed(S#{recv := undefined});
closed(#{active := A, owner := Owner} = S) when A =/= false ->
    Owner ! {tcp_closed, ?SOCKET(self())},
    {stop, normal, S};
closed(S) ->
    %% Passive: the owner gets the rest of the buffer, then {error, closed}.
    {noreply, refuse_sends(S#{closed := true})}.
