%% Elixir for "beam.com build": one Elixir file with main/1, and Mix
%% projects (mix.exs), with the Elixir compiler in the zip of beam.com.
%%
%% - A one-file program: a .ex or .exs file with modules; one of them
%%   exports main/1, which gets the arguments as binaries.
%% - A Mix project: mix.exs is read with Mix (the project and the
%%   application of the MixProject module), in the :prod environment.
%%   The Erlang files of erlc_paths (src) and the Elixir files of
%%   elixirc_paths (lib) are compiled; config/config.exs becomes
%%   sys.config (Config.Reader).
-module(beam_com_elixir).

-export([available/0, script/1, is_mix/1, mix_project/1, compile/3,
         sys_config/1]).

-ifdef(TEST).
-export([mix_deps/1]).
-endif.

%% The Elixir compiler is in the zip.
available() ->
    code:which('Elixir.Kernel.ParallelCompiler') =/= non_existing.

start(Apps) ->
    available() orelse
        throw({error, "Elixir is not in this beam.com (built with ELIXIR=0)", []}),
    case application:ensure_all_started(Apps) of
        {ok, _} -> ok;
        {error, Reason} -> throw({error, "Elixir: ~p", [Reason]})
    end.

%% Compile Elixir files into Out: [{Module, Beam}]. The code path must
%% have the modules that the files need.
compile([], _Out, _Label) ->
    [];
compile(Files, Out, Label) ->
    start([elixir]),
    ok = filelib:ensure_path(Out),
    Bins = [unicode:characters_to_binary(F) || F <- Files],
    case 'Elixir.Kernel.ParallelCompiler':compile_to_path(
           Bins, unicode:characters_to_binary(Out), [{return_diagnostics, true}]) of
        {ok, Modules, _Diagnostics} ->
            [{M, element(2, {ok, _} = file:read_file(
                                          filename:join(Out, atom_to_list(M) ++ ".beam")))}
             || M <- Modules];
        {error, _Errors, _Diagnostics} ->
            throw({error, "~ts: Elixir compilation failed", [Label]})
    end.

%% One Elixir file: #{name, beams, main}.
script(File) ->
    filelib:is_regular(File) orelse throw({error, "~ts: no such file", [File]}),
    Out = temp("script"),
    try
        Beams = compile([File], Out, File),
        Mains = [M || {M, Beam} <- Beams, lists:member({main, 1}, exports(Beam))],
        case Mains of
            [Main] -> #{beams => Beams, main => Main};
            [] -> throw({error, "~ts: no module exports main/1", [File]});
            _ -> throw({error, "~ts: more than one module exports main/1: ~ts",
                        [File, lists:join(", ", [name(M) || M <- Mains])]})
        end
    after
        file:del_dir_r(Out)
    end.

name(M) ->
    case atom_to_list(M) of
        "Elixir." ++ Name -> Name;
        Name -> Name
    end.

exports(Beam) ->
    {ok, {_, [{exports, Exports}]}} = beam_lib:chunks(Beam, [exports]),
    Exports.

is_mix(Dir) ->
    filelib:is_regular(filename:join(Dir, "mix.exs")).

