%% Messages between Erlang and the JavaScript host (wasm_host_nif.c, a
%% static NIF of the WebAssembly emulator).
-module(wasm_host).
-export([recv/0, send/1]).
-on_load(init/0).

init() -> erlang:load_nif("wasm_host", 0).

%% The next event of the host (a binary). It waits on a dirty I/O
%% scheduler.
-spec recv() -> binary().
recv() -> erlang:nif_error(not_loaded).

%% Gives iodata to the host (Module.beamHost.onsend).
-spec send(iodata()) -> ok.
send(_Data) -> erlang:nif_error(not_loaded).
