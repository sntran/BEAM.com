%% An example application for "beam.com build" with Hex packages (see
%% rebar.config): it starts a cowboy server on 127.0.0.1, gets "/" with
%% httpc, and decodes the JSON answer with jsx.
%%
%%   beam.com build examples/hexweb
%%   ./hexweb.com
-module(hexweb).
-export([main/0, init/2]).

main() ->
    Dispatch = cowboy_router:compile([{'_', [{"/", ?MODULE, []}]}]),
    {ok, _} = cowboy:start_clear(hexweb_http, [{ip, {127, 0, 0, 1}}, {port, 0}],
                                 #{env => #{dispatch => Dispatch}}),
    Port = ranch:get_port(hexweb_http),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/",
    {ok, {{_, 200, _}, Headers, Body}} = httpc:request(get, {Url, []}, [], [{body_format, binary}]),
    io:format("hexweb: content-type ~s~n", [proplists:get_value("content-type", Headers)]),
    io:format("hexweb: ~s~n", [Body]),
    #{<<"hello">> := Hello, <<"apps">> := Apps} = jsx:decode(Body),
    io:format("hexweb: hello ~s; ~s~n", [Hello, lists:join(" ", Apps)]),
    init:stop().

%% The cowboy handler of "/": JSON with the versions of the packages.
init(Req, State) ->
    Apps = [iolist_to_binary([atom_to_list(A), "-", V])
            || {A, _, V} <- lists:sort(application:loaded_applications()),
               lists:member(A, [cowboy, cowlib, ranch, jsx])],
    Body = jsx:encode(#{<<"hello">> => <<"BEAM.com">>, <<"apps">> => Apps}),
    {ok, cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, Body, Req), State}.
