%% A one-file program for "beam.com INPUT -o OUTPUT" that tests the sandbox
%% (the --allow-* flags). It does the actions of its command line and
%% prints the result of each one:
%%
%%   sandbox_check read PATH    read a file
%%   sandbox_check write PATH   write a file
%%   sandbox_check chmod PATH   change the mode of a file (to 600)
%%   sandbox_check touch PATH   change the times of a file
%%   sandbox_check unix         open a Unix datagram socket
%%   sandbox_check unixconnect PATH
%%                              connect to a Unix socket with a path: ok
%%                              also for econnrefused (the socket file is
%%                              there, with no listener). For a path of 100
%%                              bytes or more, use it as the last action
%%                              (see unix_connect/1).
%%   sandbox_check readn PATH   read 16 bytes of a file (for a device)
%%   sandbox_check stat PATH    read the information of a file
%%   sandbox_check list PATH    list a directory
%%   sandbox_check mkdir PATH   make a directory
%%   sandbox_check rmdir PATH   remove an empty directory
%%   sandbox_check delete PATH  delete a file
%%   sandbox_check rename FROM TO
%%                              rename a file
%%   sandbox_check symlink TARGET LINK
%%                              make a symbolic link
%%   sandbox_check listen       open a TCP socket on 127.0.0.1
%%   sandbox_check sockopts     set and read the options of a connected
%%                              TCP socket that inet sets (issue 157)
%%   sandbox_check rawopt       read TCP_CONGESTION, an option that the
%%                              sandbox of Linux does not allow
%%   sandbox_check connect HOST PORT
%%                              connect to a TCP port (a name or an
%%                              address), and close the socket
%%   sandbox_check udp HOST PORT
%%                              send a UDP datagram
%%   sandbox_check pyconnect HOST PORT
%%                              connect to a TCP port from python3, a
%%                              program of --allow-run (no proxy)
%%   sandbox_check run PROGRAM  run a program (a port), found in PATH, with
%%                              the arguments -c "exit 0" (sh ends at once,
%%                              and true ignores them)
%%   sandbox_check erl PATH     start the file of the program in erl mode
%%                              (BEAM_COM_ERL=1, as peer does): the new VM
%%                              reads PATH, and the result is its result
%%
%% A result is "ok" or the error, for example "write: error eperm". The
%% result of run names its program: "run sh: ok", and the result of connect
%% and udp names the host: "connect a.example: error nxdomain". The result of rawopt
%% is "ok" or "refused".
-module(sandbox_check).
-export([main/1]).

main(Args) ->
    run(Args).

run(["read", Path | Rest]) ->
    report(read, file:read_file(Path)),
    run(Rest);
run(["write", Path | Rest]) ->
    report(write, file:write_file(Path, <<"x">>)),
    run(Rest);
run(["chmod", Path | Rest]) ->
    report(chmod, file:change_mode(Path, 8#600)),
    run(Rest);
run(["touch", Path | Rest]) ->
    report(touch, file:change_time(Path, {{2026, 1, 1}, {0, 0, 0}})),
    run(Rest);
run(["unix" | Rest]) ->
    report(unix, gen_udp:open(0, [local])),
    run(Rest);
run(["unixconnect", Path | Rest]) ->
    report(unixconnect, unix_connect(Path)),
    run(Rest);
run(["readn", Path | Rest]) ->
    report(readn, read_bytes(Path, 16)),
    run(Rest);
run(["stat", Path | Rest]) ->
    report(stat, file:read_file_info(Path)),
    run(Rest);
run(["list", Path | Rest]) ->
    report(list, file:list_dir(Path)),
    run(Rest);
run(["mkdir", Path | Rest]) ->
    report(mkdir, file:make_dir(Path)),
    run(Rest);
run(["rmdir", Path | Rest]) ->
    report(rmdir, file:del_dir(Path)),
    run(Rest);
run(["delete", Path | Rest]) ->
    report(delete, file:delete(Path)),
    run(Rest);
run(["rename", From, To | Rest]) ->
    report(rename, file:rename(From, To)),
    run(Rest);
run(["symlink", Target, Link | Rest]) ->
    report(symlink, file:make_symlink(Target, Link)),
    run(Rest);
run(["listen" | Rest]) ->
    report(listen, gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}])),
    run(Rest);
run(["sockopts" | Rest]) ->
    report(sockopts, sockopts()),
    run(Rest);
run(["rawopt" | Rest]) ->
    io:format("rawopt: ~s~n", [rawopt()]),
    run(Rest);
run(["connect", Host, Port | Rest]) ->
    report("connect " ++ Host, connect(Host, list_to_integer(Port))),
    run(Rest);
run(["udp", Host, Port | Rest]) ->
    {ok, S} = gen_udp:open(0),
    report("udp " ++ Host, gen_udp:send(S, Host, list_to_integer(Port), <<"x">>)),
    gen_udp:close(S),
    run(Rest);
run(["pyconnect", Host, Port | Rest]) ->
    io:format("pyconnect ~s: ~s~n", [Host, pyconnect(Host, Port)]),
    run(Rest);
run(["erl", Path | Rest]) ->
    report(erl, erl_mode(Path)),
    run(Rest);
run(["run", Program | Rest]) ->
    report("run " ++ Program, run_program(Program)),
    run(Rest);
run([]) ->
    io:format("done~n").

report(Action, {ok, _}) -> io:format("~s: ok~n", [Action]);
report(Action, ok) -> io:format("~s: ok~n", [Action]);
report(Action, {error, Reason}) -> io:format("~s: error ~p~n", [Action, Reason]).

