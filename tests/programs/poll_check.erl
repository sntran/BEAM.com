%% The time that the poll thread of ERTS needs to see a change of its set.
%% A ping-pong of one byte over loopback TCP in the mode {active, once}:
%% each round trip arms each socket again, and the poll thread must see
%% the new socket at once. On Windows, a wake-up through a pipe came up
%% to 10 ms late (C59 of docs/UPSTREAM.md):
%%
%%   beam.com tests/programs/poll_check.erl
%%
%% gives one line, and the exit status 1 when the average of a round trip
%% is 2 ms or more (it is about 0.05 ms on Linux):
%%
%%   poll: 500 round trips, 0.050 ms each: ok
-module(poll_check).
-export([main/1]).

-define(ROUNDS, 500).
-define(LIMIT_MS, 2.0).

main(_) ->
    {ok, L} = gen_tcp:listen(0, [binary, {ip, {127, 0, 0, 1}}, {active, false}, {nodelay, true}]),
    {ok, Port} = inet:port(L),
    Self = self(),
    Echo = spawn_link(fun() ->
                              {ok, A} = gen_tcp:accept(L),
                              ok = inet:setopts(A, [{active, once}]),
                              Self ! accepted,
                              echo(A)
                      end),
    {ok, C} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}, {nodelay, true}]),
    receive accepted -> ok end,
    ok = inet:setopts(C, [{active, once}]),
    T = erlang:monotonic_time(microsecond),
    rounds(C, ?ROUNDS),
    Ms = (erlang:monotonic_time(microsecond) - T) / ?ROUNDS / 1000,
    unlink(Echo),
    gen_tcp:close(C),
    Result = case Ms < ?LIMIT_MS of
                 true -> "ok";
                 false -> "slow"
             end,
    io:format("poll: ~b round trips, ~.3f ms each: ~s~n", [?ROUNDS, Ms, Result]),
    halt(case Result of "ok" -> 0; _ -> 1 end).

echo(S) ->
    receive
        {tcp, S, D} ->
            ok = gen_tcp:send(S, D),
            ok = inet:setopts(S, [{active, once}]),
            echo(S);
        {tcp_closed, S} ->
            ok
    end.

rounds(_, 0) ->
    ok;
rounds(C, N) ->
    ok = gen_tcp:send(C, <<"x">>),
    receive {tcp, C, _} -> ok end,
    ok = inet:setopts(C, [{active, once}]),
    rounds(C, N - 1).