%% Read mix.exs with Mix: #{app, version, deps, elixirc_paths,
%% erlc_paths, application}. deps are for beam_com_hex:
%% [{Name, Package, Requirement}].
mix_project(Dir) ->
    start([mix]),
    'Elixir.Mix':'env'(prod),
    File = unicode:characters_to_binary(filename:absname(filename:join(Dir, "mix.exs"))),
    Old = code:all_loaded(),
    Mods = try 'Elixir.Code':compile_file(File)
           catch Class:Reason:Stack ->
                   throw({error, "~ts: ~ts", [File, 'Elixir.Exception':format(Class, Reason, Stack)]})
           end,
    Project = case [M || {M, _} <- Mods, erlang:function_exported(M, project, 0)] of
                  [P | _] -> P;
                  [] -> throw({error, "~ts: no Mix project", [File]})
              end,
    try
        {Config, App} =
            try {Project:project(),
                 case erlang:function_exported(Project, application, 0) of
                     true -> Project:application();
                     false -> []
                 end}
            catch C:R:S ->
                    throw({error, "~ts: ~ts", [File, 'Elixir.Exception':format(C, R, S)]})
            end,
        Get = fun(K, D) -> proplists:get_value(K, Config, D) end,
        Name = Get(app, undefined),
        is_atom(Name) andalso Name =/= undefined orelse
            throw({error, "~ts: no :app in project/0", [File]}),
        #{app => Name,
          version => unicode:characters_to_list(Get(version, <<"0.1.0">>)),
          deps => [{N, P, R} || {N, P, R, _} <- mix_deps(Get(deps, []))],
          runtime_deps => [N || {N, _, _, true} <- mix_deps(Get(deps, []))],
          elixirc_paths => [unicode:characters_to_list(P) || P <- Get(elixirc_paths, [<<"lib">>])],
          erlc_paths => [unicode:characters_to_list(P) || P <- Get(erlc_paths, [<<"src">>])],
          erlc_options => Get(erlc_options, []),
          application => App}
    after
        %% The project module of mix.exs, and the project stack of Mix.
        try 'Elixir.Mix.Project':pop() catch _:_ -> ok end,
        [begin code:purge(M), code:delete(M) end
         || {M, _} <- Mods, not lists:keymember(M, 1, Old)]
    end.

%% The deps of mix.exs: {:name, "~> 1.0"}, {:name, "~> 1.0", opts} and
%% {:name, opts}, as [{Name, Package, Requirement, Runtime}]. Deps only
%% for :dev or :test, and optional deps, are left out (as Mix does when
%% no other package needs them); a dep with runtime: false is compiled
%% but it is not in the applications. Hex is the only source.
mix_deps(Deps) ->
    lists:append([mix_dep(D) || D <- Deps]).

mix_dep({Name, Req}) when is_atom(Name), is_binary(Req) ->
    mix_dep({Name, Req, []});
mix_dep({Name, Opts}) when is_atom(Name), is_list(Opts) ->
    mix_dep({Name, any, Opts});
mix_dep({Name, Req, Opts}) when is_atom(Name), is_list(Opts) ->
    Only = proplists:get_value(only, Opts, prod),
    InProd = Only =:= prod orelse (is_list(Only) andalso lists:member(prod, Only)),
    Other = [K || K <- [git, github, path, in_umbrella], proplists:is_defined(K, Opts)],
    Optional = proplists:get_value(optional, Opts, false) =:= true,
    case {InProd andalso not Optional, Other} of
        {false, _} -> [];
        {true, [K | _]} ->
            throw({error, "the dependency ~p is not a Hex package (~p; only Hex "
                   "packages are supported)", [Name, K]});
        {true, []} ->
            Pkg = case proplists:get_value(hex, Opts) of
                      undefined -> atom_to_binary(Name);
                      H -> atom_to_binary(H)
                  end,
            [{Name, Pkg, case Req of
                             any -> any;
                             _ -> unicode:characters_to_list(Req)
                         end, proplists:get_value(runtime, Opts, true) =/= false}]
    end;
mix_dep(Dep) ->
    throw({error, "mix.exs: a bad dependency: ~p", [Dep]}).

%% config/config.exs of a Mix project, as the terms of sys.config (none
%% when there is no file).
sys_config(Dir) ->
    File = filename:join([Dir, "config", "config.exs"]),
    case filelib:is_regular(File) of
        false -> none;
        true ->
            start([elixir]),
            Config = try 'Elixir.Config.Reader':'read!'(
                           unicode:characters_to_binary(File), [{env, prod}])
                     catch Class:Reason:Stack ->
                             throw({error, "~ts: ~ts",
                                    [File, 'Elixir.Exception':format(Class, Reason, Stack)]})
                     end,
            io_lib:format("~tp.~n", [Config])
    end.

temp(What) ->
    Base = hd([D || V <- ["TMPDIR", "TMP", "TEMP"],
                    D <- [os:getenv(V)], D =/= false, D =/= ""] ++ ["/tmp"]),
    filename:join(Base, lists:concat(["beam_com_ex_", What, "_", os:getpid(), "_",
                                      erlang:unique_integer([positive])])).