%% inet:setopts/2 gives ok also when the system refuses an option, and
%% inet:getopts/2 leaves out an option that it cannot read. Postgrex and
%% Mint read sndbuf and recbuf after each connect.
sockopts() ->
    Opts = [{sndbuf, 65536}, {recbuf, 65536}, {nodelay, true},
            {keepalive, true}, {linger, {true, 1}}],
    Names = [Name || {Name, _} <- Opts],
    {ok, L} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(L),
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port, []),
    Result =
        case inet:setopts(S, Opts) of
            ok ->
                {ok, Got} = inet:getopts(S, Names),
                case [Name || Name <- Names, not lists:keymember(Name, 1, Got)] of
                    [] -> {ok, Got};
                    Missing -> {error, {missing, Missing}}
                end;
            Error ->
                Error
        end,
    gen_tcp:close(S),
    gen_tcp:close(L),
    Result.

%% TCP_CONGESTION: the level IPPROTO_TCP (6) and the option 13 of Linux.
rawopt() ->
    {ok, L} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    Result =
        case inet:getopts(L, [{raw, 6, 13, 16}]) of
            {ok, [{raw, 6, 13, _}]} -> ok;
            _ -> refused
        end,
    gen_tcp:close(L),
    Result.

%% The address of a Unix socket has 104 bytes at most on the BSDs and
%% macOS. A longer path (a deep work directory) connects with the name in
%% its directory, and the program stays in that directory: the change
%% back can be refused (unveil() of OpenBSD hides the directories outside
%% the rules), so use it as the last action.
unix_connect(Path) when length(Path) < 100 ->
    unix_result(gen_tcp:connect({local, Path}, 0, [local], 5000));
unix_connect(Path) ->
    case file:set_cwd(filename:dirname(Path)) of
        ok -> unix_result(gen_tcp:connect({local, filename:basename(Path)}, 0, [local], 5000));
        Error -> Error
    end.

unix_result({ok, S}) -> gen_tcp:close(S);
unix_result({error, econnrefused}) -> ok;
unix_result(Error) -> Error.

read_bytes(Path, N) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, F} ->
            Result = file:read(F, N),
            ok = file:close(F),
            case Result of
                eof -> {ok, <<>>};
                _ -> Result
            end;
        Error ->
            Error
    end.

connect(Host, Port) ->
    case gen_tcp:connect(Host, Port, [], 10000) of
        {ok, S} -> gen_tcp:close(S);
        Error -> Error
    end.

%% "ok", or the name of the exception of Python.
pyconnect(Host, Port) ->
    Script = "import socket, sys\n"
             "try:\n"
             "    socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=10).close()\n"
             "    print('ok')\n"
             "except Exception as e:\n"
             "    print('error', type(e).__name__)\n",
    case os:find_executable("python3") of
        false ->
            "error no_python3";
        Exe ->
            P = open_port({spawn_executable, Exe},
                          [exit_status, stderr_to_stdout, binary, {args, ["-c", Script, Host, Port]}]),
            string:trim(binary_to_list(collect(P, <<>>)))
    end.

collect(P, Acc) ->
    receive
        {P, {data, D}} -> collect(P, <<Acc/binary, D/binary>>);
        {P, {exit_status, _}} -> Acc
    after 30000 -> <<"error timeout">>
    end.

run_program(Program) ->
    case os:find_executable(Program) of
        false -> {error, not_found};
        Exe ->
            %% open_port/2 waits for erl_child_setup with no limit: these
            %% lines show in the log where a start stopped.
            io:format("run ~s: start~n", [Program]),
            try open_port({spawn_executable, Exe}, [exit_status, binary, {args, ["-c", "exit 0"]}]) of
                Port ->
                    io:format("run ~s: started, OS pid ~p~n", [Program, element(2, erlang:port_info(Port, os_pid))]),
                    wait(Port)
            catch
                error:Reason -> {error, Reason}
            end
    end.

%% The file of this program in erl mode, with the environment of this
%% VM (BEAM_COM_ALLOW too). The new VM reads Path and prints "ok" or
%% "error REASON". Another exit, for example 127 when its sandbox did not
%% start, gives {error, {exit_status, S}}.
erl_mode(Path) ->
    {ok, [[Exe]]} = init:get_argument(beam_com_exe),
    Code = lists:flatten(io_lib:format(
        "case file:read_file(~p) of {ok, _} -> io:format(\"ok~~n\"); "
        "{error, R} -> io:format(\"error ~~p~~n\", [R]) end, halt().", [Path])),
    try open_port({spawn_executable, Exe}, [{env, [{"BEAM_COM_ERL", "1"}]}, exit_status,
                                            stderr_to_stdout, {args, ["-noshell", "-eval", Code]}]) of
        Port -> erl_mode_wait(Port, [])
    catch
        error:Reason -> {error, Reason}
    end.

erl_mode_wait(Port, Out) ->
    receive
        {Port, {data, D}} -> erl_mode_wait(Port, [Out | D]);
        {Port, {exit_status, 0}} ->
            Lines = string:split(lists:flatten(Out), "\n", all),
            case [L || L <- Lines, L =:= "ok" orelse lists:prefix("error ", L)] of
                ["ok" | _] -> ok;
                ["error " ++ R | _] -> {error, list_to_atom(R)};
                [] -> {error, {no_result, lists:flatten(Out)}}
            end;
        {Port, {exit_status, S}} ->
            io:format("erl: the output of the new VM: ~ts~n", [lists:flatten(Out)]),
            {error, {exit_status, S}}
    after 60000 -> {error, timeout}
    end.

wait(Port) ->
    receive
        {Port, {data, _}} -> wait(Port);
        {Port, {exit_status, 0}} -> ok;
        {Port, {exit_status, S}} -> {error, {exit_status, S}}
    after 10000 -> {error, timeout}
    end.
