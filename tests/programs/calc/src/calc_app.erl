-module(calc_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, spawn_link(fun calc:main/0)}.

stop(_State) ->
    ok.
