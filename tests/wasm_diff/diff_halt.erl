%% A crash dump: erlang:halt/1 with a slogan writes DIR/erl_crash.dump and
%% stops the VM with the exit status 1. In WebAssembly, the dump stopped
%% the VM with abort() (the exit status 2), and the file had no bytes (EM7
%% in docs/UPSTREAM.md). The output is empty: halt/1 with a slogan does
%% not flush the output.
-module(diff_halt).
-export([main/1]).

main([Dir]) ->
    true = os:putenv("ERL_CRASH_DUMP", filename:join(Dir, "erl_crash.dump")),
    erlang:halt("diff_halt: a crash dump");
main(_) ->
    io:format("usage: diff_halt DIR~n").
