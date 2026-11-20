%% The speed of sockets and of HTTPS downloads (docs/BENCHMARKS.md,
%% "Downloads on Windows"):
%%
%%   beam.com tests/bench/net_bench.erl
%%
%% - A ping-pong of one byte over loopback TCP in the mode {active, once}:
%%   each round trip arms each socket again, so it shows the time that
%%   the poll thread of ERTS needs to see a change of its set (C59 of
%%   docs/UPSTREAM.md).
%% - Two downloads with httpc, which reads in the mode {active, once}.
%% - The same two downloads with ssl in the passive mode, as Mint and Req
%%   read.
%%
%% It needs the network. It has no test of a large send over loopback in
%% one VM: on Windows, send() of Cosmopolitan blocks (C60).
-module(net_bench).
-export([main/1]).

-define(FILES, ["https://github.com/sntran/tailwind.com/releases/download/v0.5.0/tailwind.com",
                "https://github.com/tailwindlabs/tailwindcss/releases/download/v4.1.18/tailwindcss-windows-x64.exe"]).

main(_) ->
    _ = ssl:start(),
    _ = inets:start(),
    io:format("system: ~s~n", [erlang:system_info(system_architecture)]),
    ping_pong(1000),
    lists:foreach(fun download/1, ?FILES),
    lists:foreach(fun passive_download/1, ?FILES),
    halt(0).

pair() ->
    {ok, L} = gen_tcp:listen(0, [binary, {ip, {127, 0, 0, 1}}, {active, false}, {nodelay, true}]),
    {ok, Port} = inet:port(L),
    Self = self(),
    spawn_link(fun() -> {ok, A} = gen_tcp:accept(L), ok = gen_tcp:controlling_process(A, Self), Self ! {accepted, A} end),
    {ok, C} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}, {nodelay, true}]),
    A = receive {accepted, X} -> X end,
    gen_tcp:close(L),
    {C, A}.

ping_pong(N) ->
    {C, A} = pair(),
    Echo = spawn_link(fun() -> ok = inet:setopts(A, [{active, once}]), echo(A) end),
    ok = gen_tcp:controlling_process(A, Echo),
    ok = inet:setopts(C, [{active, once}]),
    T = erlang:monotonic_time(microsecond),
    pong(C, N),
    Us = erlang:monotonic_time(microsecond) - T,
    io:format("BENCH ping-pong active once: ~b round trips, ~.3f ms each~n", [N, Us / N / 1000]),
    gen_tcp:close(C).

echo(S) ->
    receive
        {tcp, S, D} -> ok = gen_tcp:send(S, D), ok = inet:setopts(S, [{active, once}]), echo(S);
        {tcp_closed, S} -> ok
    end.

pong(_, 0) -> ok;
pong(C, N) ->
    ok = gen_tcp:send(C, <<"x">>),
    receive {tcp, C, _} -> ok = inet:setopts(C, [{active, once}]) end,
    pong(C, N - 1).

download(Url) ->
    Tls = [{verify, verify_peer}, {cacerts, public_key:cacerts_get()},
           {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
    T = erlang:monotonic_time(millisecond),
    R = httpc:request(get, {Url, [{"user-agent", "beam.com"}]}, [{ssl, Tls}, {timeout, 600000}],
                      [{body_format, binary}]),
    Ms = erlang:monotonic_time(millisecond) - T,
    case R of
        {ok, {{_, 200, _}, _, B}} ->
            io:format("BENCH download: ~b bytes in ~b ms, ~.2f MB/s~n", [byte_size(B), Ms, byte_size(B) / Ms / 1000]);
        Other ->
            io:format("BENCH download: ~p after ~b ms~n", [Other, Ms])
    end.

tls(Host) ->
    [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}, {server_name_indication, Host},
     {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}].

%% One GET with ssl in the passive mode. A redirect gives the next URL.
passive_download(Url) ->
    T = erlang:monotonic_time(millisecond),
    case passive_get(Url, 3) of
        {ok, Bytes} ->
            Ms = erlang:monotonic_time(millisecond) - T,
            io:format("BENCH passive download: ~b bytes in ~b ms, ~.2f MB/s~n", [Bytes, Ms, Bytes / Ms / 1000]);
        Error ->
            io:format("BENCH passive download: ~p~n", [Error])
    end.

passive_get(_, 0) ->
    {error, redirects};
passive_get(Url, Left) ->
    #{host := Host, path := Path} = U = uri_string:parse(Url),
    Target = case maps:get(query, U, "") of "" -> Path; Q -> Path ++ "?" ++ Q end,
    {ok, S} = ssl:connect(Host, 443, [binary, {active, false}, {packet, 0} | tls(Host)], 30000),
    ok = ssl:send(S, ["GET ", Target, " HTTP/1.1\r\nHost: ", Host,
                      "\r\nUser-Agent: beam.com\r\nConnection: close\r\n\r\n"]),
    {Head, Rest} = head(S, <<>>),
    [Status | Lines] = binary:split(Head, <<"\r\n">>, [global]),
    case binary:split(Status, <<" ">>, [global]) of
        [_, <<"200">> | _] ->
            N = body(S, byte_size(Rest)),
            ssl:close(S),
            {ok, N};
        [_, <<"30", _>> | _] ->
            ssl:close(S),
            [Loc] = [V || L <- Lines, [K, V] <- [binary:split(L, <<": ">>)],
                          string:lowercase(K) =:= <<"location">>],
            passive_get(binary_to_list(Loc), Left - 1);
        _ ->
            ssl:close(S),
            {error, Status}
    end.

head(S, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [H, R] -> {H, R};
        [_] -> {ok, D} = ssl:recv(S, 0, 30000), head(S, <<Acc/binary, D/binary>>)
    end.

body(S, N) ->
    case ssl:recv(S, 0, 60000) of
        {ok, D} -> body(S, N + byte_size(D));
        {error, closed} -> N
    end.
