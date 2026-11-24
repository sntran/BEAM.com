%% The signals of a port program and of the VM (C70 of docs/UPSTREAM.md).
%% On macOS arm64, each port program started with all signals blocked
%% (only SIGCHLD was not). Thus a trap of /bin/sh did not run, and kill
%% -TERM did not stop a program.
%%
%%   beam.com tests/programs/signal_check.erl [-- skip SIGNAL...]
%%   beam.com tests/programs/signal_check.erl -- signals
%%
%% "skip" names the signals that a shell cannot trap also with no VM: the
%% caller of the VM gave them ignored, and a VM passes that on, as the
%% usual OTP does. For example, a shell with no job control can give a
%% command in the background SIGTSTP, SIGTTIN and SIGTTOU ignored, and the
%% bash 3.2 of macOS does not run a trap of SIGCHLD for a kill to itself.
%% tests/run.sh finds them. "signals" prints the signals of step 2.
%%
%% 1. A port program reads its whole signal mask and its dispositions,
%%    signals 1 to 31: /proc/self/status on Linux, else perl, else ps
%%    (FreeBSD, NetBSD). No signal is blocked. SIGPIPE is ignored, as with
%%    the usual OTP, and a signal of "skip" can be ignored. Also not
%%    SIGSYS: on macOS and the BSD systems, the runtime of Cosmopolitan
%%    ignores it, and the execve of a port program gives it its default
%%    action again (__wrap___sys_execve() of c_src/cosmo/beam_com.c).
%% 2. /bin/sh traps each catchable signal of POSIX that it sends to
%%    itself, except the signals of "skip". A signal that is blocked or
%%    ignored fails.
%% 3. kill -TERM stops a shell with no trap (exit status 143).
%% 4. A fake release (a shell that traps TERM and waits) stops when
%%    another port program sends it TERM.
%% 5. The VM gets HUP, USR2, ALRM and TSTP from a port program
%%    (os:set_signal/2 with handle). Not USR1: the default handler of OTP
%%    (erl_signal_handler) halts the VM for it.
%%
%% Each line ends with "ok" or "skipped", and the last line is
%% "signal_check: ok".
-module(signal_check).
-export([main/1]).
%% The handler of erl_signal_server for step 5.
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2]).

