%% Hello world for BEAM.com.
%%
%% The .args file in the executable runs `-s hello main`, so this
%% module is the program. It prints a greeting and some facts about
%% the host, then stops the runtime.
-module(hello).
-export([main/0]).

main() ->
    {Family, Name} = os:type(),
    io:format("Hello, World! from BEAM.com~n"),
    io:format("  OTP release : ~s~n", [erlang:system_info(otp_release)]),
    io:format("  ERTS version: ~s~n", [erlang:system_info(version)]),
    io:format("  OS type     : ~p/~p~n", [Family, Name]),
    io:format("  Architecture: ~s~n", [erlang:system_info(system_architecture)]),
    io:format("  Schedulers  : ~p~n", [erlang:system_info(schedulers)]),
    io:format("  Arguments   : ~p~n", [init:get_plain_arguments()]),
    erlang:halt(0).
