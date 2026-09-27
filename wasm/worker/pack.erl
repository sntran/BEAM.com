#!/usr/bin/env escript
%% Packs a release (mix release or rebar3 release, without ERTS) for the
%% WebAssembly emulator on Workers: one file, release.bin, which the
%% Worker (worker.js) writes into the file system of the emulator (/app)
%% before the boot.
%%
%%   escript pack.erl REL_DIR OUT_FILE LIB_DIR...
%%
%% REL_DIR: _build/prod/rel/NAME. LIB_DIR: where the OTP and Elixir
%% applications of the .rel file are (APP or APP-VSN directories with
%% ebin), for example the lib directories of OTP and Elixir.
%%
%% The format: "BEAMFS1\n", then for each file a 32-bit big-endian length
%% and the path (relative to /app), a 32-bit length and the data. The
%% first file is .release.json: {"name": NAME, "vsn": VSN}.
-mode(compile).

main([RelDir, Out | LibDirs]) ->
    {ok, Data} = file:read_file(filename:join([RelDir, "releases", "start_erl.data"])),
    [_ErtsVsn, Vsn] = string:lexemes(string:trim(binary_to_list(Data)), " "),
    [RelFile] = filelib:wildcard(filename:join([RelDir, "releases", Vsn, "*.rel"])),
    {ok, [{release, {Name, Vsn}, _Erts, Apps}]} = file:consult(RelFile),
    Meta = {".release.json", iolist_to_binary(json:encode(#{name => list_to_binary(Name),
                                                           vsn => list_to_binary(Vsn)}))},
    RelFiles = release_files(RelDir, Vsn),
    AppFiles = lists:append([app_files(RelDir, LibDirs, Name, App) || App <- Apps]),
    Files = [Meta | RelFiles ++ AppFiles],
    Bin = ["BEAMFS1\n" | [[<<(byte_size(P)):32>>, P, <<(byte_size(D)):32>>, D]
                          || {P0, D} <- Files, P <- [unicode:characters_to_binary(P0)]]],
    ok = file:write_file(Out, Bin),
    Size = iolist_size(Bin),
    io:format("~s: ~s ~s, ~b files, ~.1f MB~n", [Out, Name, Vsn, length(Files), Size / 1048576]);
main(_) ->
    io:format(standard_error, "usage: pack.erl REL_DIR OUT_FILE LIB_DIR...~n", []),
    halt(2).

%% releases/VSN (boot script, sys.config, runtime.exs, consolidated
%% protocols) and a writable copy of sys.config (tmp/, for the runtime
%% configuration of Elixir).
release_files(RelDir, Vsn) ->
    Dir = filename:join([RelDir, "releases", Vsn]),
    Keep = fun(F) -> not lists:member(filename:extension(F), [".script", ".bat", ".sh"])
                         andalso not lists:suffix("vm.args", F) end,
    Files = [{filename:join(["releases", Vsn, F]), read(filename:join(Dir, F))}
             || F <- files(Dir), Keep(F)],
    {ok, SysConfig} = file:read_file(filename:join(Dir, "sys.config")),
    [{"releases/start_erl.data", read(filename:join([RelDir, "releases", "start_erl.data"]))},
     {"tmp/run.runtime.config", SysConfig} | Files].

%% An application of the release: from REL_DIR/lib (with its priv; only
%% the main application keeps priv/static), else from the LIB_DIRs (ebin
%% only, and an empty priv: the static NIFs load with a path in it).
app_files(RelDir, LibDirs, Name, {App, Vsn, _Type}) ->
    AppVsn = atom_to_list(App) ++ "-" ++ Vsn,
    Dest = filename:join("lib", AppVsn),
    InRel = filename:join([RelDir, "lib", AppVsn]),
    case filelib:is_dir(InRel) of
        true ->
            Main = atom_to_list(App) =:= Name,
            [{filename:join(Dest, F), data(filename:join(InRel, F))}
             || F <- files(InRel), keep_priv(F, Main)];
        false ->
            case [D || L <- LibDirs, D <- [filename:join(L, atom_to_list(App)), filename:join(L, AppVsn)],
                       filelib:is_dir(filename:join(D, "ebin"))] of
                [Src | _] ->
                    Ebin = filename:join(Src, "ebin"),
                    [{filename:join([Dest, "priv", ".keep"]), <<>>} |
                     [{filename:join([Dest, "ebin", F]), data(filename:join(Ebin, F))}
                      || F <- files(Ebin)]];
                [] ->
                    io:format(standard_error, "warning: ~s not found~n", [AppVsn]),
                    []
            end
    end.

keep_priv(F, Main) ->
    case filename:split(F) of
        ["priv", "static" | _] when not Main -> false;
        _ -> filename:extension(F) =/= ".map"
    end.

%% The files under Dir, relative to it.
files(Dir) ->
    Len = length(filename:split(Dir)),
    [filename:join(lists:nthtail(Len, filename:split(F)))
     || F <- filelib:wildcard(filename:join(Dir, "**")), filelib:is_regular(F)].

read(Path) -> {ok, B} = file:read_file(Path), B.

%% A .beam file without its debug information and docs.
data(Path) ->
    B = read(Path),
    case filename:extension(Path) of
        ".beam" -> {ok, {_, S}} = beam_lib:strip(B), S;
        _ -> B
    end.
