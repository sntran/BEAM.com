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

-export([release_dir/2, write/3]).

-ifdef(TEST).
-export([release_files/2, with_host/2, with_boot_modules/2, vm_args/1, pack/1,
         runtime_dir/1, meta/1, worker_files/3, snapshot_key/2]).
-endif.

-define(HOST_APP, wasm_host).
%% The applications whose NIFs are only in the native beam.com.
-define(NATIVE_NIFS, [esqlite, wasm, exqlite, bcrypt_elixir]).

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
    Apps = [A || {"lib/" ++ P, _} <- Files0, [D, "ebin", F] <- [string:split(P, "/", all)],
                 {A, _} <- [beam_com_build:split_dir(D)], F =:= atom_to_list(A) ++ ".app"],
    [warn(Quiet, "warning: ~p has a NIF that the WebAssembly runtime does not have", [A])
     || A <- lists:usort(Apps), lists:member(A, ?NATIVE_NIFS)],
    Files1 = with_host(Files0, Root),
    Meta = meta(Rel#{apps => Apps}),
    Mods = boot_modules(Files1, Meta, Opts),
    Files = with_boot_modules(Files1, Mods),
    Worker = worker_files(Rel#{apps => Apps}, Runtime, Root),
    Bin = pack([{".release.json", json:encode(Meta#{snapshot_key => snapshot_key(Files, Worker)})}
                | Files]),
    [ok = filelib:ensure_path(filename:join(Output, D)) || D <- ["", "release"]],
    [write_file(filename:join(Output, F), D) || {F, D} <- Worker],
    write_file(filename:join([Output, "release", "release.bin"]), Bin),
    Quiet orelse io:format("~ts: wrote ~ts (the Workers ~ts and ~ts-release)~n"
                           "  release: ~ts ~ts, ~b files, ~.1f MB~n"
                           "  boot: ~ts~n"
                           "  test: workerd serve ~ts~n"
                           "  deploy: (cd ~ts/release && wrangler deploy) && (cd ~ts && wrangler deploy)~n",
                           [beam_com:name(), Output, Name, Name, Name, Vsn, length(Files),
                            iolist_size(Bin) / 1048576,
                            case Mods of
                                [] -> "the modules load one by one (no native run)";
                                _ -> io_lib:format("~b modules in one batch", [length(Mods)])
                            end,
                            filename:join(Output, "worker.capnp"), Output, Output]),
    ok.

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
    Boot = fun(Cmds) ->
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
                              {apply, {application, start_boot, [?HOST_APP, permanent]}}];
                        (C) -> [C]
                     end, Cmds)
           end,
    [{P, case lists:suffix("/start.boot", P) of
             true -> map_boot(Boot, D);
             false -> D
         end} || {P, D} <- Files, not lists:prefix(Dir ++ "/", P)] ++ Host.

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
    Args = ["-mode", "interactive" | Config]
        ++ ["-boot", "/app/" ++ Dir ++ "start", "-boot_var", "RELEASE_LIB", "/app/lib"
            | VmArgs],
    %% Phoenix starts its server only with PHX_SERVER.
    Env = [{'PHX_SERVER', <<"true">>} || lists:member(phoenix, maps:get(apps, Rel, []))],
    #{name => unicode:characters_to_binary(Name), vsn => unicode:characters_to_binary(Vsn),
      args => [unicode:characters_to_binary(A) || A <- Args], env => maps:from_list(Env)}.

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

%% The files of DIR: the runtime Worker, the Worker with the release, and
%% the configuration of workerd.
worker_files(#{name := Name} = Rel, Runtime, Root) ->
    [Priv] = filelib:wildcard(filename:join([Root, "lib", "wasm_host-*", "priv", "worker"])),
    Worker = fun(F) -> read(filename:join(Priv, F)) end,
    Phoenix = lists:member(phoenix, maps:get(apps, Rel, [])),
    [{"worker.js", Worker("worker.js")},
     {"tcp-proxy.mjs", Worker("tcp-proxy.mjs")},
     {"beam.mjs", read(filename:join(Runtime, "beam.mjs"))},
     {"beam.wasm", read(filename:join(Runtime, "beam.wasm"))},
     {"release/app.js", Worker("app.js")},
     {"wrangler.jsonc", wrangler(Name, Phoenix)},
     {"release/wrangler.jsonc", wrangler_release(Name)},
     {"worker.capnp", capnp(Phoenix)}].

-define(DATE, "2026-09-01").

wrangler(Name, Phoenix) ->
    Vars = case Phoenix of
               true -> ",\n  // wrangler secret put SECRET_KEY_BASE (mix phx.gen.secret)\n"
                       "  \"vars\": { \"PHX_HOST\": \"" ++ Name ++ ".workers.dev\" }";
               false -> ""
           end,
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
     "  // The VM of an isolate serves all its requests.\n"
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
     "  \"services\": [{ \"binding\": \"APP\", \"service\": \"", Name, "-release\" }]",
     Vars, "\n}\n"].

wrangler_release(Name) ->
    ["// The Worker with the release (release.bin), for the runtime Worker,\n"
     "// and a snapshot of the build if there is one (snapshot.bin).\n"
     "{\n"
     "  \"name\": \"", Name, "-release\",\n"
     "  \"main\": \"app.js\",\n"
     "  \"compatibility_date\": \"", ?DATE, "\",\n"
     "  \"no_bundle\": true,\n"
     "  \"find_additional_modules\": true,\n"
     "  \"rules\": [\n"
     "    { \"type\": \"ESModule\", \"globs\": [\"app.js\"] },\n"
     "    { \"type\": \"Data\", \"globs\": [\"*.bin\"] }\n"
     "  ]\n"
     "}\n"].

capnp(Phoenix) ->
    Key = base64:encode(crypto:strong_rand_bytes(48)),
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

strip(Path, B) ->
    case filename:extension(Path) of
        ".beam" -> {ok, {_, S}} = beam_lib:strip(B), S;
        _ -> B
    end.

write_file(File, Data) ->
    case file:write_file(File, Data) of
        ok -> ok;
        {error, R} -> throw({error, "~ts: ~ts", [File, file:format_error(R)]})
    end.
