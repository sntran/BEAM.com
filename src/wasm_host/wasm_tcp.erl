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
%% host (tcp_open, tcp_data, tcp_closed, tcp_error, tcp_sent,
%% tcp_listening, tcp_accept) from the pump (wasm_host_server) and sends
%% tcp_connect, tcp_send, tcp_read, tcp_shutdown, tcp_close, tcp_listen
%% and tcp_unlisten. A tcp_closed with "half": true is the end of the data
%% of the peer only: the socket can still send.
%%
%% A program gets the results and the messages of gen_tcp with the
%% default backend (inet_drv of OTP):
%%
%% - The options of inet, with the checks of inet and prim_inet. setopts/2
%%   sets the options from the last one to the first one, as the driver
%%   does, and {active, N} adds N to the counter.
%% - All the packet types of inet, with erlang:decode_packet/3 (the parser
%%   of the driver): packet_size, and the buffer as the limit of a line.
%% - One recv at a time ({error, ealready}).
%% - The end of the peer comes after the packets that are complete. The
%%   driver reads a passive socket only for a recv, so the end waits for
%%   the next recv or for an active mode. exit_on_close, the errors after
%%   a close (closed, then enotconn) and a send after the end of the peer
%%   are those of the driver.
%% - controlling_process/2 and close/1 run in the caller, as in inet.
%%
%% docs/WORKERS.md lists the differences that stay, and why.
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
%% TCP_MAX_PACKET_SIZE of inet_drv: the largest recv and the largest
%% packet.
-define(MAX_PACKET, 16#4000000).

%% The options of inet that this module uses, and their values for a new
%% socket. The other options stay in the map other, for getopts/2.
-define(OWN, #{active => true, mode => list, packet => raw, packet_size => 0, header => 0,
               deliver => term, exit_on_close => true, show_econnreset => false,
               send_timeout => infinity, send_timeout_close => false, line_delimiter => $\n,
               buffer => 65536}).

%% The values that getopts gives for the other options when they were not
%% set. A socket of the host has no socket of the OS: these are the values
%% of a socket of Linux, with buffers of 64 KiB.
-define(DEFAULTS, #{delay_send => false, recbuf => 65536, sndbuf => 65536, nodelay => false,
                    keepalive => false, reuseaddr => false, linger => {false, 0},
                    high_watermark => 8192, low_watermark => 4096, high_msgq_watermark => 8192,
                    low_msgq_watermark => 4096, tos => 0, priority => 0, debug => false,
                    non_block_send => false, read_ahead => true, keepcnt => 9, keepidle => 7200,
                    keepintvl => 75, user_timeout => 0, reuseport => false, reuseport_lb => false,
                    exclusiveaddruse => false, bind_to_device => <<>>, recvtos => false,
                    recvttl => false, pktoptions => [], ttl => 64, dontroute => false,
                    broadcast => false, nopush => false}).

%% The options that getopts takes for a TCP socket with no value in the
%% result, as the driver gives them.
-define(NO_VALUE, [read_packets, ipv6_v6only, netns, recvtclass]).

%% The counters of getstat/2.
-define(STATS, [recv_cnt, recv_max, recv_avg, recv_dvi, recv_oct,
                send_cnt, send_max, send_avg, send_pend, send_oct]).

%% The host resolves the names.
getaddrs(Address, _Timer) -> {ok, [Address]}.
getserv(Port) when is_integer(Port) -> {ok, Port};
getserv(_) -> {error, einval}.

%% A wrong option gives {error, einval}: gen_tcp:connect then exits with
%% badarg, as with inet_tcp.
connect(Address, Port, Opts, Timeout) ->
    case options(Opts, connect) of
        {ok, O} ->
            {ok, Pid} = gen_server:start(?MODULE, {self(), O}, []),
            case gen_server:call(Pid, {connect, host(Address), Port, Timeout}, infinity) of
                ok -> {ok, ?SOCKET(Pid)};
                Error -> Error
            end;
        error ->
            {error, einval}
    end.

%% As inet_tcp: a {port, P} option wins over the argument (Ranch listens
%% with 0 and the option), and a wrong option exits with badarg.
listen(Port0, Opts) ->
    case options(Opts, listen) of
        {ok, O} ->
            Port = proplists:get_value(port, O, Port0),
            {ok, Pid} = gen_server:start(?MODULE, {listen, self(), Port, O}, []),
            case gen_server:call(Pid, listen, infinity) of
                ok -> {ok, ?SOCKET(Pid)};
                Error -> Error
            end;
        error ->
            exit(badarg)
    end.

accept(Socket) -> accept(Socket, infinity).

%% The id of the socket in the host, and the host and the port of its peer
%% as the host gave them (a name stays a name). wasm_host_fetch gives the
%% id with each request of the connection, and opens a tunnel to the peer.
host_info(?SOCKET(Pid)) -> call(Pid, host_info, closed).

