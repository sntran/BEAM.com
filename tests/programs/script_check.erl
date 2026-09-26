%% Behavior tests of one-file programs (beam_com_script): what main/1
%% gets, and the exit status of the program. tests/run.sh and
%% tests/run.ps1 build it with beam.com build and run it with:
%%
%%   args ARG...   print the arguments, one on each line
%%   return        main/1 returns: status 0
%%   raise         an exception: status 127, and the error on stderr
%%   throw         an uncaught throw: status 127
%%   halt N        erlang:halt(N) in main/1: status N
%%   exit          exit(normal) in main/1: status 127
%%   big           100000 lines, then return: all lines are written
%%   spawn         a linked process crashes after main/1 returns
%%   info          print the number of schedulers (for ERL_FLAGS)
-module(script_check).
-export([main/1]).

main(["args" | Args]) ->
    io:format("argc ~b~n", [length(Args)]),
    [io:format("arg ~ts~n", [A]) || A <- Args],
    ok;
main(["return"]) ->
    io:format("returning~n"),
    ok;
main(["raise"]) ->
    io:format("raising~n"),
    error({boom, 42});
main(["throw"]) ->
    throw(thrown_value);
main(["halt", N]) ->
    io:format("halting ~s~n", [N]),
    erlang:halt(list_to_integer(N));
main(["exit"]) ->
    exit(normal);
main(["big"]) ->
    [io:format("line ~b~n", [I]) || I <- lists:seq(1, 100000)],
    io:format("last line~n");
main(["spawn"]) ->
    spawn(fun() -> receive after 100 -> exit(crash) end end),
    io:format("returned~n");
main(["info"]) ->
    io:format("schedulers ~b~n", [erlang:system_info(schedulers)]);
main(Other) ->
    io:format(standard_error, "unknown test ~p~n", [Other]),
    halt(99).
