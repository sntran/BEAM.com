%% A counter in a gen_server. Its state stays when its code or the code of
%% reload_text changes.
-module(reload_server).
-behaviour(gen_server).
-export([start_link/0, hello/0]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, 0, []).

hello() ->
    gen_server:call(?MODULE, hello).

init(Count) ->
    {ok, Count}.

%% upgrade/reload_server.erl is the next version: its state is a map.
handle_call(hello, _From, Count) ->
    {reply, {reload_text:version(), Count + 1}, Count + 1}.

handle_cast(_Msg, Count) ->
    {noreply, Count}.