%% The data of each socket goes to the other one in the host (as a proxy),
%% no longer through Erlang: for example a connection that a listener
%% accepted, and one to the server behind it. The data in the buffers goes
%% first. The sockets end together.
splice(?SOCKET(A), ?SOCKET(B)) ->
    {ok, IdA} = call(A, id, closed),
    {ok, IdB} = call(B, id, closed),
    ok = call(A, {splice, IdB}, closed),
    ok = call(B, {splice, IdA}, closed),
    ?HOST:send_host(#{t => tcp_splice, a => IdA, b => IdB}).

accept(?SOCKET(Pid), Timeout) -> call(Pid, {accept, self(), Timeout}, closed).

send(?SOCKET(Pid), Data) -> call(Pid, {send, Data}, closed).

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
recv(?SOCKET(Pid), Length, Timeout) when is_integer(Length), Length >= 0 ->
    call(Pid, {recv, Length, Timeout}, closed).
unrecv(?SOCKET(Pid), Data) -> call(Pid, {unrecv, Data}, closed).

%% As inet:tcp_close/1: the caller also takes a {tcp_closed, Socket} from
%% its mailbox.
close(?SOCKET(Pid) = Socket) ->
    _ = call(Pid, close, ok),
    receive {tcp_closed, Socket} -> ok after 0 -> ok end.

shutdown(?SOCKET(Pid), How) when How =:= read; How =:= write; How =:= read_write ->
    call(Pid, {shutdown, How}, closed).

setopts(?SOCKET(Pid), Opts) when is_list(Opts) -> call(Pid, {setopts, Opts}, einval).
getopts(?SOCKET(Pid), Opts) when is_list(Opts) -> call(Pid, {getopts, Opts}, einval).
peername(?SOCKET(Pid)) -> call(Pid, peername, einval).
sockname(?SOCKET(Pid)) -> call(Pid, sockname, einval).
getstat(?SOCKET(Pid), Opts) when is_list(Opts) -> call(Pid, {getstat, Opts}, einval).

%% As inet:tcp_controlling_process/2, in the caller: the socket goes
%% passive, the messages of the socket in the mailbox of the caller go to
%% the new owner, the owner changes, and the active mode comes back.
controlling_process(?SOCKET(Pid) = Socket, New) when is_pid(New) ->
    Self = self(),
    case call(Pid, owner, closed) of
        {ok, New} -> ok;
        {ok, Owner} when Owner =/= Self -> {error, not_owner};
        {ok, _} ->
            case getopts(Socket, [active]) of
                {ok, [{active, A}]} ->
                    Off = case A of
                        false -> ok;
                        _ -> setopts(Socket, [{active, false}])
                    end,
                    case {sync_input(Socket, New, false), Off} of
                        {true, _} -> ok;
                        {false, ok} ->
                            case call(Pid, {controlling_process, Self, New}, closed) of
                                ok when A =/= false -> setopts(Socket, [{active, A}]);
                                Result -> Result
                            end;
                        {false, Error} -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

%% The messages that inet:tcp_controlling_process/2 gives to the new
%% owner. True when the socket closed.
sync_input(Socket, Owner, Closed) ->
    receive
        {tcp, Socket, Data} -> Owner ! {tcp, Socket, Data}, sync_input(Socket, Owner, Closed);
        {tcp_closed, Socket} -> Owner ! {tcp_closed, Socket}, sync_input(Socket, Owner, true);
        {Socket, {data, Data}} -> Owner ! {Socket, {data, Data}}, sync_input(Socket, Owner, Closed)
    after 0 -> Closed
    end.

%% A call to the process of a socket. Dead: the result when the process
%% stopped (the socket closed), as inet gives it for a closed port.
call(Pid, Request, Dead) ->
    try gen_server:call(Pid, Request, infinity)
    catch exit:{noproc, _} -> dead(Dead);
          exit:{normal, _} -> dead(Dead)
    end.

dead(ok) -> ok;
dead(Reason) -> {error, Reason}.

host(A) when is_tuple(A) -> list_to_binary(inet:ntoa(A));
host(A) when is_atom(A) -> atom_to_binary(A);
host(A) when is_list(A) -> list_to_binary(A);
host(A) when is_binary(A) -> A.

%% --- the options -------------------------------------------------------------

%% The options of connect/4 and listen/2, as inet:connect_options/2 and
%% inet:listen_options/2 check them: {ok, [{Name, Value}]} or error. The
%% options of the address (ip, ifaddr, fd, ...) have no use with no socket
%% of the OS: only port stays, for listen/2. {wasm_direct, true} (connect),
%% {wasm_fetch, true} and {wasm_fetch_tls, true} (listen) are the options
%% of wasm_host_fetch.
options(Opts, Kind) when is_list(Opts) -> options(Opts, Kind, []);
options(_, _) -> error.

options([], _Kind, Acc) -> {ok, lists:reverse(Acc)};
options([Opt | Opts], Kind, Acc) ->
    case option(Opt, Kind) of
        {ok, KV} -> options(Opts, Kind, [KV | Acc]);
        skip -> options(Opts, Kind, Acc);
        error -> error
    end;
options(_, _, _) -> error.

option(binary, _) -> {ok, {mode, binary}};
option(list, _) -> {ok, {mode, list}};
option({active, N}, _) when is_integer(N), N >= -32768, N =< 32767 -> {ok, {active, N}};
option({port, P}, listen) -> {ok, {port, P}};
option({K, _}, _) when K =:= ip; K =:= ifaddr; K =:= port; K =:= fd; K =:= netns -> skip;
option({protocol, P}, _) when P =:= tcp; P =:= mptcp -> skip;
option({backlog, _}, listen) -> skip;
option({raw, P, O, B}, Kind) -> option({raw, {P, O, B}}, Kind);
option({line_delimiter, C}, connect) when is_integer(C), C >= 0, C =< 255 ->
    {ok, {line_delimiter, C}};
option({wasm_direct, B}, connect) when is_boolean(B) -> {ok, {wasm_direct, B}};
option({K, B}, listen) when (K =:= wasm_fetch orelse K =:= wasm_fetch_tls), is_boolean(B) ->
    {ok, {K, B}};
option({Name, Value}, Kind) when is_atom(Name) ->
    case lists:member(Name, names(Kind)) andalso sockopt(Name, Value) of
        true -> {ok, {Name, Value}};
        false -> error
    end;
option(_, _) -> error.

%% connect_options() and listen_options() of inet.
names(connect) ->
    [debug, tos, tclass, priority, reuseaddr, reuseport, reuseport_lb, exclusiveaddruse, keepalive,
     linger, nodelay, sndbuf, recbuf, recvtos, recvtclass, ttl, recvttl, header, active, packet,
     packet_size, buffer, mode, deliver, line_delimiter, exit_on_close, high_watermark,
     low_watermark, high_msgq_watermark, low_msgq_watermark, send_timeout, send_timeout_close,
     delay_send, raw, show_econnreset, bind_to_device, read_ahead, keepcnt, keepidle, keepintvl,
     user_timeout];
names(listen) ->
    [debug, tos, tclass, priority, reuseaddr, reuseport, reuseport_lb, exclusiveaddruse, keepalive,
     linger, sndbuf, recbuf, nodelay, recvtos, recvtclass, ttl, recvttl, header, active, packet,
     buffer, mode, deliver, backlog, ipv6_v6only, exit_on_close, high_watermark, low_watermark,
     high_msgq_watermark, low_msgq_watermark, send_timeout, send_timeout_close, delay_send,
     packet_size, raw, show_econnreset, bind_to_device, read_ahead, keepcnt, keepidle, keepintvl,
     user_timeout].

%% The check of prim_inet for a value of an option (its type).
sockopt(Name, Value) ->
    try prim_inet:is_sockopt_val(Name, Value)
    catch _:_ -> false
    end.

%% An option of setopts/2, as the encoding of prim_inet checks it.
set_ok(binary) -> true;
set_ok(list) -> true;
set_ok({active, N}) when is_integer(N) -> N >= -32768 andalso N =< 32767;
set_ok({raw, P, O, B}) -> sockopt(raw, {P, O, B});
set_ok({Name, Value}) when is_atom(Name) -> sockopt(Name, Value);
set_ok(_) -> false.

%% setopts/2: the check of all the options first (none changes when one
%% is wrong), then the options from the last one to the first one, as
%% prim_inet and the driver set them. An {active, N} out of the range
%% stops there, with the options before it set.
set_opts(Opts, S) ->
    case lists:all(fun set_ok/1, Opts) of
        true -> set_all(lists:reverse(Opts), S);
        false -> {{error, einval}, S}
    end.

set_all([], S) -> {ok, S};
set_all(_, #{stop := true} = S) -> {ok, S};
set_all([Opt | Opts], S) ->
    case set_opt(Opt, S) of
        {ok, S1} -> set_all(Opts, S1);
        error -> {{error, einval}, S}
    end.

%% The options of connect/4, listen/2 and accept/2: the last value wins,
%% and {active, N} sets the counter.
put_opts(Opts, S) -> lists:foldl(fun put_opt/2, S, Opts).

put_opt({active, N}, S) when is_integer(N) ->
    {ok, S1} = count(N, S#{active := true}),
    S1;
put_opt(Opt, S) ->
    {ok, S1} = set_opt(Opt, S),
    S1.

%% One option, as inet_set_opts of the driver sets it: {ok, S} or error.
%% {active, N} adds N to the counter, in the range of an int16; at 0 or
%% less the socket goes passive, with {tcp_passive, S}. An active mode on
%% a closed socket gives {tcp_closed, S}.
set_opt(binary, S) -> {ok, S#{mode := binary}};
set_opt(list, S) -> {ok, S#{mode := list}};
set_opt({active, N}, S) when is_integer(N) ->
    case count(N, S) of
        {ok, S1} -> {ok, closed_active(S1)};
        error -> error
    end;
set_opt({active, A}, S) -> {ok, closed_active(S#{active := A})};
set_opt({packet, P}, S) -> {ok, S#{packet := packet_type(P)}};
set_opt({buffer, B}, S) -> {ok, S#{buffer := max(B, 1)}};
set_opt({raw, _}, S) -> {ok, S};
set_opt({raw, _, _, _}, S) -> {ok, S};
set_opt({K, V}, S) when is_map_key(K, ?OWN) -> {ok, S#{K := V}};
set_opt({K, V}, #{other := O} = S) -> {ok, S#{other := O#{K => V}}}.

count(N, #{active := A} = S) ->
    C = case A of
        A when is_integer(A) -> A + N;
        _ -> N
    end,
    if
        C > 32767; C < -32768 -> error;
        C =< 0 -> {ok, passive_msg(S#{active := false})};
        true -> {ok, S#{active := C}}
    end.

passive_msg(#{owner := Owner} = S) ->
    Owner ! {tcp_passive, ?SOCKET(self())},
    S.

%% The driver has one value for raw and 0, and one for ssl and ssl_tls.
packet_type(0) -> raw;
packet_type(ssl) -> ssl_tls;
packet_type(P) -> P.

%% A closed socket that becomes active gives {tcp_closed, S} (one time).
%% With exit_on_close the process then stops, as the port of the driver.
closed_active(#{kind := socket, st := closed, active := A} = S) when A =/= false ->
    S1 = case S of
        #{drecv := econnreset, owner := Owner} ->
            Owner ! {tcp_error, ?SOCKET(self()), econnreset},
            S#{drecv := false};
        _ -> S
    end,
    read_stop(closed_msg(S1));
closed_active(S) -> S.

get_opts(Opts, S) ->
    case lists:all(fun(O) -> is_atom(O) andalso (known(O) orelse lists:member(O, ?NO_VALUE)) end,
                   Opts) of
        true -> {ok, [{O, opt_value(O, S)} || O <- Opts, known(O)]};
        false -> {error, einval}
    end.

%% The driver gives no line_delimiter: getopts refuses it.
known(line_delimiter) -> false;
known(O) -> is_map_key(O, ?OWN) orelse is_map_key(O, ?DEFAULTS).

opt_value(packet, #{packet := raw}) -> 0;
opt_value(packet, #{packet := ssl_tls}) -> ssl;
opt_value(O, S) when is_map_key(O, ?OWN) -> maps:get(O, S);
opt_value(O, #{other := Other}) -> maps:get(O, Other, maps:get(O, ?DEFAULTS)).

%% The options of a listener, for its connections.
own(S) -> maps:with([other | maps:keys(?OWN)], S).

%% --- the process of a socket ----------------------------------------------

init({listen, Owner, Port, Opts}) ->
    Id = new_id(<<"l">>),
    ?HOST:register(Id),
    S = maps:merge(?OWN, #{kind => listen, id => Id, owner => Owner, ref => monitor(process, Owner),
                           port => Port, other => #{}, listen => undefined, stop => false,
                           conns => queue:new(), acceptors => queue:new()}),
    {ok, put_opts(Opts, S)};
init({Owner, Opts}) ->
    Id = new_id(<<"t">>),
    ?HOST:register(Id),
    {ok, put_opts(Opts, socket(Id, Owner))};
%% A connection of the listener Listener: open, and passive until accept/2
%% gives it to its owner. Until then the listener is its owner, so the
%% connection closes when the listener stops. Opts: the options of the
%% listener (a map), or a list of options of connect/4.
init({accepted, Id, Peer, Opts, Flags, Listener}) ->
    %% The pump gives this process the events that came before it, first.
    ?HOST:claim(Id),
    S0 = socket(Id, Listener),
    S = case Opts of
        _ when is_map(Opts) -> maps:merge(S0, Opts);
        _ -> {ok, L} = options(Opts, connect), put_opts(L, S0)
    end,
    {ok, maps:merge(S#{peer := Peer, active := false}, Flags)}.

new_id(Prefix) ->
    <<Prefix/binary, (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

%% The state of a socket, as the descriptor of the driver keeps it:
%% - st: open, or closed (tcp_desc_close: the socket of the host closed,
%%   and the process stays for getopts and for the errors that come later);
%% - eof: false, closed, or {error, Reason}: the end of the peer, after
%%   the bytes of buf;
%% - hgone: the host closed its socket, so a send goes nowhere;
%% - rst: a reset came (tcp_error), or the first send after the end of the
%%   host went: the next send fails, as a send after a reset of the peer;
%% - wdone and wpend: a shutdown of write, and one that waits for the
%%   sends that wait; rshut: a shutdown of read;
%% - pfin: the peer ended its data. After pfin and wdone, or after a reset
%%   (hgone and rst), the connection of the OS is closed: shutdown/2 and
%%   peername/1 give enotconn;
%% - rlen: the length of a recv that did not end (i_remain of the driver):
%%   the next read waits for these bytes, and gives them with no parse of
%%   the packet type (only its header goes, for 1, 2 and 4);
%% - unread: the bytes of buf that came while the driver did not read (they
%%   wait in the socket of the OS until the next read);
%% - dsend and drecv: the error of the next send or recv after a close
%%   (TCP_ADDF_DELAYED_CLOSE_SEND and _RECV of the driver);
%% - rpause: no read until an active mode or a recv (desc_close_read);
%% - hstate: 0 before the first line of an HTTP message, 1 in its header;
%% - stop: the process stops after this event (driver_exit).
socket(Id, Owner) ->
    maps:merge(?OWN, #{kind => socket, id => Id, owner => Owner, ref => monitor(process, Owner),
      other => #{}, buf => <<>>, recv => undefined, hstate => 0, connect => undefined,
      peer => undefined, st => open, eof => false, hgone => false, rst => false, wdone => false,
      wpend => false, rshut => false, pfin => false, rlen => 0, unread => 0,
      close_sent => false, dsend => false, drecv => false, rpause => false,
      stop => false, recv_cnt => 0, recv_oct => 0, recv_max => 0, send_cnt => 0, send_oct => 0,
      send_max => 0, ack => false, unacked => 0, ahead => 0, sack => false, inflight => 0,
      sends => queue:new()}).

%% The flow control of the host for a socket (tcp_accept, tcp_open).
flags(Meta) ->
    #{ack => maps:get(<<"ack">>, Meta, false) =:= true,
      sack => maps:get(<<"sent">>, Meta, false) =:= true}.

handle_call(Request, From, S) -> result(call_(Request, From, S)).
handle_info(Info, S) -> result(info(Info, S)).
handle_cast(_, S) -> {noreply, S}.

%% A socket whose port of the driver would exit (stop): the process stops.
result({reply, R, #{stop := true} = S}) -> {stop, normal, R, S};
result({noreply, #{stop := true} = S}) -> {stop, normal, S};
result(Result) -> Result.

terminate(_, #{id := Id}) ->
    ?HOST:unregister(Id).

%% --- the calls of a listener and of a socket -----------------------------------
call_(owner, _From, #{owner := Owner} = S) ->
    {reply, {ok, Owner}, S};
call_({controlling_process, Caller, New}, _From, #{owner := Caller, ref := Ref} = S) ->
    case node(New) =:= node() andalso is_process_alive(New) of
        true ->
            demonitor(Ref, [flush]),
            {reply, ok, S#{owner := New, ref := monitor(process, New)}};
        false ->
            {reply, {error, badarg}, S}
    end;
call_({controlling_process, _, _}, _From, S) ->
    {reply, {error, not_owner}, S};
call_({getopts, Opts}, _From, S) ->
    {reply, get_opts(Opts, S), S};
call_({getstat, Opts}, _From, S) ->
    case lists:all(fun(K) -> lists:member(K, ?STATS) end, Opts) of
        true -> {reply, {ok, [{K, stat(K, S)} || K <- Opts]}, S};
        false -> {reply, {error, einval}, S}
    end;
%% --- a listener ----------------------------------------------------------------
%% {wasm_fetch, true}: the listener of wasm_host_fetch, which the host
%% keeps apart from the listeners of the program. {wasm_fetch_tls, true}:
%% the trust store of the VM holds the CA of that server.
call_(listen, From, #{kind := listen, id := Id, port := Port, other := O} = S) ->
    Fetch = [{fetch, true} || maps:get(wasm_fetch, O, false)]
        ++ [{tls, true} || maps:get(wasm_fetch_tls, O, false)],
    ?HOST:send_host(maps:from_list([{t, tcp_listen}, {id, Id}, {port, Port} | Fetch])),
    {noreply, S#{listen := From}};
call_({accept, Pid, Timeout}, From, #{kind := listen, conns := Conns, acceptors := As} = S) ->
    case queue:out(Conns) of
        {{value, Conn}, Rest} ->
            {noreply, hand(Conn, {From, Pid, undefined, undefined}, S#{conns := Rest})};
        {empty, _} when Timeout =:= 0 ->
            {reply, {error, timeout}, S};
        {empty, _} ->
            TRef = case Timeout of
                infinity -> undefined;
                _ -> erlang:start_timer(Timeout, self(), accept)
            end,
            %% As in the driver: an acceptor that stops waits no more.
            Mon = monitor(process, Pid),
            {noreply, S#{acceptors := queue:in({From, Pid, TRef, Mon}, As)}}
    end;
call_(sockname, _From, #{kind := listen, port := Port} = S) ->
    {reply, {ok, {{0, 0, 0, 0}, Port}}, S};
call_(close, _From, #{kind := listen} = S) ->
    {stop, normal, ok, end_listener(S)};
call_({setopts, Opts}, _From, #{kind := listen} = S) ->
    {Result, S1} = set_opts(Opts, S),
    {reply, Result, S1};
call_(_, _From, #{kind := listen} = S) ->
    {reply, {error, enotconn}, S};
%% --- a socket ----------------------------------------------------------------
%% accept/2 gives a connection to its owner, with the active mode of the
%% listener (accept_opts of prim_inet).
call_({accepted, Owner, Active}, _From, #{ref := Ref} = S) ->
    demonitor(Ref, [flush]),
    S1 = put_opt({active, Active}, S#{owner := Owner, ref := monitor(process, Owner)}),
    {reply, ok, wanted(input(S1))};
call_(id, _From, #{id := Id} = S) ->
    {reply, {ok, Id}, S};
call_(host_info, _From, #{id := Id, peer := {Host, Port}} = S) ->
    {reply, {ok, #{id => Id, host => Host, port => Port}}, S};
call_({splice, Peer}, _From, #{buf := Buf} = S) ->
    Buf =/= <<>> andalso ?HOST:send_host(#{t => tcp_send, id => Peer}, Buf),
    {reply, ok, taken(<<>>, S#{spliced => Peer, active := false})};
%% {wasm_direct, true}: connect() of the host, never the fetch path (the
%% tunnel of wasm_host_fetch).
call_({connect, Host, Port, Timeout}, From, #{id := Id, other := O} = S) ->
    Direct = [{direct, true} || maps:get(wasm_direct, O, false) =:= true],
    ?HOST:send_host(maps:from_list([{t, tcp_connect}, {id, Id}, {host, Host}, {port, Port} | Direct])),
    TRef = case Timeout of
        infinity -> undefined;
        _ -> erlang:start_timer(Timeout, self(), connect)
    end,
    {noreply, S#{connect := {From, TRef}, peer := {Host, Port}}};
call_(sockname, _From, #{st := closed} = S) ->
    {reply, {error, ebadf}, S};
call_(sockname, _From, S) ->
    {reply, {ok, {{0, 0, 0, 0}, 0}}, S};
call_(peername, _From, #{st := closed} = S) ->
    {reply, {error, enotconn}, S};
call_(peername, _From, #{pfin := true, wdone := true, wpend := false} = S) ->
    {reply, {error, enotconn}, S};
call_(peername, _From, #{hgone := true, rst := true} = S) ->
    {reply, {error, enotconn}, S};
call_(peername, _From, #{peer := undefined} = S) ->
    {reply, {error, enotconn}, S};
call_(peername, _From, #{peer := {Host, Port}} = S) ->
    Addr = case inet:parse_address(binary_to_list(Host)) of
        {ok, IP} -> IP;
        _ -> {0, 0, 0, 0}
    end,
    {reply, {ok, {Addr, Port}}, S};
%% After setopts, as inet_set_opts of the driver: a new active mode reads
%% again (the driver selects the socket for reads), and a new packet type
%% of an active socket forgets the length of a packet (i_remain).
call_({setopts, Opts}, _From, #{active := A0, packet := P0} = S) ->
    {Result, S1} = set_opts(Opts, S),
    S2 = case S1 of
        #{active := false} -> S1;
        #{active := A1, packet := P1} ->
            S1a = case mode(A1) =:= mode(A0) of
                true -> S1;
                false -> S1#{rpause := false}
            end,
            case A0 =/= false andalso P1 =/= P0 of
                true -> S1a#{rlen := 0};
                false -> S1a
            end
    end,
    {reply, Result, wanted(input(S2))};
call_({send, Data}, From, S) ->
    send(Data, From, S);
call_({recv, Length, Timeout}, From, S) ->
    recv(Length, Timeout, From, S);
call_({unrecv, _}, _From, #{st := closed} = S) ->
    {reply, {error, enotconn}, S};
%% The bytes of unrecv were taken (or never came from the host): they do
%% not count again in tcp_read (ahead). They go to the buffer of the
%% driver, which then waits for no length (tcp_push_buffer).
call_({unrecv, Data}, _From, #{buf := Buf, ahead := A} = S) ->
    Bin = iolist_to_binary(Data),
    S1 = S#{buf := <<Bin/binary, Buf/binary>>, ahead := A + byte_size(Bin), rlen := 0},
    case S1 of
        #{active := false} -> {reply, ok, S1};
        _ -> {reply, ok, wanted(deliver_held(S1))}
    end;
call_({shutdown, _}, _From, #{st := closed} = S) ->
    {reply, {error, enotconn}, S};
%% The two ends of the connection came: the OS has no connection.
call_({shutdown, _}, _From, #{pfin := true, wdone := true, wpend := false} = S) ->
    {reply, {error, enotconn}, S};
call_({shutdown, _}, _From, #{hgone := true, rst := true} = S) ->
    {reply, {error, enotconn}, S};
call_({shutdown, How}, _From, S) ->
    S1 = case How of
        read -> S;
        _ -> shut_write(S)
    end,
    %% As on Linux: after a shutdown of read, a read gives the end, after
    %% the data that came.
    S2 = case How of
        write -> S1;
        _ -> peer_end(closed, S1#{rshut := true})
    end,
    {reply, ok, wanted(input(S2))};
%% As prim_inet:close/1: the sends that wait go first.
call_(close, _From, #{sends := Q} = S) ->
    S1 = lists:foldl(fun({From, Data, TRef}, Acc) ->
                             cancel(TRef),
                             reply(From, ok),
                             send_data(Data, Acc)
                     end, S#{sends := queue:new()}, queue:to_list(Q)),
    {stop, normal, ok, refuse_recv(close_host(S1))}.

%% The active mode of the driver: passive, active, once or multi.
mode(N) when is_integer(N) -> multi;
mode(A) -> A.

stat(recv_avg, #{recv_cnt := C, recv_oct := O}) when C > 0 -> O div C;
stat(send_avg, #{send_cnt := C, send_oct := O}) when C > 0 -> O div C;
stat(send_pend, _) -> 0;
stat(K, S) -> maps:get(K, S, 0).

%% --- the events of a listener ---------------------------------------------------
info({wasm_host, <<"tcp_listening">>, _, _}, #{kind := listen, listen := From} = S) ->
    gen_server:reply(From, ok),
    {noreply, S#{listen := undefined}};
info({wasm_host, <<"tcp_error">>, Meta, _}, #{kind := listen, listen := From} = S)
  when From =/= undefined ->
    gen_server:reply(From, {error, reason(Meta)}),
    {stop, normal, S};
info({wasm_host, <<"tcp_accept">>, Meta, _}, #{kind := listen} = S) ->
    #{<<"conn">> := Id} = Meta,
    Peer = {maps:get(<<"host">>, Meta, <<"0.0.0.0">>), maps:get(<<"port">>, Meta, 0)},
    {ok, Pid} = gen_server:start(?MODULE, {accepted, Id, Peer, own(S), flags(Meta), self()}, []),
    case queue:out(maps:get(acceptors, S)) of
        {{value, A}, Rest} -> {noreply, hand({Id, Pid}, A, S#{acceptors := Rest})};
        {empty, _} -> {noreply, S#{conns := queue:in({Id, Pid}, maps:get(conns, S))}}
    end;
info({timeout, TRef, accept}, #{kind := listen, acceptors := As} = S) ->
    case lists:keytake(TRef, 3, queue:to_list(As)) of
        {value, {From, _, _, Mon}, Rest} ->
            demonitor(Mon, [flush]),
            gen_server:reply(From, {error, timeout}),
            {noreply, S#{acceptors := queue:from_list(Rest)}};
        false -> {noreply, S}
    end;
%% The owner stopped: the listener closes, as a port with its owner.
info({'DOWN', Ref, process, _, _}, #{kind := listen, ref := Ref} = S) ->
    {stop, normal, end_listener(S)};
info({'DOWN', Mon, process, _, _}, #{kind := listen, acceptors := As} = S) ->
    case lists:keytake(Mon, 4, queue:to_list(As)) of
        {value, {_, _, TRef, _}, Rest} ->
            cancel(TRef),
            {noreply, S#{acceptors := queue:from_list(Rest)}};
        false -> {noreply, S}
    end;
info(_, #{kind := listen} = S) ->
    {noreply, S};
%% --- the events of a socket ----------------------------------------------------
info({wasm_host, <<"tcp_open">>, Meta, _}, #{connect := {From, TRef}} = S) ->
    cancel(TRef),
    gen_server:reply(From, ok),
    {noreply, maps:merge(S#{connect := undefined}, flags(Meta))};
info({wasm_host, <<"tcp_error">>, Meta, _}, #{connect := {From, TRef}} = S) ->
    cancel(TRef),
    gen_server:reply(From, {error, reason(Meta)}),
    {stop, normal, S};
info({timeout, TRef, connect}, #{connect := {From, TRef}} = S) ->
    gen_server:reply(From, {error, timeout}),
    {stop, normal, close_host(S)};
%% The host gave N bytes of tcp_send to the peer: the sends that wait go.
info({wasm_host, <<"tcp_sent">>, #{<<"n">> := N}, _}, #{inflight := F} = S) ->
    {noreply, drain(S#{inflight := max(F - N, 0)})};
%% Data that came before the host joined the sockets: to the peer.
info({wasm_host, <<"tcp_data">>, _, Data}, #{spliced := Peer, unacked := U} = S) ->
    ?HOST:send_host(#{t => tcp_send, id => Peer}, Data),
    {noreply, ack(S#{unacked := U + byte_size(Data)})};
info({wasm_host, <<"tcp_closed">>, _, _}, #{spliced := _} = S) ->
    {stop, normal, S};
%% A closed socket takes no more events of the host.
info({wasm_host, _, _, _}, #{st := closed} = S) ->
    {noreply, S};
%% Data after a shutdown of read and of write: as Linux, the socket resets
%% the connection, and the data goes. The bytes that came before stay,
%% and then the end (a reset).
info({wasm_host, <<"tcp_data">>, _, _}, #{rshut := true, wdone := true, hgone := false,
                                         id := Id, show_econnreset := Show} = S) ->
    ?HOST:send_host(#{t => tcp_close, id => Id}),
    End = case Show of
        true -> {error, econnreset};
        false -> closed
    end,
    S1 = (gone(S))#{rst := true, pfin := true, eof := End},
    {noreply, wanted(input(S1))};
info({wasm_host, <<"tcp_data">>, _, Data}, #{recv_cnt := C, recv_oct := O, recv_max := M} = S) ->
    {noreply, append(Data, S#{recv_cnt := C + 1, recv_oct := O + byte_size(Data),
                              recv_max := max(M, byte_size(Data))})};
%% The end of the peer: it waits behind the data of the buffer. With
%% "half", the socket of the host stays, and a send still goes.
info({wasm_host, <<"tcp_closed">>, Meta, _}, S) ->
    S1 = case maps:get(<<"half">>, Meta, false) of
        true -> S;
        _ -> gone(S)
    end,
    {noreply, wanted(input(peer_end(closed, S1#{pfin := true})))};
%% An error of the socket of the host. A reset is an end, as in the
%% driver: only show_econnreset shows it. The next send fails.
info({wasm_host, <<"tcp_error">>, Meta, _}, #{show_econnreset := Show} = S) ->
    End = case reason(Meta) of
        econnreset when not Show -> closed;
        R -> {error, R}
    end,
    {noreply, wanted(input(peer_end(End, (gone(S))#{rst := true, pfin := true})))};
%% The time of a recv ends: the driver forgets the length that it waited
%% for (a recv with a timeout of 0 does not).
info({timeout, TRef, recv}, #{recv := {From, _, TRef}} = S) ->
    gen_server:reply(From, {error, timeout}),
    {noreply, S#{recv := undefined, rlen := 0}};
info({timeout, TRef, send}, #{sends := Q} = S) ->
    Sends = queue:to_list(Q),
    case lists:keyfind(TRef, 3, Sends) of
        {From, Data, _} ->
            reply(From, {error, timeout}),
            %% The data stays in the queue, as in the driver.
            Sends1 = lists:keyreplace(TRef, 3, Sends, {undefined, Data, undefined}),
            {noreply, send_timeout_close(S#{sends := queue:from_list(Sends1)})};
        false -> {noreply, S}
    end;
info({'DOWN', Ref, process, _, _}, #{ref := Ref} = S) ->
    {stop, normal, close_host(S)};
info(_, S) ->
    {noreply, S}.

reason(Meta) -> binary_to_atom(maps:get(<<"reason">>, Meta, <<"econnrefused">>)).

%% The end of the peer (the first one counts).
peer_end(End, #{eof := false} = S) -> S#{eof := End};
peer_end(_, S) -> S.

%% The host closed its socket: the sends that wait get {error, closed},
%% and the next send fails.
gone(#{sends := Q} = S) ->
    case queue:is_empty(Q) of
        true -> S#{hgone := true};
        false -> (refuse_sends(S))#{hgone := true, rst := true}
    end.

reply(undefined, _) -> ok;
reply(From, Reply) -> gen_server:reply(From, Reply).

%% --- a listener ----------------------------------------------------------------

%% Gives the connection {Id, Pid} to the acceptor {From, Owner, TRef, Mon},
%% with the active mode of the listener. A connection that stopped still
%% goes, as a closed socket.
hand({_Id, Pid}, {From, Owner, TRef, Mon}, #{active := A} = S) ->
    cancel(TRef),
    Mon =/= undefined andalso demonitor(Mon, [flush]),
    _ = call(Pid, {accepted, Owner, A}, closed),
    gen_server:reply(From, {ok, ?SOCKET(Pid)}),
    S.

%% The end of a listener: the host stops it, and each acceptor gets
%% {error, closed}. The connections that no accept took close, because
%% the listener is their owner.
end_listener(#{id := Id, acceptors := As} = S) ->
    ?HOST:send_host(#{t => tcp_unlisten, id => Id}),
    [gen_server:reply(From, {error, closed}) || {From, _, _, _} <- queue:to_list(As)],
    S#{acceptors := queue:new()}.

%% --- the send side -----------------------------------------------------------

%% A send, as tcp_inet_commandv and tcp_sendv of the driver.
send(_Data, _From, #{st := closed, dsend := D} = S) ->
    case D of
        false -> {reply, {error, enotconn}, S};
        _ -> {reply, {error, D}, S#{dsend := false}}
    end;
send(_Data, _From, #{wdone := true} = S) ->
    send_error(epipe, S);
%% The first send after the end of the host goes nowhere, as a send to a
%% peer that closed: the next one fails, as after a reset.
send(Data, _From, #{hgone := true, rst := false, send_cnt := C, send_oct := O} = S) ->
    {reply, ok, S#{rst := true, send_cnt := C + 1, send_oct := O + iolist_size(Data)}};
send(_Data, _From, #{hgone := true} = S) ->
    send_error(econnreset, S);
%% The host holds ?SEND_WINDOW bytes or more of this socket: the send waits
%% for tcp_sent (drain/1), send_timeout at most.
send(Data, From, #{sack := true, inflight := F, sends := Q, send_timeout := T} = S)
  when F >= ?SEND_WINDOW ->
    case T of
        0 -> {reply, {error, timeout}, S#{sends := queue:in({undefined, Data, undefined}, Q)}};
        infinity -> {noreply, S#{sends := queue:in({From, Data, undefined}, Q)}};
        _ -> {noreply, S#{sends := queue:in({From, Data, erlang:start_timer(T, self(), send)}, Q)}}
    end;
send(Data, _From, S) ->
    {reply, ok, send_data(Data, S)}.

%% A send that fails (tcp_send_or_shutdown_error of the driver): epipe
%% after a shutdown of write, econnreset after the end of the host. The
%% socket closes. A passive socket gives the error to the next recv too.
send_error(Error, #{show_econnreset := Show} = S0) ->
    Reset = Error =:= econnreset andalso Show,
    Atom = case Reset of
        true -> econnreset;
        false -> closed
    end,
    S = refuse_sends(S0),
    case S of
        #{active := false} ->
            {reply, {error, Atom}, (close_desc(S))#{drecv := Atom}};
        #{owner := Owner} ->
            Reset andalso (Owner ! {tcp_error, ?SOCKET(self()), econnreset}),
            {reply, {error, Atom}, send_stop(closed_msg(S))}
    end.

%% A send that waited send_timeout ms, with send_timeout_close: the socket
%% closes (tcp_inet_send_timeout of the driver).
send_timeout_close(#{send_timeout_close := true, active := false} = S) ->
    close_desc(S);
send_timeout_close(#{send_timeout_close := true} = S) ->
    send_stop(closed_msg(S));
send_timeout_close(S) ->
    S.

%% The data of a send to the host, with the header of the packet. As the
%% driver, the header holds the low bytes of a length that does not fit.
send_data(Data, #{id := Id, packet := P, sack := Sack, inflight := F,
                  send_cnt := C, send_oct := O, send_max := M} = S) ->
    Size = iolist_size(Data),
    Header = header(P, Size),
    ?HOST:send_host(#{t => tcp_send, id => Id}, [Header, Data]),
    Held = case Sack of
        true -> F + byte_size(Header) + Size;
        false -> F
    end,
    S#{send_cnt := C + 1, send_oct := O + Size, send_max := max(M, Size), inflight := Held}.

%% The sends that wait, in order, while the host holds less than
%% ?SEND_WINDOW bytes. Then a shutdown that waited for them.
drain(#{inflight := F, sends := Q} = S) when F < ?SEND_WINDOW ->
    case queue:out(Q) of
        {{value, {From, Data, TRef}}, Rest} ->
            cancel(TRef),
            reply(From, ok),
            drain(send_data(Data, S#{sends := Rest}));
        {empty, _} ->
            case S of
                #{wpend := true} -> shutdown_host(S#{wpend := false});
                _ -> S
            end
    end;
drain(S) -> S.

%% The sends that wait get {error, closed}: no tcp_sent comes now.
refuse_sends(#{sends := Q} = S) ->
    lists:foreach(fun({From, _, TRef}) -> cancel(TRef), reply(From, {error, closed}) end,
                  queue:to_list(Q)),
    S#{sends := queue:new()}.

%% shutdown(write): the host ends the data to the peer, after the sends
%% that wait.
shut_write(#{wdone := true} = S) -> S;
shut_write(#{sends := Q} = S) ->
    case queue:is_empty(Q) of
        true -> shutdown_host(S#{wdone := true});
        false -> S#{wdone := true, wpend := true}
    end.

shutdown_host(#{hgone := true} = S) -> S;
shutdown_host(#{id := Id} = S) ->
    ?HOST:send_host(#{t => tcp_shutdown, id => Id, how => write}),
    S.

header(N, Size) when N =:= 1; N =:= 2; N =:= 4 -> <<Size:(N * 8)>>;
header(_, _) -> <<>>.

cancel(undefined) -> ok;
cancel(TRef) -> erlang:cancel_timer(TRef).

%% --- the end of a socket -----------------------------------------------------

%% The host closes its socket (one time).
close_host(#{hgone := false, st := open, id := Id} = S) ->
    ?HOST:send_host(#{t => tcp_close, id => Id}),
    S#{st := closed};
close_host(S) ->
    S#{st := closed}.

%% tcp_desc_close of the driver: the socket closes, and the process stays.
close_desc(S) ->
    (refuse_recv(refuse_sends(close_host(S))))#{buf := <<>>, ahead := 0, rlen := 0}.

%% driver_exit of the driver: the process stops, as the port.
finish(S) ->
    (refuse_recv(refuse_sends(close_host(S))))#{stop := true}.

%% The end or an error of a read of an active socket: with exit_on_close
%% the process stops, else the socket reads no more (desc_close_read).
read_stop(#{exit_on_close := true} = S) -> finish(S);
read_stop(S) -> S#{rpause := true}.

%% An error of a send of an active socket: with exit_on_close the process
%% stops, else the socket closes.
send_stop(#{exit_on_close := true} = S) -> finish(S);
send_stop(S) -> close_desc(S).

refuse_recv(#{recv := {From, _, TRef}} = S) ->
    cancel(TRef),
    gen_server:reply(From, {error, closed}),
    S#{recv := undefined};
refuse_recv(S) -> S.

%% {tcp_closed, S} to the owner, one time.
closed_msg(#{close_sent := false, owner := Owner} = S) ->
    Owner ! {tcp_closed, ?SOCKET(self())},
    S#{close_sent := true};
closed_msg(S) -> S.

%% --- the receive side --------------------------------------------------------

%% A recv, with the checks of TCP_REQ_RECV in the driver, in its order.
recv(_Length, _Timeout, _From, #{st := closed, drecv := D} = S) ->
    case D of
        false -> {reply, {error, enotconn}, S};
        _ -> {reply, {error, D}, S#{drecv := false}}
    end;
recv(_Length, _Timeout, _From, #{active := A} = S) when A =/= false ->
    {reply, {error, einval}, S};
recv(Length, _Timeout, _From, #{packet := P} = S) when P =/= raw, Length =/= 0 ->
    {reply, {error, einval}, S};
recv(Length, _Timeout, _From, S) when Length > ?MAX_PACKET ->
    {reply, {error, enomem}, S};
recv(_Length, _Timeout, _From, #{recv := {_, _, _}} = S) ->
    {reply, {error, ealready}, S};
recv(Length, Timeout, From, S) ->
    TRef = case Timeout of
        infinity -> undefined;
        0 -> undefined;
        _ -> erlang:start_timer(Timeout, self(), recv)
    end,
    S0 = case Length of
        0 -> S;
        _ -> S#{rlen := Length}
    end,
    Want = case Length of
        0 -> map_get(rlen, S0);
        _ -> Length
    end,
    S1 = case S0 of
        %% With a timeout of 0 and a known length, the driver reads one
        %% time. When that read gets data and the recv still waits, the end
        %% of the peer comes only with the next read, after the timeout.
        #{eof := Eof} when Timeout =:= 0, Eof =/= false, Want > 0 ->
            case read_size(Want, S0) of
                0 -> input(S0#{recv := {From, Length, TRef}, rpause := false});
                _ -> (input(S0#{recv := {From, Length, TRef}, rpause := false, eof := false}))#{eof := Eof}
            end;
        _ ->
            input(S0#{recv := {From, Length, TRef}, rpause := false})
    end,
    %% A timeout of 0: the recv ends now.
    S2 = case S1 of
        #{recv := {From, _, _}} when Timeout =:= 0 ->
            gen_server:reply(From, {error, timeout}),
            S1#{recv := undefined};
        _ -> S1
    end,
    {noreply, hint(wanted(S2))}.

%% Data from the host: to the buffer, then to the owner (active modes) or
%% to a waiting recv. An append to a binary that is not writable allocates
%% twice the new size, so a large recv held a binary of twice its length.
%% Data to an empty buffer is the buffer, and the data that completes a
%% waiting recv makes one binary of the exact size.
append(Data, #{buf := Buf} = S) ->
    Next = if
        Buf =:= <<>> -> Data;
        true ->
            case S of
                #{recv := {_, Len, _}} when Len > 0, byte_size(Buf) + byte_size(Data) >= Len ->
                    iolist_to_binary([Buf, Data]);
                _ -> <<Buf/binary, Data/binary>>
            end
    end,
    wanted(input(S#{buf := Next, unread := map_get(unread, S) + byte_size(Data)})).

%% The read loop of the driver (tcp_recv and tcp_deliver): the packets of
%% the buffer to the owner (an active mode) or to a waiting recv, and then
%% the end of the peer. A passive socket with no recv reads nothing.
input(#{stop := true} = S) -> S;
input(#{st := closed} = S) -> S;
input(#{spliced := _} = S) -> S;
input(#{rpause := true} = S) -> S;
input(#{active := false, recv := undefined} = S) -> S;
input(#{active := A, recv := R, eof := Eof, rlen := RLen, packet := P, unread := U,
        buf := Buf} = S0) ->
    Want = case R of
        {_, Len, _} when A =:= false, Len > 0 -> Len;
        _ -> RLen
    end,
    Held = byte_size(Buf) - U,
    {S, Packet} = if
        %% A raw socket gives the bytes in the buffer of the driver (for
        %% example the bytes of unrecv) with no read of the socket of the OS.
        Want =:= 0, P =:= raw, Held > 0, U > 0 ->
            {S0, packet(Held, S0)};
        true ->
            Read = S0#{unread := U - read_size(Want, S0)},
            {Read, next_packet(Want, Read)}
    end,
    case Packet of
        {Kind, Value, Body, Rest} ->
            S1 = taken(Rest, (reply_packet(Kind, Value, Body, S))#{rlen := 0}),
            case S1 of
                #{active := false} -> S1;
                _ -> input(S1)
            end;
        %% A packet of a known length that is not complete: the driver
        %% keeps the length (i_remain).
        {more, N} when Eof =:= false, Want =:= 0, is_integer(N) -> S#{rlen := N};
        {more, _} when Eof =:= false -> S;
        {more, _} -> read_end(S);
        {error, Reason} -> read_error(Reason, S)
    end.

%% The packet of a read. A known length (a recv, or rlen) gives the packet
%% of the packet type when that packet has this length; else the bytes of
%% the length, with no parse (packet_get_body of the driver).
next_packet(0, S) -> packet(0, S);
next_packet(Want, #{buf := Buf}) when byte_size(Buf) < Want -> {more, Want};
next_packet(Want, #{packet := raw} = S) -> packet(Want, S);
next_packet(Want, #{buf := Buf, packet := P} = S) ->
    case packet(0, S) of
        {_, _, _, Rest} = Packet when byte_size(Buf) - byte_size(Rest) =:= Want -> Packet;
        _ -> body(P, packet(Want, S))
    end.

%% unrecv of an active socket: the driver gives the packets of its own
%% buffer (tcp_deliver), with no read of the socket of the OS, also when
%% it reads no more (rpause).
deliver_held(#{buf := Buf, unread := U, eof := Eof, rpause := Rp} = S) ->
    Held = byte_size(Buf) - U,
    <<Mine:Held/binary, Os/binary>> = Buf,
    case input(S#{buf := Mine, unread := 0, eof := false, rpause := false}) of
        #{stop := true} = S1 -> S1;
        #{buf := Left} = S1 -> S1#{buf := <<Left/binary, Os/binary>>, unread := U, eof := Eof, rpause := Rp}
    end.

%% The bytes that one read of the driver takes from the socket of the OS
%% (unread, the end of buf): for a length (of a recv, or rlen), at most the
%% bytes that the length still needs; else all of them.
read_size(0, #{unread := U}) -> U;
read_size(Want, #{unread := U, buf := Buf}) -> min(max(Want - (byte_size(Buf) - U), 0), U).

%% The bytes of a remain length (rlen) as the driver gives them: with no
%% parse, and with no header for the packet types 1, 2 and 4
%% (packet_get_body of the driver).
body(N, {data, Part, Raw, Rest}) when N =:= 1; N =:= 2; N =:= 4 ->
    case Part of
        <<_:N/binary, Body/binary>> -> {data, Body, Raw, Rest};
        _ -> {data, <<>>, Raw, Rest}
    end;
body(_, Packet) -> Packet.

%% The next packet of the buffer: {data, Binary, Body, Rest} or
%% {term, Packet, Body, Rest} (http, ssl_tls), {more, Length} (the length
%% of the packet, or undefined), or {error, emsgsize}.
%% Body: the bytes of the packet, for deliver port.
packet(Len, #{buf := Buf}) when Len > 0 ->
    case Buf of
        <<Part:Len/binary, Rest/binary>> -> {data, Part, Part, Rest};
        _ -> {more, Len}
    end;
packet(_, #{buf := <<>>}) -> {more, undefined};
packet(_, #{packet := raw, buf := Buf}) -> {data, Buf, Buf, <<>>};
packet(_, #{packet := P, buf := Buf, packet_size := Size, buffer := Line,
            line_delimiter := D} = S) ->
    Opts = [{packet_size, Size}, {line_length, Line} | [{line_delimiter, D band 255} || P =:= line]],
    case erlang:decode_packet(decode_type(P, S), Buf, Opts) of
        {ok, Packet, Rest} when is_binary(Packet) ->
            {data, Packet, Packet, Rest};
        {ok, Packet, Rest} ->
            {term, Packet, binary:part(Buf, 0, byte_size(Buf) - byte_size(Rest)), Rest};
        {more, N} when is_integer(N), N > ?MAX_PACKET -> {error, emsgsize};
        {more, N} -> {more, N};
        {error, _} -> {error, emsgsize}
    end.

%% The driver keeps the state of an HTTP message: its first line, then the
%% lines of its header (httph), then the first line of the next message.
decode_type(http, #{hstate := 1}) -> httph;
decode_type(http_bin, #{hstate := 1}) -> httph_bin;
decode_type(P, _) -> P.

hstate(Packet, #{packet := P} = S) when P =:= httph; P =:= httph_bin ->
    S#{hstate := case Packet of http_eoh -> 0; _ -> 1 end};
hstate({http_request, _, _, _}, S) -> S#{hstate := 1};
hstate({http_response, _, _, _}, S) -> S#{hstate := 1};
hstate(http_eoh, S) -> S#{hstate := 0};
hstate(_, S) -> S.

%% A packet to the owner or to the recv, as tcp_reply_data of the driver.
%% With deliver port, the bytes go to the owner as the data of a port,
%% also for a recv (which then waits on, with no time limit). After a
%% packet, once and the end of {active, N} make the socket passive.
reply_packet(Kind, Value, Body, S0) ->
    S = case Kind of
        term -> hstate(Value, S0);
        data -> S0
    end,
    Socket = ?SOCKET(self()),
    case S of
        #{deliver := port, owner := Owner} ->
            Owner ! {Socket, {data, binary_to_list(Body)}},
            S1 = case S of
                #{recv := {From, L, TRef}} -> cancel(TRef), S#{recv := {From, L, undefined}};
                _ -> S
            end,
            to_passive(S1);
        #{active := false, recv := {From, _, TRef}} ->
            cancel(TRef),
            gen_server:reply(From, {ok, packet_value(Kind, Value, Socket, S)}),
            S#{recv := undefined};
        #{owner := Owner} ->
            Owner ! message(Kind, Value, Socket, S),
            to_passive(S)
    end.

packet_value(data, Bin, _Socket, S) -> data(Bin, S);
packet_value(term, {ssl_tls, _, Type, Version, Data}, Socket, _S) ->
    {ssl_tls, Socket, Type, Version, Data};
packet_value(term, Packet, _Socket, _S) -> Packet.

message(data, Bin, Socket, S) -> {tcp, Socket, data(Bin, S)};
message(term, {ssl_tls, _, Type, Version, Data}, Socket, _S) ->
    {ssl_tls, Socket, Type, Version, Data};
message(term, Packet, Socket, _S) -> {http, Socket, Packet}.

%% INET_CHECK_ACTIVE_TO_PASSIVE of the driver.
to_passive(#{active := once} = S) -> S#{active := false};
to_passive(#{active := 1} = S) -> passive_msg(S#{active := false});
to_passive(#{active := N} = S) when is_integer(N) -> S#{active := N - 1};
to_passive(S) -> S.

%% The data of a packet: a list, a binary, or the first header bytes as a
%% list before a binary ([H1, ..., Hn | Binary]).
data(Bin, #{mode := list}) -> binary_to_list(Bin);
data(Bin, #{header := 0}) -> Bin;
data(Bin, #{header := H}) when byte_size(Bin) < H -> binary_to_list(Bin);
data(Bin, #{header := H}) ->
    <<Head:H/binary, Rest/binary>> = Bin,
    binary_to_list(Head) ++ Rest.

%% The end of the data of the peer, after the packets of the buffer
%% (tcp_recv_closed of the driver). The bytes of a packet that is not
%% complete go. A send that waits gets {error, closed}; else the next send
%% after a close gets it. A passive socket gives {error, closed} to its
%% recv, an active one {tcp_closed, S}. With exit_on_close, the socket
%% closes (passive) or the process stops (active).
read_end(#{eof := {error, Reason}} = S) -> read_error(Reason, S);
read_end(#{sends := Q} = S0) ->
    S = case queue:is_empty(Q) of
        true -> S0#{dsend := closed, buf := <<>>, ahead := 0, rlen := 0};
        false -> (refuse_sends(S0))#{buf := <<>>, ahead := 0, rlen := 0}
    end,
    case S of
        #{active := false, recv := {From, _, TRef}} ->
            cancel(TRef),
            gen_server:reply(From, {error, closed}),
            read_closed(S#{recv := undefined});
        _ ->
            read_stop(closed_msg(S))
    end.

%% An error of a read (tcp_recv_error of the driver): emsgsize for a
%% packet above packet_size, or an error of the host. A passive socket
%% gives it to its recv, an active one {tcp_error, S, Reason} and then
%% {tcp_closed, S}.
read_error(Reason, S0) ->
    S1 = (refuse_sends(S0))#{buf := <<>>, ahead := 0, rlen := 0},
    S = case S1 of
        #{eof := {error, _}} -> S1#{eof := closed};
        _ -> S1
    end,
    case S of
        #{active := false, recv := {From, _, TRef}} ->
            cancel(TRef),
            gen_server:reply(From, {error, Reason}),
            read_closed(S#{recv := undefined});
        #{owner := Owner} ->
            Owner ! {tcp_error, ?SOCKET(self()), Reason},
            read_stop(closed_msg(S))
    end.

%% A passive socket after the end or an error of a read: with
%% exit_on_close it closes, else it reads no more until the next recv.
read_closed(#{exit_on_close := true} = S) -> close_desc(S);
read_closed(S) -> S#{rpause := true}.

%% --- the flow control of the reads --------------------------------------------

%% The owner waits, and the buffer does not have what it waits for: the
%% bytes of the buffer that tcp_read did not count yet count now (ahead).
wanted(#{ack := true, st := open, buf := Buf, ahead := A, unacked := U} = S)
  when byte_size(Buf) > A ->
    case waits(S) of
        true -> ack(S#{ahead := byte_size(Buf), unacked := U + byte_size(Buf) - A});
        false -> S
    end;
wanted(S) -> S.

waits(#{recv := {_, _, _}}) -> true;
waits(#{active := A}) -> A =/= false.

%% The owner took the start of the buffer: Rest stays. The bytes that
%% wanted/1 counted (ahead) do not count again.
taken(Rest, #{buf := Buf, unacked := U, ahead := A} = S) ->
    T = byte_size(Buf) - byte_size(Rest),
    C = min(T, A),
    ack(S#{buf := Rest, unacked := U + T - C, ahead := A - C}).

%% tcp_read to the host (with "ack": true), after ?ACK_BYTES taken bytes,
%% and when the buffer is empty. Not after the end of the socket.
ack(#{ack := true, st := open, hgone := false, unacked := U, buf := Buf} = S)
  when U >= ?ACK_BYTES; U > 0, Buf =:= <<>> ->
    read_host(S);
ack(S) -> S.

%% A new recv that waits for ?ACK_BYTES or more beyond the buffer: the
%% host learns it at once, not at the next tcp_read.
hint(#{ack := true, st := open, hgone := false} = S) ->
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
