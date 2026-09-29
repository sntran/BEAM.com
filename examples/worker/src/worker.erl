%% An Erlang REPL on the web, from one Cowboy app that runs natively, on
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
%% The messages of the WebSocket are JSON. The page sends {"eval": TEXT}
%% or {"interrupt": true}. The server sends {"hello": FACTS} once, then
%% {"output": TEXT} for the output of io, and {"value": TEXT} or
%% {"error": TEXT} at the end of each evaluation.
-module(worker).
-behaviour(application).
-export([start/2, stop/1, init/2, websocket_init/1, websocket_handle/2, websocket_info/2,
         terminate/3]).

start(_Type, _Args) ->
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
    {cowboy_websocket, Req, #{bindings => erl_eval:new_bindings(), running => none},
     #{idle_timeout => 600000, max_frame_size => 65536}}.

websocket_init(State) ->
    Facts = #{otp => list_to_binary(erlang:system_info(otp_release)),
              arch => list_to_binary(erlang:system_info(system_architecture)),
              host => list_to_binary(os:getenv("BEAM_HOST", "native")),
              processes => erlang:system_info(process_count)},
    {[frame(#{hello => Facts})], State}.

websocket_handle({text, Text}, State) ->
    try json:decode(Text) of
        #{<<"eval">> := Source} when is_binary(Source) -> eval(Source, State);
        #{<<"interrupt">> := true} -> interrupt(State);
        _ -> {[frame(#{error => <<"** unknown message\n">>})], State}
    catch
        _:_ -> {[frame(#{error => <<"** not JSON\n">>})], State}
    end;
websocket_handle(_Frame, State) ->
    {[], State}.

eval(_Source, #{running := {_, _}} = State) ->
    {[frame(#{error => <<"** an evaluation runs: wait, or interrupt it\n">>})], State};
eval(Source, #{bindings := Bindings} = State) ->
    case worker_repl:parse(Source) of
        {ok, Exprs} ->
            Ref = make_ref(),
            Pid = worker_repl:start(Ref, Exprs, Bindings),
            {[], State#{running := {Ref, Pid}}};
        {error, Message} ->
            {[frame(#{error => Message})], State}
    end.

interrupt(#{running := {Ref, Pid}} = State) ->
    Pid ! {Ref, interrupt},
    {[], State};
interrupt(State) ->
    {[], State}.

websocket_info({Ref, output, Text}, #{running := {Ref, _}} = State) ->
    {[frame(#{output => Text})], State};
websocket_info({Ref, result, {value, Text, Bindings}}, #{running := {Ref, _}} = State) ->
    {[frame(#{value => Text})], State#{bindings := Bindings, running := none}};
websocket_info({Ref, result, {error, Text, Bindings}}, #{running := {Ref, _}} = State) ->
    {[frame(#{error => Text})], State#{bindings := Bindings, running := none}};
websocket_info(_Info, State) ->
    {[], State}.

terminate(_Reason, _Req, #{running := {Ref, Pid}}) ->
    Pid ! {Ref, interrupt},
    ok;
terminate(_Reason, _Req, _State) ->
    ok.

frame(Map) ->
    {text, json:encode(Map)}.
