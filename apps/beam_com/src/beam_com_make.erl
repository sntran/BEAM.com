%% make for elixir_make, in the tools of Elixir (mix.com, iex.com,
%% elixir.com, elixirc.com). The tools set MAKE to a program "make" that
%% is beam.com (make_link() in cosmo/beam_com.c), and beam.com runs this
%% module for it.
%%
%% elixir_make runs make in the directory of a package that has C code (a
%% NIF), with the build directory of the package in MIX_APP_PATH
%% (_build/dev/lib/APP). The NIFs of some packages are linked into
%% beam.com (the env nifs of the beam_com application, which build.sh
%% sets: [{exqlite, "0.41.0"}, {bcrypt_elixir, "3.3.2"}]). ERTS finds a
%% static NIF by the name of its module, before it opens the file that
%% load_nif/2 gets, so these packages need no make and no C compiler:
%%
%%   - A package with a linked NIF, of the same version: nothing to do.
%%   - A package with a linked NIF, of another version: an error (the NIF
%%     functions of the two versions can be different).
%%   - Another package: the make of PATH (gmake or make) runs, with the
%%     same arguments. Without make, an error.
-module(beam_com_make).

-export([main/0]).

-ifdef(TEST).
-export([run/2, dep_version/1]).
-endif.

main() ->
    Env = #{app_path => os:getenv("MIX_APP_PATH", ""),
            cwd => element(2, file:get_cwd()),
            nifs => nifs(),
            make => os:getenv("MAKE", "")},
    Status = try run(init:get_plain_arguments(), Env) of
                 ok -> 0;
                 {make, Make, Args} -> make(Make, Args)
             catch
                 throw:{error, Format, Args} ->
                     io:format(standard_error, "~ts: make: " ++ Format ++ "~n",
                               [beam_com:name() | Args]),
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
    case lists:keyfind(list_to_atom(App), 1, Nifs) of
        {_, Vsn} ->
            case dep_version(Cwd) of
                Other when is_list(Other), Other =/= Vsn ->
                    throw({error, "~ts ~ts has a NIF, and ~ts has the NIF of ~ts ~ts "
                           "(which it always uses). Use ~ts ~ts (in the deps of "
                           "mix.exs: {:~ts, \"~ts\"})",
                           [App, Other, beam_com:name(), App, Vsn, App, Vsn, App, Vsn]});
                _ ->
                    %% "all" or "clean": the NIF is in beam.com.
                    ok
            end;
        false ->
            case find_make(maps:get(make, Env)) of
                false ->
                    throw({error, "~ts has C code (a NIF) that is not in ~ts, and there "
                           "is no make in PATH. The NIFs in ~ts: ~ts",
                           [App, beam_com:name(), beam_com:name(),
                            case Nifs of
                                [] -> "none";
                                _ -> lists:join(", ", [[atom_to_list(A), " ", V]
                                                       || {A, V} <- Nifs])
                            end]});
                Make ->
                    {make, Make, Args}
            end
    end.

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

nifs() ->
    _ = application:load(beam_com),
    case application:get_env(beam_com, nifs) of
        {ok, Nifs} when is_list(Nifs) -> Nifs;
        _ -> []
    end.
