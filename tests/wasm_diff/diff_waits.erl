%% The waits of libc in many processes at the same time: file:sync/1
%% (fsync, on a dirty I/O scheduler) and a sleep of a scheduler
%% (erts_milli_sleep, with select). Other processes wait on timers. Under
%% JSPI, fsync and select suspend the thread, and the other threads run
%% during the wait. The output has only counts.
-module(diff_waits).
-export([main/1]).

main([Dir]) ->
    % The sleep needs the internal state, which logs a warning with a time.
    ok = logger:set_primary_config(level, error),
    _ = erts_debug:set_internal_state(available_internal_state, true),
    Self = self(),
    Run = fun(F) -> spawn_monitor(fun() -> Self ! {done, F()} end) end,
    Pids = [Run(fun() -> sync(filename:join(Dir, "sync" ++ integer_to_list(N)), 0) end)
            || N <- lists:seq(1, 20)]
        ++ [Run(fun() -> sleep(0) end) || _ <- lists:seq(1, 4)]
        ++ [Run(fun() -> wait(N, 0) end) || N <- lists:seq(1, 20)],
    Sums = [receive {done, S} -> S end || _ <- Pids],
    [receive {'DOWN', M, process, P, normal} -> ok end || {P, M} <- Pids],
    io:format("waits: ~w~n", [lists:sum(Sums)]);
main(_) ->
    io:format("usage: diff_waits DIR~n").

sync(_, 40) -> 40;
sync(File, I) ->
    {ok, F} = file:open(File, [write, raw, binary]),
    ok = file:write(F, <<I>>),
    ok = file:sync(F),
    ok = file:close(F),
    sync(File, I + 1).

sleep(20) -> 20;
sleep(I) ->
    true = erts_debug:set_internal_state(sleep, 1),
    sleep(I + 1).

wait(_, 40) -> 40;
wait(N, I) ->
    receive after (N + I) rem 3 -> ok end,
    wait(N, I + 1).
