%% The commands of beam.com. beam.com starts this module with
%% "-run beam_com main" when its zip has no release, and for "build":
%%
%%   beam.com [help [COMMAND]]
%%   beam.com version
%%   beam.com build INPUT [-o OUTPUT] [-a APP]...
-module(beam_com).

-export([main/0]).

-ifdef(TEST).
-export([command/1, build_options/2, help/1, version/0]).
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

command([]) ->
    io:put_chars(help([]));
command([Help | Rest]) when Help =:= "help"; Help =:= "--help"; Help =:= "-h" ->
    io:put_chars(help(Rest));
command([Version]) when Version =:= "version"; Version =:= "--version" ->
    io:put_chars(version());
command(["version" | _]) ->
    throw({error, "usage: beam.com version", []});
command(["build" | Args]) ->
    beam_com_build:run(build_options(Args, #{apps => []}));
command([Command | _]) ->
    throw({error, "unknown command ~ts (see beam.com help)", [Command]}).

build_options([], #{input := _} = Opts) ->
    Opts;
build_options([], _Opts) ->
    usage();
build_options(["-o", Output | Rest], Opts) ->
    build_options(Rest, Opts#{output => Output});
build_options(["-a", App | Rest], #{apps := Apps} = Opts) ->
    build_options(Rest, Opts#{apps := Apps ++ [list_to_atom(App)]});
build_options(["--pledge", Promises | Rest], Opts) ->
    build_options(Rest, Opts#{pledge => beam_com_build:check_promises(Promises)});
build_options(["--unveil", Rule | Rest], Opts) ->
    Rules = maps:get(unveil, Opts, []),
    build_options(Rest, Opts#{unveil => Rules ++ [beam_com_build:check_unveil(Rule)]});
build_options(["--native", Target | Rest], Opts) ->
    build_options(Rest, Opts#{native => beam_com_build:check_native(Target)});
build_options([Option], _Opts) when Option =:= "-o"; Option =:= "-a";
                                    Option =:= "--pledge"; Option =:= "--unveil";
                                    Option =:= "--native" ->
    throw({error, "option ~ts needs a value", [Option]});
build_options([[$- | _] = Option | _], _Opts) ->
    throw({error, "unknown option ~ts", [Option]});
build_options([Input | Rest], Opts) when not is_map_key(input, Opts) ->
    build_options(Rest, Opts#{input => Input});
build_options(_, _Opts) ->
    usage().

usage() ->
    throw({error, "usage: " ++ build_usage(), []}).

build_usage() ->
    "beam.com build INPUT [-o OUTPUT] [-a APP]... [--pledge PROMISES]~n"
    "               [--unveil \"PERMISSIONS PATH\"]... [--native TARGET]~n"
    "  INPUT     a .erl file with main/1, or an application directory~n"
    "  OUTPUT    the new executable (default: the name of INPUT.com)~n"
    "  APP       an OTP application to add (for calls that the~n"
    "            builder cannot see, such as apply/3)~n"
    "  PROMISES  the system calls that the program keeps (Linux and~n"
    "            OpenBSD), such as \"inet dns\"; \"stdio rpath\" are always~n"
    "            added~n"
    "  PATH      a file or directory that the program can use (Linux and~n"
    "            OpenBSD), with PERMISSIONS of r, w, x and c; other paths~n"
    "            are hidden~n"
    "  TARGET    a native file for one system, not an APE file:~n"
    "            linux-x86_64, linux-aarch64, freebsd-x86_64 or~n"
    "            macos-x86_64".

%% The text of "beam.com help [COMMAND]".
help([]) ->
    ["BEAM.com: Erlang/OTP ", otp_version(), " in one executable file, for Linux,\n"
     "macOS, Windows and the BSDs, on x86_64 and aarch64.\n"
     "\n"
     "usage: beam.com COMMAND [ARGUMENTS]\n"
     "\n"
     "Commands:\n"
     "  build INPUT [-o OUTPUT] [-a APP]...\n"
     "                  make an executable from a .erl file with main/1, or\n"
     "                  from an application directory\n"
     "  version         show the versions, the emulator and the platform\n"
     "  help [COMMAND]  show this text, or the help of a command\n"
     "\n"
     "To run an OTP release, add it to the zip of a copy of beam.com.\n"
     "More: https://github.com/sntran/BEAM.com\n"];
help(["build"]) ->
    ["usage: ", io_lib:format(build_usage(), []), "\n"
     "\n"
     "The new executable has the compiled code, an OTP release with the\n"
     "applications that the code needs, and the runtime of beam.com.\n"
     "\n"
     "Promises: stdio rpath wpath cpath dpath flock fattr inet anet unix\n"
     "dns tty recvfd sendfd proc exec id unveil settime prot_exec vminfo\n"
     "tmppath chown. A forbidden system call returns an error (EPERM) on\n"
     "Linux; OpenBSD stops the program. The other systems ignore them.\n"];
help(["version"]) ->
    "usage: beam.com version\n"
    "\n"
    "Shows the versions of Erlang/OTP and ERTS, the emulator, the\n"
    "platform, and the applications in the zip of beam.com.\n";
help(["help"]) ->
    "usage: beam.com help [COMMAND]\n";
help([Command | _]) ->
    throw({error, "unknown command ~ts (see beam.com help)", [Command]}).

%% The text of "beam.com version".
version() ->
    _ = application:load(beam_com),
    {Family, Name} = os:type(),
    Apps = lists:sort([{atom_to_list(A), V}
                       || {A, _, V} <- application:loaded_applications()] ++
                      zip_apps()),
    ["beam.com ", vsn(), "\n",
     io_lib:format("  Erlang/OTP  : ~ts~n", [otp_version()]),
     io_lib:format("  ERTS        : ~ts~n", [erlang:system_info(version)]),
     io_lib:format("  Emulator    : ~ts~n", [erlang:system_info(emu_flavor)]),
     io_lib:format("  OS type     : ~p/~p~n", [Family, Name]),
     io_lib:format("  Architecture: ~ts~n", [erlang:system_info(system_architecture)]),
     io_lib:format("  Schedulers  : ~p~n", [erlang:system_info(schedulers)]),
     io_lib:format("  Applications: ~ts~n",
                   [lists:join(" ", [[A, "-", V] || {A, V} <- lists:usort(Apps)])])].

vsn() ->
    case application:get_key(beam_com, vsn) of
        {ok, Vsn} -> Vsn;
        undefined -> "(unknown version)"
    end.

%% The full OTP version (29.1.1), which build.sh writes into the .app
%% file. erlang:system_info(otp_release) gives only the major version.
otp_version() ->
    _ = application:load(beam_com),
    case application:get_env(beam_com, otp_version) of
        {ok, Vsn} when Vsn =/= "" -> Vsn;
        _ -> erlang:system_info(otp_release)
    end.

%% The applications in the lib directory ("name-vsn"), also the ones that
%% are not loaded.
zip_apps() ->
    Lib = code:lib_dir(),
    [list_to_tuple(string:split(D, "-", trailing))
     || D <- filelib:wildcard("*-*", Lib),
        filelib:is_dir(filename:join(Lib, D))].
