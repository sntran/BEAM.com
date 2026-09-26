%% Benchmarks for BEAM.com: a one-file program for "beam.com build".
%%
%%   beam.com build tests/bench/bench.erl -o bench.com
%%   ./bench.com [NAME...]        the benchmarks (all without NAME)
%%   ./bench.com none              nothing (to measure the start)
%%   ./bench.com start EXE ARG...  the start time of a program
%%
%% Each benchmark runs 3 times; the best time is printed, one line each:
%%
%%   bench NAME MILLISECONDS
%%
%% The work is the same for each build, so the times of a build with the
%% interpreter (beam.com) and with the JIT (beam-jit.com) can be compared
%% on the same machine. tests/bench/run.sh runs it and makes a table.
-module(bench).
-export([main/1]).

-define(RUNS, 3).

main(["start", Exe | Args]) ->
    start_time(Exe, Args);
main(["none"]) ->
    ok;
main(Names) ->
    All = benchmarks(),
    Selected = case Names of
                   [] -> All;
                   _ -> [B || {N, _} = B <- All, lists:member(atom_to_list(N), Names)]
               end,
    [run(Name, Fun) || {Name, Fun} <- Selected],
    ok.

benchmarks() ->
    [{fib, fun() -> fib(32) end},
     {lists, fun lists_work/0},
     {maps, fun maps_work/0},
     {ets, fun ets_work/0},
     {binary, fun binary_work/0},
     {messages, fun messages_work/0},
     {crypto, fun crypto_work/0},
     {sqlite, fun sqlite_work/0},
     {wasm_calls, fun wasm_calls/0},
     {wasm_loop, fun wasm_loop/0}].

%% The start time of a program: the median of 10 runs, from the start of
%% the process to its end (as a port program, so not on Windows).
start_time(Exe, Args) ->
    Path = case filename:pathtype(Exe) of
               absolute -> Exe;
               _ -> os:find_executable(Exe)
           end,
    Times = lists:sort([run_once(Path, Args) || _ <- lists:seq(1, 10)]),
    io:format("start ~b~n", [lists:nth(5, Times)]).

run_once(Path, Args) ->
    T0 = erlang:monotonic_time(millisecond),
    Port = open_port({spawn_executable, Path},
                     [{args, Args}, exit_status, binary, stderr_to_stdout]),
    0 = wait_exit(Port),
    erlang:monotonic_time(millisecond) - T0.

wait_exit(Port) ->
    receive
        {Port, {data, _}} -> wait_exit(Port);
        {Port, {exit_status, Status}} -> Status
    end.

run(Name, Fun) ->
    Times = [time_ms(Fun) || _ <- lists:seq(1, ?RUNS)],
    io:format("bench ~s ~b~n", [Name, lists:min(Times)]).

time_ms(Fun) ->
    {Us, _} = timer:tc(Fun),
    Us div 1000.

%% Function calls and integer arithmetic.
fib(N) when N < 2 -> N;
fib(N) -> fib(N - 1) + fib(N - 2).

%% List functions on 1000000 numbers.
lists_work() ->
    L = [(I * 7919) rem 100003 || I <- lists:seq(1, 1000000)],
    S = lists:sort(L),
    M = lists:map(fun(X) -> X * 2 + 1 end, S),
    lists:foldl(fun(X, Acc) -> Acc + X end, 0, M).

