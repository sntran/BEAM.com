%% Timers of many processes, with work on the dirty schedulers at the
%% same time. The schedulers then often wait with a time limit while
%% another thread wakes them. The output has only counts.
-module(diff_timers).
-export([main/1]).

main([Dir]) ->
    File = filename:join(Dir, "timers.bin"),
    ok = file:write_file(File, binary:copy(<<"0123456789">>, 10000)),
    Self = self(),
    Pids = [spawn_monitor(fun() -> Self ! {done, work(N, File, 0)} end)
            || N <- lists:seq(1, 100)],
    Sums = [receive {done, S} -> S end || _ <- Pids],
    [receive {'DOWN', M, process, P, normal} -> ok end || {P, M} <- Pids],
    io:format("timers: ~w~n", [lists:sum(Sums)]);
main(_) ->
    io:format("usage: diff_timers DIR~n").

work(_, _, 30) -> 30;
work(N, File, I) ->
    receive after (N + I) rem 3 -> ok end,
    case (N + I) rem 4 of
        0 -> {ok, _} = file:read_file(File);
        1 -> _ = erlang:md5(binary:copy(<<N>>, 50000));
        2 -> erlang:garbage_collect();
        3 -> erlang:yield()
    end,
    work(N, File, I + 1).
