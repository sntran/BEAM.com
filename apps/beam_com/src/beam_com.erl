%% The commands of beam.com. The file starts this module with "-run beam_com main" when its zip has no
%% release, and for "build":
%%
%%   beam.com [help [COMMAND]]
%%   beam.com version
%%   beam.com build INPUT [-o OUTPUT] [-a APP]...
-module(beam_com).

-export([main/0, name/0]).

-ifdef(TEST).
-export([command/1, build_options/2, help/1, version/0, name/1]).
-endif.

main() ->
    Status = try command(init:get_plain_arguments()) of
                 ok -> 0
             catch
                 throw:{error, Format, Args} ->
                     io:format(standard_error, "~ts: " ++ Format ++ "~n",
                               [name() | Args]),
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
    throw({error, "usage: ~ts version", [name()]});
command(["build" | Args]) ->
    beam_com_build:run(build_options(Args, #{apps => []}));
command([Command | _]) ->
    throw({error, "unknown command ~ts (see ~ts help)", [Command, name()]}).

%% The name of this file for the messages: beam.com, beam-emu.com, or
%% the name of a copy (also a copy named beam.exe on Windows).
name() ->
    case init:get_argument(beam_com_exe) of
        {ok, [[Exe | _] | _]} -> name(Exe);
        _ -> "beam.com"
    end.

%% The path can have backslashes on Windows, where os:type() is unix.
name(Exe) ->
    filename:rootname(lists:last(string:lexemes(Exe, "/\\"))) ++ ".com".

elixir_version() ->
    case lists:keyfind("elixir", 1, zip_apps()) of
        {_, Vsn} -> Vsn;
        false -> none
    end.

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
build_options(["--main", Module | Rest], Opts) ->
    build_options(Rest, Opts#{main => list_to_atom(Module)});
build_options(["--tool", Tool | Rest], Opts) when Tool =:= "rebar"; Tool =:= "mix" ->
    build_options(Rest, Opts#{tool => list_to_atom(Tool)});
build_options(["--tool", Tool | _], _Opts) ->
    throw({error, "--tool is rebar or mix, not ~ts", [Tool]});
build_options(["--extract-priv", App | Rest], Opts) ->
    build_options(Rest, Opts#{extract_priv => maps:get(extract_priv, Opts, []) ++ [list_to_atom(App)]});
build_options(["--target", Target | Rest], Opts) ->
    build_options(Rest, Opts#{target => beam_com_build:check_target(Target)});
build_options([Option], _Opts) when Option =:= "-o"; Option =:= "-a";
                                    Option =:= "--pledge"; Option =:= "--unveil";
                                    Option =:= "--target"; Option =:= "--main";
                                    Option =:= "--tool"; Option =:= "--extract-priv" ->
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
    Name = name(),
    Pad = lists:duplicate(length(Name) + 7, $\s),
    Name ++ " build INPUT [-o OUTPUT] [-a APP]... [--pledge PROMISES]~n" ++
    Pad ++ "[--unveil \"PERMISSIONS PATH\"]... [--target TARGET]~n" ++
    Pad ++ "[--main MODULE] [--tool rebar|mix] [--extract-priv APP]...~n"
    "  INPUT     a .erl, .ex or .exs file with main/1, or an application~n"
    "            directory (rebar3 or Mix)~n"
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
    "            x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu,~n"
    "            x86_64-unknown-freebsd or x86_64-apple-darwin (also~n"
    "            x86_64-linux, aarch64-linux, x86_64-freebsd, x86_64-macos)~n"
    "  MODULE    for an application: the module whose main/1 runs, with~n"
    "            the arguments, after the start (as an escript); found in~n"
    "            rebar.config (escript) or mix.exs (:escript) when not given~n"
    "  --extract-priv  an application whose priv files are copied to real~n"
    "            files at the first start (for other programs that read~n"
    "            them); automatic when priv has an executable file~n"
    "  --tool    the layout of a directory with both rebar.config and~n"
    "            mix.exs (default: rebar)".

%% The text of "beam.com help [COMMAND]".
help([]) ->
    Name = name(),
    {Runtime, Inputs, Tools} =
        case elixir_version() of
            none -> {[], "a .erl file with main/1, or\n"
                         "                  from an application directory\n", []};
            Elixir -> {[" and Elixir ", Elixir],
                       "a .erl, .ex or .exs file with\n"
                       "                  main/1, or from an application directory\n"
                       "                  (rebar3 or Mix)\n",
                       ["  mix, iex, elixir, elixirc [ARGUMENTS]\n"
                        "                  the tools of Elixir, as with an Elixir\n"
                        "                  installation (\"", Name, " mix test\")\n"]}
        end,
    ["BEAM.com: Erlang/OTP ", otp_version(), Runtime, " in one executable file, for\n"
     "Linux, macOS, Windows and the BSDs, on x86_64 and aarch64.\n"
     "\n"
     "usage: ", Name, " COMMAND [ARGUMENTS]\n"
     "\n"
     "Commands:\n"
     "  build INPUT [-o OUTPUT] [-a APP]...\n"
     "                  make an executable from ", Inputs,
     "  escript FILE [ARGUMENTS]\n"
     "                  run an escript\n",
     Tools,
     "  version         show the versions, the emulator and the platform\n"
     "  help [COMMAND]  show this text, or the help of a command\n"
     "\n"
     "A copy of this file or a link to it with the name of a tool (escript",
     case Tools of [] -> ""; _ -> ",\nmix, iex, elixir, elixirc; also mix.com, iex.com, ..." end,
     ") runs that tool.\n"
     "To run an OTP release, add it to the zip of a copy of ", Name, ".\n"
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
    ["usage: ", name(), " version\n"
     "\n"
     "Shows the versions of Erlang/OTP, ERTS and Elixir, the emulator, the\n"
     "platform, and the applications in the zip of ", name(), ".\n"];
help(["help"]) ->
    ["usage: ", name(), " help [COMMAND]\n"];
help([Command | _]) ->
    throw({error, "unknown command ~ts (see ~ts help)", [Command, name()]}).

%% The text of "beam.com version".
version() ->
    _ = application:load(beam_com),
    {Family, Name} = os:type(),
    Apps = lists:sort([{atom_to_list(A), V}
                       || {A, _, V} <- application:loaded_applications()] ++
                      zip_apps()),
    [name(), " ", vsn(), "\n",
     io_lib:format("  Erlang/OTP  : ~ts~n", [otp_version()]),
     case elixir_version() of
         none -> [];
         Elixir -> io_lib:format("  Elixir      : ~ts~n", [Elixir])
     end,
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
