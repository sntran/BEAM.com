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
%%   - A package with a NIF library in WebAssembly in beam.com
%%     (?WASM_NIFS, with the files of priv/nifs/APP-VSN of beam_com, from
%%     scripts/lazy_html.sh): make copies
%%     the files into the priv directory of the package. load_nif/2 then
%%     loads PATH.wasm or its AOT file (docs/NIFS.md). Of another version:
%%     an error.
%%   - Another package: the make of PATH (gmake or make) runs, with the
%%     same arguments. Without make, an error.
%%
%% elixir_make runs make for a package with a precompiled NIF only when
%% the package is in the env force_build of elixir_make. Else it gets a
%% native library for the system, which beam.com cannot load. So the
%% tools of Elixir run force_build/0 at their start (beam_com.c).
-module(beam_com_make).

-export([main/0, force_build/0, wasm_nif_files/2]).

-ifdef(TEST).
-export([run/2, dep_version/1, force_build/1, wasm_nif_files/3]).
-endif.

%% The packages whose NIF library in WebAssembly is in priv/nifs.
-define(WASM_NIFS, [{lazy_html, "0.1.13"}]).

main() ->
    Env = #{app_path => os:getenv("MIX_APP_PATH", ""),
            cwd => element(2, file:get_cwd()),
            nifs => nifs(),
            wasm_nifs => ?WASM_NIFS,
            priv => filename:join(code:lib_dir(beam_com), "priv"),
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
    case lists:keyfind(list_to_atom(App), 1, maps:get(wasm_nifs, Env, [])) of
        {_, Vsn} -> wasm_nif(Args, App, Vsn, Env);
        false -> run(Args, App, Nifs, Env)
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

%% A package with a NIF library in WebAssembly in beam.com: "all" (or no
%% target) copies its files into MIX_APP_PATH/priv, "clean" does nothing.
wasm_nif(Args, App, Vsn, #{app_path := AppPath, cwd := Cwd, priv := Priv}) ->
    case dep_version(Cwd) of
        Other when is_list(Other), Other =/= Vsn ->
            throw({error, "~ts ~ts has a NIF, and ~ts has the NIF library in WebAssembly "
                   "of ~ts ~ts. Use ~ts ~ts (in the deps of mix.exs: {:~ts, \"~ts\"})",
                   [App, Other, name(), App, Vsn, App, Vsn, App, Vsn]});
        _ ->
            ok
    end,
    case lists:member("clean", Args) of
        true ->
            ok;
        false ->
            Dst = filename:join(case AppPath of "" -> Cwd; _ -> AppPath end, "priv"),
            Files = case wasm_nif_files(list_to_atom(App), Vsn, Priv) of
                        [_ | _] = Fs -> Fs;
                        [] -> throw({error, "~ts: no NIF library of ~ts ~ts",
                                     [filename:join([Priv, "nifs", App ++ "-" ++ Vsn]), App, Vsn]})
                    end,
            ok = filelib:ensure_path(Dst),
            [ok = file:write_file(filename:join(Dst, F), Data) || {F, Data} <- Files],
            ok
    end.

%% The files of the NIF library in WebAssembly of App in beam.com, for
%% the version Vsn: [{Name, Data}], or [] for another package or version.
%% beam_com_build adds them to the priv directory of App in a program.
wasm_nif_files(App, Vsn) ->
    case lists:keyfind(App, 1, ?WASM_NIFS) of
        {_, Vsn} -> wasm_nif_files(App, Vsn, filename:join(code:lib_dir(beam_com), "priv"));
        _ -> []
    end.

wasm_nif_files(App, Vsn, Priv) ->
    Dir = filename:join([Priv, "nifs", atom_to_list(App) ++ "-" ++ Vsn]),
    case file:list_dir(Dir) of
        {ok, Names} ->
            [{N, element(2, {ok, _} = file:read_file(filename:join(Dir, N)))}
             || N <- lists:sort(Names)];
        {error, _} ->
            []
    end.

%% The env force_build of elixir_make, with each package of ?WASM_NIFS,
%% before Mix loads the configuration of the project. persistent: a later
%% load of elixir_make keeps it.
force_build() ->
    force_build(?WASM_NIFS).

force_build(WasmNifs) ->
    Old = case application:get_env(elixir_make, force_build) of
              {ok, L} when is_list(L) -> L;
              _ -> []
          end,
    New = Old ++ [{A, true} || {A, _} <- WasmNifs, not lists:keymember(A, 1, Old)],
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