%% The catchable signals of POSIX, also in the XSI option. SIGPIPE is
%% ignored, as in the usual OTP: ERTS ignores it, and a port program
%% gets that disposition.
-define(SIGNALS, ["HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "FPE", "USR1", "SEGV",
                  "USR2", "ALRM", "TERM", "CHLD", "CONT", "TSTP", "TTIN", "TTOU", "URG",
                  "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "SYS"]).
-define(VM_SIGNALS, [sighup, sigusr2, sigalrm, sigtstp]).
-define(TIMEOUT, 10000).

main(["signals"]) ->
    io:format("~s~n", [lists:join(" ", ?SIGNALS)]);
main(Args) ->
    Skip = case Args of ["skip" | Names] -> Names; _ -> [] end,
    Results = [mask(Skip) | [trap(S, Skip) || S <- ?SIGNALS]]
        ++ [default_term(), release() | [vm(S) || S <- ?VM_SIGNALS]],
    case lists:all(fun(R) -> R end, Results) of
        true -> io:format("signal_check: ok~n");
        false -> halt(1)
    end.

%% The numbers of the signals on Linux, and on macOS and the BSD systems.
linux_number(Name) ->
    proplists:get_value(Name, lists:zip(["HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "BUS",
                                         "FPE", "KILL", "USR1", "SEGV", "USR2", "PIPE",
                                         "ALRM", "TERM", "STKFLT", "CHLD", "CONT", "STOP",
                                         "TSTP", "TTIN", "TTOU", "URG", "XCPU", "XFSZ",
                                         "VTALRM", "PROF", "WINCH", "IO", "PWR", "SYS"],
                                        lists:seq(1, 31))).
bsd_number(Name) ->
    proplists:get_value(Name, lists:zip(["HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "EMT",
                                         "FPE", "KILL", "BUS", "SEGV", "SYS", "PIPE", "ALRM",
                                         "TERM", "URG", "STOP", "TSTP", "CONT", "CHLD",
                                         "TTIN", "TTOU", "IO", "XCPU", "XFSZ", "VTALRM",
                                         "PROF", "WINCH", "INFO", "USR1", "USR2"],
                                        lists:seq(1, 31))).

%% The bits of a mask of the signals Names (signal N is bit N - 1).
bits(Number, Names) ->
    lists:foldl(fun(N, Acc) -> Acc bor (1 bsl (Number(N) - 1)) end, 0, Names).

%% Step 1. On Linux, the bits of SigBlk and SigIgn of the kernel. Else
%% perl names the blocked and the ignored signals. Perl itself ignores
%% SIGFPE at its start (PERL_FPU_INIT), so that signal is not in its list:
%% step 2 checks SIGFPE with a trap. Else ps of FreeBSD and NetBSD gives
%% the two masks in hexadecimal. The ignored signals, less the signals of
%% Skip, must be SIGPIPE only.
mask(Skip) ->
    %% NetBSD has a /proc/self/status too, with no SigBlk.
    case {os:type() =:= {unix, linux}, os:find_executable("perl"), os:find_executable("ps")} of
        {true, _, _} ->
            {_, Out} = run("/bin/cat", ["/proc/self/status"]),
            Lines = [L || L <- binary:split(Out, <<"\n">>, [global]),
                          binary:match(L, [<<"SigBlk:">>, <<"SigIgn:">>]) =/= nomatch],
            Bits = [{K, binary_to_integer(string:trim(V), 16)}
                    || L <- Lines, [K, V] <- [binary:split(L, <<":">>)]],
            report("the mask of a port program in /proc (" ++ text(iolist_to_binary(lists:join(", ", Lines))) ++ ")",
                   case Bits of
                       [{<<"SigBlk">>, 0}, {<<"SigIgn">>, Ign}] ->
                           Ign band bnot bits(fun linux_number/1, Skip) =:= bits(fun linux_number/1, ["PIPE"]);
                       _ ->
                           false
                   end);
        {false, Perl, _} when is_list(Perl) ->
            Script = "use POSIX; use Config; my @n = split ' ', $Config{sig_name}; "
                "my $m = POSIX::SigSet->new; sigprocmask(SIG_BLOCK, POSIX::SigSet->new, $m); "
                "my (@b, @i); for my $s (1 .. 31) { next if $s == SIGKILL || $s == SIGSTOP; "
                "push @b, $n[$s] if $m->ismember($s); next if $s == SIGFPE; "
                "my $a = POSIX::SigAction->new; sigaction($s, undef, $a) or next; "
                "push @i, $n[$s] if $a->handler eq 'IGNORE' } "
                "print \"blocked: @b\\nignored: @i\\n\"",
            {_, Out} = run(Perl, ["-e", Script]),
            Got = case binary:split(Out, <<"\n">>, [global]) of
                      [<<"blocked: ">>, <<"ignored: ", I/binary>> | _] ->
                          lists:usort(string:lexemes(binary_to_list(I), " ")) -- Skip;
                      _ -> bad
                  end,
            report("the mask of a port program with perl (" ++ text(Out) ++ ")", Got =:= ["PIPE"]);
        {false, false, Ps} when is_list(Ps) ->
            {_, Out} = sh(Ps ++ " -o sigmask= -o sigignore= -p $$"),
            case [hex(W) || W <- binary:split(string:trim(Out), [<<" ">>, <<"\t">>], [global, trim_all])] of
                [Blocked, Ign] when is_integer(Blocked), is_integer(Ign) ->
                    report("the mask of a port program with ps (" ++ text(Out) ++ ")",
                           Blocked =:= 0 andalso
                               Ign band bnot bits(fun bsd_number/1, Skip) =:= bits(fun bsd_number/1, ["PIPE"]));
                _ ->
                    io:format("signal_check: the mask of a port program: skipped (ps gave ~p), "
                              "the traps check each signal~n", [Out]),
                    true
            end;
        _ ->
            io:format("signal_check: the mask of a port program: skipped (no /proc, perl or "
                      "ps), the traps check each signal~n"),
            true
    end.

hex(Word) ->
    try binary_to_integer(Word, 16) catch error:badarg -> bad end.

text(Bin) ->
    string:trim(unicode:characters_to_list(binary:replace(Bin, <<"\n">>, <<"; ">>, [global])),
                trailing, "; ").

%% The output and the exit status of a program, or timeout.
run(Prog, Args) ->
    P = open_port({spawn_executable, Prog},
                  [{args, Args}, exit_status, stream, stderr_to_stdout]),
    collect(P, []).

collect(P, Acc) ->
    receive
        {P, {data, D}} -> collect(P, [Acc, D]);
        {P, {exit_status, S}} -> {S, iolist_to_binary(Acc)}
    after ?TIMEOUT ->
        try port_close(P) catch error:badarg -> ok end,
        {timeout, iolist_to_binary(Acc)}
    end.

sh(Script) ->
    run("/bin/sh", ["-c", Script]).

%% Step 2. A shell that does not know a name (for example SIGSYS on an
%% old shell) fails the trap command, and the check names the signal.
trap(Sig, Skip) ->
    case lists:member(Sig, Skip) of
        true ->
            io:format("signal_check: a trap of ~s: skipped (also with no VM)~n", [Sig]),
            true;
        false ->
            trap(Sig)
    end.

trap(Sig) ->
    Script = "trap 'echo got " ++ Sig ++ "; exit 0' " ++ Sig ++ " || exit 3; kill -" ++ Sig
        ++ " $$; sleep 2; echo missed " ++ Sig,
    Got = list_to_binary("got " ++ Sig ++ "\n"),
    report("a trap of " ++ Sig, sh(Script) =:= {0, Got}).

%% Step 3.
default_term() ->
    R = sh("kill -TERM $$; sleep 2; echo alive"),
    report("kill -TERM of a shell with no trap (status 143)", element(1, R) =:= 143).

%% Step 4.
release() ->
    P = open_port({spawn_executable, "/bin/sh"},
                  [{args, ["-c", "trap 'echo stopped; exit 0' TERM; echo $$; "
                           "while :; do sleep 0.1; done"]},
                   exit_status, {line, 64}, stderr_to_stdout]),
    Pid = receive {P, {data, {eol, Line}}} -> Line after ?TIMEOUT -> "0" end,
    _ = sh("kill -TERM " ++ Pid),
    Ok = receive
             {P, {data, {eol, "stopped"}}} ->
                 receive {P, {exit_status, 0}} -> true after ?TIMEOUT -> false end
         after ?TIMEOUT ->
             _ = sh("kill -KILL " ++ Pid),
             false
         end,
    report("a fake release stops with TERM from another port program", Ok).

%% Step 5. erl_signal_server sends each signal that the VM handles to its
%% handlers. Then the default comes back.
vm(Sig) ->
    ok = gen_event:add_handler(erl_signal_server, ?MODULE, self()),
    ok = os:set_signal(Sig, handle),
    Name = string:uppercase(lists:nthtail(3, atom_to_list(Sig))),
    _ = sh("kill -" ++ Name ++ " " ++ os:getpid()),
    Ok = receive {signal_check, Sig} -> true after ?TIMEOUT -> false end,
    ok = os:set_signal(Sig, default),
    ok = gen_event:delete_handler(erl_signal_server, ?MODULE, []),
    report("the VM gets " ++ Name ++ " from a port program", Ok).

init(Pid) -> {ok, Pid}.
handle_event(Sig, Pid) -> Pid ! {signal_check, Sig}, {ok, Pid}.
handle_call(_, Pid) -> {ok, ok, Pid}.
handle_info(_, Pid) -> {ok, Pid}.
terminate(_, _) -> ok.

report(Text, Ok) ->
    io:format("signal_check: ~s: ~s~n", [Text, if Ok -> "ok"; true -> "failed" end]),
    Ok.
