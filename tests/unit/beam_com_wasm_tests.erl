%% Unit tests for beam_com_wasm (--target wasm32).
-module(beam_com_wasm_tests).

-include_lib("eunit/include/eunit.hrl").

vm_args_test_() ->
    [?_assertEqual([], beam_com_wasm:vm_args(<<"## a comment\n-noshell\n">>)),
     {"no emulator flags, no node name, no -env",
      ?_assertEqual(["-kernel", "shell_history", "enabled", "-s", "m"],
                    beam_com_wasm:vm_args(<<"+S 4\n+A 8\n-sname app # the name\n-setcookie c\n"
                                            "-env A 1\n+sbwt none\n-kernel shell_history enabled\n"
                                            "-s m\n">>))},
     {"a flag of the emulator without a value",
      ?_assertEqual(["-mode", "embedded"], beam_com_wasm:vm_args(<<"+Bi\n-mode embedded\n">>))}].

boot() ->
    term_to_binary({script, {"app", "1"},
                    [{preLoaded, [init]},
                     {path, ["$ROOT/lib/kernel-1/ebin", "$ROOT/lib/stdlib-2/ebin"]},
                     {primLoad, [lists]},
                     {kernel_load_completed},
                     {path, ["$ROOT/lib/kernel-1/ebin"]},
                     {primLoad, [gen_tcp]},
                     {path, ["$ROOT/lib/stdlib-2/ebin"]},
                     {primLoad, [maps]},
                     {apply, {application, start_boot, [kernel, permanent]}},
                     {apply, {application, start_boot, [stdlib, permanent]}},
                     {apply, {application, start_boot, [app, permanent]}}]}).

commands(Files) ->
    {_, Boot} = lists:keyfind("releases/1/start.boot", 1, Files),
    {script, _, Cmds} = binary_to_term(Boot),
    Cmds.

%% A zip of beam.com with the application wasm_host.
root() ->
    Root = filename:join(os:getenv("TMPDIR", "/tmp"), "beam_com_wasm_root"),
    _ = file:del_dir_r(Root),
    Ebin = filename:join([Root, "lib", "wasm_host-0.1.0", "ebin"]),
    ok = filelib:ensure_path(Ebin),
    ok = file:write_file(filename:join(Ebin, "wasm_host.app"),
                         io_lib:format("~p.~n", [{application, wasm_host, [{vsn, "0.1.0"}]}])),
    {ok, wasm_tcp, Beam} = compile:forms([{attribute, 1, module, wasm_tcp}], [binary]),
    ok = file:write_file(filename:join(Ebin, "wasm_tcp.beam"), Beam),
    Root.

with_host_test_() ->
    Root = root(),
    Files = beam_com_wasm:with_host([{"releases/1/start.boot", boot()}], Root),
    Cmds = commands(Files),
    Ebin = "$ROOT/lib/wasm_host-0.1.0/ebin",
    [{"the files of wasm_host",
      ?_assert(lists:keymember("lib/wasm_host-0.1.0/ebin/wasm_tcp.beam", 1, Files))},
     {"the paths with stdlib get the ebin of wasm_host (a path command replaces "
      "the one before it)",
      [?_assert(lists:member({path, ["$ROOT/lib/kernel-1/ebin", "$ROOT/lib/stdlib-2/ebin", Ebin]},
                             Cmds)),
       ?_assert(lists:member({path, ["$ROOT/lib/stdlib-2/ebin", Ebin]}, Cmds)),
       ?_assert(lists:member({path, ["$ROOT/lib/kernel-1/ebin"]}, Cmds))]},
     {"wasm_host starts after stdlib, before the program",
      ?_assertMatch([stdlib, wasm_host, app],
                    [A || {apply, {application, start_boot, [A, _]}} <- Cmds, A =/= kernel])},
     {"and it is loaded first",
      ?_assertMatch([{apply, {application, load, [{application, wasm_host, _}]}}],
                    [C || {apply, {application, load, _}} = C <- Cmds])},
     {"a release with its own copy of a module of wasm_host",
      ?_assertThrow({error, "~ts: the release has its own copy of a module of wasm_host; remove it",
                     ["lib/app-1/ebin/wasm_tcp.beam"]},
                    beam_com_wasm:with_host([{"lib/app-1/ebin/wasm_tcp.beam", <<>>}], Root))}].

with_boot_modules_test_() ->
    Files = [{"releases/1/start.boot", boot()}, {"lib/a-1/ebin/a.beam", <<"x">>}],
    [?_assertEqual(Files, beam_com_wasm:with_boot_modules(Files, [])),
     {"the batch after kernel starts",
      ?_assertMatch([_, {apply, {application, start_boot, [kernel, _]}},
                     {apply, {code, ensure_modules_loaded, [[lists, maps]]}},
                     {apply, {application, start_boot, [stdlib, _]}} | _],
                    lists:nthtail(7, commands(
                                       beam_com_wasm:with_boot_modules(Files, [lists, maps]))))}].

