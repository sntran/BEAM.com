%% Hello world for BEAM.com.
%%
%% This module is the program of the hello release. It prints a greeting
%% and some facts about the host, then stops the runtime.
-module(hello).
-export([main/0]).

main() ->
    {Family, Name} = os:type(),
    {ok, Greeting} = application:get_env(hello, greeting),
    io:format("~s~n", [Greeting]),
    io:format("  OTP release : ~s~n", [erlang:system_info(otp_release)]),
    io:format("  ERTS version: ~s~n", [erlang:system_info(version)]),
    io:format("  OS type     : ~p/~p~n", [Family, Name]),
    io:format("  Architecture: ~s~n", [erlang:system_info(system_architecture)]),
    io:format("  Emulator    : ~s~n", [erlang:system_info(emu_flavor)]),
    io:format("  Schedulers  : ~p~n", [erlang:system_info(schedulers)]),
    io:format("  Release     : ~p~n", [release()]),
    io:format("  Arguments   : ~p~n", [init:get_plain_arguments()]),
    erlang:halt(0).

release() ->
    case init:get_argument(boot) of
        {ok, [[Boot]]} -> Boot;
        _ -> none
    end.
