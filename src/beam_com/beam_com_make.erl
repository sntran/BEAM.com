%% make for elixir_make, in the tools of Elixir (mix.com, iex.com,
%% elixir.com, elixirc.com). The tools set MAKE to a program "make" that
%% is beam.com (make_link() in c_src/cosmo/beam_com.c), and beam.com runs this
%% module for it.
%%
%% elixir_make runs make in the directory of a package that has C code (a
%% NIF), with the build directory of the package in MIX_APP_PATH
%% (_build/dev/lib/APP). The NIFs of some packages are linked into
%% beam.com (the env nifs of the beam_com application, which the
%% step bundle of scripts/steps.sh sets: [{exqlite, "0.41.0"}, {bcrypt_elixir, "3.3.2"},
%% {argon2_elixir, "4.1.3"}]). ERTS finds a
%% static NIF by the name of its module, before it opens the file that
%% load_nif/2 gets, so these packages need no make and no C compiler:
%%
%%   - A package with a linked NIF, of the same version: nothing to do.
%%   - A package with a linked NIF, of another version: an error (the NIF
%%     functions of the two versions can be different).
%%   - A package with NIF files in beam.com: the directory
%%     priv/nifs/APP-VSN of beam_com holds files of the priv directory of
%%     the package. They are a NIF library in WebAssembly (lazy_html,
%%     scripts/lazy_html.sh), or native NIF objects (LIB.x86_64.o and
%%     LIB.aarch64.o, a program assembled from parts, docs/NIFS.md). make
%%     copies the files into the priv directory of the package, and
%%     load_nif/2 then loads them. Of another version: an error. The
%%     list of these packages comes from the directory, so a program
%%     with more files in its zip needs no other build.
%%   - Another package: the make of PATH (gmake or make) runs, with the
%%     same arguments. Without make, an error.
%%
%% elixir_make runs make for a package with a precompiled NIF only when
%% the package is in the env force_build of elixir_make. Else it gets a
%% native library for the system, which beam.com cannot load. So the
%% tools of Elixir run force_build/0 at their start (beam_com.c).
-module(beam_com_make).

-export([main/0, force_build/0, nif_files/2, nif_files/3, file_nifs/0, file_nifs/1,
         priv/0, linked_nifs/0]).

-ifdef(TEST).
-export([run/2, dep_version/1, force_build/1, app_file_nifs/1]).
-endif.

main() ->
    Priv = priv(),
    Env = #{app_path => os:getenv("MIX_APP_PATH", ""),
            cwd => element(2, file:get_cwd()),
            nifs => nifs(),
            file_nifs => file_nifs(Priv),
            priv => Priv,
            make => os:getenv("MAKE", "")},
    Status = try run(init:get_plain_arguments(), Env) of
                 ok -> 0;
                 {make, Make, Args} -> make(Make, Args)
             catch
                 throw:{error, Format, Args} ->
                     io:format(standard_error, "~ts: make: " ++ Format ++ "~n",
                               [name() | Args]),
                     1
             end,
    erlang:halt(Status).

