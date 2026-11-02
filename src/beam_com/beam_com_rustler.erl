%% The NIFs of Rust (Rustler) in beam.com, for the tools of Elixir.
%%
%% A package with a NIF of Rust uses Rustler, or rustler_precompiled. The
%% NIF of some of these packages is linked into beam.com (EXTRA_NIFS,
%% build_rust_nif in scripts/steps.sh), and ERTS finds a static NIF by the
%% name of its module. So these packages need no cargo and no download:
%%
%%   - force_build/1 (at the start of a tool of Elixir) makes
%%     rustler_precompiled "build" each crate with Rustler. A precompiled
%%     NIF is a native library, which beam.com cannot load.
%%   - Without the package rustler, the module Rustler of beam.com
%%     ('Elixir.Rustler') gives the module of the NIF an on_load function
%%     that loads the linked NIF (using/1 and config/2). This function
%%     calls no module of beam.com: a program or a release of Mix has
%%     none. For a crate that is not linked, the compilation stops with
%%     an error.
%%   - With the package rustler (in the deps of the project), its module
%%     Rustler comes first in the code path. force_build/1 then sets
%%     skip_compilation? for each linked crate: Rustler runs no cargo, and
%%     load_nif/2 finds the static NIF.
-module(beam_com_rustler).

-export([force_build/1, config/2, using/1]).

-ifdef(TEST).
-export([linked/1, check/3]).
-endif.

%% The packages with a NIF of Rust that beam.com can link: the package,
%% the module of the NIF and the name of the crate.
-define(CRATES, [{rusty_csv, 'Elixir.RustyCSV.Native', <<"rustycsv">>}]).

%% Nifs: the linked NIFs ([{App, Vsn}], the env nifs of beam_com). The
%% env is persistent: a later load of an application keeps it. Mix
%% removes beam_com (not a dependency) from the code path before it
%% compiles. So this function loads the modules of the compilation, and
%% config/2 gets Nifs from a persistent term.
force_build(Nifs) ->
    [{module, M} = code:ensure_loaded(M)
     || M <- ['Elixir.Rustler', ?MODULE, beam_com_make, beam_com]],
    persistent_term:put(?MODULE, Nifs),
    application:set_env(rustler_precompiled, force_build_all, true, [{persistent, true}]),
    lists:foreach(
      fun({App, Module, _Crate, _Vsn}) ->
              Old = case application:get_env(App, Module) of
                        {ok, L} when is_list(L) -> L;
                        _ -> []
                    end,
              New = [{'skip_compilation?', true} | proplists:delete('skip_compilation?', Old)],
              application:set_env(App, Module, New, [{persistent, true}])
      end, linked(Nifs)).

%% The crates of ?CRATES that are linked: [{App, Module, Crate, Vsn}].
linked(Nifs) ->
    [{App, Module, Crate, Vsn} || {App, Module, Crate} <- ?CRATES,
                                  {A, Vsn} <- Nifs, A =:= App].

%% The quoted code of "use Rustler, Opts" (Opts: the quoted options).
%% Each variable has a name with the prefix beam_com_rustler_, because it
%% is a variable of the body of the module.
using(Opts) ->
    Code = <<"beam_com_rustler_config = :beam_com_rustler.config(__MODULE__, beam_com_rustler_opts)\n"
             "@on_load :rustler_init\n"
             "@doc false\n"
             "def rustler_init do\n"
             "  :code.purge(__MODULE__)\n"
             "  :erlang.load_nif(\n"
             "    unquote(elem(beam_com_rustler_config, 0)),\n"
             "    unquote(elem(beam_com_rustler_config, 1))\n"
             "  )\n"
             "end\n">>,
    {'__block__', _, Body} = 'Elixir.Code':'string_to_quoted!'(Code),
    {'__block__', [], [{'=', [], [{beam_com_rustler_opts, [], nil}, Opts]} | Body]}.

%% At the compilation of the module of the NIF: {Path, LoadData}, the
%% arguments of load_nif/2 (LoadData quoted), or an error (a RuntimeError
%% of Elixir) for a crate that is not linked. ERTS finds the static NIF by
%% the name of the module, and does not open the file Path.
config(Module, Opts) when is_list(Opts) ->
    App = proplists:get_value(otp_app, Opts),
    Crate = name(proplists:get_value(crate, Opts, App)),
    Nifs = persistent_term:get(?MODULE, beam_com_make:linked_nifs()),
    case check(Crate, linked(Nifs), dep_version(App)) of
        ok ->
            LoadData = case proplists:get_value(load_data_fun, Opts) of
                           {M, F} when is_atom(M), is_atom(F) -> {{'.', [], [M, F]}, [], []};
                           undefined -> 'Elixir.Macro':escape(
                                          proplists:get_value(load_data, Opts, 0))
                       end,
            Path = unicode:characters_to_list(
                     [atom_to_binary(App), "/priv/native/lib", Crate]),
            {Path, LoadData};
        {error, Message} ->
            erlang:error('Elixir.RuntimeError':exception(
                           iolist_to_binary(['Elixir.Kernel':inspect(Module), ": ", Message])))
    end.

%% ok, or {error, Message}. Version: the version of the package that
%% compiles, or undefined.
check(Crate, Linked, Version) ->
    case lists:keyfind(Crate, 3, Linked) of
        {_, _, _, Vsn} when Version =:= undefined; Version =:= Vsn ->
            ok;
        {App, _, _, Vsn} ->
            {error, io_lib:format(
                      "~ts ~ts has a NIF of Rust, and ~ts has the NIF of ~ts ~ts "
                      "(which it always uses). Use ~ts ~ts (in the deps of mix.exs: "
                      "{:~ts, \"~ts\"})",
                      [App, Version, beam_com:name(), App, Vsn, App, Vsn, App, Vsn])};
        false ->
            Names = [[atom_to_list(A), " ", V] || {A, _, _, V} <- Linked],
            {error, io_lib:format(
                      "the Rust crate ~ts is not in ~ts, and ~ts cannot load a NIF "
                      "library. The NIFs of Rust in ~ts: ~ts",
                      [Crate, beam_com:name(), beam_com:name(), beam_com:name(),
                       case Names of [] -> "none"; _ -> lists:join(", ", Names) end])}
    end.

name(A) when is_atom(A) -> atom_to_binary(A);
name(B) when is_binary(B) -> B;
name(L) when is_list(L) -> unicode:characters_to_binary(L).

%% The version of the package App while Mix compiles it, else undefined.
dep_version(App) ->
    case code:is_loaded('Elixir.Mix.Project') of
        {file, _} ->
            try 'Elixir.Mix.Project':config() of
                Config when is_list(Config) ->
                    case {proplists:get_value(app, Config),
                          proplists:get_value(version, Config)} of
                        {App, V} when is_binary(V) -> binary_to_list(V);
                        _ -> undefined
                    end;
                _ -> undefined
            catch
                _:_ -> undefined
            end;
        false ->
            undefined
    end.
