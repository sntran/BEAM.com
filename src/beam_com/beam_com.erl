%% The command line of beam.com. The file starts this module with
%% "-run beam_com main" when its zip has no release:
%%
%%   beam.com [FLAGS] [INPUT] [-- ARGUMENTS]   run INPUT (default: the
%%                                             project in this directory)
%%   beam.com [FLAGS] INPUT -o OUTPUT          make an executable of INPUT
%%   beam.com --help | --version
-module(beam_com).

-export([main/0, name/0, cache_dir/0, vsn/0, otp_version/0]).

-ifdef(TEST).
-export([command/1, build_options/2, help/1, version/0, name/1, run_file/2,
         is_project/1, nif_include/0]).
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

command([Help | _]) when Help =:= "--help"; Help =:= "-h" ->
    io:put_chars(help([]));
command(["--version"]) ->
    io:put_chars(version());
command(["--version" | _]) ->
    throw({error, "usage: ~ts --version", [name()]});
command(["--nif-include"]) ->
    io:put_chars([nif_include(), $\n]);
command(["--nif-include" | _]) ->
    throw({error, "usage: ~ts --nif-include", [name()]});
command(["--nif-modules", App, Dir]) ->
    beam_com_wasm:nif_modules(App, Dir);
command(["--nif-modules" | _]) ->
    throw({error, "usage: ~ts --nif-modules APP.com DIR", [name()]});
