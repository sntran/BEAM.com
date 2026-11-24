%% The signals of a port program (C70 of docs/UPSTREAM.md). On macOS
%% arm64, each port program started with HUP, INT, QUIT, USR1, USR2, TERM
%% and the other signals blocked. Thus a trap of /bin/sh did not run, and
%% kill -TERM did not stop a program.
%%
%%   beam.com tests/programs/signal_check.erl
%%
%% 1. For each of these signals, /bin/sh traps the signal that it sends to
%%    itself.
%% 2. kill -TERM stops a shell with no trap (exit status 143).
%% 3. A fake release (a shell that traps TERM and waits) stops when
%%    another port program sends it TERM.
%%
%% Each line ends with "ok", and the last line is "signal_check: ok".
-module(signal_check).
-export([main/1]).

-define(SIGNALS, ["HUP", "INT", "QUIT", "USR1", "USR2", "TERM"]).

main(_) ->
    Trapped = [trap(S) || S <- ?SIGNALS],
    Default = default_term(),
    Release = release(),
    case lists:all(fun(R) -> R end, [Default, Release | Trapped]) of
        true -> io:format("signal_check: ok~n");
        false -> halt(1)
    end.

%% The output and the exit status of a port program, or timeout.
run(Args) ->
    P = open_port({spawn_executable, "/bin/sh"},
                  [{args, Args}, exit_status, stream, stderr_to_stdout]),
    collect(P, []).

collect(P, Acc) ->
    receive
        {P, {data, D}} -> collect(P, [Acc, D]);
        {P, {exit_status, S}} -> {S, iolist_to_binary(Acc)}
    after 10000 ->
        try port_close(P) catch error:badarg -> ok end,
        {timeout, iolist_to_binary(Acc)}
    end.

trap(Sig) ->
    Script = "trap 'echo got " ++ Sig ++ "; exit 0' " ++ Sig ++ "; kill -" ++ Sig
        ++ " $$; sleep 2; echo missed " ++ Sig,
    Got = list_to_binary("got " ++ Sig ++ "\n"),
    report("a trap of " ++ Sig, run(["-c", Script]) =:= {0, Got}).

default_term() ->
    R = run(["-c", "kill -TERM $$; sleep 2; echo alive"]),
    report("kill -TERM of a shell with no trap (status 143)", element(1, R) =:= 143).

release() ->
    P = open_port({spawn_executable, "/bin/sh"},
                  [{args, ["-c", "trap 'echo stopped; exit 0' TERM; echo $$; "
                           "while :; do sleep 0.1; done"]},
                   exit_status, {line, 64}, stderr_to_stdout]),
    Pid = receive {P, {data, {eol, Line}}} -> Line after 10000 -> "0" end,
    _ = run(["-c", "kill -TERM " ++ Pid]),
    Ok = receive
             {P, {data, {eol, "stopped"}}} ->
                 receive {P, {exit_status, 0}} -> true after 10000 -> false end
         after 10000 ->
             _ = run(["-c", "kill -KILL " ++ Pid]),
             false
         end,
    report("a fake release stops with TERM from another port program", Ok).

report(Text, Ok) ->
    io:format("signal_check: ~s: ~s~n", [Text, if Ok -> "ok"; true -> "failed" end]),
    Ok.
