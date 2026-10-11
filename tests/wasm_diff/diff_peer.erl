%% Peer nodes with the standard I/O as their control connection (the peer
%% module). In the WebAssembly runtime, the host starts a second VM for
%% each port of the program of the VM (Module.beamHost.spawn of run.mjs).
%% The output has no time and no memory size.
-module(diff_peer).
-export([main/1]).

main([_Dir]) ->
    {ok, Peer, Node} = peer:start(#{connection => standard_io, wait_boot => 60000}),
    io:format("node: ~p~n", [Node]),
    io:format("sum: ~p~n", [peer:call(Peer, erlang, '+', [1, 2])]),
    io:format("node of the peer: ~p~n", [peer:call(Peer, erlang, node, [])]),
    List = peer:call(Peer, lists, seq, [1, 100000]),
    io:format("list: ~p ~p~n", [length(List), lists:sum(List)]),
    Binary = peer:call(Peer, binary, copy, [<<1, 2, 3>>, 100000]),
    io:format("binary: ~p ~p~n", [byte_size(Binary), erlang:crc32(Binary)]),
    Error = try peer:call(Peer, erlang, error, [boom]) catch error:Reason -> Reason end,
    io:format("error: ~p~n", [Error]),
    %% A second peer at the same time, and a stop of the first one.
    {ok, Second, _} = peer:start(#{connection => standard_io, wait_boot => 60000}),
    ok = peer:stop(Peer),
    io:format("second: ~p~n", [peer:call(Second, erlang, '*', [6, 7])]),
    ok = peer:stop(Second),
    io:format("stopped~n").
