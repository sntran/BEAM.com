%% A counter in a registered process. The release of this application
%% has a node name (config/vm.args), so "counter.com remote" opens a
%% shell in the running node:
%%
%%   beam.com examples/counter -o counter.com
%%   ./counter.com &
%%   ./counter.com remote
%%   (counter@host)1> counter:incr().
-module(counter).
-behaviour(gen_server).
-export([start_link/0, incr/0, value/0]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, 0, []).

incr() -> gen_server:call(?MODULE, incr).
value() -> gen_server:call(?MODULE, value).

init(N) -> {ok, N}.

handle_call(incr, _From, N) -> {reply, N + 1, N + 1};
handle_call(value, _From, N) -> {reply, N, N}.

handle_cast(_Msg, N) -> {noreply, N}.
