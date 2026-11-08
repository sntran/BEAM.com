%% The next version of reload_server (check.sh): its state is a map.
%% upgrade/reload.appup tells beam.com to call code_change/3, which turns
%% the count of the version before into the map.
-module(reload_server).
-behaviour(gen_server).
-export([start_link/0, hello/0]).
-export([init/1, handle_call/3, handle_cast/2, code_change/3]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, #{count => 0}, []).

hello() ->
    gen_server:call(?MODULE, hello).

init(State) ->
    {ok, State}.

handle_call(hello, _From, #{count := Count} = State) ->
    {reply, {reload_text:version(), Count + 1}, State#{count := Count + 1}}.

handle_cast(_Msg, State) ->
    {noreply, State}.

code_change(_OldVsn, Count, Extra) when is_integer(Count) ->
    {ok, #{count => Count, extra => Extra}}.
