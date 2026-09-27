%% The pump of the WebAssembly runtime: it takes the events of the
%% JavaScript host (wasm_host:recv/0) and gives each one to the process
%% of its TCP socket or listener (wasm_tcp). The servers of the program
%% (Bandit, Cowboy, ...) listen with gen_tcp on these sockets.
%%
%% An event is a JSON header, a newline, and the body:
%%
%%     {"t":"tcp_data","id":"t7"}
%%     {"t":"tcp_accept","id":"l3","conn":"a9","host":"1.2.3.4","port":5678}
%%
%% It also starts distributed Erlang over wasm_tcp (DIST_NAME).
-module(wasm_host_server).
-behaviour(gen_server).

-export([start_link/0, register/1, unregister/1, send_host/1, send_host/2]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(TABLE, ?MODULE).
-define(EVENTS, [<<"tcp_open">>, <<"tcp_data">>, <<"tcp_closed">>, <<"tcp_error">>,
                 <<"tcp_listening">>]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% The calling process gets the events of the socket or listener Id.
register(Id) -> ets:insert(?TABLE, {Id, self()}).
unregister(Id) -> ets:delete(?TABLE, Id).

%% A message to the host: a header (a map) and a body.
send_host(Header) -> send_host(Header, <<>>).
send_host(Header, Body) -> wasm_host:send([json:encode(Header), $\n, Body]).

init([]) ->
    ?TABLE = ets:new(?TABLE, [named_table, public, {read_concurrency, true}]),
    %% gen_tcp makes sockets of the host.
    ok = inet_db:set_tcp_module(wasm_tcp),
    %% No native resolver (inet_gethost is a port program): the hosts file.
    ok = inet_db:set_lookup([file]),
    Pump = spawn_link(fun pump/0),
    %% After the pump: a listener waits for an event of the host.
    spawn(fun start_distribution/0),
    %% The host can take requests now.
    send_host(#{t => ready}),
    {ok, #{pump => Pump}}.

handle_call(_Request, _From, State) -> {reply, ok, State}.
handle_cast(_Request, State) -> {noreply, State}.

%% Distributed Erlang over wasm_tcp (the boot has -proto_dist wasm_tcp and
%% -erl_epmd_port: no epmd). It starts here, when wasm_tcp works:
%% DIST_NAME=name@host, DIST_COOKIE, DIST_LISTEN=true to take connections
%% (in Workers: WebSockets to /.tcp/DIST_PORT), DIST_CONNECT=node to connect
%% to that node, and again when the connection ends.
start_distribution() ->
    case os:getenv("DIST_NAME") of
        false -> ok;
        Name ->
            Listen = os:getenv("DIST_LISTEN") =:= "true",
            %% The listener takes DIST_PORT (all nodes use it: no epmd).
            Port = list_to_integer(os:getenv("DIST_PORT", "4370")),
            application:set_env(kernel, inet_dist_listen_min, Port),
            application:set_env(kernel, inet_dist_listen_max, Port),
            {ok, _} = net_kernel:start(list_to_atom(Name),
                                       #{name_domain => longnames, dist_listen => Listen}),
            case os:getenv("DIST_COOKIE") of
                false -> ok;
                Cookie -> erlang:set_cookie(list_to_atom(Cookie))
            end,
            case os:getenv("DIST_CONNECT") of
                false -> ok;
                Node -> spawn(fun() -> keep_connected(list_to_atom(Node)) end)
            end
    end.

keep_connected(Node) ->
    case net_kernel:connect_node(Node) of
        true ->
            erlang:monitor_node(Node, true),
            receive {nodedown, Node} -> ok end;
        _ ->
            timer:sleep(2000)
    end,
    keep_connected(Node).

pump() ->
    Event = wasm_host:recv(),
    [Header, Body] = binary:split(Event, <<"\n">>),
    case json:decode(Header) of
        %% A connection to a listener of wasm_tcp: its events go to the
        %% listener until the process of the connection registers.
        #{<<"t">> := <<"tcp_accept">>, <<"id">> := Id, <<"conn">> := Conn} = Meta ->
            case ets:lookup(?TABLE, Id) of
                [{Id, Pid}] ->
                    ets:insert_new(?TABLE, {Conn, Pid}),
                    Pid ! {wasm_host, <<"tcp_accept">>, Meta, Body};
                [] ->
                    send_host(#{t => tcp_close, id => Conn})
            end;
        #{<<"t">> := T, <<"id">> := Id} = Meta ->
            case lists:member(T, ?EVENTS) andalso ets:lookup(?TABLE, Id) of
                [{Id, Pid}] -> Pid ! {wasm_host, T, Meta, Body};
                _ -> ok
            end;
        _ ->
            ok
    end,
    pump().
