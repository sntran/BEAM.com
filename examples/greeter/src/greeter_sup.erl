-module(greeter_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Server = #{id => greeter_server,
               start => {greeter_server, start_link, []}},
    {ok, {#{strategy => one_for_one}, [Server]}}.
