-module(crypto_check_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, spawn_link(fun crypto_check:main/0)}.

stop(_State) ->
    ok.