%% ok, {make, Make, Args} (run the make of PATH), or an error (throw).
%% The arguments (the targets, "all" or "clean") do not change what is
%% done for a linked NIF.
run(Args, #{app_path := AppPath, cwd := Cwd, nifs := Nifs} = Env) ->
    App = case AppPath of
              "" -> filename:basename(Cwd);
              _ -> filename:basename(AppPath)
          end,
    case [V || {A, V} <- maps:get(file_nifs, Env, []), atom_to_list(A) =:= App] of
        [_ | _] = Vsns -> file_nif(Args, App, Vsns, Env);
        [] -> run(Args, App, Nifs, Env)
    end.

run(Args, App, Nifs, #{cwd := Cwd} = Env) ->
    case lists:keyfind(list_to_atom(App), 1, Nifs) of
        {_, Vsn} ->
            case dep_version(Cwd) of
                Other when is_list(Other), Other =/= Vsn ->
                    throw({error, "~ts ~ts has a NIF, and ~ts has the NIF of ~ts ~ts "
                           "(which it always uses). Use ~ts ~ts (in the deps of "
                           "mix.exs: {:~ts, \"~ts\"})",
                           [App, Other, name(), App, Vsn, App, Vsn, App, Vsn]});
                _ ->
                    %% "all" or "clean": the NIF is in beam.com.
                    ok
            end;
        false ->
            case find_make(maps:get(make, Env)) of
                false ->
                    throw({error, "~ts has C code (a NIF) that is not in ~ts, and there "
                           "is no make in PATH. The NIFs in ~ts: ~ts",
                           [App, name(), name(),
                            case Nifs of
                                [] -> "none";
                                _ -> lists:join(", ", [[atom_to_list(A), " ", V]
                                                       || {A, V} <- Nifs])
                            end]});
                Make ->
                    {make, Make, Args}
            end
    end.

%% A package with NIF files in beam.com (Vsns: the versions in
%% priv/nifs): "all" (or no target) copies its files into
%% MIX_APP_PATH/priv, "clean" does nothing.
file_nif(Args, App, Vsns, #{app_path := AppPath, cwd := Cwd, priv := Priv}) ->
    Vsn = case dep_version(Cwd) of
              Other when is_list(Other) ->
                  case lists:member(Other, Vsns) of
                      true -> Other;
                      false -> throw({error, "~ts ~ts has a NIF, and ~ts has the NIF of ~ts "
                                      "~ts. Use ~ts ~ts (in the deps of mix.exs: "
                                      "{:~ts, \"~ts\"})",
                                      [App, Other, name(), App, hd(Vsns), App, hd(Vsns),
                                       App, hd(Vsns)]})
                  end;
              undefined ->
                  hd(Vsns)
          end,
    case lists:member("clean", Args) of
        true ->
            ok;
        false ->
            Dst = filename:join(case AppPath of "" -> Cwd; _ -> AppPath end, "priv"),
            Files = case nif_files(list_to_atom(App), Vsn, Priv) of
                        [_ | _] = Fs -> Fs;
                        [] -> throw({error, "~ts: no NIF files of ~ts ~ts",
                                     [filename:join([Priv, "nifs", App ++ "-" ++ Vsn]), App, Vsn]})
                    end,
            write_files(Dst, Files)
    end.

%% Writes the files [{Name, Data}] (Name can have directories) into Dir.
write_files(Dir, Files) ->
    [begin
         Path = filename:join(Dir, F),
         ok = filelib:ensure_dir(Path),
         ok = file:write_file(Path, Data)
     end || {F, Data} <- Files],
    ok.

%% The NIF files of App in beam.com, for the version Vsn: [{Name, Data}],
%% with Name relative to the priv directory of App, or [] for another
%% package or version. beam_com_build adds them to the priv directory of
%% App in a program, and beam_com_rustler copies them.
nif_files(App, Vsn) ->
    nif_files(App, Vsn, priv()).

nif_files(App, Vsn, Priv) ->
    Dir = filename:join([Priv, "nifs", atom_to_list(App) ++ "-" ++ Vsn]),
    [{N, element(2, {ok, _} = file:read_file(filename:join(Dir, N)))}
     || N <- lists:sort(filelib:wildcard("**", Dir)),
        filelib:is_regular(filename:join(Dir, N))].

%% The packages with NIF files in beam.com: [{App, Vsn}], from the names
%% APP-VSN of the directories of priv/nifs.
file_nifs() ->
    file_nifs(priv()).

file_nifs(Priv) ->
    case file:list_dir(filename:join(Priv, "nifs")) of
        {ok, Names} ->
            [{list_to_atom(A), V} || N <- lists:sort(Names),
                                     [A, V] <- [string:split(N, "-")],
                                     A =/= "", V =/= "",
                                     filelib:is_dir(filename:join([Priv, "nifs", N]))];
        {error, _} ->
            []
    end.

%% The priv directory of beam_com, also when beam_com is not loaded (it
%% is in the code path). Mix removes beam_com from the code path before
%% it compiles: beam_com_rustler keeps this directory from the start.
priv() ->
    case code:lib_dir(beam_com) of
        Dir when is_list(Dir) -> filename:join(Dir, "priv");
        {error, _} -> "/nonexistent"
    end.

%% The env force_build of elixir_make, with each package with NIF files
%% and each linked NIF (a package such as vix gets a precompiled NIF
%% without it), before Mix loads the configuration of the project.
%% persistent: a later load of elixir_make keeps it. The same for the
%% NIFs of Rust (beam_com_rustler).
force_build() ->
    Nifs = start_nifs(),
    beam_com_rustler:force_build(Nifs),
    force_build(file_nifs() ++ Nifs).

%% The linked NIFs ([{App, Vsn}]), also when beam_com is not loaded.
linked_nifs() ->
    start_nifs().

%% The linked NIFs at the start of a tool of Elixir. When beam_com is not
%% loaded, they come from its .app file, and beam_com stays not loaded:
%% Mix loads the application of the project, and keeps an application
%% that is already loaded (the beam_com of the runtime, in the tests of
%% beam_com).
start_nifs() ->
    case lists:keymember(beam_com, 1, application:loaded_applications()) of
        true -> nifs();
        false -> app_file_nifs(code:where_is_file("beam_com.app"))
    end.

%% The env nifs of the .app file File. [] when the file cannot be read.
app_file_nifs(File) when is_list(File) ->
    case file:consult(File) of
        {ok, [{application, _, Props}]} when is_list(Props) ->
            case proplists:get_value(nifs, proplists:get_value(env, Props, [])) of
                Nifs when is_list(Nifs) -> Nifs;
                _ -> []
            end;
        _ ->
            []
    end;
app_file_nifs(non_existing) ->
    [].

force_build(FileNifs) ->
    Old = case application:get_env(elixir_make, force_build) of
              {ok, L} when is_list(L) -> L;
              _ -> []
          end,
    New = Old ++ [{A, true} || {A, _} <- lists:ukeysort(1, FileNifs),
                              not lists:keymember(A, 1, Old)],
    application:set_env(elixir_make, force_build, New, [{persistent, true}]).

%% The version of the package in the directory Dir: from
%% hex_metadata.config (a package of hex.pm), else from "@version" or
%% "version:" in mix.exs. undefined when it is not found.
dep_version(Dir) ->
    case file:consult(filename:join(Dir, "hex_metadata.config")) of
        {ok, Terms} when is_list(Terms) ->
            case lists:keyfind(<<"version">>, 1, Terms) of
                {_, Vsn} when is_binary(Vsn) -> binary_to_list(Vsn);
                _ -> mix_version(Dir)
            end;
        _ ->
            mix_version(Dir)
    end.

mix_version(Dir) ->
    case file:read_file(filename:join(Dir, "mix.exs")) of
        {ok, Bin} ->
            case re:run(Bin, "(?:@version\\s+|\\bversion:\\s*)\"([^\"]+)\"",
                        [{capture, all_but_first, list}]) of
                {match, [Vsn]} -> Vsn;
                nomatch -> undefined
            end;
        {error, _} ->
            undefined
    end.

%% The make of PATH, not this program (the value of MAKE). elixir_make
%% uses gmake on the BSDs (the make there is not GNU make).
find_make(Self) ->
    Names = case os:type() of
                {unix, OS} when OS =:= freebsd; OS =:= openbsd; OS =:= netbsd;
                                OS =:= dragonfly -> ["gmake", "make"];
                _ -> ["make", "gmake"]
            end,
    Found = [F || N <- Names, F <- [os:find_executable(N)], F =/= false,
                  filename:absname(F) =/= filename:absname(Self)],
    case Found of
        [Make | _] -> Make;
        [] -> false
    end.

%% Run Make with Args, with its output on standard output. Returns its
%% exit status. Without MAKE: GNU make takes $(MAKE) from the environment,
%% so a Makefile that runs $(MAKE) would start this program again.
make(Make, Args) ->
    Port = open_port({spawn_executable, Make},
                     [{args, Args}, {env, [{"MAKE", false}]}, exit_status, binary,
                      stream, stderr_to_stdout]),
    make_loop(Port).

make_loop(Port) ->
    receive
        {Port, {data, Data}} ->
            ok = file:write(standard_io, Data),
            make_loop(Port);
        {Port, {exit_status, Status}} ->
            Status
    end.

%% The name of beam.com for the messages. This program is a link named
%% make to it (a script on macOS, which starts the file itself).
name() ->
    case init:get_argument(beam_com_exe) of
        {ok, [[Exe | _] | _]} ->
            case file:read_link_all(Exe) of
                {ok, Target} -> filename:rootname(filename:basename(Target)) ++ ".com";
                {error, _} -> beam_com:name()
            end;
        _ ->
            beam_com:name()
    end.

nifs() ->
    _ = application:load(beam_com),
    case application:get_env(beam_com, nifs) of
        {ok, Nifs} when is_list(Nifs) -> Nifs;
        _ -> []
    end.
