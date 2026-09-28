%% The application of the WebAssembly host. "beam.com INPUT -o DIR
%% --target wasm32" adds it to the release, and the boot script starts it
%% after stdlib, before the applications of the program: so gen_tcp uses
%% the sockets of the host (wasm_tcp) when a server of the program
%% listens. It starts the pump (wasm_host_server) only in the WebAssembly
%% runtime (the host sets WASM_HOST); in a native run it does nothing.
-module(wasm_host_app).
-behaviour(application).
-behaviour(supervisor).

-export([start/2, stop/1, init/1, record/1]).

start(_Type, _Args) ->
    supervisor:start_link({local, wasm_host_sup}, ?MODULE, []).

stop(_State) ->
    ok.

init([]) ->
    Children = case os:getenv("WASM_HOST") of
                   false -> [];
                   _ -> [#{id => wasm_host_server, start => {wasm_host_server, start_link, []}}]
               end,
    {ok, {#{strategy => one_for_one, intensity => 0, period => 1}, Children}}.

%% "-s wasm_host_app record FILE": write the modules that the boot loaded
%% (one name for each line), and the modules of the host, which a native
%% run does not load; then stop. The build runs the release natively with
%% this, and the boot script of the Worker loads these modules in one
%% batch (code:ensure_modules_loaded/1).
record([File]) ->
    Loaded = [M || {M, _} <- code:all_loaded()],
    {ok, Mods} = application:get_key(wasm_host, modules),
    Names = lists:usort(Loaded ++ Mods -- [wasm_tcp_dist]),
    ok = file:write_file(atom_to_list(File), [[atom_to_list(M), $\n] || M <- Names]),
    erlang:halt(0).
