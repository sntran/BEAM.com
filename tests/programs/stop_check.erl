%% A one-file program for "beam.com INPUT -o app.com" that tests the hosts of
%% the npm package when the VM stops (tests/host/app_stop.sh). It is an
%% HTTP server on port 4000 (the port of the bridge of worker.js):
%%
%%   GET /halt    the VM stops with erlang:halt(3)
%%   GET /abort   the VM stops with erlang:halt(abort) (a trap in the runtime)
%%   GET /slow    no answer
%%   GET PATH     200 with the start time of the VM, for example "vm 12345"
%%
%% A new VM has a new start time, so the text shows that the host started a
%% new VM after a stop.
-module(stop_check).
-export([main/1]).

main(_) ->
    {ok, L} = gen_tcp:listen(4000, [binary, {active, false}, {reuseaddr, true}]),
    accept(L).

accept(L) ->
    {ok, S} = gen_tcp:accept(L),
    Pid = spawn(fun() -> receive go -> serve(S) end end),
    ok = gen_tcp:controlling_process(S, Pid),
    Pid ! go,
    accept(L).

serve(S) ->
    {ok, Data} = gen_tcp:recv(S, 0),
    [_, Path | _] = binary:split(Data, <<" ">>, [global]),
    case Path of
        <<"/halt">> -> erlang:halt(3);
        <<"/abort">> -> erlang:halt(abort);
        <<"/slow">> -> receive after infinity -> ok end;
        _ -> reply(S, io_lib:format("vm ~p~n", [erlang:system_info(start_time)]))
    end.

reply(S, Body) ->
    gen_tcp:send(S, ["HTTP/1.1 200 OK\r\ncontent-length: ", integer_to_list(iolist_size(Body)),
                     "\r\nconnection: close\r\n\r\n", Body]),
    gen_tcp:close(S).
