%% The close of a written file and of a socket with a linger (C64 and C65
%% of docs/UPSTREAM.md).
%%
%%   beam.com tests/programs/close_check.erl DIR
%%
%% 1. 50 times: open a file of DIR, write 1 byte, close. The median of the
%%    close must be less than 2 ms. On Windows, the libc flushed the file
%%    to the disk at each close (about 9 ms on the ARM64 runner of CI).
%% 2. A socket with {linger, {true, 10}} and 200000 bytes in flight is
%%    closed: the peer must get all the bytes and then the end of the
%%    stream. On Windows, the connection stayed open with no owner.
%%
%% Each line ends with "ok", and the last line is "close_check: ok".
-module(close_check).
-export([main/1]).

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
    linger(),
    io:format("close_check: ok~n"),
    halt(0).

linger() ->
    {ok, L} = gen_tcp:listen(0, [binary, {ip, {127, 0, 0, 1}}, {active, false}, {recbuf, 4096}]),
    {ok, Port} = inet:port(L),
    {ok, C} = gen_tcp:connect({127, 0, 0, 1}, Port,
                              [binary, {active, false}, {sndbuf, 1 bsl 20}, {linger, {true, 10}}]),
    {ok, A} = gen_tcp:accept(L, 5000),
    gen_tcp:close(L),
    ok = gen_tcp:send(C, binary:copy(<<"z">>, 200000)),
    ok = gen_tcp:close(C),
    case drain(A, 0) of
        {closed, 200000} ->
            io:format("close_check: close with a linger, the peer got 200000 bytes and the end: ok~n");
        Other ->
            io:format("close_check: close with a linger, the peer got ~p~n", [Other]),
            halt(1)
    end.

drain(S, N) ->
    case gen_tcp:recv(S, 0, 10000) of
        {ok, D} -> drain(S, N + byte_size(D));
        {error, E} -> {E, N}
    end.
