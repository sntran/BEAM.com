%% The program of examples/reload: a counter (reload_server), a process
%% with a loop of local calls (reload_loop), and a TCP server on
%% 127.0.0.1:RELOAD_PORT that answers one command on each line. See
%% README.md.
-module(reload_app).
-behaviour(application).
-export([start/2, stop/1, accept/1]).

start(_Type, _Args) ->
    Port = list_to_integer(os:getenv("RELOAD_PORT", "18461")),
    {ok, Listen} = gen_tcp:listen(Port, [binary, {packet, line}, {active, false},
                                         {ip, {127, 0, 0, 1}}, {reuseaddr, true}]),
    {ok, Server} = reload_server:start_link(),
    reload_loop:start(),
    spawn(?MODULE, accept, [Listen]),
    {ok, Server}.

stop(_State) ->
    ok.

accept(Listen) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    spawn(?MODULE, accept, [Listen]),
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, Line} ->
            Answer = command(string:trim(Line)),
            gen_tcp:send(Socket, [Answer, "\n"]);
        {error, _} ->
            ok
    end,
    gen_tcp:close(Socket).

%% hello: the version of reload_text and the count, which stays in the
%% state of reload_server. loop: the version of the code that reload_loop
%% runs. move: reload_loop calls the current code. status: the state of
%% the reload of beam.com.
command(<<"hello">>) ->
    {Version, Count} = reload_server:hello(),
    io_lib:format("~ts ~w", [Version, Count]);
command(<<"loop">>) ->
    io_lib:format("loop ~w", [reload_loop:version()]);
command(<<"move">>) ->
    reload_loop:move(),
    "moved";
command(<<"status">>) ->
    case whereis(beam_com_reload) of
        undefined -> "no reload";
        _ -> io_lib:format("~w", [beam_com_reload:status()])
    end;
command(Other) ->
    io_lib:format("unknown ~ts", [Other]).
