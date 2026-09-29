%% The NIF of exqlite in the WebAssembly runtime (a static NIF of
%% beam.wasm, wasm/erts/build.sh): SQLite in the VM. Its files are the
%% memory files of Emscripten, or the files of the host when it has them
%% (wasm/erts/sqlite_vfs.c: Deno KV in deno.js). wasm_host_sqlite sends
%% the calls of the module Exqlite.Sqlite3NIF of a release here when the
%% host does not run the SQL itself.
-module(wasm_host_exqlite).
-on_load(init/0).

-export([available/0]).
-export([open/2, close/1, execute/2, changes/1, prepare/2, reset/1, bind_parameter_count/1,
         bind_parameter_index/2, bind_text/3, bind_blob/3, bind_integer/3, bind_float/3,
         bind_null/2, step/2, multi_step/3, columns/2, last_insert_rowid/1,
         transaction_status/1, serialize/2, deserialize/3, release/2,
         enable_load_extension/2, set_update_hook/2, set_authorizer/2, set_log_hook/1,
         interrupt/1, set_busy_timeout/2, set_progress_handler_steps/2, cancel/1, errmsg/1,
         errstr/1, erlang_allocator_enabled/0]).

%% A runtime without this NIF (an older beam.wasm, or a native run) loads
%% the module with no NIF: available/0 is then false.
init() ->
    _ = erlang:load_nif("wasm_host_exqlite", #{disable_erlang_allocator => false}),
    ok.

-spec available() -> boolean().
available() ->
    try erlang_allocator_enabled() of
        _ -> true
    catch
        error:{nif_not_loaded, _} -> false;
        error:not_loaded -> false
    end.

open(_Path, _Flags) -> erlang:nif_error(not_loaded).
close(_Conn) -> erlang:nif_error(not_loaded).
execute(_Conn, _Sql) -> erlang:nif_error(not_loaded).
changes(_Conn) -> erlang:nif_error(not_loaded).
prepare(_Conn, _Sql) -> erlang:nif_error(not_loaded).
reset(_Stmt) -> erlang:nif_error(not_loaded).
bind_parameter_count(_Stmt) -> erlang:nif_error(not_loaded).
bind_parameter_index(_Stmt, _Name) -> erlang:nif_error(not_loaded).
bind_text(_Stmt, _Index, _Text) -> erlang:nif_error(not_loaded).
bind_blob(_Stmt, _Index, _Blob) -> erlang:nif_error(not_loaded).
bind_integer(_Stmt, _Index, _Int) -> erlang:nif_error(not_loaded).
bind_float(_Stmt, _Index, _Float) -> erlang:nif_error(not_loaded).
bind_null(_Stmt, _Index) -> erlang:nif_error(not_loaded).
step(_Conn, _Stmt) -> erlang:nif_error(not_loaded).
multi_step(_Conn, _Stmt, _Steps) -> erlang:nif_error(not_loaded).
columns(_Conn, _Stmt) -> erlang:nif_error(not_loaded).
last_insert_rowid(_Conn) -> erlang:nif_error(not_loaded).
transaction_status(_Conn) -> erlang:nif_error(not_loaded).
serialize(_Conn, _Db) -> erlang:nif_error(not_loaded).
deserialize(_Conn, _Db, _Bin) -> erlang:nif_error(not_loaded).
release(_Conn, _Stmt) -> erlang:nif_error(not_loaded).
enable_load_extension(_Conn, _Flag) -> erlang:nif_error(not_loaded).
set_update_hook(_Conn, _Pid) -> erlang:nif_error(not_loaded).
set_authorizer(_Conn, _DenyList) -> erlang:nif_error(not_loaded).
set_log_hook(_Pid) -> erlang:nif_error(not_loaded).
interrupt(_Conn) -> erlang:nif_error(not_loaded).
set_busy_timeout(_Conn, _Ms) -> erlang:nif_error(not_loaded).
set_progress_handler_steps(_Conn, _Steps) -> erlang:nif_error(not_loaded).
cancel(_Conn) -> erlang:nif_error(not_loaded).
errmsg(_Conn) -> erlang:nif_error(not_loaded).
errstr(_Code) -> erlang:nif_error(not_loaded).
erlang_allocator_enabled() -> erlang:nif_error(not_loaded).
