%% The commands of beam.com. beam_com.c starts this module with
%% "-run beam_com main" when the first argument is a command:
%%
%%   beam.com build INPUT [-o OUTPUT] [-a APP]...
-module(beam_com).

-export([main/0]).

-ifdef(TEST).
-export([command/1, build_options/2]).
-endif.

main() ->
    Status = try command(init:get_plain_arguments()) of
                 ok -> 0
             catch
                 throw:{error, Format, Args} ->
                     io:format(standard_error, "beam.com: " ++ Format ++ "~n",
                               Args),
                     1
             end,
    erlang:halt(Status).

command(["build" | Args]) ->
    beam_com_build:run(build_options(Args, #{apps => []}));
command(_) ->
    usage().

build_options([], #{input := _} = Opts) ->
    Opts;
build_options([], _Opts) ->
    usage();
build_options(["-o", Output | Rest], Opts) ->
    build_options(Rest, Opts#{output => Output});
build_options(["-a", App | Rest], #{apps := Apps} = Opts) ->
    build_options(Rest, Opts#{apps := Apps ++ [list_to_atom(App)]});
build_options([Option], _Opts) when Option =:= "-o"; Option =:= "-a" ->
    throw({error, "option ~ts needs a value", [Option]});
build_options([[$- | _] = Option | _], _Opts) ->
    throw({error, "unknown option ~ts", [Option]});
build_options([Input | Rest], Opts) when not is_map_key(input, Opts) ->
    build_options(Rest, Opts#{input => Input});
build_options(_, _Opts) ->
    usage().

usage() ->
    throw({error,
           "usage: beam.com build INPUT [-o OUTPUT] [-a APP]...~n"
           "  INPUT   a .erl file with main/1, or an application directory~n"
           "  OUTPUT  the new executable (default: the name of INPUT.com)~n"
           "  APP     an OTP application to add (for calls that the~n"
           "          builder cannot see, such as apply/3)", []}).
