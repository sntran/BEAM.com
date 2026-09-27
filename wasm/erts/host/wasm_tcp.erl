%% TCP client sockets through the JavaScript host: node:net in Node.js,
%% connect() of cloudflare:sockets in Workers. After
%% inet_db:set_tcp_module(wasm_tcp), gen_tcp:connect/3,4 makes such
%% sockets, and gen_tcp and inet dispatch to this module for them
%% ({'$inet', wasm_tcp, Pid}, as for the socket backend).
%%
%% Each socket is a process. It gets the events of the host (tcp_open,
%% tcp_data, tcp_closed, tcp_error) from the pump ('Elixir.WasmHost.Server')
%% and sends tcp_connect, tcp_send and tcp_close. Only {packet, raw}.
-module(wasm_tcp).
-behaviour(gen_server).

-export([getaddrs/2, getserv/1, connect/4, send/2, recv/2, recv/3, unrecv/2,
         close/1, shutdown/2, controlling_process/2, setopts/2, getopts/2,
         peername/1, sockname/1, getstat/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SOCKET(Pid), {'$inet', ?MODULE, Pid}).
-define(HOST, 'Elixir.WasmHost.Server').

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

send(?SOCKET(Pid), Data) -> call(Pid, {send, Data}).
recv(Socket, Length) -> recv(Socket, Length, infinity).
recv(?SOCKET(Pid), Length, Timeout) -> call(Pid, {recv, Length, Timeout}).
unrecv(?SOCKET(Pid), Data) -> call(Pid, {unrecv, Data}).
close(?SOCKET(Pid)) -> _ = call(Pid, close), ok.
shutdown(?SOCKET(Pid), _How) -> call(Pid, close).
controlling_process(?SOCKET(Pid), NewOwner) -> call(Pid, {controlling_process, self(), NewOwner}).
setopts(?SOCKET(Pid), Opts) -> call(Pid, {setopts, Opts}).
getopts(?SOCKET(Pid), Opts) -> call(Pid, {getopts, Opts}).
peername(?SOCKET(Pid)) -> call(Pid, peername).
sockname(?SOCKET(_)) -> {ok, {{0, 0, 0, 0}, 0}}.
getstat(?SOCKET(_), _) -> {ok, []}.

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

init({Owner, Opts}) ->
    Id = <<"t", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    ?HOST:register(Id),
    Ref = monitor(process, Owner),
    S0 = #{id => Id, owner => Owner, ref => Ref, active => true, mode => list,
           buf => <<>>, recv => undefined, connect => undefined, peer => undefined,
           closed => false},
    {ok, options(Opts, S0)}.

options(Opts, S) -> lists:foldl(fun option/2, S, Opts).

option(binary, S) -> S#{mode := binary};
option(list, S) -> S#{mode := list};
option({mode, M}, S) -> S#{mode := M};
option({active, A}, S) -> S#{active := A};
option(_, S) -> S.

