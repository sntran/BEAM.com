%% Unit tests for wasm_host_sqlite, the NIF of exqlite in the WebAssembly
%% runtime (the parts that need no host).
-module(wasm_host_sqlite_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    case ets:info(wasm_host_sqlite) of
        undefined -> wasm_host_sqlite:table();
        _ -> ok
    end.

local_test_() ->
    L = fun wasm_host_sqlite:local/1,
    [?_assertEqual(tx_begin, L(<<"BEGIN IMMEDIATE TRANSACTION">>)),
     ?_assertEqual(tx_begin, L(<<"SAVEPOINT exqlite_savepoint">>)),
     ?_assertEqual(tx_release, L(<<"RELEASE SAVEPOINT exqlite_savepoint">>)),
     ?_assertEqual(tx_rollback_to, L(<<"ROLLBACK TO SAVEPOINT exqlite_savepoint">>)),
     ?_assertEqual(tx_rollback, L(<<"ROLLBACK TRANSACTION">>)),
     ?_assertEqual(tx_commit, L(<<"commit;">>)),
     ?_assertEqual({pragma, <<"journal_mode">>, <<"WAL">>}, L(<<"PRAGMA journal_mode = WAL">>)),
     ?_assertEqual({pragma, <<"foreign_keys">>}, L(<<"PRAGMA foreign_keys">>)),
     {"a PRAGMA with an argument: the host", ?_assertEqual(host, L(<<"PRAGMA table_info(\"notes\")">>))},
     ?_assertEqual(host, L(<<"SELECT 1">>))].

params_test_() ->
    P = fun wasm_host_sqlite:params/1,
    [?_assertEqual({3, []}, P(<<"SELECT ?1, ?2 FROM t WHERE a = ?3">>)),
     ?_assertEqual({2, []}, P(<<"INSERT INTO t VALUES (?, ?)">>)),
     {"not in strings or quoted names",
      ?_assertEqual({1, []}, P(<<"SELECT '?', \"a?\", [b?], `c?`, ? -- ?\n /* ? */">>))},
     {"a quote in a string",
      ?_assertEqual({1, []}, P(<<"SELECT 'it''s ?', ?">>))},
     {"named parameters, once each",
      ?_assertEqual({2, [{<<":a">>, 1}, {<<"@b">>, 2}]}, P(<<"SELECT :a, @b, :a">>))}].

wire_test_() ->
    [?_assertEqual(#{b => <<"AAH/">>}, wasm_host_sqlite:wire({blob, <<0, 1, 255>>})),
     ?_assertEqual(#{i => <<"9007199254740993">>}, wasm_host_sqlite:wire(9007199254740993)),
     ?_assertEqual(42, wasm_host_sqlite:wire(42)),
     ?_assertEqual(null, wasm_host_sqlite:wire(null)),
     ?_assertEqual(<<0, 1, 255>>, wasm_host_sqlite:unwire(#{<<"b">> => <<"AAH/">>})),
     ?_assertEqual(9007199254740993, wasm_host_sqlite:unwire(#{<<"i">> => <<"9007199254740993">>})),
     ?_assertEqual(nil, wasm_host_sqlite:unwire(null))].

connection_test_() ->
    {setup, fun setup/0,
     fun(_) ->
             {ok, C} = wasm_host_sqlite:open("db", []),
             [?_assertEqual({ok, idle}, wasm_host_sqlite:transaction_status(C)),
              ?_test(begin
                         ok = wasm_host_sqlite:execute(C, "BEGIN TRANSACTION"),
                         ?assertEqual({ok, transaction}, wasm_host_sqlite:transaction_status(C)),
                         ok = wasm_host_sqlite:execute(C, "SAVEPOINT exqlite_savepoint"),
                         ok = wasm_host_sqlite:execute(C, "RELEASE SAVEPOINT exqlite_savepoint"),
                         ?assertEqual({ok, transaction}, wasm_host_sqlite:transaction_status(C)),
                         ok = wasm_host_sqlite:execute(C, "COMMIT"),
                         ?assertEqual({ok, idle}, wasm_host_sqlite:transaction_status(C))
                     end),
              {"a PRAGMA that was set, read back as a row",
               ?_test(begin
                          ok = wasm_host_sqlite:execute(C, "PRAGMA foreign_keys = ON"),
                          {ok, S} = wasm_host_sqlite:prepare(C, "PRAGMA foreign_keys"),
                          ?assertEqual({ok, [<<"foreign_keys">>]}, wasm_host_sqlite:columns(C, S)),
                          ?assertEqual({done, [[<<"ON">>]]}, wasm_host_sqlite:multi_step(C, S, 50))
                      end)},
              {"binds and the parameter count",
               ?_test(begin
                          {ok, S} = wasm_host_sqlite:prepare(C, "SELECT ?1, :x"),
                          ?assertEqual(2, wasm_host_sqlite:bind_parameter_count(S)),
                          ?assertEqual(2, wasm_host_sqlite:bind_parameter_index(S, ":x")),
                          ?assertEqual(0, wasm_host_sqlite:bind_text(S, 1, "a")),
                          ?assertEqual(0, wasm_host_sqlite:bind_blob(S, 2, <<1>>)),
                          ?assertEqual(ok, wasm_host_sqlite:release(C, S))
                      end)},
              ?_assertEqual(ok, wasm_host_sqlite:close(C))]
     end}.
