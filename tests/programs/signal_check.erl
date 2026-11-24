%% The signals of a port program and of the VM (C70 of docs/UPSTREAM.md).
%% On macOS arm64, each port program started with all signals blocked
%% (only SIGCHLD was not). Thus a trap of /bin/sh did not run, and kill
%% -TERM did not stop a program.
%%
%%   beam.com tests/programs/signal_check.erl
%%
%% 1. A port program reads its whole signal mask and its dispositions,
%%    signals 1 to 31: /proc/self/status on Linux, else perl. No signal is
%%    blocked. Only SIGPIPE is ignored, as with the usual OTP, and also
%%    SIGSYS on macOS and the BSD systems: the runtime of Cosmopolitan
%%    ignores SIGSYS at its start there (libc/runtime/cosmo2.c), and
%%    erl_child_setup is a program of Cosmopolitan. A system with neither
%%    /proc nor perl (FreeBSD, NetBSD) skips this step, and step 2 checks
%%    each signal.
%% 2. /bin/sh traps each catchable signal of POSIX that it sends to
%%    itself. A signal that is blocked or ignored fails. Not SIGSYS on
%%    macOS and the BSD systems (see step 1), and not SIGCHLD on macOS:
%%    its bash 3.2 does not run a trap of SIGCHLD for a kill to itself,
%%    also with no VM. Step 1 checks SIGCHLD there.
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

signals({unix, linux}) -> ?SIGNALS;
signals({unix, darwin}) -> ?SIGNALS -- ["CHLD", "SYS"];
signals(_) -> ?SIGNALS -- ["SYS"].

%% The ignored signals of a port program, in the sequence of the numbers.
ignored({unix, linux}) -> <<"PIPE">>;
ignored(_) -> <<"SYS PIPE">>.

main(_) ->
    Results = [mask() | [trap(S) || S <- signals(os:type())]]
        ++ [default_term(), release() | [vm(S) || S <- ?VM_SIGNALS]],
    case lists:all(fun(R) -> R end, Results) of
        true -> io:format("signal_check: ok~n");
        false -> halt(1)
    end.

%% Step 1. On Linux, the bits of SigBlk and SigIgn of the kernel: SIGPIPE
%% (13) is bit 12. Else perl names the blocked and the ignored signals.
%% Perl itself ignores SIGFPE at its start (PERL_FPU_INIT), so that
%% signal is not in its list. Step 2 checks SIGFPE with a trap.
mask() ->
    case {filelib:is_regular("/proc/self/status"), os:find_executable("perl")} of
        {true, _} ->
            {_, Out} = run("/bin/cat", ["/proc/self/status"]),
            Lines = [L || L <- binary:split(Out, <<"\n">>, [global]),
                          binary:match(L, [<<"SigBlk:">>, <<"SigIgn:">>]) =/= nomatch],
            Bits = [{K, binary_to_integer(string:trim(V), 16)}
                    || L <- Lines, [K, V] <- [binary:split(L, <<":">>)]],
            report("the mask of a port program in /proc (" ++ text(iolist_to_binary(lists:join(", ", Lines))) ++ ")",
                   Bits =:= [{<<"SigBlk">>, 0}, {<<"SigIgn">>, 1 bsl 12}]);
        {false, Perl} when is_list(Perl) ->
            Script = "use POSIX; use Config; my @n = split ' ', $Config{sig_name}; "
                "my $m = POSIX::SigSet->new; sigprocmask(SIG_BLOCK, POSIX::SigSet->new, $m); "
                "my (@b, @i); for my $s (1 .. 31) { next if $s == SIGKILL || $s == SIGSTOP; "
                "push @b, $n[$s] if $m->ismember($s); next if $s == SIGFPE; "
                "my $a = POSIX::SigAction->new; sigaction($s, undef, $a) or next; "
                "push @i, $n[$s] if $a->handler eq 'IGNORE' } "
                "print \"blocked: @b\\nignored: @i\\n\"",
            {_, Out} = run(Perl, ["-e", Script]),
            report("the mask of a port program with perl (" ++ text(Out) ++ ")",
                   Out =:= <<"blocked: \nignored: ", (ignored(os:type()))/binary, "\n">>);
        {false, false} ->
            io:format("signal_check: the mask of a port program: skipped (no perl and no "
                      "/proc), the traps check each signal~n"),
            true
    end.

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
