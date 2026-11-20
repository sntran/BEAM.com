%% Short timers (C67 of docs/UPSTREAM.md). On Windows, a wait ended at a
%% tick of the system timer, about 15.6 ms, so timer:sleep(1) took about
%% 15 ms. BEAM.com asks Windows for 1 ms at the start of the VM.
%%
%%   beam.com tests/programs/timer_check.erl [LIMIT_MS]
%%
%% 100 calls of timer:sleep(1), and 100 waits of receive ... after 1. With
%% LIMIT_MS, each set of 100 must take less than LIMIT_MS milliseconds:
%% tests/run.ps1 gives 800 (about 1500 before the fix). Some systems, as
%% OpenBSD and NetBSD, have a timer of 10 ms, so tests/run.sh gives no
%% limit.
%%
%% Each line ends with "ok", and the last line is "timer_check: ok".
-module(timer_check).
-export([main/1]).

main(Args) ->
    Limit = case Args of
                [L] -> list_to_integer(L);
                [] -> infinity
            end,
    Sleep = time(fun() -> timer:sleep(1) end),
    After = time(fun() -> receive after 1 -> ok end end),
    report("100 calls of timer:sleep(1)", Sleep, Limit),
    report("100 waits of receive after 1", After, Limit),
    io:format("timer_check: ok~n"),
    halt(0).

time(F) ->
    T0 = erlang:monotonic_time(microsecond),
    [F() || _ <- lists:seq(1, 100)],
    (erlang:monotonic_time(microsecond) - T0) div 1000.

report(What, Ms, Limit) when Ms < Limit ->
    io:format("timer_check: ~s in ~b ms: ok~n", [What, Ms]);
report(What, Ms, Limit) ->
    io:format("timer_check: ~s in ~b ms, the limit is ~b ms~n", [What, Ms, Limit]),
    halt(1).
