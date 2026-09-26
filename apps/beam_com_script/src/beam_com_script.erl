%% Runs a program that "beam.com build" made from one .erl file.
%%
%% The application of the program has {mod, {beam_com_script, Module}}.
%% When the release has started, Module:main/1 gets the command line
%% arguments, as with escript. The program halts with status 0 when
%% main/1 returns, and with status 127 on an exception.
-module(beam_com_script).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, Module) ->
    {ok, spawn(fun() -> run(Module) end)}.

stop(_State) ->
    ok.

run(Module) ->
    wait_for_boot(),
    Status = try Module:main(init:get_plain_arguments()) of
                 _ -> 0
             catch
                 Class:Reason:Stack ->
                     Error = erl_error:format_exception(Class, Reason, Stack),
                     io:put_chars(standard_error,
                                  ["beam.com: ", Error, "\n"]),
                     127
             end,
    erlang:halt(Status).

wait_for_boot() ->
    case init:get_status() of
        {started, _} ->
            ok;
        _ ->
            receive after 10 -> wait_for_boot() end
    end.
