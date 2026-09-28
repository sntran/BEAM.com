%% Messages between Erlang and the JavaScript host (wasm_host_nif.c, a
%% static NIF of the WebAssembly emulator).
-module(wasm_host).
-export([select/0, take/0, send/1]).
-on_load(init/0).

init() -> erlang:load_nif("wasm_host", 0).

%% The caller gets {select, _, undefined, ready_input} when the host has
%% events (enif_select on a pipe that the host writes to): then take/0.
-spec select() -> ok.
select() -> erlang:nif_error(not_loaded).

%% The next event of the host (a binary), or empty. It does not wait.
-spec take() -> binary() | empty.
take() -> erlang:nif_error(not_loaded).

%% Gives iodata to the host (Module.beamHost.onsend).
-spec send(iodata()) -> ok.
send(_Data) -> erlang:nif_error(not_loaded).
