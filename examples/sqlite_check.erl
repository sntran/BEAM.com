%% A one-file program for "beam.com build" that uses SQLite (esqlite).
%% It needs a beam.com built with SQLITE=1.
%%
%%   beam.com build sqlite_check.erl
%%   ./sqlite_check.com [DATABASE]   (default: an in-memory database)
-module(sqlite_check).
-export([main/1]).

main(Args) ->
    File = case Args of
               [F | _] -> F;
               [] -> ":memory:"
           end,
    {ok, Db} = esqlite3:open(File),
    [[Version]] = esqlite3:q(Db, "SELECT sqlite_version()"),
    io:format("sqlite: version ~s~n", [Version]),
    ok = esqlite3:exec(Db, "CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, name TEXT)"),
    ok = esqlite3:exec(Db, "DELETE FROM t"),
    [[] = esqlite3:q(Db, "INSERT INTO t (name) VALUES (?)", [Name])
     || Name <- [<<"alpha">>, <<"beta">>, <<"gamma">>]],
    Rows = esqlite3:q(Db, "SELECT id, name FROM t ORDER BY id"),
    io:format("sqlite: rows ~p~n", [Rows]),
    [[Json]] = esqlite3:q(Db, "SELECT json_group_array(name) FROM t"),
    io:format("sqlite: json ~s~n", [Json]),
    [[Count]] = esqlite3:q(Db, "SELECT count(*) FROM t"),
    io:format("sqlite: ~b rows in ~ts~n", [Count, File]),
    ok = esqlite3:close(Db).