command([]) ->
    case is_project(".") of
        true -> run(#{input => ".", apps => [], args => []});
        false -> io:put_chars(help([]))
    end;
command(Args) ->
    Opts = build_options(Args, #{apps => []}),
    case Opts of
        #{output := _} -> beam_com_build:run(Opts);
        _ -> run(Opts)
    end.

%% The directory with the headers of a NIF library in WebAssembly
%% (docs/NIFS.md): a copy of priv/include of the wasm application in the
%% cache, for each version of OTP. A file that differs is written again.
nif_include() ->
    Src = case code:priv_dir(wasm) of
              {error, _} -> throw({error, "~ts has no WebAssembly runtime (a build with WASM=0)", [name()]});
              Priv -> filename:join(Priv, "include")
          end,
    Dir = filename:join(cache_dir(), "nif-include-" ++ otp_version()),
    ok = filelib:ensure_path(Dir),
    {ok, Names} = file:list_dir(Src),
    [ok = copy_if_new(filename:join(Src, N), filename:join(Dir, N)) || N <- Names],
    Dir.

copy_if_new(From, To) ->
    {ok, Bin} = file:read_file(From),
    case file:read_file(To) of
        {ok, Bin} -> ok;
        _ -> file:write_file(To, Bin)
    end.

%% A directory with a project of rebar3 or Mix, or an application (src/).
is_project(Dir) ->
    lists:any(fun(F) -> filelib:is_file(filename:join(Dir, F)) end,
              ["mix.exs", "rebar.config", "src"]).

%% Run INPUT: the executable that "-o" would make, in the cache of
%% BEAM.com (made again when a file of INPUT or this file is newer). This
%% process ends, and beam_com.c replaces it with the executable (execv,
%% at exit; the path in the file BEAM_COM_RUN_FILE), with the arguments
%% after "--": the program gets the terminal, and its exit status is the
%% one of beam.com.
run(#{target := _}) ->
    throw({error, "--target makes a file for another system: use it with -o", []});
run(#{input := Input} = Opts) ->
    File = run_file(Input, maps:without([input, args], Opts)),
    case is_fresh(File, Input) of
        true -> ok;
        false ->
            ok = filelib:ensure_dir(File),
            beam_com_build:run(Opts#{output => File, quiet => true})
    end,
    %% beam_com.c runs File at exit (execv): it names the file for its path.
    case os:getenv("BEAM_COM_RUN_FILE") of
        false -> throw({error, "no BEAM_COM_RUN_FILE: run ~ts itself", [File]});
        Run -> ok = filelib:ensure_dir(Run), ok = file:write_file(Run, File)
    end,
    erlang:halt(0).

%% The file of INPUT in the cache: a name from the path of INPUT and the
%% options of the build (the sandbox, the applications).
run_file(Input, Opts) ->
    Abs = filename:absname(Input),
    Hash = binary:encode_hex(crypto:hash(sha256, term_to_binary({Abs, Opts})), lowercase),
    Name = filename:rootname(filename:basename(Abs)),
    filename:join([cache_dir(), "run", Name ++ "-" ++ binary_to_list(binary:part(Hash, 0, 12)) ++ ".com"]).

cache_dir() ->
    Env = fun(V) -> case os:getenv(V) of false -> ""; X -> X end end,
    case {Env("BEAM_COM_CACHE"), Env("XDG_CACHE_HOME"), Env("LOCALAPPDATA"), Env("HOME")} of
        {C, _, _, _} when C =/= "" -> C;
        {_, X, _, _} when X =/= "" -> filename:join(X, "beam.com");
        {_, _, L, _} when L =/= "" -> filename:join(L, "beam.com");
        {_, _, _, H} -> filename:join([H, ".cache", "beam.com"])
    end.

%% The file in the cache is newer than the files of INPUT (not _build,
%% deps, .git) and than this file.
is_fresh(File, Input) ->
    case filelib:last_modified(File) of
        0 -> false;
        T ->
            Self = case init:get_argument(beam_com_exe) of
                       {ok, [[Exe | _] | _]} -> filelib:last_modified(Exe);
                       _ -> 0
                   end,
            Self =< T andalso newest(Input) =< T
    end.

newest(Path) ->
    case filelib:is_dir(Path) of
        false -> filelib:last_modified(Path);
        true ->
            {ok, Names} = file:list_dir(Path),
            lists:max([filelib:last_modified(Path) |
                       [newest(filename:join(Path, N))
                        || N <- Names, not lists:member(N, ["_build", "deps", ".git", ".elixir_ls"])]])
    end.

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
build_options([], Opts) ->
    case is_project(".") of
        true -> Opts#{input => "."};
        false -> usage()
    end;
build_options(["--" | Args], Opts) ->
    build_options([], Opts#{args => Args});
build_options(["-o", Output | Rest], Opts) ->
    build_options(Rest, Opts#{output => Output});
build_options(["-a", App | Rest], #{apps := Apps} = Opts) ->
    build_options(Rest, Opts#{apps := Apps ++ [list_to_atom(App)]});
build_options([[$-, C] = Flag | Rest], Opts) when C =:= $R; C =:= $W; C =:= $N; C =:= $A ->
    build_options(Rest, Opts#{allow => beam_com_build:allow(Flag, maps:get(allow, Opts, #{}))});
build_options(["--allow-" ++ _ = Flag | Rest], Opts) ->
    build_options(Rest, Opts#{allow => beam_com_build:allow(Flag, maps:get(allow, Opts, #{}))});
build_options(["--deny-" ++ _ = Flag | _], _Opts) ->
    beam_com_build:allow(Flag, #{});
build_options(["--main", Module | Rest], Opts) ->
    build_options(Rest, Opts#{main => list_to_atom(Module)});
build_options(["--tool", Tool | Rest], Opts) when Tool =:= "rebar"; Tool =:= "mix" ->
    build_options(Rest, Opts#{tool => list_to_atom(Tool)});
build_options(["--tool", Tool | _], _Opts) ->
    throw({error, "--tool is rebar or mix, not ~ts", [Tool]});
build_options(["--extract-priv", App | Rest], Opts) ->
    build_options(Rest, Opts#{extract_priv => maps:get(extract_priv, Opts, []) ++ [list_to_atom(App)]});
build_options(["--no-edge" | Rest], Opts) ->
    build_options(Rest, Opts#{edge => false});
build_options(["--page" | Rest], Opts) ->
    build_options(Rest, Opts#{page => true});
build_options(["--cacerts", File | Rest], Opts) ->
    build_options(Rest, Opts#{cacerts => File});
build_options(["--target", Target | Rest], Opts) ->
    build_options(Rest, Opts#{target => beam_com_build:check_target(Target)});
build_options([Option], _Opts) when Option =:= "-o"; Option =:= "-a";
                                    Option =:= "--target"; Option =:= "--main";
                                    Option =:= "--tool"; Option =:= "--extract-priv";
                                    Option =:= "--cacerts" ->
    throw({error, "option ~ts needs a value", [Option]});
build_options([[$- | _] = Option | _], _Opts) ->
    throw({error, "unknown option ~ts", [Option]});
build_options([Input | Rest], Opts) when not is_map_key(input, Opts) ->
    old_command(Input),
    build_options(Rest, Opts#{input => Input});
build_options([Arg | _], #{input := Input}) ->
    %% "beam.com build app.erl" with a directory build: still the old command.
    is_old_command(Input) andalso old_hint(Input),
    throw({error, "~ts: the arguments of the program come after \"--\" (see ~ts --help)",
           [Arg, name()]}).

%% The commands before beam.com 0.2 (help, version and build): a hint,
%% when there is no file of that name.
old_command(Input) ->
    case is_old_command(Input) andalso not filelib:is_file(Input) of
        true -> old_hint(Input);
        false -> ok
    end.

is_old_command(Input) -> lists:member(Input, ["build", "help", "version"]).

old_hint(Input) ->
    New = #{"build" => "~ts INPUT -o OUTPUT", "help" => "~ts --help",
            "version" => "~ts --version"},
    throw({error, "there is no command ~ts: use \"" ++ maps:get(Input, New) ++ "\"",
           [Input, name()]}).

usage() ->
    throw({error, "usage: " ++ usage_text() ++ "(see ~ts --help)", [name()]}).

usage_text() ->
    Name = name(),
    Name ++ " [FLAGS] [INPUT] [-- ARGUMENTS]    run INPUT~n"
    "       " ++ Name ++ " [FLAGS] INPUT -o OUTPUT        make an executable~n".

%% The text of "beam.com --help".
help([]) ->
    Name = name(),
    Pad = lists:duplicate(length(Name) + 1, $\s),
    {Runtime, Inputs, Tools} =
        case elixir_version() of
            none -> {[], "a .erl file with main/1, an application directory\n"
                         "            (rebar3), or a release directory (_build/prod/rel/NAME)\n", []};
            Elixir -> {[" and Elixir ", Elixir],
                       "a .erl, .ex or .exs file with main/1, an application\n"
                       "            directory (rebar3 or Mix), or a release directory\n"
                       "            (_build/prod/rel/NAME)\n",
                       ["  mix, iex, elixir, elixirc [ARGUMENTS]\n"
                        "            the tools of Elixir, as with an Elixir installation\n"
                        "            (\"", Name, " mix test\")\n"]}
        end,
    ["BEAM.com: Erlang/OTP ", otp_version(), Runtime, " in one executable file, for\n"
     "Linux, macOS, Windows and the BSDs, on x86_64 and aarch64.\n"
     "\n"
     "usage: ", Name, " [FLAGS] [INPUT] [-- ARGUMENTS]\n",
     Pad, "run INPUT (default: the project in this directory)\n"
     "       ", Name, " [FLAGS] INPUT -o OUTPUT\n",
     Pad, "make an executable of INPUT\n"
     "       ", Name, " --help | --version | --nif-include | --nif-modules APP.com DIR\n"
     "\n"
     "  INPUT     ", Inputs,
     "  ARGUMENTS the arguments of the program\n"
     "  -o OUTPUT make the executable OUTPUT (with the compiled code, an OTP\n"
     "            release with the applications that the code needs, and the\n"
     "            runtime of ", Name, "), and do not run it\n"
     "  -a APP    an OTP application to add (for calls that the builder\n"
     "            cannot see, such as apply/3)\n"
     "  --allow-read[=PATH,...]  --allow-write[=PATH,...]  --allow-net\n"
     "  --allow-run[=PROGRAM,...]  --allow-all\n"
     "            the sandbox, as the permissions of Deno (Linux and OpenBSD):\n"
     "            with one of them, the program can do only what they allow.\n"
     "            -R, -W, -N and -A are short for --allow-read, --allow-write,\n"
     "            --allow-net and --allow-all. PATH: a file or directory that\n"
     "            the program can read (and write); without paths, all.\n"
     "            PROGRAM: a program that it can run (a port), by path or by\n"
     "            name; without programs, all. Reading or writing another file\n"
     "            gives {error, eacces}, and a socket or a port without the flag\n"
     "            {error, eperm}. BEAM_COM_ALLOW (\"read=/etc;net\") gives\n"
     "            permissions to a program that has none in its file.\n"
     "  --target TARGET\n"
     "            (with -o) a native file for one system, not an APE file:\n"
     "            x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu,\n"
     "            x86_64-unknown-freebsd or x86_64-apple-darwin (also\n"
     "            x86_64-linux, aarch64-linux, x86_64-freebsd, x86_64-macos).\n"
     "            wasm32 with -o FILE.com: only the part that the WebAssembly\n"
     "            runtime reads (a zip with the release and the edge part), with\n"
     "            no native program: about 25 MB less, for serve(app) of the\n"
     "            npm package beam.com. It does not run natively\n"
     "  --page    (with -o) OUTPUT is a directory: a static site that runs\n"
     "            the app in the browser of each visitor (GitHub Pages), with\n"
     "            OUTPUT/app.com and the page of the WebAssembly runtime\n"
     "  --no-edge (with -o) no WebAssembly part in OUTPUT. By default, the\n"
     "            same file also runs in the WebAssembly runtime (Workers,\n"
     "            Deno, a web page), with about 40 to 80 KB more\n"
     "  --cacerts FILE\n"
     "            the trusted root certificates of the WebAssembly runtime\n"
     "            (TLS), a PEM file, in the edge part of OUTPUT; by default,\n"
     "            none\n"
     "  --main MODULE\n"
     "            for an application: the module whose main/1 runs, with the\n"
     "            arguments, after the start (as an escript); found in\n"
     "            rebar.config (escript) or mix.exs (:escript) when not given\n"
     "  --extract-priv APP\n"
     "            an application whose priv files are copied to real files at\n"
     "            the first start (for other programs that read them);\n"
     "            automatic when priv has an executable file\n"
     "  --tool rebar|mix\n"
     "            the layout of a directory with both rebar.config and mix.exs\n"
     "            (default: rebar)\n"
     "\n"
     "A run builds the executable in the cache of ", Name, " (BEAM_COM_CACHE, else\n"
     "~/.cache/beam.com), again when a file of INPUT is newer, and runs it.\n"
     "\n"
     "The tools:\n"
     "  escript FILE [ARGUMENTS]\n"
     "            run an escript\n"
     "  --nif-include\n"
     "            write the headers of a NIF library in WebAssembly (erl_nif.h\n"
     "            for wasm32-wasip1) to the cache, and print their directory.\n"
     "            load_nif/2 loads PATH.wasm when there is no native library\n"
     "  --nif-modules APP.com DIR\n"
     "            write DIR/nifs.js and DIR/nifs/ with the NIF libraries in\n"
     "            WebAssembly of APP.com, for a Worker that runs it:\n"
     "            serve(app, { nifs }) of the npm package beam.com\n",
     Tools,
     "  -FLAG ...  the flags of erl (\"-sname me -remsh app\"): run as erl\n"
     "  epmd [ARGUMENTS]\n"
     "            epmd, which -sname, -name and -remsh start\n"
     "  inotifywait, mac_listener\n"
     "            the file watcher of the file_system package\n"
     "\n"
     "A copy of this file or a link to it with the name of a tool (escript",
     case Tools of [] -> ""; _ -> ",\nmix, iex, elixir, elixirc; also mix.com, iex.com, ..." end,
     ") runs that tool.\n"
     "To run an OTP release, add it to the zip of a copy of ", Name, ".\n"
     "More: https://github.com/sntran/BEAM.com\n"].

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
     %% The Elixir packages whose NIFs are linked (see beam_com_make).
     case application:get_env(beam_com, nifs, []) of
         [] -> [];
         Nifs -> io_lib:format("  Linked NIFs : ~ts~n",
                               [lists:join(" ", [[atom_to_list(A), "-", V]
                                                 || {A, V} <- Nifs])])
     end,
     io_lib:format("  Applications: ~ts~n",
                   [lists:join(" ", [[A, "-", V] || {A, V} <- lists:usort(Apps)])])].

vsn() ->
    _ = application:load(beam_com),
    case application:get_key(beam_com, vsn) of
        {ok, Vsn} -> Vsn;
        undefined -> "(unknown version)"
    end.

%% The full OTP version (29.1.1), which the build (scripts/steps.sh)
%% writes into the .app
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
