%% The memory of the VM in the runtime of WebAssembly (issue 141), with
%% the cases of the mmap() of ERTS for Emscripten (wasm/erts/otp.patch):
%%
%%   renders       renders of about 2 MB of terms in new processes, as the
%%                 render of a big page of LiveView
%%   big_binaries  binaries of 16 MB (a carrier of their own) in new
%%                 processes
%%   heap_shrink   a big heap, then a garbage collection that shrinks it
%%                 (an unmap of the tail of a carrier, erts_mremap())
%%   binary_growth a binary that grows in steps (a carrier that grows)
%%   parallel      16 processes with big heaps at one time, then their end
%%
%% Each case runs a first time, then again: the output has the memory of
%% WebAssembly (wasm_host:memory/0) after the first time and at the end,
%% and the same for the memory that malloc() gives out
%% (wasm_host:memory(used)), with the time of that call in microseconds.
%% A process keeps a binary of 8 MB and a list during all the cases, and
%% checks them at the end: an unmap must not free memory that is in use.
%% Only for the runtime of WebAssembly.
%%
%% With the argument pause, the program waits 1500 ms after the first
%% case: the driver takes a snapshot 300 ms after the first line, and the
%% threads of ERTS return only while the program waits.
-module(mem_check).
-export([main/1]).

main(Args) ->
    %% A crash dump goes where the test reads it (as diff_halt does).
    true = os:putenv("ERL_CRASH_DUMP", "/work/erl_crash.dump"),
    Keeper = keeper(),
    run(renders, fun() -> renders(50) end, fun() -> renders(250) end),
    case lists:member(pause, Args) of
        true -> receive after 1500 -> ok end;
        false -> ok
    end,
    run(big_binaries, fun() -> repeat(3, fun big_binary/0) end,
        fun() -> repeat(20, fun big_binary/0) end),
    run(heap_shrink, fun() -> repeat(3, fun heap_shrink/0) end,
        fun() -> repeat(30, fun heap_shrink/0) end),
    run(binary_growth, fun() -> repeat(2, fun binary_growth/0) end,
        fun() -> repeat(10, fun binary_growth/0) end),
    run(parallel, fun() -> repeat(2, fun parallel/0) end,
        fun() -> repeat(10, fun parallel/0) end),
    Keeper ! {check, self()},
    receive
        {keeper, Result} -> io:format("mem_check: keeper ~p~n", [Result])
    end,
    io:format("mem_check: erlang_memory ~s~n", [erlang_memory()]).

run(Name, First, Again) ->
    First(),
    put(used_first, wasm_host:memory(used)),
    A = wasm_host:memory(),
    put(steps, [A]),
    Again(),
    B = wasm_host:memory(),
    All = lists:reverse(erase(steps)),
    Steps = changes(All),
    io:format("mem_check: ~s ~b ~b~n", [Name, A, B]),
    io:format("mem_check: ~s steps~s~n", [Name, [[$\s, integer_to_list(S)] || S <- Steps]]),
    %% The memory that malloc() gives out after the first time and at the
    %% end (wasm_host:memory(used)): it goes down when the VM frees memory,
    %% so a leak grows it, and free memory that a block does not fit in
    %% does not.
    UsedA = get(used_first),
    {Time, UsedB} = timer:tc(wasm_host, memory, [used]),
    io:format("mem_check: ~s used ~b ~b ~b~n", [Name, UsedA, UsedB, Time]).

%% The memory after each repetition of the second time, with no two
%% values the same one after the other: a leak gives many steps, and the
%% free memory of malloc that does not fit a block gives one.
changes([X, X | T]) -> changes([X | T]);
changes([X | T]) -> [X | changes(T)];
changes([]) -> [].

repeat(0, _) -> ok;
repeat(N, F) -> in_process(F), step(), repeat(N - 1, F).

step() ->
    case get(steps) of
        undefined -> ok;
        Steps -> put(steps, [wasm_host:memory() | Steps])
    end.

%% F in a new process, which then ends.
in_process(F) ->
    {Pid, Ref} = spawn_monitor(fun() -> exit({done, F()}) end),
    receive
        {'DOWN', Ref, process, Pid, {done, _}} -> ok;
        {'DOWN', Ref, process, Pid, Other} -> exit({mem_check, Other})
    end.

renders(N) -> repeat(N, fun() -> byte_size(render(1000)) end).

%% K * 8 rows of small tuples and strings, and one binary of them.
render(K) ->
    Rows = [{row, I, "item-" ++ integer_to_list(I),
             [[" x=\"", float_to_list(I * 1.5), "\""], [" y=\"", float_to_list(I / 3), "\""]]}
            || I <- lists:seq(1, K * 8)],
    iolist_to_binary([["<g id=\"", Id, "\"", Attrs, ">", integer_to_list(I), "</g>"]
                      || {row, I, Id, Attrs} <- Rows]).

big_binary() ->
    B = binary:copy(<<1, 2, 3, 4, 5, 6, 7, 8>>, 2 * 1024 * 1024),
    16 * 1024 * 1024 = byte_size(B),
    <<1, 2, 3, 4, 5, 6, 7, 8>> = binary:part(B, byte_size(B) - 8, 8),
    ok.

%% A heap of about 8 MB, then a collection that keeps 1 element in 100.
heap_shrink() ->
    L = [{I, I * 2} || I <- lists:seq(1, 300000)],
    Kept = [X || {I, _} = X <- L, I rem 100 =:= 0],
    erlang:garbage_collect(),
    3000 = length(Kept),
    true = lists:sum([I || {I, _} <- Kept]) =:= lists:sum(lists:seq(100, 300000, 100)),
    erlang:garbage_collect(),
    ok.

%% A binary of 8 MB from appends of 64 KB.
binary_growth() ->
    Chunk = binary:copy(<<7>>, 65536),
    B = lists:foldl(fun(_, Acc) -> <<Acc/binary, Chunk/binary>> end, <<>>, lists:seq(1, 128)),
    8388608 = byte_size(B),
    ok.

%% 16 processes with heaps of about 1 MB at one time.
parallel() ->
    Self = self(),
    Pids = [spawn_link(fun() ->
                           L = lists:seq(1, 60000),
                           Self ! {ready, self()},
                           receive go -> length(L) end
                       end) || _ <- lists:seq(1, 16)],
    [receive {ready, P} -> ok end || P <- Pids],
    [P ! go || P <- Pids],
    ok.

keeper() ->
    Bin = rand:bytes(8 * 1024 * 1024),
    List = lists:seq(1, 100000),
    Sum = {erlang:md5(Bin), lists:sum(List)},
    spawn(fun() -> keep(Bin, List, Sum) end).

keep(Bin, List, Sum) ->
    receive
        {check, From} ->
            Now = {erlang:md5(Bin), lists:sum(List)},
            From ! {keeper, case Now of Sum -> ok; _ -> changed end}
    end.

%% erlang:memory(total), or none with -Mea min.
erlang_memory() ->
    try integer_to_list(erlang:memory(total))
    catch error:_ -> "none"
    end.
