%% The memory of the VM over renders in new processes (issue 141). Each
%% render makes about 2 MB of terms in a new process, which then ends,
%% as the render of a big page of LiveView. The output: the memory of
%% WebAssembly (wasm_host:memory/0) after the first renders, and after
%% all of them. Only for the runtime of WebAssembly.
-module(mem_check).
-export([main/1]).

main(_) ->
    renders(50),
    First = wasm_host:memory(),
    renders(250),
    Last = wasm_host:memory(),
    io:format("mem_check: ~b ~b~n", [First, Last]).

renders(0) ->
    ok;
renders(N) ->
    {Pid, Ref} = spawn_monitor(fun() -> exit({size, byte_size(render(1000))}) end),
    receive
        {'DOWN', Ref, process, Pid, {size, _}} -> ok
    end,
    renders(N - 1).

%% K * 8 rows of small tuples and strings, and one binary of them.
render(K) ->
    Rows = [{row, I, "item-" ++ integer_to_list(I),
             [[" x=\"", float_to_list(I * 1.5), "\""], [" y=\"", float_to_list(I / 3), "\""]]}
            || I <- lists:seq(1, K * 8)],
    iolist_to_binary([["<g id=\"", Id, "\"", Attrs, ">", integer_to_list(I), "</g>"]
                      || {row, I, Id, Attrs} <- Rows]).
