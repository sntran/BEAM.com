%% A one-file program for "beam.com INPUT -o app.com" that tests the ports
%% to bindings of the hosts of the npm package (tests/host/app_ports.sh).
%% The host gives the bindings ECHO, SINK and SOURCE (tests/host/ports/).
%% It is an HTTP server on port 4000 (the port of the bridge of worker.js):
%%
%%   GET /echo           4 MiB to ECHO and back: "echo 4194304 true"
%%   GET /sink           4 MiB to SINK, which reads 2 MiB for each second:
%%                       "sink 4194304 true" when the sends waited for it
%%   GET /missing        the port /env/MISSING: "missing enoent"
%%   GET /through        the 4 MiB of SOURCE through the VM, in chunks
%%   GET /splice         the 4 MiB of SOURCE as the body (x-beam-port)
%%   GET /splice-after   the response first, then 1 MiB to ECHO and the
%%                       close of the port: the body
%%   GET /splice-before  64 KiB to ECHO and the close of the port, then
%%                       the response
%%   GET /splice-none    x-beam-port of no port: the host gives 502
%%   GET /bytes/N        N bytes of the pattern of SOURCE, from the VM
%%   GET PATH            200 "ports"
%%
%% The pattern: the byte at the offset K is K band 255.
-module(ports_check).
-export([main/1]).

-define(MIB, 1048576).
-define(RATE, (2 * ?MIB)).

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
        <<"/echo">> -> echo(S);
        <<"/sink">> -> sink(S);
        <<"/missing">> -> missing(S);
        <<"/through">> -> through(S);
        <<"/splice">> -> splice(S);
        <<"/splice-after">> -> splice_after(S);
        <<"/splice-before">> -> splice_before(S);
        <<"/splice-none">> -> head(S, 999999, 0);
        <<"/bytes/", N/binary>> -> reply(S, pattern(binary_to_integer(N)));
        _ -> reply(S, "ports\n")
    end.

echo(S) ->
    P = open_port({spawn_executable, "/env/ECHO"}, [binary, exit_status]),
    send(P, 4 * ?MIB),
    Back = read(P, 4 * ?MIB, []),
    port_close(P),
    reply(S, io_lib:format("echo ~p ~p~n", [byte_size(Back), Back =:= pattern(4 * ?MIB)])).

%% At 2 MiB for each second, 4 MiB take 2 s. The sends end when less than
%% about one window waits: after 1 s at least.
sink(S) ->
    Args = [integer_to_list(?RATE), integer_to_list(4 * ?MIB)],
    P = open_port({spawn_executable, "/env/SINK"}, [binary, exit_status, {args, Args}]),
    T0 = erlang:monotonic_time(millisecond),
    send(P, 4 * ?MIB),
    Sent = erlang:monotonic_time(millisecond) - T0,
    Line = line(P, <<>>),
    reply(S, io_lib:format("sink ~s ~p~n", [Line, Sent >= 1000])).

missing(S) ->
    Result = try open_port({spawn_executable, "/env/MISSING"}, [binary]) of
        P -> port_close(P), opened
    catch
        error:E -> E
    end,
    reply(S, io_lib:format("missing ~p~n", [Result])).

through(S) ->
    P = source(4 * ?MIB, []),
    ok = gen_tcp:send(S, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n"),
    relay(S, P, 4 * ?MIB),
    ok = gen_tcp:send(S, "0\r\n\r\n"),
    gen_tcp:close(S).

%% The VM keeps the port open until its end, and gets its exit status.
splice(S) ->
    P = source(4 * ?MIB, response()),
    head(S, os_pid(P), 4 * ?MIB),
    status(P).

splice_after(S) ->
    P = open_port({spawn_executable, "/env/ECHO"}, [binary, exit_status | response()]),
    head(S, os_pid(P), ?MIB),
    send(P, ?MIB),
    port_close(P).

splice_before(S) ->
    P = open_port({spawn_executable, "/env/ECHO"}, [binary, exit_status | response()]),
    Pid = os_pid(P),
    send(P, 65536),
    port_close(P),
    head(S, Pid, 65536).

source(Size, Opts) ->
    open_port({spawn_executable, "/env/SOURCE"},
              [binary, exit_status, {args, [integer_to_list(Size)]} | Opts]).

response() -> [{env, [{"BEAM_PORT_OUTPUT", "response"}]}].

os_pid(P) ->
    {os_pid, Pid} = erlang:port_info(P, os_pid),
    Pid.

%% A response with no body that gives its body to the port of Pid.
head(S, Pid, Size) ->
    ok = gen_tcp:send(S, ["HTTP/1.1 200 OK\r\nx-beam-port: ", integer_to_list(Pid),
                          "\r\nx-beam-port-length: ", integer_to_list(Size),
                          "\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"]),
    gen_tcp:close(S).

%% Size bytes of the pattern to the port, in parts of 64 KiB.
send(P, Size) ->
    Block = pattern(65536),
    [true = port_command(P, Block) || _ <- lists:seq(1, Size div 65536)],
    ok.

pattern(N) ->
    Run = list_to_binary(lists:seq(0, 255)),
    <<Part:(N rem 256)/binary, _/binary>> = Run,
    <<(binary:copy(Run, N div 256))/binary, Part/binary>>.

%% Left bytes of the port to the socket, as chunks.
relay(_S, _P, Left) when Left =< 0 -> ok;
relay(S, P, Left) ->
    receive
        {P, {data, D}} ->
            ok = gen_tcp:send(S, [integer_to_list(byte_size(D), 16), "\r\n", D, "\r\n"]),
            relay(S, P, Left - byte_size(D))
    after 30000 ->
        exit({timeout, Left})
    end.

%% N bytes of the port.
read(_P, 0, Acc) ->
    iolist_to_binary(lists:reverse(Acc));
read(P, N, Acc) ->
    receive
        {P, {data, D}} when byte_size(D) =< N -> read(P, N - byte_size(D), [D | Acc])
    after 30000 ->
        exit({timeout, N})
    end.

%% One line of the port, with no end of line.
line(P, Acc) ->
    case binary:split(Acc, <<"\n">>) of
        [Line, _] -> Line;
        [_] ->
            receive
                {P, {data, D}} -> line(P, <<Acc/binary, D/binary>>)
            after 30000 ->
                exit({timeout, line})
            end
    end.

status(P) ->
    receive
        {P, {exit_status, St}} -> St
    after 30000 ->
        none
    end.

reply(S, Body) ->
    gen_tcp:send(S, ["HTTP/1.1 200 OK\r\ncontent-length: ", integer_to_list(iolist_size(Body)),
                     "\r\nconnection: close\r\n\r\n", Body]),
    gen_tcp:close(S).