meta_test_() ->
    Files = [{"releases/1/vm.args", <<"-sname a\n-s m\n">>}, {"releases/1/sys.config", <<"[].">>}],
    [{"a release of beam.com: its sys.config, and the flags of vm.args",
      ?_assertEqual(#{name => <<"app">>, vsn => <<"1">>, env => #{},
                      args => [<<"-mode">>, <<"interactive">>,
                               <<"-config">>, <<"/app/releases/1/sys">>,
                               <<"-boot">>, <<"/app/releases/1/start">>,
                               <<"-boot_var">>, <<"RELEASE_LIB">>, <<"/app/lib">>,
                               <<"-s">>, <<"m">>]},
                    beam_com_wasm:meta(#{name => "app", vsn => "1", kind => beam_com,
                                         files => Files}))},
     {"a mix release: the runtime configuration in tmp/, and PHX_SERVER for Phoenix",
      ?_assertMatch(#{args := [<<"-mode">>, <<"interactive">>,
                               <<"-config">>, <<"/app/tmp/run.runtime">> | _],
                      env := #{'PHX_SERVER' := <<"true">>}},
                    beam_com_wasm:meta(#{name => "app", vsn => "1", kind => mix, files => [],
                                         apps => [phoenix]}))}].

pack_test() ->
    Bin = iolist_to_binary(beam_com_wasm:pack([{"a", <<"xy">>}, {"é", [<<"z">>]}])),
    ?assertEqual(<<"BEAMFS1\n", 1:32, "a", 2:32, "xy", 2:32, "é"/utf8, 1:32, "z">>, Bin).

runtime_dir_test_() ->
    Root = root(),
    Runtime = filename:join(Root, "runtime"),
    Set = fun(V) -> case V of false -> os:unsetenv("BEAM_COM_WASM_RUNTIME");
                        _ -> os:putenv("BEAM_COM_WASM_RUNTIME", V) end end,
    Cache = os:getenv("BEAM_COM_CACHE"),
    {setup,
     fun() ->
             os:putenv("BEAM_COM_CACHE", filename:join(Root, "cache")),
             Old = os:getenv("BEAM_COM_WASM_RUNTIME"),
             Set(false),
             Old
     end,
     fun(Old) ->
             Set(Old),
             case Cache of false -> os:unsetenv("BEAM_COM_CACHE");
                 _ -> os:putenv("BEAM_COM_CACHE", Cache) end
     end,
     [{"no runtime",
       ?_assertThrow({error, "the WebAssembly runtime (beam.wasm and beam.mjs) is not in ~ts: "
                      "set BEAM_COM_WASM_RUNTIME to its directory, or put it in ~ts", _},
                     beam_com_wasm:runtime_dir(Root))},
      {"BEAM_COM_WASM_RUNTIME",
       fun() ->
               ok = filelib:ensure_path(Runtime),
               [ok = file:write_file(filename:join(Runtime, F), <<>>)
                || F <- ["beam.wasm", "beam.mjs"]],
               Set(Runtime),
               ?assertEqual(Runtime, beam_com_wasm:runtime_dir(Root)),
               Set(false)
       end},
      {"in the zip",
       fun() ->
               Priv = filename:join([Root, "lib", "wasm_host-0.1.0", "priv", "runtime"]),
               ok = filelib:ensure_path(Priv),
               [ok = file:write_file(filename:join(Priv, F), <<>>)
                || F <- ["beam.wasm", "beam.mjs"]],
               ?assertEqual(Priv, beam_com_wasm:runtime_dir(Root))
       end}]}.

snapshot_key_test_() ->
    Files = [{"lib/a-1/ebin/a.beam", <<"x">>}],
    Worker = [{"worker.js", <<"w">>}, {"beam.mjs", <<"m">>}, {"beam.wasm", <<"b">>},
              {"worker.capnp", <<"a random key">>}],
    Key = beam_com_wasm:snapshot_key(Files, Worker),
    [?_assertEqual(64, byte_size(Key)),
     {"the same runtime, Worker and release: the same key",
      ?_assertEqual(Key, beam_com_wasm:snapshot_key(Files, lists:keyreplace("worker.capnp", 1, Worker,
                                                                           {"worker.capnp", <<"other">>})))},
     {"another release: another key",
      ?_assertNotEqual(Key, beam_com_wasm:snapshot_key([{"lib/a-1/ebin/a.beam", <<"y">>}], Worker))},
     {"another runtime: another key",
      ?_assertNotEqual(Key, beam_com_wasm:snapshot_key(Files, lists:keyreplace("beam.wasm", 1, Worker,
                                                                               {"beam.wasm", <<"c">>})))}].

