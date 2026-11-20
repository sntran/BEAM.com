%% Large sends over loopback TCP between two processes of one VM (C60 of
%% docs/UPSTREAM.md). On Windows, a send of the libc waited until the
%% peer read the data, and the scheduler thread that ran the port waited
%% with it. A transfer of 64 MiB in one VM then got about 1.1 MB/s, or it
%% did not end.
%%
%%   beam.com tests/programs/send_check.erl
%%
%% 1. 64 MiB to a reader in the passive mode, and 64 MiB to a reader in
%%    the mode {active, once}. Each transfer must end in 30 s, with the
%%    CRC-32 of the data.
%% 2. With one scheduler online, 16 MiB to a reader that starts to read
%%    after a timer of 200 ms. A send that holds the only scheduler stops
%%    the timer and the reader, and the transfer never ends.
%%
%% Each line ends with "ok", and the last line is "send_check: ok".
-module(send_check).
-export([main/1]).

-define(MIB, 1048576).
-define(LIMIT_MS, 30000).

main(_) ->
    Chunk = chunk(),
    ok = transfer(passive, 64, Chunk),
    ok = transfer(once, 64, Chunk),
    Online = erlang:system_flag(schedulers_online, 1),
    ok = transfer(late, 16, Chunk),
    _ = erlang:system_flag(schedulers_online, Online),
    io:format("send_check: ok~n"),
    halt(0).

%% 1 MiB of a pattern.
chunk() ->
    << <<(I rem 251)>> || I <- lists:seq(0, ?MIB - 1) >>.

pair() ->
    {ok, L} = gen_tcp:listen(0, [binary, {ip, {127, 0, 0, 1}}, {active, false}]),
    {ok, Port} = inet:port(L),
    Self = self(),
    spawn_link(fun() ->
                       {ok, A} = gen_tcp:accept(L),
                       ok = gen_tcp:controlling_process(A, Self),
                       Self ! {accepted, A}
               end),
    {ok, C} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    A = receive {accepted, X} -> X end,
    gen_tcp:close(L),
    {C, A}.

transfer(Mode, Mib, Chunk) ->
    {C, A} = pair(),
    Self = self(),
    Want = lists:foldl(fun(_, Crc) -> erlang:crc32(Crc, Chunk) end, 0, lists:seq(1, Mib)),
    T = erlang:monotonic_time(millisecond),
    Sender = spawn_link(fun() ->
                                [ok = gen_tcp:send(A, Chunk) || _ <- lists:seq(1, Mib)],
                                ok = gen_tcp:close(A),
                                Self ! sent
                        end),
    ok = gen_tcp:controlling_process(A, Sender),
    Reader = spawn_link(fun() -> Self ! {read, read(Mode, C)} end),
    ok = gen_tcp:controlling_process(C, Reader),
    Reader ! go,
    {Bytes, Crc} = receive {read, R} -> R after ?LIMIT_MS -> {timeout, 0} end,
    Ms = erlang:monotonic_time(millisecond) - T,
    Result = case {Bytes, Crc} of
                 {timeout, _} -> "no end in 30 s";
                 _ when Bytes =/= Mib * ?MIB -> io_lib:format("~b bytes", [Bytes]);
                 _ when Crc =/= Want -> "a wrong CRC-32";
                 _ -> "ok"
             end,
    io:format("send_check: ~p, ~b MiB in ~b ms: ~s~n", [Mode, Mib, Ms, Result]),
    receive sent -> ok after 1000 -> ok end,
    case Result of
        "ok" -> ok;
        _ -> halt(1)
    end.

read(Mode, C) ->
    receive go -> ok end,
    case Mode of
        passive ->
            passive(C, 0, 0);
        once ->
            ok = inet:setopts(C, [{active, once}]),
            once(C, 0, 0);
        late ->
            receive after 200 -> ok end,
            passive(C, 0, 0)
    end.

passive(C, N, Crc) ->
    case gen_tcp:recv(C, 0) of
        {ok, D} -> passive(C, N + byte_size(D), erlang:crc32(Crc, D));
        {error, closed} -> {N, Crc}
    end.

once(C, N, Crc) ->
    receive
        {tcp, C, D} ->
            ok = inet:setopts(C, [{active, once}]),
            once(C, N + byte_size(D), erlang:crc32(Crc, D));
        {tcp_closed, C} ->
            {N, Crc}
    end.
