%% A blue-green upgrade of one beam.com file: a new file of the program
%% takes the place of the running one, with no failed request and no lost
%% state. A spike: see examples/bluegreen/README.md.
%%
%%   beam.com examples/bluegreen/bluegreen.erl -o bluegreen.com
%%   ./bluegreen.com serve PORT            serve "count C version V upgrades U"
%%   ./bluegreen.com upgrade PORT FILE     replace the server with FILE
%%   ./bluegreen.com load PORT N [V]       N requests, one after the other
%%                                         (with V: then more, until version V answers)
%%   ./bluegreen.com wait PORT             wait until the server answers
%%   ./bluegreen.com stop PORT             stop the server
%%
%% The upgrade:
%%
%% 1. Check. The server starts FILE as a peer node (the peer module of
%%    OTP, erl mode) and calls migrate/1 of the new code with the state.
%%    A file that does not start, or a migrate/1 that refuses the state,
%%    stops the upgrade, and the server goes on.
%% 2. Listen. FILE starts as its own process ("serve PORT HANDOFF"): a
%%    peer node stops when the node that started it stops. It listens on
%%    the same port (SO_REUSEPORT), but does not accept yet.
%% 3. Hand off. The server closes its listener, waits for its open
%%    requests, and writes its state to HANDOFF. The new connections wait
%%    in the queue of the new listener.
%% 4. The new server reads the state, calls its migrate/1, and accepts.
%%    The old server stops.
-module(bluegreen).
-export([main/1, migrate/1, version/0]).

-define(VERSION, 1).

version() -> ?VERSION.

