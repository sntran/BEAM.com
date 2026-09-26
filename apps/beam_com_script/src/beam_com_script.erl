%% Runs a program that "beam.com build" made from one .erl file (or one
%% Elixir file).
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
    Elixir = lists:prefix("Elixir.", atom_to_list(Module)),
    Args = case Elixir of
               %% Elixir programs get binaries, as from System.argv/0.
               true -> [unicode:characters_to_binary(A) || A <- init:get_plain_arguments()];
               false -> init:get_plain_arguments()
           end,
    Status = try Module:main(Args) of
                 _ -> 0
             catch
                 Class:Reason:Stack ->
                     io:put_chars(standard_error,
                                  ["beam.com: ", format(Elixir, Class, Reason, Stack), "\n"]),
                     127
             end,
    erlang:halt(Status).

format(true, Class, Reason, Stack) ->
    'Elixir.Exception':format(Class, Reason, Stack);
format(false, Class, Reason, Stack) ->
    erl_error:format_exception(Class, Reason, Stack).

wait_for_boot() ->
    case init:get_status() of
        {started, _} ->
            ok;
        _ ->
            receive after 10 -> wait_for_boot() end
    end.
