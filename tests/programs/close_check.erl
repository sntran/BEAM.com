%% The close of a written file and of a socket with a linger (C64 and C65
%% of docs/UPSTREAM.md).
%%
%%   beam.com tests/programs/close_check.erl DIR
%%
%% 1. 50 times: open a file of DIR, write 1 byte, close. The median of the
%%    close must be less than 2 ms. On Windows, the libc flushed the file
%%    to the disk at each close (about 9 ms on the ARM64 runner of CI).
%% 2. A socket with {linger, {true, 10}} and 48000 bytes in flight is
%%    closed: the peer must get all the bytes and then the end of the
%%    stream, in less than 5 s, 20 times. On Windows, the connection stayed
%%    open with no owner (C65). On Linux, close() waited for the peer, in
%%    the poll thread or in a scheduler, for up to the linger time (O29).
%%    The closing socket is in the mode {active, true}, and the peer starts
%%    to read only after the close, so the data surely waits at the close.
%%
%% Each line ends with "ok", and the last line is "close_check: ok".
-module(close_check).
-export([main/1]).

-define(BYTES, 48000).

main([Dir]) ->
    F = filename:join(Dir, "close_check.tmp"),
    Us = [begin
              {ok, Fd} = file:open(F, [write, raw, binary]),
              ok = file:write(Fd, <<"x">>),
              element(1, timer:tc(file, close, [Fd]))
          end || _ <- lists:seq(1, 50)],
    ok = file:delete(F),
    Median = lists:nth(25, lists:sort(Us)),
    io:format("close_check: close of a written file, median ~b us: ~s~n",
              [Median, if Median < 2000 -> "ok"; true -> "too slow" end]),
    Median < 2000 orelse halt(1),
    T0 = erlang:monotonic_time(millisecond),
    lists:foreach(fun linger/1, lists:seq(1, 20)),
    io:format("close_check: close with a linger, 20 times in ~b ms, the peer got ~b bytes and the end: ok~n",
              [erlang:monotonic_time(millisecond) - T0, ?BYTES]),
    io:format("close_check: ok~n"),
    halt(0).

linger(Round) ->
    %% The send buffer of the system takes all the data, so the queue of
    %% the driver is empty, and gen_tcp:close/1 does not wait for the peer.
    %% (NetBSD gave a smaller buffer for {sndbuf, 1 bsl 20}, and close/1
    %% waited 5 s for the queue.) The peer holds 8 KiB (16 KiB on Linux),
    %% so the rest of the data waits in the system at the close.
    {ok, L} = gen_tcp:listen(0, [binary, {ip, {127, 0, 0, 1}}, {active, false}, {recbuf, 8192}]),
    {ok, Port} = inet:port(L),
    {ok, C} = gen_tcp:connect({127, 0, 0, 1}, Port,
                              [binary, {active, true}, {sndbuf, 65536}, {linger, {true, 10}}]),
    {ok, A} = gen_tcp:accept(L, 5000),
    gen_tcp:close(L),
    Self = self(),
    Reader = spawn_link(fun() ->
                                receive go -> ok end,
                                Self ! {drained, drain(A, 0)}
                        end),
    ok = gen_tcp:controlling_process(A, Reader),
    T0 = erlang:monotonic_time(millisecond),
    ok = gen_tcp:send(C, binary:copy(<<"z">>, ?BYTES)),
    ok = gen_tcp:close(C),
    Reader ! go,
    Got = receive {drained, R} -> R after 30000 -> no_end_in_30_s end,
    Ms = erlang:monotonic_time(millisecond) - T0,
    case Got of
        {closed, ?BYTES} when Ms < 5000 ->
            ok;
        _ ->
            io:format("close_check: close with a linger, round ~b, the peer got ~p in ~b ms~n",
                      [Round, Got, Ms]),
            halt(1)
    end.

drain(S, N) ->
    case gen_tcp:recv(S, 0, 10000) of
        {ok, D} -> drain(S, N + byte_size(D));
        {error, E} -> {E, N}
    end.