%% The state of version ?VERSION from the state of an older version.
migrate(#{count := _} = State) ->
    {ok, State#{upgrades => maps:get(upgrades, State, 0) + 1}};
migrate(Other) ->
    {error, {unknown_state, Other}}.

main(["serve", Port]) ->
    serve(list_to_integer(Port), #{count => 0, upgrades => 0}, undefined);
main(["serve", Port, Handoff]) ->
    serve(list_to_integer(Port), undefined, Handoff);
main(["upgrade", Port, File]) ->
    io:format("~s", [request(list_to_integer(Port), "POST /upgrade", filename:absname(File))]);
main(["load", Port, N]) ->
    load(list_to_integer(Port), list_to_integer(N), 0);
main(["load", Port, N, Version]) ->
    load(list_to_integer(Port), list_to_integer(N), list_to_integer(Version));
main(["wait", Port]) ->
    wait_up(list_to_integer(Port), 3000);
main(["stop", Port]) ->
    io:format("~s", [request(list_to_integer(Port), "POST /stop", "")]);
main(_) ->
    io:format("usage: bluegreen serve PORT | upgrade PORT FILE | load PORT N [V] | stop PORT~n"),
    erlang:halt(2).

%% The server

serve(Port, State0, Handoff) ->
    %% Only the loopback address: /upgrade starts the file that a client
    %% names, and it has no other check.
    {ok, Listen} = gen_tcp:listen(Port, [binary, {packet, http_bin}, {active, false},
                                         {ip, {127, 0, 0, 1}},
                                         {reuseaddr, true}, {reuseport, true},
                                         {backlog, 1024}]),
    State = case Handoff of
                undefined ->
                    State0;
                _ ->
                    %% Step 2: listening. Step 4: the state of the old server.
                    ok = file:write_file(Handoff ++ ".listening", <<>>),
                    {ok, Old} = wait_file(Handoff, 30000),
                    {ok, New} = migrate(binary_to_term(Old)),
                    ok = file:delete(Handoff),
                    New
            end,
    Self = self(),
    spawn_link(fun() -> acceptor(Listen, Self) end),
    loop(#{listen => Listen, port => Port, state => State, handlers => #{},
           handoff => undefined, acceptor => running}).

loop(#{state := State, handlers := Handlers} = S) ->
    receive
        {count, From} ->
            Count = maps:get(count, State) + 1,
            From ! {count, Count, maps:get(upgrades, State)},
            loop(S#{state := State#{count := Count}});
        {started, Pid} ->
            Ref = monitor(process, Pid),
            loop(S#{handlers := Handlers#{Ref => Pid}});
        {'DOWN', Ref, process, _, _} when is_map_key(Ref, Handlers) ->
            maybe_finish(S#{handlers := maps:remove(Ref, Handlers)});
        {upgrade, From, File} ->
            Self = self(),
            spawn(fun() -> upgrade(Self, From, File, maps:get(port, S), State) end),
            loop(S);
        {switch, Handoff} ->
            %% Step 3: no new connection comes to this server.
            ok = gen_tcp:close(maps:get(listen, S)),
            loop(S#{handoff := Handoff});
        acceptor_done ->
            maybe_finish(S#{acceptor := done});
        stop ->
            erlang:halt(0)
    end.

maybe_finish(#{handoff := Handoff, acceptor := done, handlers := H, state := State})
  when Handoff =/= undefined, map_size(H) =:= 0 ->
    %% Write and rename: the new server never reads a part of the file.
    ok = file:write_file(Handoff ++ ".new", term_to_binary(State)),
    ok = file:rename(Handoff ++ ".new", Handoff),
    erlang:halt(0);
maybe_finish(S) ->
    loop(S).

acceptor(Listen, Server) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            Pid = spawn(fun() -> receive go -> handle(Socket, Server) end end),
            ok = gen_tcp:controlling_process(Socket, Pid),
            Server ! {started, Pid},
            Pid ! go,
            acceptor(Listen, Server);
        {error, closed} ->
            Server ! acceptor_done
    end.

handle(Socket, Server) ->
    {Method, Path, Length} = read_request(Socket, undefined, undefined, 0),
    ok = inet:setopts(Socket, [{packet, raw}]),
    Body = case Length of
               0 -> <<>>;
               _ -> {ok, B} = gen_tcp:recv(Socket, Length), B
           end,
    Reply = case {Method, Path} of
                {'GET', <<"/">>} ->
                    Server ! {count, self()},
                    receive {count, C, U} -> io_lib:format("count ~b version ~b upgrades ~b~n", [C, ?VERSION, U]) end;
                {'POST', <<"/upgrade">>} ->
                    Server ! {upgrade, self(), binary_to_list(Body)},
                    receive {upgrade, Text} -> Text end;
                {'POST', <<"/stop">>} ->
                    Server ! stop,
                    "stopping\n";
                _ ->
                    "not found\n"
            end,
    Bin = iolist_to_binary(Reply),
    ok = gen_tcp:send(Socket, ["HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: ",
                               integer_to_list(byte_size(Bin)), "\r\n\r\n", Bin]),
    gen_tcp:close(Socket).

read_request(Socket, Method, Path, Length) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, {http_request, M, {abs_path, P}, _}} -> read_request(Socket, M, P, Length);
        {ok, {http_header, _, 'Content-Length', _, V}} ->
            read_request(Socket, Method, Path, binary_to_integer(V));
        {ok, {http_header, _, _, _, _}} -> read_request(Socket, Method, Path, Length);
        {ok, http_eoh} -> {Method, Path, Length}
    end.

%% The upgrade, in its own process: the server serves during the check.
upgrade(Server, From, File, Port, State) ->
    Text = case check(File, State) of
               {ok, Version} ->
                   Handoff = filename:join(filename:dirname(File),
                                           "bluegreen-handoff-" ++ os:getpid()),
                   start(File, Port, Handoff),
                   case wait_file(Handoff ++ ".listening", 30000) of
                       {ok, _} ->
                           ok = file:delete(Handoff ++ ".listening"),
                           Server ! {switch, Handoff},
                           io_lib:format("upgrade to version ~b~n", [Version]);
                       timeout ->
                           "upgrade refused: the new file did not listen\n"
                   end;
               {error, Reason} ->
                   io_lib:format("upgrade refused: ~0p~n", [Reason])
           end,
    From ! {upgrade, Text}.

%% Step 1: the new code in a peer node, with the state of this server.
%% peer:start/1, not start_link/1: a file that does not start must give
%% an error here, not an exit signal.
check(File, State) ->
    try peer:start(#{exec => {File, []}, env => [{"BEAM_COM_ERL", "1"}],
                     connection => standard_io, wait_boot => 30000}) of
        {ok, Peer, _} -> migrate_in(Peer, State);
        {error, {Reason, Stack}} when is_list(Stack) -> {error, {cannot_start, Reason}};
        {error, Reason} -> {error, {cannot_start, Reason}}
    catch
        Class:Error -> {error, {Class, Error}}
    end.

migrate_in(Peer, State) ->
    try peer:call(Peer, ?MODULE, migrate, [State], 10000) of
        {ok, _} -> {ok, peer:call(Peer, ?MODULE, version, [], 10000)};
        {error, Reason} -> {error, Reason}
    catch
        Class:Error -> {error, {Class, Error}}
    after
        peer:stop(Peer)
    end.

%% Step 2: the new file as its own process, not as a child that stops
%% with this node.
start(File, Port, Handoff) ->
    Quote = fun(S) -> "'" ++ string:replace(S, "'", "'\\''", all) ++ "'" end,
    _ = os:cmd(lists:flatten(["nohup ", Quote(File), " serve ", integer_to_list(Port), " ",
                              Quote(Handoff), " > /dev/null 2>&1 &"])),
    ok.

wait_file(File, Left) when Left > 0 ->
    case file:read_file(File) of
        {ok, Bin} -> {ok, Bin};
        {error, enoent} -> timer:sleep(10), wait_file(File, Left - 10)
    end;
wait_file(_, _) ->
    timeout.

%% The clients

request(Port, Line, Body) ->
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    ok = gen_tcp:send(S, [Line, " HTTP/1.1\r\nHost: localhost\r\nContent-Length: ",
                          integer_to_list(iolist_size(Body)), "\r\n\r\n", Body]),
    {ok, Reply} = recv_all(S, <<>>),
    [_, Text] = binary:split(Reply, <<"\r\n\r\n">>),
    Text.

recv_all(S, Acc) ->
    case gen_tcp:recv(S, 0, 30000) of
        {ok, B} -> recv_all(S, <<Acc/binary, B/binary>>);
        {error, closed} -> {ok, Acc};
        {error, _} = E -> E
    end.

%% Up to 30 s (3000 tries, 10 ms apart) for the first answer.
wait_up(Port, 0) ->
    io:format("no server on port ~b~n", [Port]),
    erlang:halt(1);
wait_up(Port, Tries) ->
    try request(Port, "GET /", "") of
        Text -> io:format("~s", [Text])
    catch
        _:_ -> timer:sleep(10), wait_up(Port, Tries - 1)
    end.

%% N requests, one after the other. With Until > 0, more requests follow
%% until version Until answers (at most 60 s more): the switch of an
%% upgrade is then inside the load, also when N requests take less time
%% than the start of the new server. Each count must be one more than the
%% count before it: no request failed, and no state was lost.
load(Port, N, Until) ->
    Deadline = erlang:monotonic_time(millisecond) + 60000,
    Timed = lists:reverse(load_loop(Port, N, Until, Deadline, [])),
    Results = [R || {_, R} <- Timed],
    Slowest = lists:max([T || {T, _} <- Timed]) div 1000,
    Failed = [R || {failed, _} = R <- Results],
    Parsed = [list_to_tuple([binary_to_integer(X) || X <- binary:split(T, [<<"count ">>, <<" version ">>, <<" upgrades ">>, <<"\n">>], [global, trim_all])])
              || T <- Results, is_binary(T)],
    Counts = [C || {C, _, _} <- Parsed],
    InOrder = Counts =:= lists:seq(hd(Counts), hd(Counts) + length(Counts) - 1),
    Versions = lists:usort([V || {_, V, _} <- Parsed]),
    io:format("load: ~b ok, ~b failed, counts in order ~p, versions ~w, slowest ~b ms~n",
              [length(Parsed), length(Failed), InOrder, Versions, Slowest]),
    [io:format("failed: ~p~n", [R]) || {failed, R} <- lists:sublist(Failed, 3)],
    ok.

load_loop(Port, N, Until, Deadline, Acc) ->
    {_, R} = Timed = timer:tc(fun() -> try request(Port, "GET /", "") catch _:E -> {failed, E} end end),
    Acc1 = [Timed | Acc],
    More = N > 1 orelse (version_of(R) < Until andalso erlang:monotonic_time(millisecond) < Deadline),
    case More of
        true -> load_loop(Port, N - 1, Until, Deadline, Acc1);
        false -> Acc1
    end.

%% The version in a reply "count C version V upgrades U", or 0.
version_of(Text) when is_binary(Text) ->
    case re:run(Text, <<" version ([0-9]+) ">>, [{capture, all_but_first, binary}]) of
        {match, [V]} -> binary_to_integer(V);
        nomatch -> 0
    end;
version_of(_) ->
    0.
