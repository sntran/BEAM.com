%% A process whose loop calls itself with a local call: it stays in the
%% code that it runs, also when a new version of this module loads. Only
%% the message move makes it call the current code (?MODULE:loop/0). So
%% while it runs old code, the next version of this module cannot load,
%% and the reload of beam.com waits for it.
-module(reload_loop).
-export([start/0, version/0, move/0, loop/0]).

-define(VERSION, 1).

start() ->
    register(?MODULE, spawn(fun loop/0)).

version() ->
    call(version).

move() ->
    call(move).

call(Request) ->
    Ref = make_ref(),
    ?MODULE ! {Request, self(), Ref},
    receive {Ref, Answer} -> Answer after 5000 -> timeout end.

loop() ->
    receive
        {version, From, Ref} ->
            From ! {Ref, ?VERSION},
            loop();
        {move, From, Ref} ->
            From ! {Ref, ok},
            ?MODULE:loop()
    end.