%% Map inserts and lookups.
maps_work() ->
    M = lists:foldl(fun(I, Acc) -> Acc#{I => I} end, #{}, lists:seq(1, 200000)),
    lists:foldl(fun(I, Acc) -> Acc + maps:get(I, M) end, 0, lists:seq(1, 200000)).

%% ETS inserts and lookups.
ets_work() ->
    T = ets:new(bench, [set]),
    [ets:insert(T, {I, I}) || I <- lists:seq(1, 200000)],
    S = lists:foldl(fun(I, Acc) -> [{_, V}] = ets:lookup(T, I), Acc + V end,
                    0, lists:seq(1, 200000)),
    ets:delete(T),
    S.

%% Building and matching binaries.
binary_work() ->
    B = << <<(I band 255)>> || I <- lists:seq(1, 5000000) >>,
    count_bytes(B, 0).

count_bytes(<<X, Rest/binary>>, Acc) -> count_bytes(Rest, Acc + X);
count_bytes(<<>>, Acc) -> Acc.

%% 200000 messages there and back between two processes.
messages_work() ->
    Self = self(),
    Pid = spawn_link(fun() -> echo(Self) end),
    ping(Pid, 200000),
    Pid ! stop,
    ok.

ping(_, 0) -> ok;
ping(Pid, N) ->
    Pid ! {ping, N},
    receive {pong, N} -> ping(Pid, N - 1) end.

echo(Parent) ->
    receive
        {ping, N} -> Parent ! {pong, N}, echo(Parent);
        stop -> ok
    end.

%% SHA-256 of 64 MB (the crypto NIF: the same code with and without JIT).
crypto_work() ->
    Block = binary:copy(<<"0123456789abcdef">>, 65536),
    Ctx = lists:foldl(fun(_, C) -> crypto:hash_update(C, Block) end,
                      crypto:hash_init(sha256), lists:seq(1, 64)),
    crypto:hash_final(Ctx).

%% 20000 inserts in one transaction, and a query.
sqlite_work() ->
    {ok, Db} = esqlite3:open(":memory:"),
    ok = esqlite3:exec(Db, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"),
    ok = esqlite3:exec(Db, "BEGIN"),
    [[] = esqlite3:q(Db, "INSERT INTO t (v) VALUES (?)", [I])
     || I <- lists:seq(1, 20000)],
    ok = esqlite3:exec(Db, "COMMIT"),
    [[_]] = esqlite3:q(Db, "SELECT sum(v) FROM t"),
    ok = esqlite3:close(Db).

%% 100000 calls from Erlang into WebAssembly (the cost of a call).
wasm_calls() ->
    Inst = wasm_instance(),
    wasm_add(Inst, 100000).

wasm_add(_, 0) -> ok;
wasm_add(Inst, N) ->
    {ok, [_]} = wasm:call(Inst, "add", [N, 1]),
    wasm_add(Inst, N - 1).

%% A loop in WebAssembly: the sum of 64 KB, 200 times (the interpreter
%% of WAMR).
wasm_loop() ->
    Inst = wasm_instance(),
    [{ok, [_]} = wasm:call(Inst, "sum", [0, 65535]) || _ <- lists:seq(1, 200)],
    ok.

wasm_instance() ->
    {ok, Mod} = wasm:load(math_module()),
    {ok, Inst} = wasm:instantiate(Mod),
    Inst.

%% The module of examples/wasm_check.erl: add(i32, i32) and
%% sum(ptr, len), which adds the bytes of the memory.
math_module() ->
    Types = vec([functype([i32, i32], [i32])]),
    Funcs = vec([uleb(0), uleb(0)]),
    Memory = vec([<<0, 1>>]),
    Exports = vec([export("add", 0, 0), export("sum", 0, 1),
                   export("memory", 2, 0)]),
    Add = body([], <<16#20, 0, 16#20, 1, 16#6a>>),
    Sum = body([{1, i32}],
               <<16#02, 16#40, 16#03, 16#40,
                 16#20, 1, 16#45, 16#0d, 1,
                 16#20, 2, 16#20, 0, 16#2d, 0, 0, 16#6a, 16#21, 2,
                 16#20, 0, 16#41, 1, 16#6a, 16#21, 0,
                 16#20, 1, 16#41, 1, 16#6b, 16#21, 1,
                 16#0c, 0, 16#0b, 16#0b,
                 16#20, 2>>),
    module([section(1, Types), section(3, Funcs), section(5, Memory),
            section(7, Exports), section(10, vec([Add, Sum]))]).

module(Sections) -> iolist_to_binary([<<0, "asm", 1, 0, 0, 0>> | Sections]).
section(Id, Contents) -> <<Id, (bin_vec(Contents))/binary>>.
vec(Items) -> iolist_to_binary([uleb(length(Items)) | Items]).
bin_vec(Bin) -> <<(uleb(byte_size(Bin)))/binary, Bin/binary>>.
name(S) -> bin_vec(list_to_binary(S)).
functype(Params, Results) ->
    <<16#60, (vec([<<16#7f>> || i32 <- Params]))/binary,
      (vec([<<16#7f>> || i32 <- Results]))/binary>>.
export(Name, Kind, Index) -> <<(name(Name))/binary, Kind, (uleb(Index))/binary>>.
body(Locals, Instrs) ->
    L = vec([<<(uleb(N))/binary, 16#7f>> || {N, i32} <- Locals]),
    bin_vec(<<L/binary, Instrs/binary, 16#0b>>).
uleb(N) when N < 128 -> <<N>>;
uleb(N) -> <<(N band 127 bor 128), (uleb(N bsr 7))/binary>>.
