%% Many sockets in the set of the poll thread (C61 to C63 of
%% docs/UPSTREAM.md). On Windows, select() of Cosmopolitan failed with
%% E2BIG for 129 fds or more, and then no socket got an event. With 64 to
%% 128 fds, poll() did not wait, and the idle VM used a whole CPU. An
%% error of a socket that waited only for POLLOUT was never reported.
%%
%%   beam.com tests/programs/fds_check.erl
%%
%% 1. 150 pairs of loopback sockets in the mode {active, true}: after each
%%    new pair, one message on it must arrive in 5 s. With a lower limit of
%%    open files (max_fds of check_io: 128 on OpenBSD), fewer pairs, with
%%    room for 32 other fds of the VM. On Windows, max_fds is 1024.
%% 2. With these sockets idle, the VM uses less than 1 s of CPU in 3 s.
%% 3. A send waits for room, and the peer resets the connection: the send
%%    ends with an error in 10 s.
%%
%% Each line ends with "ok", and the last line is "fds_check: ok".
-module(fds_check).
-export([main/1]).

-define(PAIRS, 150).

main(_) ->
    %% With too many fds, each turn of the poll thread logs one report.
    logger:set_primary_config(level, none),
    Count = min(?PAIRS, (max_fds() - 32) div 2),
    Pairs = pairs(1, Count, []),
    io:format("fds_check: ~b pairs, one message on each: ok~n", [Count]),
    timer:sleep(500),
    {R0, _} = erlang:statistics(runtime),
    timer:sleep(3000),
    {R1, _} = erlang:statistics(runtime),
    Cpu = R1 - R0,
    io:format("fds_check: idle with ~b sockets, ~b ms of CPU in 3 s: ~s~n",
              [2 * Count, Cpu, if Cpu < 1000 -> "ok"; true -> "too much" end]),
    [begin gen_tcp:close(C), gen_tcp:close(A) end || {C, A} <- Pairs],
    Cpu < 1000 orelse halt(1),
    reset(),
    io:format("fds_check: ok~n"),
    halt(0).

%% The limit of fds of the poll set of the VM (the limit of open files).
max_fds() ->
    Info = lists:flatten(erlang:system_info(check_io)),
    proplists:get_value(max_fds, Info, 1024).

pairs(N, Count, Ps) when N > Count ->
    Ps;
pairs(N, Count, Ps) ->
    {ok, L} = gen_tcp:listen(0, [binary, {ip, {127, 0, 0, 1}}, {active, false}]),
    {ok, Port} = inet:port(L),
    {ok, C} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    {ok, A} = gen_tcp:accept(L, 5000),
    gen_tcp:close(L),
    ok = inet:setopts(A, [{active, true}]),
    ok = inet:setopts(C, [{active, true}]),
    ok = gen_tcp:send(C, <<"q">>),
    receive
        {tcp, A, <<"q">>} -> pairs(N + 1, Count, [{C, A} | Ps])
    after 5000 ->
        io:format("fds_check: no message on pair ~b (~b sockets) in 5 s~n", [N, 2 * N]),
        halt(1)
    end.

reset() ->
    {ok, L} = gen_tcp:listen(0, [binary, {ip, {127, 0, 0, 1}}, {active, false}, {recbuf, 4096}]),
    {ok, Port} = inet:port(L),
    {ok, C} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    {ok, A} = gen_tcp:accept(L, 5000),
    gen_tcp:close(L),
    Self = self(),
    Chunk = binary:copy(<<"r">>, 1 bsl 20),
    spawn_link(fun() -> Self ! {sent, send_loop(C, Chunk, 0)} end),
    %% The sender fills the buffers and waits for room.
    timer:sleep(1500),
    ok = inet:setopts(A, [{linger, {true, 0}}]),
    T0 = erlang:monotonic_time(millisecond),
    gen_tcp:close(A),
    R = receive {sent, X} -> X after 10000 -> no_end end,
    Ms = erlang:monotonic_time(millisecond) - T0,
    case R of
        {{error, E}, _} ->
            io:format("fds_check: a reset while a send waits: {error, ~p} in ~b ms: ok~n", [E, Ms]);
        _ ->
            io:format("fds_check: a reset while a send waits: ~p after ~b ms~n", [R, Ms]),
            halt(1)
    end.

send_loop(C, Chunk, N) ->
    case gen_tcp:send(C, Chunk) of
        ok when N < 4096 -> send_loop(C, Chunk, N + 1);
        ok -> {all_sent, N};
        E -> {E, N}
    end.
