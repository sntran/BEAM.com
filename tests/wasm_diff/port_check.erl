%% The ports to bindings of worker.js (openPort), with the port programs of
%% run.mjs ("ports" of the job), and their flow control:
%% - echo: 4 MiB there and back, the same bytes.
%% - sink: a port that reads 2 MiB for each second. The sends of 4 MiB wait
%%   for it, because the pipe and the host hold only a window of bytes.
%% - source: a port that gives 4 MiB as fast as the VM takes them. The host
%%   holds at most a window of bytes for the VM, so the source waits for the
%%   reads of ERTS. ERTS reads a port at each poll, also while the process
%%   sleeps or computes, as natively: the source does not wait for the
%%   process.
%% Each line of the output is one check.
-module(port_check).
-export([main/1]).

-define(MIB, 1048576).
-define(RATE, (2 * ?MIB)).

main([_Dir]) ->
    Block = list_to_binary([I band 255 || I <- lists:seq(0, 65535)]),
    All = binary:copy(Block, 64),
    echo(Block, All),
    sink(Block, All),
    source(All).

echo(Block, All) ->
    P = open_port({spawn_executable, "/env/ECHO"}, [binary, exit_status]),
    [true = port_command(P, Block) || _ <- lists:seq(1, 64)],
    {Back, <<>>} = read(P, byte_size(All), []),
    port_close(P),
    io:format("echo: the same bytes ~p~n", [Back =:= All]).

sink(Block, All) ->
    Args = [integer_to_list(?RATE), integer_to_list(byte_size(All))],
    P = open_port({spawn_executable, "/env/SINK"}, [binary, exit_status, {args, Args}]),
    T0 = erlang:monotonic_time(millisecond),
    [true = port_command(P, Block) || _ <- lists:seq(1, 64)],
    Sent = erlang:monotonic_time(millisecond) - T0,
    Line = line(P, <<>>),
    Hash = binary:encode_hex(crypto:hash(sha256, All), lowercase),
    io:format("sink: the same bytes ~p~n", [Line =:= <<"4194304 ", Hash/binary>>]),
    %% At 2 MiB for each second, 4 MiB take 2 s. The sends end when less
    %% than about one window waits: after 1 s at least.
    io:format("sink: the sends waited for the port ~p~n", [Sent >= 1000]),
    io:format("sink: exit ~p~n", [status(P)]).

source(All) ->
    P = open_port({spawn_executable, "/env/SOURCE"},
                  [binary, exit_status, {args, [integer_to_list(byte_size(All))]}]),
    {Data, Rest} = read(P, byte_size(All), []),
    %% The last line of the source: its time, and the count of the times
    %% that the window of the VM was full.
    [_Ms, <<"ms">>, Full] = binary:split(line(P, Rest), <<" ">>, [global]),
    io:format("source: the same bytes ~p~n", [Data =:= All]),
    io:format("source: the port waited for the reads of the VM ~p~n", [binary_to_integer(Full) > 0]),
    io:format("source: exit ~p~n", [status(P)]).

%% N bytes of the port, and the bytes after them.
read(_P, 0, Acc) ->
    {iolist_to_binary(lists:reverse(Acc)), <<>>};
read(P, N, Acc) ->
    receive
        {P, {data, D}} when byte_size(D) =< N ->
            read(P, N - byte_size(D), [D | Acc]);
        {P, {data, D}} ->
            <<Mine:N/binary, Rest/binary>> = D,
            {iolist_to_binary(lists:reverse([Mine | Acc])), Rest}
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
        {P, {exit_status, S}} -> S
    after 10000 ->
        none
    end.