handle_call({connect, Host, Port, Timeout}, From, #{id := Id} = S) ->
    ?HOST:send_host(#{t => tcp_connect, id => Id, host => Host, port => Port}),
    TRef = case Timeout of
        infinity -> undefined;
        _ -> erlang:send_after(Timeout, self(), connect_timeout)
    end,
    {noreply, S#{connect := {From, TRef}, peer := {Host, Port}}};
handle_call({send, Data}, _From, #{id := Id} = S) ->
    ?HOST:send_host(#{t => tcp_send, id => Id}, Data),
    {reply, ok, S};
handle_call({recv, _, _}, _From, #{active := A} = S) when A =/= false ->
    {reply, {error, einval}, S};
handle_call({recv, Length, Timeout}, From, S) ->
    TRef = case Timeout of
        infinity -> undefined;
        _ -> erlang:send_after(Timeout, self(), recv_timeout)
    end,
    {noreply, serve_recv(S#{recv := {From, Length, TRef}})};
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
    {reply, ok, flush_active(options(Opts, S))};
handle_call({getopts, Opts}, _From, #{active := A, mode := M} = S) ->
    Known = #{active => A, mode => M, packet => raw, header => 0},
    {reply, {ok, [{K, V} || K <- Opts, {ok, V} <- [maps:find(K, Known)]]}, S};
handle_call(peername, _From, #{peer := {Host, Port}} = S) ->
    Addr = case inet:parse_address(binary_to_list(Host)) of
        {ok, IP} -> IP;
        _ -> {0, 0, 0, 0}
    end,
    {reply, {ok, {Addr, Port}}, S}.

handle_cast(_, S) -> {noreply, S}.

handle_info({wasm_host, <<"tcp_open">>, _, _}, #{connect := {From, TRef}} = S) ->
    cancel(TRef),
    gen_server:reply(From, ok),
    {noreply, S#{connect := undefined}};
handle_info({wasm_host, <<"tcp_error">>, Meta, _}, #{connect := {From, TRef}} = S) ->
    cancel(TRef),
    gen_server:reply(From, {error, reason(Meta)}),
    {stop, normal, S};
handle_info({wasm_host, <<"tcp_error">>, Meta, _}, #{owner := Owner} = S) ->
    Owner ! {tcp_error, ?SOCKET(self()), reason(Meta)},
    {noreply, S};
handle_info({wasm_host, <<"tcp_data">>, _, Data}, S) ->
    {noreply, deliver(Data, S)};
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

cancel(undefined) -> ok;
cancel(TRef) -> erlang:cancel_timer(TRef).

close_host(#{id := Id} = S) ->
    ?HOST:send_host(#{t => tcp_close, id => Id}),
    S.

data(Bin, #{mode := binary}) -> Bin;
data(Bin, #{mode := list}) -> binary_to_list(Bin).

%% Data from the host: to the owner (active modes) or to the buffer.
deliver(Data, #{active := false, buf := Buf} = S) ->
    serve_recv(S#{buf := <<Buf/binary, Data/binary>>});
deliver(Data, #{owner := Owner, active := A} = S) ->
    Socket = ?SOCKET(self()),
    Owner ! {tcp, Socket, data(Data, S)},
    case A of
        true -> S;
        once -> S#{active := false};
        1 -> Owner ! {tcp_passive, Socket}, S#{active := false};
        N when is_integer(N) -> S#{active := N - 1}
    end.

flush_active(#{active := A, buf := Buf} = S) when A =/= false, Buf =/= <<>> ->
    deliver(Buf, S#{buf := <<>>});
flush_active(S) -> S.

serve_recv(#{recv := {From, 0, TRef}, buf := Buf} = S) when Buf =/= <<>> ->
    cancel(TRef),
    gen_server:reply(From, {ok, data(Buf, S)}),
    S#{recv := undefined, buf := <<>>};
serve_recv(#{recv := {From, Len, TRef}, buf := Buf} = S)
  when Len > 0, byte_size(Buf) >= Len ->
    cancel(TRef),
    <<Part:Len/binary, Rest/binary>> = Buf,
    gen_server:reply(From, {ok, data(Part, S)}),
    S#{recv := undefined, buf := Rest};
serve_recv(#{recv := {From, _, TRef}, closed := true} = S) ->
    cancel(TRef),
    gen_server:reply(From, {error, closed}),
    S#{recv := undefined};
serve_recv(S) -> S.

closed(#{recv := {From, _, TRef}} = S) ->
    cancel(TRef),
    gen_server:reply(From, {error, closed}),
    closed(S#{recv := undefined});
closed(#{active := A, owner := Owner} = S) when A =/= false ->
    Owner ! {tcp_closed, ?SOCKET(self())},
    {stop, normal, S};
closed(S) ->
    %% Passive: the owner gets the rest of the buffer, then {error, closed}.
    {noreply, S#{closed := true}}.
