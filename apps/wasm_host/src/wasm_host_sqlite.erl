%% The NIF of exqlite (Exqlite.Sqlite3NIF, for Ecto SQLite: ecto_sqlite3)
%% in the WebAssembly runtime, where there is no SQLite: the host runs the
%% SQL (worker.js: the SQLite storage of a Durable Object, or D1).
%% "beam.com INPUT -o DIR --target wasm32" puts a module
%% 'Elixir.Exqlite.Sqlite3NIF' in the release that calls this one.
%%
%% A statement runs on the host at its first columns/2, step/2 or
%% multi_step/3 (after the binds), and its rows come back at once. The
%% transactions: BEGIN, COMMIT, ROLLBACK and the savepoints only change
%% transaction_status/1, because neither backend lets SQL control a
%% transaction: each statement commits alone, and a rollback does not undo
%% (see docs/WORKERS.md). A PRAGMA that sets a value does nothing; a PRAGMA
%% with no value gives the value that was set.
-module(wasm_host_sqlite).

-export([open/2, close/1, interrupt/1, set_busy_timeout/2, set_progress_handler_steps/2,
         cancel/1, execute/2, changes/1, prepare/2, step/2, multi_step/3, columns/2,
         last_insert_rowid/1, transaction_status/1, serialize/2, deserialize/3, release/2,
         enable_load_extension/2, set_update_hook/2, set_authorizer/2, set_log_hook/1,
         bind_parameter_count/1, bind_parameter_index/2, bind_text/3, bind_blob/3,
         bind_integer/3, bind_float/3, bind_null/2, reset/1, errmsg/1, errstr/1,
         erlang_allocator_enabled/0]).
-export([table/0, params/1, wire/1, unwire/1, local/1]).

-define(TABLE, wasm_host_sqlite).
-define(TIMEOUT, 60000).

%% The table of the connections and the statements (the owner: the pump,
%% wasm_host_server).
table() ->
    ets:new(?TABLE, [named_table, public, {read_concurrency, true}]).

%% --- connections ---------------------------------------------------------

