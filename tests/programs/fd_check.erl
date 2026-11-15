%% beam_com_fd (c_src/fd/beam_com_fd.c): the descriptor of a TCP
%% listener goes over a Unix socket of gen_tcp, and the copy accepts.
%% A connection waits in the queue before the handover, and the old
%% listener closes: the copy must accept that connection, with no reset.
%%
%%   beam.com tests/programs/fd_check.erl -o fd_check.com
%%   ./fd_check.com DIR
-module(fd_check).
-export([main/1]).

main([Dir]) ->
    Path = filename:join(Dir, "fd_check-" ++ os:getpid() ++ ".sock"),
    _ = file:delete(Path),
    {ok, U} = gen_tcp:listen(0, [binary, {active, false}, {ifaddr, {local, Path}}]),
    {ok, C} = gen_tcp:connect({local, Path}, 0, [local, binary, {active, false}], 5000),
    {ok, S} = gen_tcp:accept(U, 5000),
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(L),
    %% Accepted by the kernel, but not by the program: in the queue.
    {ok, Early} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    ok = beam_com_fd:send(S, L),
    {ok, Fd} = beam_com_fd:recv(C, 5000),
    ok = gen_tcp:close(L),
    {ok, Copy} = gen_tcp:listen(0, [{fd, Fd}, binary, {active, false}]),
    {ok, CopyPort} = inet:port(Copy),
    {ok, A1} = gen_tcp:accept(Copy, 5000),
    ok = gen_tcp:send(Early, <<"early">>),
    EarlyData = gen_tcp:recv(A1, 5, 5000),
    {ok, Late} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    {ok, A2} = gen_tcp:accept(Copy, 5000),
    ok = gen_tcp:send(Late, <<"late">>),
    LateData = gen_tcp:recv(A2, 4, 5000),
    io:format("fd: same port ~p, early ~p, late ~p~n",
              [CopyPort =:= Port, EarlyData, LateData]),
    io:format("fd timeout: ~p~n", [beam_com_fd:recv(C, 100)]),
    ok = gen_tcp:close(S),
    io:format("fd closed: ~p~n", [beam_com_fd:recv(C, 5000)]),
    ok = gen_tcp:close(U),
    ok = file:delete(Path).
