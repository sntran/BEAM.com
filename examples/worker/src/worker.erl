%% The Erlang shell on the web, from one Cowboy app that runs natively, on
%% Cloudflare Workers, on Deno Deploy and in a web page. "/" is the page
%% (priv/index.html), "/ws" is the WebSocket of a session, and "/hello"
%% is a text with a count of the requests of this VM. It listens on PORT
%% (default 4000).
%%
%%   beam.com examples/worker                                # natively
%%   beam.com examples/worker -o worker --target wasm32      # the output
%%   cd worker && wrangler dev                               # Workers
%%   cd worker && deno serve -A deno.js                      # Deno
%%
%% Caution: the REPL runs the code of each visitor in the VM, with the
%% network of the host. Give the VM no secret.
%%
%% Each WebSocket is a session of the Erlang shell (worker_shell): the
%% shell of stdlib, as a restricted shell. The messages are JSON. The page
%% sends {"input": LINE} or {"interrupt": true}. The server sends
%% {"hello": FACTS} once, then {"output": TEXT} for the output of the
%% shell, and {"prompt": TEXT} when the shell waits for a line.
-module(worker).
-behaviour(application).
-export([start/2, stop/1, init/2, websocket_init/1, websocket_handle/2, websocket_info/2,
         terminate/3]).

start(_Type, _Args) ->
    %% The shells of the sessions refuse q(), halt() and init:stop().
    application:set_env(stdlib, restricted_shell, worker_shell),
    Port = list_to_integer(os:getenv("PORT", "4000")),
    Dispatch = cowboy_router:compile(
                 [{'_', [{"/", cowboy_static, {priv_file, worker, "index.html"}},
                         {"/hello", ?MODULE, hello},
                         {"/ws", ?MODULE, ws}]}]),
    {ok, _} = cowboy:start_clear(worker_http, [{port, Port}], #{env => #{dispatch => Dispatch}}),
    persistent_term:put(worker_count, counters:new(1, [])),
    {ok, self()}.

stop(_State) ->
    ok.

init(Req, hello) ->
    Count = persistent_term:get(worker_count),
    counters:add(Count, 1, 1),
    Body = io_lib:format("Hello from Erlang/OTP ~s on ~s: request ~b of this VM~n",
                         [erlang:system_info(otp_release),
                          erlang:system_info(system_architecture),
                          counters:get(Count, 1)]),
    {ok, cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain">>}, Body, Req), hello};
init(Req, ws) ->
    {cowboy_websocket, Req, none, #{idle_timeout => 600000, max_frame_size => 65536}}.

websocket_init(none) ->
    Facts = #{otp => list_to_binary(erlang:system_info(otp_release)),
              arch => list_to_binary(erlang:system_info(system_architecture)),
              host => list_to_binary(os:getenv("BEAM_HOST", "native")),
              processes => erlang:system_info(process_count)},
    {[frame(#{hello => Facts})], worker_shell:start()}.

websocket_handle({text, Text}, Session) ->
    try json:decode(Text) of
        #{<<"input">> := Line} when is_binary(Line) -> worker_shell:input(Session, Line);
        #{<<"interrupt">> := true} -> worker_shell:interrupt(Session);
        _ -> ok
    catch
        _:_ -> ok
    end,
    {[], Session};
websocket_handle(_Frame, Session) ->
    {[], Session}.

websocket_info({shell, Session, {output, Text}}, Session) ->
    {[frame(#{output => Text})], Session};
websocket_info({shell, Session, {prompt, Text}}, Session) ->
    {[frame(#{prompt => Text})], Session};
websocket_info({shell, Session, down}, Session) ->
    {[{close, 1000, <<"the shell stopped">>}], Session};
websocket_info(_Info, Session) ->
    {[], Session}.

terminate(_Reason, _Req, _Session) ->
    ok.

frame(Map) ->
    {text, json:encode(Map)}.
