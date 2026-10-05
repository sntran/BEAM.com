%% A one-file program for "beam.com INPUT -o OUTPUT" that tests the sandbox
%% (the --allow-* flags). It does the actions of its command line and
%% prints the result of each one:
%%
%%   sandbox_check read PATH    read a file
%%   sandbox_check write PATH   write a file
%%   sandbox_check listen       open a TCP socket on 127.0.0.1
%%   sandbox_check run PROGRAM  run a program (a port), found in PATH, with
%%                              the arguments -c "exit 0" (sh ends at once,
%%                              and true ignores them)
%%
%% A result is "ok" or the error, for example "write: error eperm". The
%% result of run names its program: "run sh: ok".
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
run(["listen" | Rest]) ->
    report(listen, gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}])),
    run(Rest);
run(["run", Program | Rest]) ->
    report("run " ++ Program, run_program(Program)),
    run(Rest);
run([]) ->
    io:format("done~n").

report(Action, {ok, _}) -> io:format("~s: ok~n", [Action]);
report(Action, ok) -> io:format("~s: ok~n", [Action]);
report(Action, {error, Reason}) -> io:format("~s: error ~p~n", [Action, Reason]).

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

wait(Port) ->
    receive
        {Port, {data, _}} -> wait(Port);
        {Port, {exit_status, 0}} -> ok;
        {Port, {exit_status, S}} -> {error, {exit_status, S}}
    after 10000 -> {error, timeout}
    end.
