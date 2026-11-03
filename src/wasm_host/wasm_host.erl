%% Messages between Erlang and the JavaScript host (wasm_host_nif.c, a
%% static NIF of the WebAssembly emulator).
-module(wasm_host).
-export([select/0, take/0, send/1, memory/0, memory/1]).
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

%% The size of the memory of WebAssembly in bytes: all the memory of the
%% VM, which the host counts against its limit (128 MB on Cloudflare
%% Workers). It never shrinks, so it is also the peak of the VM. It works
%% also with -Mea min, where erlang:memory/0 is not supported.
-spec memory() -> non_neg_integer().
memory() -> erlang:nif_error(not_loaded).

%% memory(size) is memory/0. memory(used) is the memory that the VM uses
%% now: the bytes that malloc() gives out, which go down when the VM frees
%% memory. With -Mea min, this is near the use of ERTS. With the default
%% allocators, it also has the free parts of the carriers of ERTS. Thus
%% memory(size) - memory(used) is about the memory that the VM can use
%% again before the size grows. The call walks all the chunks of malloc(),
%% so call it at most each few seconds.
-spec memory(size | used) -> non_neg_integer().
memory(_Kind) -> erlang:nif_error(not_loaded).
