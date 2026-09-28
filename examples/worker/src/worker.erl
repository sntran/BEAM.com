%% A Cowboy server that runs natively and on Cloudflare Workers: "/" gives
%% a text with a count of the requests of this VM, and "/ws" is a WebSocket
%% that sends each message back. It listens on PORT (default 4000).
%%
%%   beam.com examples/worker                                # natively
%%   beam.com examples/worker -o worker --target wasm32      # the Workers
%%   workerd serve worker/worker.capnp                       # http://127.0.0.1:8789/
-module(worker).
-behaviour(application).
-export([start/2, stop/1, init/2, websocket_handle/2, websocket_info/2]).

start(_Type, _Args) ->
    Port = list_to_integer(os:getenv("PORT", "4000")),
    Dispatch = cowboy_router:compile([{'_', [{"/", ?MODULE, page}, {"/ws", ?MODULE, ws}]}]),
    {ok, _} = cowboy:start_clear(worker_http, [{port, Port}], #{env => #{dispatch => Dispatch}}),
    persistent_term:put(worker_count, counters:new(1, [])),
    {ok, self()}.

stop(_State) ->
    ok.

init(Req, page) ->
    Count = persistent_term:get(worker_count),
    counters:add(Count, 1, 1),
    Body = io_lib:format("Hello from Erlang/OTP ~s on ~s: request ~b of this VM~n",
                         [erlang:system_info(otp_release),
                          erlang:system_info(system_architecture),
                          counters:get(Count, 1)]),
    {ok, cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain">>}, Body, Req), page};
init(Req, ws) ->
    {cowboy_websocket, Req, ws}.

websocket_handle({text, Text}, State) -> {[{text, Text}], State};
websocket_handle(_Frame, State) -> {[], State}.

websocket_info(_Info, State) -> {[], State}.