open(Path, _Flags) ->
    Conn = {wasm_sqlite, make_ref()},
    Db = unicode:characters_to_binary(Path),
    ets:insert(?TABLE, {Conn, #{db => Db, depth => 0, changes => 0, rowid => 0, pragmas => #{}}}),
    {ok, Conn}.

close(Conn) -> ets:delete(?TABLE, Conn), ok.
interrupt(_Conn) -> ok.
set_busy_timeout(_Conn, _Ms) -> ok.
set_progress_handler_steps(_Conn, _Steps) -> ok.
cancel(_Conn) -> ok.
enable_load_extension(_Conn, _Flag) -> ok.
set_update_hook(_Conn, _Pid) -> ok.
set_authorizer(_Conn, _DenyList) -> ok.
set_log_hook(_Pid) -> ok.
erlang_allocator_enabled() -> false.
serialize(_Conn, _Db) -> {error, <<"serialize is not supported by the host">>}.
deserialize(_Conn, _Db, _Bin) -> {error, <<"deserialize is not supported by the host">>}.

changes(Conn) -> {ok, maps:get(changes, conn(Conn))}.
last_insert_rowid(Conn) -> {ok, maps:get(rowid, conn(Conn))}.

transaction_status(Conn) ->
    case maps:get(depth, conn(Conn)) of
        0 -> {ok, idle};
        _ -> {ok, transaction}
    end.

execute(Conn, Sql0) ->
    Sql = iolist_to_binary(Sql0),
    C = conn(Conn),
    case local(Sql) of
        tx_begin -> put_conn(Conn, C#{depth := maps:get(depth, C) + 1}), ok;
        tx_commit -> put_conn(Conn, C#{depth := 0}), ok;
        tx_rollback -> put_conn(Conn, C#{depth := 0}), ok;
        tx_release -> put_conn(Conn, C#{depth := max(0, maps:get(depth, C) - 1)}), ok;
        tx_rollback_to -> ok;
        {pragma, Name, Value} ->
            put_conn(Conn, C#{pragmas := (maps:get(pragmas, C))#{Name => Value}}), ok;
        {pragma, _Name} -> ok;
        host ->
            case run(Conn, C, Sql, []) of
                {ok, _Columns, _Rows} -> ok;
                {error, _} = E -> E
            end
    end.

%% The statements that the shim answers itself.
local(Sql) ->
    Words = string:lexemes(string:uppercase(unicode:characters_to_list(Sql)), " \t\r\n;"),
    case Words of
        ["BEGIN" | _] -> tx_begin;
        ["SAVEPOINT" | _] -> tx_begin;
        ["COMMIT" | _] -> tx_commit;
        ["END" | _] -> tx_commit;
        ["ROLLBACK", "TO" | _] -> tx_rollback_to;
        ["ROLLBACK" | _] -> tx_rollback;
        ["RELEASE" | _] -> tx_release;
        ["PRAGMA" | _] -> pragma(Sql);
        _ -> host
    end.

%% PRAGMA name = value (set), PRAGMA name (get); else (table_info(t) and
%% the others) the host.
pragma(Sql) ->
    Rest = string:trim(string:slice(string:trim(Sql, both, " \t\r\n;"), 6)),
    case re:run(Rest, "^([A-Za-z_][A-Za-z0-9_.]*)\\s*(=\\s*(.*))?$", [{capture, all, binary}]) of
        {match, [_, Name]} -> {pragma, string:lowercase(Name)};
        {match, [_, Name, _, Value]} -> {pragma, string:lowercase(Name), string:trim(Value)};
        nomatch -> host
    end.

%% --- statements ------------------------------------------------------------

prepare(Conn, Sql0) ->
    _ = conn(Conn),
    Sql = iolist_to_binary(Sql0),
    Stmt = {wasm_sqlite_stmt, make_ref()},
    {Count, Names} = params(Sql),
    ets:insert(?TABLE, {Stmt, #{conn => Conn, sql => Sql, count => Count, names => Names,
                                binds => #{}, result => none}}),
    {ok, Stmt}.

release(_Conn, Stmt) -> ets:delete(?TABLE, Stmt), ok.

reset(Stmt) -> update(Stmt, fun(S) -> S#{result := none} end), ok.

bind_parameter_count(Stmt) -> maps:get(count, stmt(Stmt)).

bind_parameter_index(Stmt, Name) ->
    case lists:keyfind(iolist_to_binary(Name), 1, maps:get(names, stmt(Stmt))) of
        {_, Index} -> Index;
        false -> 0
    end.

bind_text(Stmt, I, V) -> bind(Stmt, I, iolist_to_binary(V)).
bind_blob(Stmt, I, V) -> bind(Stmt, I, {blob, iolist_to_binary(V)}).
bind_integer(Stmt, I, V) -> bind(Stmt, I, V).
bind_float(Stmt, I, V) -> bind(Stmt, I, V).
bind_null(Stmt, I) -> bind(Stmt, I, null).

bind(Stmt, I, V) ->
    update(Stmt, fun(#{binds := B} = S) -> S#{binds := B#{I => V}, result := none} end),
    0.

columns(Conn, Stmt) ->
    case result(Conn, Stmt) of
        {ok, #{columns := Columns}} -> {ok, Columns};
        {error, _} = E -> E
    end.

step(Conn, Stmt) ->
    case result(Conn, Stmt) of
        {ok, #{rows := [Row | Rest]} = R} -> set_result(Stmt, R#{rows := Rest}), {row, Row};
        {ok, #{rows := []}} -> set_result(Stmt, none), done;
        {error, _} = E -> E
    end.

%% As the NIF: each chunk in reverse order (Exqlite.Sqlite3 reverses it).
multi_step(Conn, Stmt, Chunk) ->
    case result(Conn, Stmt) of
        {ok, #{rows := Rows} = R} when length(Rows) > Chunk ->
            {Take, Rest} = lists:split(Chunk, Rows),
            set_result(Stmt, R#{rows := Rest}),
            {rows, lists:reverse(Take)};
        {ok, #{rows := Rows}} ->
            set_result(Stmt, none),
            {done, lists:reverse(Rows)};
        {error, _} = E -> E
    end.

errmsg(_) -> nil.
errstr(Rc) -> iolist_to_binary(io_lib:format("error ~p", [Rc])).

%% The rows of a statement: the ones that are left, or a new run.
result(Conn, Stmt) ->
    case stmt(Stmt) of
        #{result := none, sql := Sql, count := Count, binds := Binds} ->
            C = conn(Conn),
            case local(Sql) of
                {pragma, Name} ->
                    Value = maps:get(Name, maps:get(pragmas, C), nil),
                    R = #{columns => [Name], rows => [[Value]]},
                    set_result(Stmt, R),
                    {ok, R};
                _ ->
                    Params = [maps:get(I, Binds, null) || I <- lists:seq(1, Count)],
                    case run(Conn, C, Sql, Params) of
                        {ok, Columns, Rows} ->
                            R = #{columns => Columns, rows => Rows},
                            set_result(Stmt, R),
                            {ok, R};
                        {error, _} = E -> E
                    end
            end;
        #{result := R} ->
            {ok, R}
    end.

%% One statement on the host: {"t":"sql","id":ID,"db":DB}, and a JSON body
%% {"sql", "params"}. The answer: {"t":"sql_reply","id":ID} and {"columns",
%% "rows", "changes", "last_row_id"} or {"error"}.
run(Conn, C, Sql, Params) ->
    Id = iolist_to_binary(["q", integer_to_binary(erlang:unique_integer([positive]))]),
    wasm_host_server:register(Id),
    try
        wasm_host_server:send_host(#{t => sql, id => Id, db => maps:get(db, C)},
                                   json:encode(#{sql => Sql, params => [wire(P) || P <- Params]})),
        receive
            {wasm_host, <<"sql_reply">>, #{<<"id">> := Id}, Body} ->
                case json:decode(Body) of
                    #{<<"error">> := Msg} ->
                        {error, Msg};
                    #{<<"columns">> := Columns, <<"rows">> := Rows} = R ->
                        C1 = conn(Conn),
                        put_conn(Conn, C1#{changes := maps:get(<<"changes">>, R, 0),
                                           rowid := maps:get(<<"last_row_id">>, R, maps:get(rowid, C1))}),
                        {ok, Columns, [[unwire(V) || V <- Row] || Row <- Rows]}
                end
        after ?TIMEOUT ->
                {error, <<"the host did not answer">>}
        end
    after
        wasm_host_server:unregister(Id)
    end.

%% The values on the wire (JSON): an integer out of the safe range of
%% JavaScript as {"i": "123"}, a blob as {"b": base64}.
wire(null) -> null;
wire({blob, B}) -> #{b => base64:encode(B)};
wire(I) when is_integer(I), abs(I) > 9007199254740991 -> #{i => integer_to_binary(I)};
wire(V) -> V.

unwire(null) -> nil;
unwire(#{<<"b">> := B}) -> base64:decode(B);
unwire(#{<<"i">> := I}) -> binary_to_integer(I);
unwire(V) -> V.

%% The number of the parameters of SQL (?, ?NNN, :name, @name, $name), and
%% the names with their indexes; not in strings, quoted names or comments.
params(Sql) -> params(Sql, 0, []).

params(<<>>, N, Names) -> {N, lists:reverse(Names)};
params(<<$', R/binary>>, N, Names) -> params(skip(R, $'), N, Names);
params(<<$", R/binary>>, N, Names) -> params(skip(R, $"), N, Names);
params(<<$`, R/binary>>, N, Names) -> params(skip(R, $`), N, Names);
params(<<$[, R/binary>>, N, Names) -> params(skip(R, $]), N, Names);
params(<<"--", R/binary>>, N, Names) ->
    params(case binary:split(R, <<"\n">>) of [_, T] -> T; _ -> <<>> end, N, Names);
params(<<"/*", R/binary>>, N, Names) ->
    params(case binary:split(R, <<"*/">>) of [_, T] -> T; _ -> <<>> end, N, Names);
params(<<$?, R/binary>>, N, Names) ->
    {Digits, T} = digits(R, <<>>),
    case Digits of
        <<>> -> params(T, N + 1, Names);
        _ -> params(T, max(N, binary_to_integer(Digits)), Names)
    end;
params(<<P, C, R/binary>>, N, Names) when (P =:= $: orelse P =:= $@ orelse P =:= $$),
                                          (C >= $a andalso C =< $z orelse C >= $A andalso C =< $Z
                                           orelse C =:= $_) ->
    {Name, T} = word(<<C, R/binary>>, <<>>),
    Full = <<P, Name/binary>>,
    case lists:keymember(Full, 1, Names) of
        true -> params(T, N, Names);
        false -> params(T, N + 1, [{Full, N + 1} | Names])
    end;
params(<<_, R/binary>>, N, Names) -> params(R, N, Names).

skip(<<Q, Q, R/binary>>, Q) -> skip(R, Q);
skip(<<Q, R/binary>>, Q) -> R;
skip(<<_, R/binary>>, Q) -> skip(R, Q);
skip(<<>>, _) -> <<>>.

digits(<<D, R/binary>>, Acc) when D >= $0, D =< $9 -> digits(R, <<Acc/binary, D>>);
digits(R, Acc) -> {Acc, R}.

word(<<C, R/binary>>, Acc) when C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9; C =:= $_ ->
    word(R, <<Acc/binary, C>>);
word(R, Acc) -> {Acc, R}.

%% --- the table ---------------------------------------------------------------

conn(Conn) ->
    case ets:lookup(?TABLE, Conn) of
        [{_, C}] -> C;
        [] -> error(badarg)
    end.

put_conn(Conn, C) -> ets:insert(?TABLE, {Conn, C}).

stmt(Stmt) ->
    case ets:lookup(?TABLE, Stmt) of
        [{_, S}] -> S;
        [] -> error(badarg)
    end.

update(Stmt, F) -> ets:insert(?TABLE, {Stmt, F(stmt(Stmt))}).

set_result(Stmt, R) -> update(Stmt, fun(S) -> S#{result := R} end).
