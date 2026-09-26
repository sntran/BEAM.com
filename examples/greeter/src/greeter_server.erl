%% Greets a few times with a timer, then stops the node.
-module(greeter_server).
-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, Name} = application:get_env(greeter, name),
    {ok, Count} = application:get_env(greeter, count),
    {ok, Vsn} = application:get_key(greeter, vsn),
    io:format("greeter ~s: started under ~p~n", [Vsn, greeter_sup]),
    erlang:send_after(10, self(), tick),
    {ok, #{name => Name, left => Count, seen => 0}}.

handle_info(tick, #{left := 0, seen := Seen} = State) ->
    io:format("greeter: said hello ~p times; os ~p; stopping~n",
              [Seen, os:type()]),
    init:stop(),
    {noreply, State};
handle_info(tick, #{name := Name, left := Left, seen := Seen} = State) ->
    io:format("greeter: Hello, ~s! (~p)~n", [Name, Seen + 1]),
    erlang:send_after(10, self(), tick),
    {noreply, State#{left := Left - 1, seen := Seen + 1}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
