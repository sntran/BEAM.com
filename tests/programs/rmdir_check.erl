%% The removal of a directory (C68 of docs/UPSTREAM.md). On Windows, the
%% libc waited about 2 s before rmdir() failed for a directory with a
%% file.
%%
%%   beam.com tests/programs/rmdir_check.erl -- DIR
%%
%% 1. file:del_dir/1 of a directory with a file fails in less than 500 ms,
%%    10 times.
%% 2. After the delete of its file, the directory goes at once.
%% 3. A tree of 4 directories with 20 files goes with file:del_dir_r/1.
%%
%% Each line ends with "ok", and the last line is "rmdir_check: ok".
-module(rmdir_check).
-export([main/1]).

main([Dir]) ->
    D = filename:join(Dir, "rmdir_check.tmp"),
    _ = file:del_dir_r(D),
    ok = file:make_dir(D),
    F = filename:join(D, "f"),
    ok = file:write_file(F, <<"x">>),
    Ms = [begin
              T0 = erlang:monotonic_time(microsecond),
              {error, _} = file:del_dir(D),
              (erlang:monotonic_time(microsecond) - T0) div 1000
          end || _ <- lists:seq(1, 10)],
    Max = lists:max(Ms),
    io:format("rmdir_check: del_dir of a directory with a file, 10 times, at most ~b ms: ~s~n",
              [Max, if Max < 500 -> "ok"; true -> "too slow" end]),
    Max < 500 orelse halt(1),
    ok = file:delete(F),
    case file:del_dir(D) of
        ok ->
            io:format("rmdir_check: del_dir after the delete of the file: ok~n");
        E ->
            io:format("rmdir_check: del_dir after the delete of the file: ~p~n", [E]),
            halt(1)
    end,
    tree(D, 3),
    T1 = erlang:monotonic_time(millisecond),
    ok = file:del_dir_r(D),
    false = filelib:is_dir(D),
    io:format("rmdir_check: del_dir_r of a tree in ~b ms: ok~n",
              [erlang:monotonic_time(millisecond) - T1]),
    io:format("rmdir_check: ok~n"),
    halt(0).

%% A directory with 5 files and, above level 0, 1 directory of level - 1.
tree(D, Level) ->
    ok = file:make_dir(D),
    [ok = file:write_file(filename:join(D, integer_to_list(I)), <<"y">>) || I <- lists:seq(1, 5)],
    Level > 0 andalso tree(filename:join(D, "sub"), Level - 1).
