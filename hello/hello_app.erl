%% The application callback of the hello release.
%%
%% The release boots kernel, stdlib and hello. This callback runs the
%% program in a new process, and the program stops the runtime.
-module(hello_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, spawn_link(fun hello:main/0)}.

stop(_State) ->
    ok.
