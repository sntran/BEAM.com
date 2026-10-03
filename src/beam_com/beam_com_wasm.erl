%% beam.com INPUT -o DIR --target wasm32: a release for the WebAssembly
%% runtime of BEAM.com (ERTS built with Emscripten, threads on JSPI), as
%% Cloudflare Workers.
%%
%% The input is what beam.com builds (a .erl or .ex file, an application
%% directory, a Mix project), or a release directory (mix release or
%% rebar3 release, without ERTS: _build/prod/rel/NAME). DIR gets:
%%
%%   wrangler.jsonc, worker.js, beam.mjs, beam.wasm
%%                    the runtime Worker (NAME): the BEAM, with no program
%%   release/wrangler.jsonc, release/app.js, release/release.bin
%%                    the Worker with the release (NAME-release), which the
%%                    runtime gets at the first request of an isolate
%%   worker.capnp     both Workers for workerd, to test on this computer
%%   tcp-proxy.mjs    a local TCP port for a listener of the program
%%   runtime-id.js    the identity of the runtime (runtime_id/1), for the
%%                    hosts that read a native app.com (app-com.js)
%%
%% The release gets the application wasm_host (the TCP sockets of the
%% host, and distributed Erlang over them), which starts after stdlib.
%% The build also runs the release natively once, to find the modules
%% that its boot loads: the boot script of the Worker loads them in one
%% batch (a shorter cold start).
%%
%% release.bin: "BEAMFS1\n", then for each file a 32-bit big-endian
%% length and the path (relative to /app), a 32-bit length and the data.
%% The first file is .release.json: the name, the version, the boot
%% arguments and the environment.
-module(beam_com_wasm).

-export([release_dir/2, write/3, overlay/4]).
-export([sqlite_shim/1, wasm_shim/0]).

-ifdef(TEST).
-export([release_files/2, with_host/2, with_boot_modules/2, vm_args/1, pack/1,
         runtime_dir/1, meta/1, worker_files/3, snapshot_key/2, runtime_nifs/1,
         strip_beams/1, strip/2, compress_beams/2, with_cacerts/2, worker_name/1, with_wasm/1,
         page_files/3, page_env/1, page_worker/1, host_worker/2, static_files/2, write_page/2,
         edge_runtime/1, runtime_id/1, apps/1]).
-endif.

%% The chunks of a .beam file in a release: the loader, the line numbers and
%% the attributes.
-define(KEEP_CHUNKS, ["Atom", "AtU8", "Attr", "Code", "StrT", "ImpT", "ExpT", "FunT",
                      "LitT", "Line", "Type", "Meta", "Recs"]).

-define(HOST_APP, wasm_host).
%% The files of the runtime, in the order of runtime_id/1.
-define(RUNTIME_FILES, ["app-com.js", "beam.mjs", "beam.wasm", "worker.js"]).
-define(CACERTS, "etc/cacerts.pem").

%% A release directory (with releases/start_erl.data) as the input.
release_dir(Dir, Root) ->
    filelib:is_regular(filename:join([Dir, "releases", "start_erl.data"]))
        andalso release_files(Dir, Root).