%% The files of the output directory: the global scope variant only
%% without Ecto SQLite, the Durable Object with its own name, and the
%% Worker with the release with no public URL.
worker_files_test() ->
    Root = root(),
    Priv = filename:join([Root, "lib", "wasm_host-0.1.0", "priv", "worker"]),
    Runtime = filename:join(Root, "runtime"),
    [ok = filelib:ensure_path(D) || D <- [Priv, Runtime]],
    [ok = file:write_file(filename:join(Priv, F), F)
     || F <- ["worker.js", "durable.js", "global.js", "tcp-proxy.mjs", "app.js"]],
    [ok = file:write_file(filename:join(Runtime, F), F) || F <- ["beam.mjs", "beam.wasm"]],
    Files = fun(Apps) -> [{F, iolist_to_binary(D)}
                          || {F, D} <- beam_com_wasm:worker_files(#{name => "app", apps => Apps},
                                                                  Runtime, Root)] end,
    Plain = Files([]),
    Has = fun(Fs, Name, Text) -> binary:match(proplists:get_value(Name, Fs), Text) =/= nomatch end,
    ?assertEqual(<<"global.js">>, proplists:get_value("global.js", Plain)),
    ?assert(Has(Plain, "wrangler.global.jsonc", <<"\"main\": \"global.js\"">>)),
    ?assert(Has(Plain, "wrangler.global.jsonc", <<"\"BEAM_WARM\": \"/\"">>)),
    ?assert(Has(Plain, "wrangler.durable.jsonc", <<"\"name\": \"app-durable\"">>)),
    ?assert(Has(Plain, "release/wrangler.jsonc", <<"\"workers_dev\": false">>)),
    ?assert(Has(Plain, "wrangler.jsonc", <<"\"version_metadata\": { \"binding\": \"BEAM_VERSION\" }">>)),
    ?assert(Has(Plain, "wrangler.durable.jsonc", <<"\"version_metadata\"">>)),
    Sqlite = Files([exqlite]),
    ?assertNot(lists:keymember("global.js", 1, Sqlite)),
    ?assertNot(lists:keymember("wrangler.global.jsonc", 1, Sqlite)),
    ?assert(Has(Sqlite, "wrangler.jsonc", <<"\"d1_databases\"">>)),
    Phoenix = Files([phoenix]),
    ?assert(Has(Phoenix, "wrangler.jsonc", <<"\"PHX_HOST\": \"app.SUBDOMAIN.workers.dev\"">>)),
    ?assert(Has(Phoenix, "wrangler.global.jsonc",
                <<"\"BEAM_WARM\": \"/\", \"PHX_HOST\": \"app.SUBDOMAIN.workers.dev\"">>)).

%% A module in place of the NIF of exqlite: the exports of the original,
%% calls to the shim, and not_supported for the others.
sqlite_shim_test() ->
    Mod = 'Elixir.Exqlite.Sqlite3NIF',
    Forms = [{attribute, 1, module, Mod},
             {attribute, 1, export, [{load_nif, 0}, {open, 2}, {made_up, 1}]},
             {function, 1, load_nif, 0, [{clause, 1, [], [], [{atom, 1, native}]}]},
             {function, 1, open, 2, [{clause, 1, [{var, 1, '_'}, {var, 1, '_'}], [], [{atom, 1, native}]}]},
             {function, 1, made_up, 1, [{clause, 1, [{var, 1, '_'}], [], [{atom, 1, native}]}]}],
    {ok, Mod, Original} = compile:forms(Forms, [binary]),
    Bin = beam_com_wasm:sqlite_shim(Original, [{open, 2}]),
    {module, Mod} = code:load_binary(Mod, "shim", Bin),
    try
        ?assertEqual(ok, Mod:load_nif()),
        ets:info(wasm_host_sqlite) =:= undefined andalso wasm_host_sqlite:table(),
        ?assertMatch({ok, {wasm_sqlite, _}}, Mod:open("db", [])),   % the shim
        ?assertError(not_supported, Mod:made_up(x))
    after
        code:purge(Mod), code:delete(Mod)
    end.

%% The file nifs of the runtime: the hex.pm packages whose NIFs it has.
runtime_nifs_test() ->
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"), "beam_com_wasm_nifs"),
    ok = filelib:ensure_path(Dir),
    _ = file:delete(filename:join(Dir, "nifs")),
    ?assertEqual([], beam_com_wasm:runtime_nifs(Dir)),
    ok = file:write_file(filename:join(Dir, "nifs"), <<"bcrypt_elixir 3.3.2\nargon2_elixir 4.1.3\n">>),
    ?assertEqual([bcrypt_elixir, argon2_elixir], beam_com_wasm:runtime_nifs(Dir)).
