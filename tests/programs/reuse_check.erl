%% The options reuseaddr and reuseport (C66 of docs/UPSTREAM.md). On
%% Windows, the libc made {reuseport, true} an exclusive port, and a second
%% UDP socket on one port gave eaddrinuse. Erlang/OTP for Windows allows it.
%%
%%   beam.com tests/programs/reuse_check.erl
%%
%% 1. Two UDP sockets with {reuseaddr, true} and {reuseport, true} open on
%%    one port, and inet:getopts/2 gives both options as true.
%% 2. A datagram to that port arrives at one of the two sockets in 5 s.
%% 3. A second TCP listener on a port with {reuseaddr, true} alone gets
%%    eaddrinuse, on each system: the fix does not let a program take the
%%    port of another listener.
%%
%% Each line ends with "ok", and the last line is "reuse_check: ok".
-module(reuse_check).
-export([main/1]).

-define(LOOP, {127, 0, 0, 1}).

main(_) ->
    Opts = [binary, {active, true}, {reuseaddr, true}, {reuseport, true}, {ip, ?LOOP}],
    {ok, U1} = gen_udp:open(0, Opts),
    {ok, Port} = inet:port(U1),
    U2 = case gen_udp:open(Port, Opts) of
             {ok, S2} ->
                 io:format("reuse_check: two UDP sockets on one port: ok~n"),
                 S2;
             Error ->
                 io:format("reuse_check: two UDP sockets on one port: ~p~n", [Error]),
                 halt(1)
         end,
    case inet:getopts(U2, [reuseaddr, reuseport]) of
        {ok, [{reuseaddr, true}, {reuseport, true}]} ->
            io:format("reuse_check: getopts gives reuseaddr and reuseport: ok~n");
        Got ->
            io:format("reuse_check: getopts gives ~p~n", [Got]),
            halt(1)
    end,
    {ok, S} = gen_udp:open(0, [binary, {ip, ?LOOP}]),
    ok = gen_udp:send(S, ?LOOP, Port, <<"x">>),
    receive
        {udp, U, _, _, <<"x">>} when U =:= U1; U =:= U2 ->
            io:format("reuse_check: a datagram to the port arrives: ok~n")
    after 5000 ->
        io:format("reuse_check: no datagram in 5 s~n"),
        halt(1)
    end,
    [gen_udp:close(X) || X <- [S, U1, U2]],
    {ok, L} = gen_tcp:listen(0, [{reuseaddr, true}, {ip, ?LOOP}]),
    {ok, LPort} = inet:port(L),
    case gen_tcp:listen(LPort, [{reuseaddr, true}, {ip, ?LOOP}]) of
        {error, eaddrinuse} ->
            io:format("reuse_check: a second TCP listener with reuseaddr alone gets eaddrinuse: ok~n");
        Other ->
            io:format("reuse_check: a second TCP listener with reuseaddr alone got ~p~n", [Other]),
            halt(1)
    end,
    gen_tcp:close(L),
    io:format("reuse_check: ok~n"),
    halt(0).