%% Rel: #{name, vsn, files => [{Path, Data}], kind => mix | beam_com}.
write(Output, #{name := Name, vsn := Vsn, files := Files0} = Rel, Opts) ->
    Root = maps:get(root, Opts, "/zip"),
    Quiet = maps:get(quiet, Opts, false),
    Runtime = runtime_dir(Root),
    case filelib:is_regular(Output) of
        true -> throw({error, "~ts: a file; --target wasm32 writes a directory", [Output]});
        false -> ok
    end,
    Apps = apps(Files0),
    [warn(Quiet, "warning: ~p has a NIF that the WebAssembly runtime does not have", [A])
     || A <- lists:usort(Apps), lists:member(A, native_nifs() -- runtime_nifs(Runtime))],
    Files1 = with_cacerts(with_wasm(with_sqlite(with_host(Files0, Root), Root)), Opts),
    Meta = meta(Rel#{apps => Apps, cacerts => lists:keymember(?CACERTS, 1, Files1)}),
    Mods = boot_modules(Files1, Meta, Opts),
    Files = with_boot_modules(Files1, Mods),
    Worker = worker_files(Rel#{apps => Apps}, Runtime, Root),
    %% release.bin: the code without its debug information and docs, and
    %% the modules that the boot does not load compressed (a smaller
    %% release.bin in the memory of the isolate).
    {Packed, Compressed} = compress_beams(strip_beams(Files), Mods),
    Bin = pack([{".release.json", json:encode(Meta#{snapshot_key => snapshot_key(Files, Worker)})}
                | Packed]),
    [ok = filelib:ensure_path(filename:join(Output, D)) || D <- ["", "release"]],
    %% A file can be in a subdirectory (release/, licenses/otp/).
    [begin ok = filelib:ensure_dir(P), write_file(P, D) end
     || {F, D} <- Worker, P <- [filename:join(Output, F)]],
    write_file(filename:join([Output, "release", "release.bin"]), Bin),
    write_page(Output, page_files(Rel#{apps => Apps}, Worker, Root)),
    Quiet orelse io:format("~ts: wrote ~ts (the Workers ~ts and ~ts-release)~n"
                           "  release: ~ts ~ts, ~b files, ~.1f MB (~b modules compressed)~n"
                           "  boot: ~ts~n"
                           "  test: workerd serve ~ts~n"
                           "  deploy: (cd ~ts/release && wrangler deploy) && (cd ~ts && wrangler deploy)~n"
                           "  (or one Durable Object: wrangler deploy -c wrangler.durable.jsonc)~n"
                           "  web page: ~ts (a static site, for example on GitHub Pages)~n"
                           "~ts",
                           [beam_com:name(), Output, worker_name(Name), worker_name(Name), Name, Vsn, length(Files),
                            iolist_size(Bin) / 1048576, Compressed,
                            case Mods of
                                [] -> "the modules load one by one (no native run)";
                                _ -> io_lib:format("~b modules in one batch", [length(Mods)])
                            end,
                            filename:join(Output, "worker.capnp"), Output, Output,
                            filename:join(Output, "page"),
                            case lists:keymember("global.js", 1, Worker) of
                                true -> "  (or the VM restored in the global scope: see "
                                        "wrangler.global.jsonc and wrangler.durable-global.jsonc)\n";
                                false -> ""
                            end]),
    ok.

%% The applications of the files of a release: lib/NAME-VSN/ebin/NAME.app.
apps(Files) ->
    [A || {"lib/" ++ P, _} <- Files, [D, "ebin", F] <- [string:split(P, "/", all)],
          {A, _} <- [beam_com_build:split_dir(D)], F =:= atom_to_list(A) ++ ".app"].

%% The edge part of a native app.com (beam_com_build): the files that the
%% WebAssembly runtime needs beyond the files of the native release, under
%% .wasm/ in the zip. The runtime reads lib/ and releases/ of the zip, with
%% the files of .wasm/ in their place (app-com.js of wasm_host):
%%
%%   .wasm/.release.json    the boot of the VM (meta/1), the snapshot key,
%%                          and the runtime and the beam.com of the build
%%   .wasm/lib/wasm_host-VSN/ebin/   the application wasm_host
%%   .wasm/releases/VSN/start.boot   the boot script, with wasm_host
%%
%% and the other files that the runtime reads with other content: the
%% modules in the place of NIFs (exqlite, wasm), the files of the release
%% that the native file changes (Originals of beam_com_build), and
%% etc/cacerts.pem of --cacerts.
%%
%% View: the files of the release as the runtime sees them (lib/,
%% releases/). Native: the files of the zip ([{Path, Data}]), where a file
%% that the zip of beam.com gives can have no data (<<>>, in View too).
%% The build does not run the release (--target wasm32 does): the boot
%% loads the modules one by one, and the zip deflates them. The result is
%% [] when the zip of beam.com has no wasm_host or no runtime, or when the
%% release cannot have wasm_host (Warn: a warning).
overlay(View, Native, #{name := Name, vsn := Vsn, kind := Kind}, Opts) ->
    Root = maps:get(root, Opts, "/zip"),
    case edge_runtime(Root) of
        none ->
            [];
        Runtime ->
            try with_cacerts(with_wasm(with_sqlite(with_host(View, Root), Root)), Opts) of
                Files ->
                    Rel = #{name => Name, vsn => Vsn, kind => Kind, files => Files,
                            apps => apps(View), cacerts => lists:keymember(?CACERTS, 1, Files)},
                    Meta = (meta(Rel))#{snapshot_key => snapshot_key(Files, Runtime),
                                        runtime => runtime_id(Runtime),
                                        beam_com => unicode:characters_to_binary(beam_com:vsn()),
                                        otp => unicode:characters_to_binary(beam_com:otp_version())},
                    Have = maps:from_list([{P, iolist_to_binary(D)} || {P, D} <- Native]),
                    %% Without debug information and docs, as in release.bin.
                    Changed = strip_beams([F || {P, D} = F <- Files,
                                                maps:get(P, Have, none) =/= iolist_to_binary(D)]),
                    [{".wasm/.release.json", json:encode(Meta)} | [{".wasm/" ++ P, D} || {P, D} <- Changed]]
            catch
                throw:{error, Format, Args} ->
                    warn(maps:get(quiet, Opts, false), "warning: no WebAssembly part: " ++ Format, Args),
                    []
            end
    end.

%% The runtime of the edge part: worker.js and app-com.js of wasm_host,
%% beam.mjs and beam.wasm (runtime_dir/1). none when the zip has no
%% runtime.
edge_runtime(Root) ->
    Js = [filelib:wildcard(filename:join([Root, "lib", "wasm_host-*", "priv", "worker", F]))
          || F <- ["worker.js", "app-com.js"]],
    case Js of
        [[WorkerJs], [AppComJs]] ->
            try runtime_dir(Root) of
                Dir -> [{"worker.js", read(WorkerJs)},
                        {"app-com.js", read(AppComJs)},
                        {"beam.mjs", read(filename:join(Dir, "beam.mjs"))},
                        {"beam.wasm", read(filename:join(Dir, "beam.wasm"))}]
            catch
                throw:{error, _, _} -> none
            end;
        _ ->
            none
    end.

%% The identity of a runtime: the SHA-256 of the output of
%% "sha256sum app-com.js beam.mjs beam.wasm worker.js" (?RUNTIME_FILES).
%% The edge part of a native file holds the identity of the runtime of the
%% build, and the hosts give the identity of their runtime (runtime-id.js
%% of DIR): the loader (app-com.js) refuses a file for another runtime. A
%% Worker cannot calculate it (it gets beam.wasm as a module, not as
%% bytes), so DIR has it as a value.
runtime_id(Files) ->
    Line = fun(F) ->
                   {F, D} = lists:keyfind(F, 1, Files),
                   [binary:encode_hex(crypto:hash(sha256, D), lowercase), "  ", F, "\n"]
           end,
    binary:encode_hex(crypto:hash(sha256, lists:map(Line, ?RUNTIME_FILES)), lowercase).

%% runtime-id.js of DIR: the identity of its runtime, as a module.
runtime_id_module(Files) ->
    ["// The identity of this runtime (beam_com_wasm:runtime_id/1): the SHA-256 of\n"
     "// the output of \"sha256sum app-com.js beam.mjs beam.wasm worker.js\".\n"
     "export default '", runtime_id(Files), "';\n"].

warn(true, _Format, _Args) -> ok;
warn(false, Format, Args) ->
    io:format(standard_error, "~ts: " ++ Format ++ "~n", [beam_com:name() | Args]).

%% The runtime: beam.wasm and beam.mjs of wasm/erts/build.sh (WORKER=1).
runtime_dir(Root) ->
    Dirs = [D || D <- [os:getenv("BEAM_COM_WASM_RUNTIME")], D =/= false, D =/= ""]
        ++ filelib:wildcard(filename:join([Root, "lib", "wasm_host-*", "priv", "runtime"]))
        ++ [filename:join(beam_com:cache_dir(), "wasm32")],
    case [D || D <- Dirs, filelib:is_regular(filename:join(D, "beam.wasm")),
               filelib:is_regular(filename:join(D, "beam.mjs"))] of
        [Dir | _] -> Dir;
        [] -> throw({error, "the WebAssembly runtime (beam.wasm and beam.mjs) is not in "
                     "~ts: set BEAM_COM_WASM_RUNTIME to its directory, or put it in ~ts",
                     [beam_com:name(), lists:last(Dirs)]})
    end.

%% The applications whose NIFs are in the native beam.com: esqlite, and
%% the hex.pm packages of the env nifs of beam_com (scripts/steps.sh), but
%% exqlite and wasm, whose modules the runtime replaces (with_sqlite/2,
%% with_wasm/1).
native_nifs() ->
    _ = application:load(beam_com),
    Hex = case application:get_env(beam_com, nifs) of
              {ok, Nifs} when is_list(Nifs) -> [A || {A, _} <- Nifs];
              _ -> []
          end,
    [esqlite | Hex] -- [exqlite].

%% The hex.pm packages whose NIFs are in the WebAssembly runtime: the file
%% nifs next to beam.wasm ("NAME VSN" on each line).
runtime_nifs(Runtime) ->
    case file:read_file(filename:join(Runtime, "nifs")) of
        {ok, Data} ->
            [binary_to_atom(N) || L <- binary:split(Data, <<"\n">>, [global]),
                                  [N | _] <- [string:lexemes(L, " ")]];
        {error, _} -> []
    end.

%% The files of a release directory, and the applications of its .rel
%% file that are not in its lib/ (a release without ERTS can leave out
%% OTP and Elixir): from the zip of beam.com.
release_files(Dir, Root) ->
    {ok, Data} = file:read_file(filename:join([Dir, "releases", "start_erl.data"])),
    [_ErtsVsn, Vsn] = string:lexemes(string:trim(binary_to_list(Data)), " "),
    RelDir = filename:join([Dir, "releases", Vsn]),
    Name = case filelib:wildcard(filename:join(RelDir, "*.rel")) of
               [RelFile] ->
                   {ok, [{release, {N, Vsn}, _, RelApps}]} = file:consult(RelFile),
                   put(rel_apps, RelApps),
                   N;
               _ -> throw({error, "~ts: no .rel file", [RelDir]})
           end,
    Kind = case filelib:is_regular(filename:join(RelDir, "env.sh")) of
               true -> mix;
               false -> beam_com
           end,
    Skip = fun(F) -> lists:member(filename:extension(F), [".script", ".bat", ".sh", ".eex"])
                         orelse filename:basename(F) =:= "start_clean.boot"
                         orelse filename:basename(F) =:= "remote.vm.args" end,
    Rels = [{filename:join(["releases", Vsn, F]), read(filename:join(RelDir, F))}
            || F <- files(RelDir), not Skip(F)],
    Libs = lists:append([app_files(Dir, Root, App, AppVsn)
                         || {App, AppVsn, _} <- [norm(A) || A <- get(rel_apps)]]),
    Config = case lists:keyfind(filename:join(["releases", Vsn, "sys.config"]), 1, Rels) of
                 {_, C} -> C;
                 false -> <<"[].\n">>
             end,
    %% A mix release writes the runtime configuration into tmp/.
    Tmp = [{"tmp/run.runtime.config", Config} || Kind =:= mix],
    #{name => Name, vsn => Vsn, kind => Kind,
      files => [{"releases/start_erl.data", Data} | Rels ++ Tmp ++ Libs]}.

norm({A, V}) -> {A, V, permanent};
norm({A, V, T}) -> {A, V, T};
norm({A, V, T, _}) -> {A, V, T}.

app_files(Dir, Root, App, Vsn) ->
    AppVsn = atom_to_list(App) ++ "-" ++ Vsn,
    Dest = "lib/" ++ AppVsn,
    case [D || D <- [filename:join([Dir, "lib", AppVsn]), filename:join([Root, "lib", AppVsn])],
               filelib:is_dir(filename:join(D, "ebin"))] of
        [Src | _] ->
            [{Dest ++ "/" ++ F, data(filename:join(Src, F))}
             || F <- files(Src), keep(F)];
        [] ->
            throw({error, "~ts is not in the release or in ~ts", [AppVsn, beam_com:name()]})
    end.

%% ebin/ and priv/ (without source maps).
keep(F) ->
    case string:split(F, "/") of
        ["ebin", _] -> true;
        ["priv", _] -> filename:extension(F) =/= ".map";
        _ -> false
    end.

%% The application wasm_host (from the zip of beam.com), and the boot
%% script that starts it after stdlib.
with_host(Files, Root) ->
    [Src] = filelib:wildcard(filename:join([Root, "lib", "wasm_host-*"])),
    Dir = "lib/" ++ filename:basename(Src),
    Host = [{Dir ++ "/" ++ F, data(filename:join(Src, F))}
            || F <- files(Src), lists:prefix("ebin/", F)],
    HostMods = [filename:basename(F) || {F, _} <- Host, filename:extension(F) =:= ".beam"],
    [throw({error, "~ts: the release has its own copy of a module of wasm_host; remove it", [P]})
     || {"lib/" ++ _ = P, _} <- Files, not lists:prefix(Dir ++ "/", P),
        lists:member(filename:basename(P), HostMods)],
    {ok, [{application, ?HOST_APP, Props}]} =
        file:consult(filename:join([Src, "ebin", "wasm_host.app"])),
    Ebin = "$ROOT/" ++ Dir ++ "/ebin",
    %% The base path of a web app (wasm_host_base): after the config
    %% providers of a Mix release (runtime.exs), else after wasm_host.
    Base = {apply, {wasm_host_base, set, []}},
    Boot = fun(Cmds) ->
                   Providers = lists:member({apply, {'Elixir.Config.Provider', boot, []}}, Cmds),
                   lists:flatmap(
                     %% A path command gives the path of the next
                     %% commands (it does not add to the one before).
                     fun({path, P} = C) ->
                             case lists:any(fun(E) -> string:find(E, "/stdlib-") =/= nomatch end, P) of
                                 true -> [{path, P ++ [Ebin]}];
                                 false -> [C]
                             end;
                        ({apply, {application, start_boot, [stdlib | _]}} = C) ->
                             [C, {apply, {application, load, [{application, ?HOST_APP, Props}]}},
                              {apply, {application, start_boot, [?HOST_APP, permanent]}}
                              | [Base || not Providers]];
                        ({apply, {'Elixir.Config.Provider', boot, []}} = C) ->
                             [C, Base];
                        (C) -> [C]
                     end, Cmds)
           end,
    [{P, case lists:suffix("/start.boot", P) of
             true -> map_boot(Boot, D);
             false -> D
         end} || {P, D} <- Files, not lists:prefix(Dir ++ "/", P)] ++ Host.

%% Ecto SQLite (exqlite): its NIF module in place of the one of exqlite,
%% which calls wasm_host_sqlite:dispatch/2: the host runs the SQL, or
%% SQLite in the VM (wasm_host_exqlite) when the host does not.
with_sqlite(Files, _Root) ->
    [case lists:suffix("/ebin/Elixir.Exqlite.Sqlite3NIF.beam", P) of
         true -> {P, sqlite_shim(iolist_to_binary(D))};
         false -> {P, D}
     end || {P, D} <- Files].

%% A module 'Elixir.Exqlite.Sqlite3NIF' with the exports of the original
%% (Beam): each one calls wasm_host_sqlite:dispatch(F, Args). No on_load
%% (no NIF to load).
sqlite_shim(Beam) ->
    Mod = 'Elixir.Exqlite.Sqlite3NIF',
    {ok, {Mod, [{exports, Exports0}]}} = beam_lib:chunks(Beam, [exports]),
    Exports = [FA || {F, _} = FA <- Exports0, F =/= module_info],
    Fun = fun({load_nif = F, 0}) ->
                  {function, 1, F, 0, [{clause, 1, [], [], [{atom, 1, ok}]}]};
             ({F, A}) ->
                  Vars = [{var, 1, list_to_atom("A" ++ integer_to_list(I))} || I <- lists:seq(1, A)],
                  Args = lists:foldr(fun(V, T) -> {cons, 1, V, T} end, {nil, 1}, Vars),
                  Body = {call, 1, {remote, 1, {atom, 1, wasm_host_sqlite}, {atom, 1, dispatch}},
                          [{atom, 1, F}, Args]},
                  {function, 1, F, A, [{clause, 1, Vars, [], [Body]}]}
          end,
    Forms = [{attribute, 1, module, Mod}, {attribute, 1, export, Exports}
             | [Fun(FA) || FA <- Exports]],
    {ok, Mod, Bin} = compile:forms(Forms, [binary, return_errors]),
    Bin.

%% WebAssembly (the API of the application wasm of beam.com, whose NIF is
%% WAMR): the module wasm calls wasm_host_wasm, and the engine of the host
%% runs the modules. It takes the place of the module of the application
%% wasm when the release has it, else it goes into wasm_host, so that the
%% code of any release can call wasm:run/2.
with_wasm(Files) ->
    Shim = wasm_shim(),
    case [P || {P, _} <- Files, lists:suffix("/ebin/wasm.beam", P)] of
        [] ->
            [Host] = [filename:dirname(P) || {P, _} <- Files,
                                             lists:suffix("/ebin/wasm_host.app", P)],
            Files ++ [{Host ++ "/wasm.beam", Shim}];
        _ ->
            [case lists:suffix("/ebin/wasm.beam", P) of
                 true -> {P, Shim};
                 false -> {P, D}
             end || {P, D} <- Files]
    end.

%% The module wasm: each function of the application wasm calls the same
%% function of wasm_host_wasm.
wasm_shim() ->
    Exports = [{compile, 1}, {instantiate, 1}, {instantiate, 2}, {instantiate, 3},
               {call_function, 3}, {function_exists, 2}, {start, 1}, {run, 2},
               {memory_size, 1}, {memory_grow, 2}, {read_binary, 3}, {write_binary, 3}],
    Fun = fun({F, A}) ->
                  Vars = [{var, 1, list_to_atom("A" ++ integer_to_list(I))} || I <- lists:seq(1, A)],
                  Body = {call, 1, {remote, 1, {atom, 1, wasm_host_wasm}, {atom, 1, F}}, Vars},
                  {function, 1, F, A, [{clause, 1, Vars, [], [Body]}]}
          end,
    Forms = [{attribute, 1, module, wasm}, {attribute, 1, export, Exports}
             | [Fun(FA) || FA <- Exports]],
    {ok, wasm, Bin} = compile:forms(Forms, [binary, return_errors]),
    Bin.

%% The boot script loads Mods in one batch, after kernel starts.
with_boot_modules(Files, []) ->
    Files;
with_boot_modules(Files, Mods) ->
    Boot = fun(Cmds) ->
                   lists:flatmap(
                     fun({apply, {application, start_boot, [kernel | _]}} = C) ->
                             [C, {apply, {code, ensure_modules_loaded, [Mods]}}];
                        (C) -> [C]
                     end, Cmds)
           end,
    [{P, case lists:suffix("/start.boot", P) of
             true -> map_boot(Boot, D);
             false -> D
         end} || {P, D} <- Files].

%% The chunks that the loader uses, the line numbers and the attributes
%% (?KEEP_CHUNKS), as beam_com_build:strip/1 and "mix release"
%% (strip_beams). Only the files with debug information, docs or the
%% checker chunk of Elixir: a file of "mix release" is stripped and
%% compressed already.
strip_beams(Files) ->
    Keep = ?KEEP_CHUNKS,
    [{P, case filename:extension(P) =:= ".beam" andalso is_binary(D) andalso strip_beam(D, Keep) of
             false -> D;
             S -> S
         end} || {P, D} <- Files].

strip_beam(<<"FOR1", _/binary>> = D, Keep) ->
    case beam_lib:chunks(D, ["Dbgi", "Docs", "ExCk"], [allow_missing_chunks]) of
        {ok, {_, Extra}} ->
            case [C || {_, X} = C <- Extra, is_binary(X)] of
                [] -> false;
                _ ->
                    {ok, {_, Chunks}} = beam_lib:chunks(D, Keep, [allow_missing_chunks]),
                    {ok, S} = beam_lib:build_module([C || {_, X} = C <- Chunks, is_binary(X)]),
                    S
            end;
        {error, _, _} -> false
    end;
strip_beam(_, _) ->
    false.

%% The modules that the boot does not load, compressed with gzip: the
%% loader of ERTS reads them so (as the files of "mix release"). The
%% modules of the boot stay as they are, for a shorter boot. With no list
%% of the boot modules (no native run), none.
compress_beams(Files, []) ->
    {Files, 0};
compress_beams(Files, Mods) ->
    Boot = sets:from_list([atom_to_list(M) || M <- Mods], [{version, 2}]),
    lists:mapfoldl(fun({P, <<"FOR1", _/binary>> = D} = F, N) ->
                           case filename:extension(P) =:= ".beam"
                               andalso not sets:is_element(filename:basename(P, ".beam"), Boot) of
                               true -> {{P, zlib:gzip(D)}, N + 1};
                               false -> {F, N}
                           end;
                      (F, N) -> {F, N}
                   end, 0, Files).

%% --cacerts FILE: the trusted root certificates of the runtime (TLS,
%% Req, httpc), a PEM file. The runtime has no certificates of its own.
%% The builder does not copy the store of the computer of the build,
%% because that store can have a local CA (of a proxy, for example).
with_cacerts(Files, #{cacerts := File}) ->
    Pem = case file:read_file(File) of
              {ok, Data} -> Data;
              {error, Reason} ->
                  throw({error, "--cacerts ~ts: ~ts", [File, file:format_error(Reason)]})
          end,
    case [C || {'Certificate', _, not_encrypted} = C <- pem_decode(Pem)] of
        [] -> throw({error, "--cacerts ~ts: no certificate", [File]});
        Certs -> Files ++ [{?CACERTS, public_key:pem_encode(Certs)}]
    end;
with_cacerts(Files, _Opts) ->
    Files.

pem_decode(Pem) ->
    try public_key:pem_decode(Pem) catch _:_ -> [] end.

map_boot(Fun, Data) ->
    {script, Id, Cmds} = binary_to_term(iolist_to_binary(Data)),
    term_to_binary({script, Id, Fun(Cmds)}).

%% .release.json: the boot arguments and the environment of the release.
meta(#{name := Name, vsn := Vsn, kind := Kind, files := Files} = Rel) ->
    Dir = "releases/" ++ Vsn ++ "/",
    VmArgs = case lists:keyfind(Dir ++ "vm.args", 1, Files) of
                 {_, V} -> vm_args(V);
                 false -> []
             end,
    Config = case Kind of
                 mix -> ["-config", "/app/tmp/run.runtime"];
                 beam_com -> [A || lists:keymember(Dir ++ "sys.config", 1, Files),
                                   A <- ["-config", "/app/" ++ Dir ++ "sys"]]
             end,
    %% public_key:cacerts_get/0 reads the file of --cacerts (see
    %% with_cacerts/2), as beam.com does on Windows.
    Certs = case maps:get(cacerts, Rel, false) of
                true -> ["-public_key", "cacerts_path", "\"/app/" ++ ?CACERTS ++ "\""];
                false -> []
            end,
    Args = ["-mode", "interactive" | Config] ++ Certs
        ++ ["-boot", "/app/" ++ Dir ++ "start", "-boot_var", "RELEASE_LIB", "/app/lib"
            | VmArgs],
    %% Phoenix starts its server only with PHX_SERVER. DATABASE_PATH: the
    %% runtime.exs of Ecto SQLite needs it, and the host runs the SQL (as in
    %% page_env/1). A variable of the host replaces each one (worker.js).
    Apps = maps:get(apps, Rel, []),
    Env = [{'PHX_SERVER', <<"true">>} || lists:member(phoenix, Apps)]
        ++ [{'DATABASE_PATH', unicode:characters_to_binary(["/tmp/", Name, ".db"])}
            || lists:member(exqlite, Apps)],
    %% sql: Ecto SQLite (exqlite), whose boot can change the database (the
    %% migrations): worker.js then keeps a snapshot for each database.
    #{name => unicode:characters_to_binary(Name), vsn => unicode:characters_to_binary(Vsn),
      args => [unicode:characters_to_binary(A) || A <- Args], env => maps:from_list(Env),
      sql => lists:member(exqlite, maps:get(apps, Rel, []))}.

%% A snapshot that a Worker makes (worker.js) holds the memory of this
%% runtime with this release: its key is the hash of both, and of the code
%% of the Worker that restores it.
snapshot_key(Files, Worker) ->
    Parts = [D || {F, D} <- Worker, lists:member(F, ["worker.js", "beam.mjs", "beam.wasm"])],
    binary:encode_hex(crypto:hash(sha256, [Parts | pack(Files)]), lowercase).

%% The flags of vm.args that the runtime takes: not the emulator flags
%% (+S and the others: the runtime has its own), not a node name (use
%% DIST_NAME), and not the flags that erlexec takes.
vm_args(Data) ->
    Words = lists:append([string:lexemes(hd(string:split(L, "#")), " \t")
                          || L <- string:split(unicode:characters_to_list(Data), "\n", all)]),
    vm_args(Words, []).

vm_args([], Acc) -> lists:reverse(Acc);
vm_args(["+" ++ _, V | Rest], Acc) when hd(V) =/= $-, hd(V) =/= $+ -> vm_args(Rest, Acc);
vm_args(["+" ++ _ | Rest], Acc) -> vm_args(Rest, Acc);
vm_args(["-env", _, _ | Rest], Acc) ->
    vm_args(Rest, Acc);
vm_args([F, _ | Rest], Acc) when F =:= "-sname"; F =:= "-name"; F =:= "-setcookie";
                                 F =:= "-remsh" ->
    vm_args(Rest, Acc);
vm_args([F | Rest], Acc) when F =:= "-noshell"; F =:= "-noinput"; F =:= "-detached";
                              F =:= "-heart" ->
    vm_args(Rest, Acc);
vm_args([W | Rest], Acc) -> vm_args(Rest, [W | Acc]).

pack(Files) ->
    ["BEAMFS1\n" | [[<<(byte_size(P)):32>>, P, <<(iolist_size(D)):32>>, D]
                    || {P0, D} <- Files, P <- [unicode:characters_to_binary(P0)]]].

%% The name of a Worker for an app: a Worker name and a workers.dev host
%% name have only a-z, 0-9 and "-" (my_phoenix_app: my-phoenix-app).
worker_name(App) ->
    string:lowercase(re:replace(App, "[^A-Za-z0-9-]", "-", [global, {return, list}])).

%% The files of DIR: the runtime Worker, the Worker with the release, and
%% the configuration of workerd.
worker_files(Rel, Runtime, Root) ->
    [Priv] = filelib:wildcard(filename:join([Root, "lib", "wasm_host-*", "priv", "worker"])),
    Worker = fun(F) -> read(filename:join(Priv, F)) end,
    %% The VM restored in the global scope (global.js): a runtime Worker,
    %% or a spare VM for the Durable Objects (durable-global.js).
    Files = [{F, Worker(F)} || F <- ["worker.js", "app-com.js", "durable.js", "global.js",
                                     "durable-global.js", "tcp-proxy.mjs"]] ++
            [{"beam.mjs", read(filename:join(Runtime, "beam.mjs"))},
             {"beam.wasm", read(filename:join(Runtime, "beam.wasm"))},
             {"release/app.js", Worker("app.js")}] ++
            [F || {P, _} = F <- host_files(Rel, base64:encode(crypto:strong_rand_bytes(48))),
                  not lists:prefix("page/", P)] ++ hosts(Root) ++ licenses(Root) ++
            app_hosts(Worker),
    Files ++ [{"runtime-id.js", runtime_id_module(Files)}].

%% The hosts that run a native app.com with the runtime of the npm package
%% (runtime/ of scripts/npm.sh), each with its copy of worker.js
%% (host_worker/2):
%%
%%   deno/worker.js     for deno.js, with no import map: the imports of
%%                      deno/, so deno.js also runs from node_modules
%%   cloudflare/        a Worker that Wrangler bundles (index.js, the
%%                      module beam.com/cloudflare): worker.js (a plain
%%                      Worker) and durable.js (a Durable Object), with the
%%                      release of the app.com of the project (release.js)
%%
%% The configurations of DIR upload none of them.
app_hosts(Worker) ->
    Js = Worker("worker.js"),
    [{"deno/worker.js", host_worker(deno, Js)},
     {"cloudflare/worker.js", host_worker(cloudflare, Js)},
     {"cloudflare/durable.js", Worker("durable.js")},
     {"cloudflare/index.js", Worker("cloudflare/index.js")},
     {"cloudflare/release.js", Worker("cloudflare/release.js")},
     {"cloudflare/snapshot.js", Worker("cloudflare/snapshot.js")}].

%% The files of DIR that depend on the app: the configurations of Workers
%% and workerd, and the variables of the VM of the page. Key: the
%% SECRET_KEY_BASE of worker.capnp for a Phoenix app.
host_files(#{name := App} = Rel, Key) ->
    Name = worker_name(App),
    Phoenix = lists:member(phoenix, maps:get(apps, Rel, [])),
    Sqlite = lists:member(exqlite, maps:get(apps, Rel, [])),
    [{"wrangler.jsonc", wrangler(Name, Phoenix, Sqlite)},
     {"wrangler.durable.jsonc", wrangler_durable(Name, Phoenix)},
     {"wrangler.global.jsonc", wrangler_global(Name, Phoenix, Sqlite)},
     {"wrangler.durable-global.jsonc", wrangler_durable_global(Name, Phoenix, Sqlite)},
     {"release/wrangler.jsonc", wrangler_release(Name)},
     {"worker.capnp", capnp(Phoenix, Key)},
     {"page/env.json", page_env(Rel)}].

%% The other hosts of worker.js: Deno (deno.js, deno.json, deno/) and a web
%% page (browser.js, browser/). Each one gives worker.js the parts of the
%% Workers runtime that it uses, so one DIR runs on all of them. The
%% configurations of Workers upload none of these files.
hosts(Root) ->
    [Priv] = filelib:wildcard(filename:join([Root, "lib", "wasm_host-*", "priv"])),
    [{F, read(filename:join(Dir, F))}
     || Host <- ["deno", "browser"],
        Dir <- [filename:join(Priv, Host)],
        F <- filelib:wildcard("**", Dir),
        filelib:is_regular(filename:join(Dir, F))].

%% The license texts of the zip (licenses/NOTICE names the software in
%% beam.wasm), in the directory licenses/ of DIR. Wrangler uploads the
%% .txt files as text modules (about 80 KB), which the Worker does not
%% read: so the notices go with the runtime.
licenses(Root) ->
    Dir = filename:join(Root, "licenses"),
    [{"licenses/" ++ F, read(filename:join(Dir, F))}
     || F <- filelib:wildcard("**", Dir), filelib:is_regular(filename:join(Dir, F))].

%% DIR/page/: a static site that runs the app in the browser of each
%% visitor (for example on GitHub Pages). It is the root of the site:
%%
%%   index.html, sw.js, vm.js, ws-shim.js, scope.js, 404.html
%%                 the page (priv/wasm_host/page)
%%   env.json      the name of the app and the variables of its VM
%%   worker.js     worker.js with the imports of browser/: the VM runs in a
%%                 module Web Worker, which has no import map
%%   browser.js, browser/, beam.mjs, licenses/
%%   app/static.json, app/...   the files of priv/static of the app, which
%%                 the site serves (not the VM)
%%
%% beam.wasm and release.bin are hard links to the files of DIR
%% (write_page/2).
page_files(#{name := Name, files := Files} = Rel, Worker, Root) ->
    [Priv] = filelib:wildcard(filename:join([Root, "lib", "wasm_host-*", "priv", "page"])),
    Statics = static_files(Name, Files),
    [{F, read(filename:join(Priv, F))} || F <- files(Priv)]
        ++ [{"env.json", page_env(Rel)},
            {"worker.js", page_worker(proplists:get_value("worker.js", Worker))}]
        ++ [{F, D} || {F, D} <- Worker,
                      F =:= "browser.js" orelse F =:= "beam.mjs"
                          orelse lists:prefix("browser/", F) orelse lists:prefix("licenses/", F)]
        ++ [{"app/static.json", json:encode([unicode:characters_to_binary(P) || {P, _} <- Statics])}
            | [{"app" ++ P, D} || {P, D} <- Statics]].

%% The variables of the VM of the page. secrets: the names of the variables
%% that the page sets to random values, one for each browser.
page_env(#{name := Name} = Rel) ->
    Apps = maps:get(apps, Rel, []),
    Phoenix = lists:member(phoenix, Apps),
    %% PHX_HOST: the host that vm.js sends, so that check_origin of Phoenix
    %% takes the WebSocket.
    Env = [{'PORT', <<"4000">>}, {'HOME', <<"/tmp">>}]
        ++ [{K, V} || Phoenix, {K, V} <- [{'PHX_SERVER', <<"true">>}, {'PHX_HOST', <<"localhost">>}]]
        ++ [{'DATABASE_PATH', unicode:characters_to_binary(["/tmp/", Name, ".db"])}
            || lists:member(exqlite, Apps)],
    json:encode(#{name => unicode:characters_to_binary(Name), env => maps:from_list(Env),
                  secrets => [<<"SECRET_KEY_BASE">> || Phoenix]}).

%% The four imports of worker.js that a Web Worker cannot resolve: the
%% modules of browser/ in their place.
page_worker(Js) ->
    host_worker(page, Js).

%% worker.js with the imports of the modules of a host in place of the
%% modules of a Worker. Each import must be in worker.js, and the copy
%% must have none of the old ones.
host_worker(Host, Js) ->
    Map = case Host of
              page -> [{<<"from 'node:net'">>, <<"from './browser/net.js'">>},
                       {<<"from './beam.wasm'">>, <<"from './browser/beam-wasm.js'">>},
                       {<<"import('./release.bin')">>, <<"import('./browser/none.js')">>},
                       {<<"import('./snapshot.bin')">>, <<"import('./browser/none.js')">>}];
              deno -> [{<<"from './beam.mjs'">>, <<"from '../beam.mjs'">>},
                       {<<"from './beam.wasm'">>, <<"from './beam-wasm.js'">>},
                       {<<"import('./release.bin')">>, <<"import('./release-bin.js')">>},
                       {<<"import('./snapshot.bin')">>, <<"import('./snapshot-bin.js')">>}];
              cloudflare -> [{<<"from './beam.mjs'">>, <<"from '../beam.mjs'">>},
                             {<<"from './beam.wasm'">>, <<"from '../beam.wasm'">>},
                             {<<"(await import('./release.bin')).default">>,
                              <<"(await import('./release.js')).release()">>},
                             {<<"import('./snapshot.bin')">>, <<"import('./snapshot.js')">>}]
          end,
    In = iolist_to_binary(Js),
    Out = lists:foldl(fun({A, B}, J) -> binary:replace(J, A, B, [global]) end, In, Map),
    %% The specifier in quotes: also in another form (new URL(...)).
    Quoted = fun(A) -> {match, [Q]} = re:run(A, "'[^']*'", [{capture, first, binary}]), Q end,
    [throw({error, "worker.js: the ~p host cannot import ~ts", [Host, Quoted(A)]})
     || {A, _} <- Map, binary:match(Out, Quoted(A)) =/= nomatch],
    [throw({error, "worker.js: no ~ts for the ~p host", [A, Host]})
     || {A, _} <- Map, binary:match(In, A) =:= nomatch],
    Out.

%% The files of priv/static of the application of the release, as
%% {"/PATH", Data}, without the copies that Plug.Static compresses (the
%% site compresses its files). Not a path with a name that starts with "."
%% (.well-known/): actions/upload-pages-artifact leaves them out of the
%% site, so the VM serves them.
static_files(Name, Files) ->
    Prefix = "lib/" ++ Name ++ "-",
    lists:sort([{"/" ++ string:join(Parts, "/"), D}
                || {P, D} <- Files, lists:prefix(Prefix, P),
                   [_Vsn, "priv", "static" | Parts] <- [string:split(lists:nthtail(length(Prefix), P), "/", all)],
                   Parts =/= [], not lists:member(filename:extension(P), [".gz", ".br"]),
                   not lists:any(fun(F) -> lists:prefix(".", F) end, Parts)]).

write_page(Output, Files) ->
    Page = filename:join(Output, "page"),
    [begin ok = filelib:ensure_dir(P), write_file(P, D) end
     || {F, D} <- Files, P <- [filename:join(Page, F)]],
    link_file(filename:join(Output, "beam.wasm"), filename:join(Page, "beam.wasm")),
    link_file(filename:join([Output, "release", "release.bin"]), filename:join(Page, "release.bin")).

%% A hard link, or a copy when the file system has no hard links.
link_file(From, To) ->
    _ = file:delete(To),
    case file:make_link(From, To) of
        ok -> ok;
        {error, _} -> write_file(To, read(From))
    end.

%% The compatibility date of the Workers: 2026-08-04 or later, so that
%% nodejs_compat is on (node:net of worker.js).
-define(DATE, "2026-09-01").
%% The version of the deploy is in the key of the snapshot (worker.js).
-define(VERSION, "  // The version of the deploy: a new deploy makes a new snapshot.\n"
                 "  \"version_metadata\": { \"binding\": \"BEAM_VERSION\" }").

wrangler(Name, Phoenix, Sqlite) ->
    D1 = case Sqlite of
             true -> ",\n  // Ecto SQLite: the host runs the SQL on this D1 database (BEAM_D1\n"
                     "  // names another binding). wrangler d1 create " ++ Name ++ ", then its id.\n"
                     "  \"d1_databases\": [{ \"binding\": \"DB\", \"database_name\": \"" ++ Name ++
                     "\", \"database_id\": \"00000000-0000-0000-0000-000000000000\" }]";
             false -> ""
         end,
    Vars = phx_vars(Name, Phoenix),
    ["// The BEAM runtime Worker. It gets the release from the Worker\n"
     "// ", Name, "-release (deploy that one first). The text \"vars\" are\n"
     "// the environment of the release.\n"
     "//\n"
     "// At the first request of a new deploy, the Worker makes a snapshot of\n"
     "// its booted VM, and the next isolates start from it (a short cold\n"
     "// start). It keeps it in the Cache API, or in an R2 bucket bound as\n"
     "// SNAPSHOTS (\"r2_buckets\"). The var BEAM_SNAPSHOT = \"off\" turns this off.\n"
     "{\n"
     "  \"name\": \"", Name, "\",\n"
     "  \"main\": \"worker.js\",\n"
     "  \"compatibility_date\": \"", ?DATE, "\",\n"
     "  // The VM of an isolate serves all its requests. From this date,\n"
     "  // nodejs_compat is on: the TCP sockets of the VM use node:net.\n"
     "  \"compatibility_flags\": [\"no_handle_cross_request_promise_resolution\"],\n"
     "  // The files as they are (no bundle): an optional module that is not\n"
     "  // here (release.bin) is an error only at run time.\n"
     "  \"no_bundle\": true,\n"
     "  \"find_additional_modules\": true,\n"
     "  \"rules\": [\n"
     "    { \"type\": \"ESModule\", \"globs\": [\"worker.js\", \"beam.mjs\"] },\n"
     "    { \"type\": \"CompiledWasm\", \"globs\": [\"beam.wasm\"] },\n"
     "    { \"type\": \"Data\", \"globs\": [\"*.bin\"] }\n"
     "  ],\n"
     "  \"services\": [{ \"binding\": \"APP\", \"service\": \"", Name, "-release\" }],\n",
     ?VERSION,
     D1, Vars, "\n}\n"].

%% The host of a workers.dev URL has the subdomain of the account
%% (NAME.SUBDOMAIN.workers.dev), which the build does not know.
phx_vars(_Name, false) ->
    "";
phx_vars(Name, true) ->
    ",\n  // wrangler secret put SECRET_KEY_BASE (mix phx.gen.secret). PHX_HOST:\n"
    "  // the host of the Worker (wrangler deploy shows it).\n"
    "  \"vars\": { \"PHX_HOST\": \"" ++ Name ++ ".SUBDOMAIN.workers.dev\" }".

%% The same runtime in one Durable Object (durable.js), with its SQLite
%% storage for Ecto SQLite. Its own name (NAME-durable), so that it does
%% not replace the runtime Worker NAME.
wrangler_durable(Name, Phoenix) ->
    Vars = phx_vars(Name, Phoenix),
    ["// The BEAM runtime in one Durable Object (durable.js): one VM for all\n"
     "// the requests, and its SQLite storage for Ecto SQLite.\n"
     "//   wrangler deploy -c wrangler.durable.jsonc\n"
     "// Vars: BEAM_TENANTS (\"cookie\", \"host\" or \"path\"): an object for each\n"
     "// tenant; BEAM_INSTANCES (with \"path\"): instances with a time limit\n"
     "// (see durable.js);\n"
     "// BEAM_PERSIST (\"/data,...\"): directories whose files stay in the\n"
     "// storage of the object; BEAM_ERL_FLAGS (\"-Mea min\"): more flags of\n"
     "// the emulator (-Mea min: less memory, no :erlang.memory/0).\n"
     "{\n"
     "  \"name\": \"", Name, "-durable\",\n"
     "  \"main\": \"durable.js\",\n"
     "  \"compatibility_date\": \"", ?DATE, "\",\n"
     "  \"compatibility_flags\": [\"no_handle_cross_request_promise_resolution\"],\n"
     "  \"no_bundle\": true,\n"
     "  \"find_additional_modules\": true,\n"
     "  \"rules\": [\n"
     "    { \"type\": \"ESModule\", \"globs\": [\"durable.js\", \"worker.js\", \"beam.mjs\"] },\n"
     "    { \"type\": \"CompiledWasm\", \"globs\": [\"beam.wasm\"] },\n"
     "    { \"type\": \"Data\", \"globs\": [\"*.bin\"] }\n"
     "  ],\n"
     "  \"services\": [{ \"binding\": \"APP\", \"service\": \"", Name, "-release\" }],\n",
     ?VERSION,
     ",\n  \"durable_objects\": { \"bindings\": [{ \"name\": \"BEAM\", \"class_name\": \"Beam\" }] },\n"
     "  \"migrations\": [{ \"tag\": \"v1\", \"new_sqlite_classes\": [\"Beam\"] }]",
     Vars, "\n}\n"].

%% The runtime Worker with the release and a snapshot of the build in it
%% (global.js): the global scope restores the VM.
wrangler_global(Name, Phoenix, Sqlite) ->
    ["// The BEAM runtime Worker with the release and a snapshot of the build\n"
     "// (global.js): its global scope restores the VM, so the first request\n"
     "// of an isolate is short. First make release/snapshot.bin:\n",
     snapshot_command(Sqlite),
     "//   wrangler deploy -c wrangler.global.jsonc\n"
     "{\n"
     "  \"name\": \"", Name, "\",\n"
     "  \"main\": \"global.js\",\n"
     "  \"compatibility_date\": \"", ?DATE, "\",\n"
     "  \"compatibility_flags\": [\"no_handle_cross_request_promise_resolution\"],\n"
     "  \"no_bundle\": true,\n"
     "  \"find_additional_modules\": true,\n"
     "  \"rules\": [\n"
     "    { \"type\": \"ESModule\", \"globs\": [\"global.js\", \"worker.js\", \"beam.mjs\"] },\n"
     "    { \"type\": \"CompiledWasm\", \"globs\": [\"beam.wasm\"] },\n"
     "    { \"type\": \"Data\", \"globs\": [\"release/*.bin\"] }\n"
     "  ]",
     d1(Name, Sqlite), global_vars(Name, Phoenix, Sqlite), "\n}\n"].

%% The Durable Objects with a spare VM that the global scope restored
%% (durable-global.js).
wrangler_durable_global(Name, Phoenix, Sqlite) ->
    ["// The BEAM runtime in Durable Objects (durable-global.js): the global\n"
     "// scope of an isolate restores a spare VM from the snapshot of the\n"
     "// build, and the first object of the isolate takes it. First make\n"
     "// release/snapshot.bin:\n",
     snapshot_command(Sqlite),
     "//   wrangler deploy -c wrangler.durable-global.jsonc\n"
     "// BEAM_TENANTS (\"cookie\" or \"host\"): an object for each tenant (durable.js).\n"
     "{\n"
     "  \"name\": \"", Name, "-durable\",\n"
     "  \"main\": \"durable-global.js\",\n"
     "  \"compatibility_date\": \"", ?DATE, "\",\n"
     "  \"compatibility_flags\": [\"no_handle_cross_request_promise_resolution\"],\n"
     "  \"no_bundle\": true,\n"
     "  \"find_additional_modules\": true,\n"
     "  \"rules\": [\n"
     "    { \"type\": \"ESModule\", \"globs\": [\"durable-global.js\", \"durable.js\", \"worker.js\", \"beam.mjs\"] },\n"
     "    { \"type\": \"CompiledWasm\", \"globs\": [\"beam.wasm\"] },\n"
     "    { \"type\": \"Data\", \"globs\": [\"release/*.bin\"] }\n"
     "  ],\n",
     ?VERSION,
     ",\n  \"durable_objects\": { \"bindings\": [{ \"name\": \"BEAM\", \"class_name\": \"Beam\" }] },\n"
     "  \"migrations\": [{ \"tag\": \"v1\", \"new_sqlite_classes\": [\"Beam\"] }]",
     global_vars(Name, Phoenix, Sqlite), "\n}\n"].

%% Ecto SQLite: a snapshot at the boot point, before the program and its
%% migrations (a snapshot of the build has no database).
snapshot_command(true) ->
    "//   node wasm/snapshot/snapshot.mjs DIR --boot-point\n";
snapshot_command(false) ->
    "//   node wasm/snapshot/snapshot.mjs DIR --warm 4000:/\n"
    "// BEAM_WARM: a path of the app for one GET request in the global\n"
    "// scope (with no SQL or sockets); remove it for no request.\n".

d1(_Name, false) -> "";
d1(Name, true) ->
    ",\n  \"d1_databases\": [{ \"binding\": \"DB\", \"database_name\": \"" ++ Name ++
    "\", \"database_id\": \"00000000-0000-0000-0000-000000000000\" }]".

%% BEAM_WARM, not with the boot point (the program is not started).
global_vars(Name, Phoenix, Sqlite) ->
    Warm = case Sqlite of
               true -> "";
               false -> "\"BEAM_WARM\": \"/\""
           end,
    case {phx_vars(Name, Phoenix), Warm} of
        {"", ""} -> "";
        {"", W} -> ",\n  \"vars\": { " ++ W ++ " }";
        {V, ""} -> V;
        {V, W} -> string:replace(V, "\"vars\": { ", "\"vars\": { " ++ W ++ ", ")
    end.

%% No workers.dev URL: the runtime Worker gets the release through its
%% service binding, and no one else may get release.bin.
wrangler_release(Name) ->
    ["// The Worker with the release (release.bin), for the runtime Worker,\n"
     "// and a snapshot of the build if there is one (snapshot.bin). It has no\n"
     "// public URL: the runtime Worker gets them through its service binding.\n"
     "{\n"
     "  \"name\": \"", Name, "-release\",\n"
     "  \"main\": \"app.js\",\n"
     "  \"compatibility_date\": \"", ?DATE, "\",\n"
     "  \"workers_dev\": false,\n"
     "  \"preview_urls\": false,\n"
     "  \"no_bundle\": true,\n"
     "  \"find_additional_modules\": true,\n"
     "  \"rules\": [\n"
     "    { \"type\": \"ESModule\", \"globs\": [\"app.js\"] },\n"
     "    { \"type\": \"Data\", \"globs\": [\"*.bin\"] }\n"
     "  ]\n"
     "}\n"].

capnp(Phoenix, Key) ->
    Bindings = case Phoenix of
                   true -> ["    (name = \"PHX_HOST\", text = \"localhost\"),\n"
                            "    (name = \"SECRET_KEY_BASE\", text = \"", Key, "\"),\n"];
                   false -> []
               end,
    ["# workerd serve worker.capnp: the runtime Worker on http://127.0.0.1:8789,\n"
     "# and the Worker with the release, which it reaches with a service binding.\n"
     "using Workerd = import \"/workerd/workerd.capnp\";\n\n"
     "const config :Workerd.Config = (\n"
     "  services = [\n"
     "    (name = \"beam\", worker = .beam),\n"
     "    (name = \"app\", worker = .app),\n"
     "    (name = \"net\", network = (allow = [\"public\", \"private\", \"local\"])),\n"
     "  ],\n"
     "  sockets = [ (name = \"http\", address = \"127.0.0.1:8789\", http = (), service = \"beam\") ],\n"
     ");\n\n"
     "const beam :Workerd.Worker = (\n"
     "  modules = [\n"
     "    (name = \"worker.js\", esModule = embed \"worker.js\"),\n"
     "    (name = \"beam.mjs\", esModule = embed \"beam.mjs\"),\n"
     "    (name = \"beam.wasm\", wasm = embed \"beam.wasm\"),\n"
     "  ],\n"
     "  compatibilityDate = \"", ?DATE, "\",\n"
     "  compatibilityFlags = [\"no_handle_cross_request_promise_resolution\"],\n"
     "  globalOutbound = \"net\",\n"
     "  bindings = [\n"
     "    (name = \"APP\", service = \"app\"),\n", Bindings,
     "  ],\n"
     ");\n\n"
     "const app :Workerd.Worker = (\n"
     "  modules = [\n"
     "    (name = \"app.js\", esModule = embed \"release/app.js\"),\n"
     "    (name = \"release.bin\", data = embed \"release/release.bin\"),\n"
     "  ],\n"
     "  compatibilityDate = \"", ?DATE, "\",\n"
     ");\n"].

%% The modules that the boot loads: the build runs the release natively
%% (beam.com in erl mode, with the boot script of the release) until the
%% boot ends, and wasm_host_app:record/1 writes the loaded modules. Only
%% the modules with a .beam file in the release stay. With no run (no
%% port programs on Windows, BEAM_COM_WASM_NATIVE_RUN=0, or the boot
%% fails natively), the Worker loads the modules one by one. The run
%% starts the applications of the program on this computer, with PORT=0.
boot_modules(Files, Meta, Opts) ->
    Quiet = maps:get(quiet, Opts, false),
    case {maps:get(boot_modules, Opts, os:getenv("BEAM_COM_WASM_NATIVE_RUN") =/= "0"),
          os:type()} of
        {false, _} -> [];
        {_, {_, windows}} -> [];
        _ ->
            Tmp = beam_com_build:temp_dir("wasm"),
            try native_run(Files, Meta, Tmp, Opts) of
                {ok, Loaded} ->
                    Have = sets:from_list([filename:basename(P, ".beam")
                                           || {"lib/" ++ P, _} <- Files,
                                              filename:extension(P) =:= ".beam"]),
                    [list_to_atom(M) || M <- Loaded, sets:is_element(M, Have)];
                {error, Output} ->
                    warn(Quiet, "warning: the native run of the release failed; the Worker "
                         "loads the modules one by one:~n~ts", [Output]),
                    []
            after
                file:del_dir_r(Tmp)
            end
    end.

native_run(Files, #{name := Name, vsn := Vsn, args := Args, env := Env}, Tmp, Opts) ->
    [begin
         Path = filename:join(Tmp, P),
         ok = filelib:ensure_dir(Path),
         write_file(Path, D)
     end || {P, D} <- Files],
    Dir = filename:join([Tmp, "releases", binary_to_list(Vsn)]),
    Native = fun(Cmds) -> [relocate(C, Tmp) || C <- Cmds] end,
    write_file(filename:join(Dir, "native.boot"),
               map_boot(Native, read(filename:join(Dir, "start.boot")))),
    Out = filename:join(Tmp, "boot-modules.txt"),
    %% The arguments of the Worker, with the paths of Tmp, and the boot
    %% script with these paths.
    RunArgs = [case A of
                   "/app/" ++ R -> filename:join(Tmp, R);
                   "\"/app/" ++ R -> "\"" ++ filename:join(Tmp, R);
                   _ -> A
               end || B <- Args, A <- [binary_to_list(B)]],
    Final = boot_arg(RunArgs, filename:join(Dir, "native"))
        ++ ["-noshell", "-s", "wasm_host_app", "record", Out],
    Key = binary_to_list(base64:encode(crypto:strong_rand_bytes(48))),
    Default = fun(V, D) -> case os:getenv(V) of false -> [{V, D}]; _ -> [] end end,
    RunEnv = [{"RELEASE_ROOT", Tmp}, {"RELEASE_NAME", binary_to_list(Name)},
              {"RELEASE_VSN", binary_to_list(Vsn)}, {"RELEASE_MODE", "interactive"},
              {"RELEASE_TMP", filename:join(Tmp, "tmp")},
              {"RELEASE_SYS_CONFIG", filename:join([Tmp, "tmp", "run.runtime"])},
              {"RELEASE_PROG", binary_to_list(Name)}, {"WASM_HOST", false}]
        ++ [{atom_to_list(K), binary_to_list(V)} || K := V <- Env]
        %% As in the Worker, where no other program has the port; a
        %% Phoenix app needs a key.
        ++ Default("PORT", "0") ++ Default("SECRET_KEY_BASE", Key),
    ok = filelib:ensure_path(filename:join(Tmp, "tmp")),
    Exe = maps:get(exe, Opts, beam_com_build:executable()),
    Port = open_port({spawn_executable, Exe},
                     [{args, Final}, {env, RunEnv}, exit_status, stderr_to_stdout, binary,
                      {cd, Tmp}]),
    case collect(Port, [], 60000) of
        {0, _} ->
            {ok, Text} = file:read_file(Out),
            {ok, [binary_to_list(M) || M <- string:lexemes(Text, "\n")]};
        {_, Output} ->
            {error, Output}
    end.

boot_arg(["-boot", _ | Rest], Boot) -> ["-boot", Boot | Rest];
boot_arg([A | Rest], Boot) -> [A | boot_arg(Rest, Boot)];
boot_arg([], _Boot) -> [].

collect(Port, Acc, Timeout) ->
    receive
        {Port, {data, D}} -> collect(Port, [Acc | D], Timeout);
        {Port, {exit_status, S}} -> {S, lists:flatten(io_lib:format("~ts", [Acc]))}
    after Timeout ->
            case erlang:port_info(Port, os_pid) of
                {os_pid, Pid} -> os:cmd("kill -9 " ++ integer_to_list(Pid));
                _ -> ok
            end,
            try port_close(Port) catch error:badarg -> ok end,
            {timeout, "the boot did not end in 60 s"}
    end.

relocate(T, Tmp) when is_tuple(T) -> list_to_tuple(relocate(tuple_to_list(T), Tmp));
relocate("$ROOT" ++ Rest, Tmp) -> Tmp ++ Rest;
relocate(T, Tmp) when is_list(T) ->
    case io_lib:char_list(T) of
        true -> T;
        false -> [relocate(E, Tmp) || E <- T]
    end;
relocate(T, _Tmp) -> T.

%% The files under Dir, relative to it.
files(Dir) ->
    Len = length(filename:split(Dir)),
    [filename:join(lists:nthtail(Len, filename:split(F)))
     || F <- filelib:wildcard(filename:join(Dir, "**")), filelib:is_regular(F)].

read(Path) ->
    case file:read_file(Path) of
        {ok, B} -> B;
        {error, R} -> throw({error, "~ts: ~ts", [Path, file:format_error(R)]})
    end.

%% A .beam file without its debug information and docs.
data(Path) ->
    strip(Path, read(Path)).

%% The chunks of ?KEEP_CHUNKS. Not beam_lib:strip/1: it also removes the
%% attributes, and code such as Ecto.Repo reads the behaviours of a module
%% (module_info(attributes)).
strip(Path, B) ->
    case filename:extension(Path) of
        ".beam" ->
            {ok, {_, Chunks}} = beam_lib:chunks(B, ?KEEP_CHUNKS, [allow_missing_chunks]),
            {ok, S} = beam_lib:build_module([C || {_, X} = C <- Chunks, is_binary(X)]),
            S;
        _ -> B
    end.

write_file(File, Data) ->
    case file:write_file(File, Data) of
        ok -> ok;
        {error, R} -> throw({error, "~ts: ~ts", [File, file:format_error(R)]})
    end.
