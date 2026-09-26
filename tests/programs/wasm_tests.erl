%% Behavior tests of the wasm application, in beam.com itself (the NIF
%% is static, so these tests cannot run in a normal Erlang).
%%
%%   beam.com build tests/programs/wasm_tests.erl
%%   ./wasm_tests.com
%%
%% It prints one line for each test and "wasm_tests: all N passed", and
%% exits with 1 when a test fails. The modules are made by the small
%% encoder at the end, so the tests need no WebAssembly compiler.
-module(wasm_tests).
-export([main/1]).
-export([test_i32/0, test_i32_range/0, test_i64/0, test_i64_range/0,
         test_f32/0, test_f64/0, test_integer_as_float/0, test_non_finite/0,
         test_multi_value/0, test_bad_calls/0, test_traps/0,
         test_after_trap/0, test_stack_exhaustion/0, test_memory/0,
         test_memory_grow/0, test_no_memory/0, test_load_errors/0,
         test_missing_import/0, test_resource_lifetime/0,
         test_concurrent_calls/0, test_many_instances/0, test_wasi_exit/0,
         test_wasi_return/0, test_wasi_args_env/0, test_no_start/0,
         test_run_module/0, test_instantiate_options/0,
         test_instantiate_bytes/0, test_imports/0, test_function_exists/0,
         test_memory_grow_erlang/0, test_start/0]).

main(_) ->
    Tests = [T || {T, 0} <- ?MODULE:module_info(exports),
                  lists:prefix("test_", atom_to_list(T))],
    Results = [run(T) || T <- lists:sort(Tests)],
    Failed = [T || {T, fail} <- Results],
    case Failed of
        [] -> io:format("wasm_tests: all ~b passed~n", [length(Results)]);
        _ -> io:format("wasm_tests: ~b of ~b failed: ~p~n",
                       [length(Failed), length(Results), Failed]),
             halt(1)
    end.

run(T) ->
    try ?MODULE:T() of
        _ -> io:format("PASS ~s~n", [T]), {T, pass}
    catch
        C:R:S -> io:format("FAIL ~s: ~p:~p~n  ~p~n", [T, C, R, S]), {T, fail}
    end.



-define(eq(Expected, Expr),
        (fun() ->
                 Want = Expected,
                 case Expr of
                     Want -> ok;
                     Other -> error({not_equal, ??Expr, Want, Other})
                 end
         end)()).

%%% Values

%% (func (param i32 i32) (result i32) (i32.add))
test_i32() ->
    I = inst(binop(i32, 16#6a)),
    ?eq({ok, [3]}, wasm:call_function(I, "f", [1, 2])),
    ?eq({ok, [-2]}, wasm:call_function(I, "f", [-1, -1])),
    %% Wraps around, and results are signed.
    ?eq({ok, [-2147483648]}, wasm:call_function(I, "f", [2147483647, 1])),
    ?eq({ok, [-1]}, wasm:call_function(I, "f", [16#ffffffff, 0])),
    ?eq({ok, [0]}, wasm:call_function(I, "f", [16#ffffffff, 1])).

test_i32_range() ->
    I = inst(binop(i32, 16#6a)),
    ?eq({ok, [-2147483648]}, wasm:call_function(I, "f", [-2147483648, 0])),
    ?eq({error, badarg}, wasm:call_function(I, "f", [-2147483649, 0])),
    ?eq({error, badarg}, wasm:call_function(I, "f", [16#100000000, 0])),
    ?eq({error, badarg}, wasm:call_function(I, "f", [1 bsl 100, 0])),
    ?eq({error, badarg}, wasm:call_function(I, "f", [1.0, 0])),
    ?eq({error, badarg}, wasm:call_function(I, "f", [one, 0])).

test_i64() ->
    I = inst(binop(i64, 16#7c)),
    Max = 16#7fffffffffffffff,
    Min = -16#8000000000000000,
    ?eq({ok, [Max]}, wasm:call_function(I, "f", [Max, 0])),
    ?eq({ok, [Min]}, wasm:call_function(I, "f", [Max, 1])),
    ?eq({ok, [Min]}, wasm:call_function(I, "f", [Min, 0])),
    %% Unsigned values up to 2^64-1 are accepted (as their bits).
    ?eq({ok, [-1]}, wasm:call_function(I, "f", [16#ffffffffffffffff, 0])).

test_i64_range() ->
    I = inst(binop(i64, 16#7c)),
    ?eq({error, badarg}, wasm:call_function(I, "f", [1 bsl 64, 0])),
    ?eq({error, badarg}, wasm:call_function(I, "f", [-(1 bsl 63) - 1, 0])),
    ?eq({error, badarg}, wasm:call_function(I, "f", [2.0, 0])).

test_f32() ->
    I = inst(binop(f32, 16#92)),
    ?eq({ok, [3.5]}, wasm:call_function(I, "f", [1.25, 2.25])),
    %% f32 precision: 0.1 is not exact in 32 bits.
    {ok, [X]} = wasm:call_function(I, "f", [0.1, 0.0]),
    true = X =/= 0.1 andalso abs(X - 0.1) < 1.0e-7,
    ok.

test_f64() ->
    I = inst(binop(f64, 16#a0)),
    ?eq({ok, [0.30000000000000004]}, wasm:call_function(I, "f", [0.1, 0.2])),
    ?eq({ok, [1.7976931348623157e308]}, wasm:call_function(I, "f", [1.7976931348623157e308, 0.0])).

test_integer_as_float() ->
    I = inst(binop(f64, 16#a0)),
    ?eq({ok, [5.0]}, wasm:call_function(I, "f", [2, 3])),
    ?eq({error, badarg}, wasm:call_function(I, "f", [x, 3])).

%% Results that Erlang floats cannot hold (NaN and infinity).
test_non_finite() ->
    I = inst(binop(f64, 16#a3)),                  % f64.div
    ?eq({ok, [nan]}, wasm:call_function(I, "f", [0.0, 0.0])),
    ?eq({ok, [infinity]}, wasm:call_function(I, "f", [1.0, 0.0])),
    ?eq({ok, ['-infinity']}, wasm:call_function(I, "f", [-1.0, 0.0])),
    %% The atoms are accepted as arguments too.
    ?eq({ok, [infinity]}, wasm:call_function(I, "f", [infinity, 1.0])),
    ?eq({ok, [nan]}, wasm:call_function(I, "f", [nan, 1.0])).

%% (func (param i32 i64) (result i64 i32)): the results in order.
test_multi_value() ->
    Types = vec([functype([i32, i64], [i64, i32])]),
    Body = body([], <<16#20, 1, 16#20, 0>>),
    I = inst(module([section(1, Types), section(3, vec([uleb(0)])),
                     section(7, vec([export("f", 0, 0)])),
                     section(10, vec([Body]))])),
    ?eq({ok, [9, 7]}, wasm:call_function(I, "f", [7, 9])).

test_bad_calls() ->
    I = inst(binop(i32, 16#6a)),
    ?eq({error, badarg}, wasm:call_function(I, "f", [1])),
    ?eq({error, badarg}, wasm:call_function(I, "f", [1, 2, 3])),
    ?eq({error, not_found}, wasm:call_function(I, "g", [])),
    ?eq({error, not_found}, wasm:call_function(I, "", [])),
    %% An export that is not a function.
    ?eq({error, not_found}, wasm:call_function(I, "memory", [])),
    %% The name can be iodata.
    ?eq({ok, [3]}, wasm:call_function(I, [<<"f">>], [1, 2])),
    expect_function_clause(fun() -> wasm:call_function(I, "f", not_a_list) end),
    expect_badarg(fun() -> wasm:call_function(I, not_a_name, []) end),
    expect_badarg(fun() -> wasm:call_function(not_an_instance, "f", [1, 2]) end),
    expect_badarg(fun() -> wasm:call_function(I, lists:duplicate(300, $f), []) end).

%%% Traps

test_traps() ->
    I = inst(traps()),
    {error, {trap, T1}} = wasm:call_function(I, "unreachable", []),
    contains(T1, "unreachable"),
    {error, {trap, T2}} = wasm:call_function(I, "div", [1, 0]),
    contains(T2, "divide by zero"),
    {error, {trap, T3}} = wasm:call_function(I, "div", [-2147483648, -1]),
    contains(T3, "overflow"),
    {error, {trap, T4}} = wasm:call_function(I, "load", [65536]),
    contains(T4, "out of bounds"),
    ok.

%% The instance works after a trap.
test_after_trap() ->
    I = inst(traps()),
    {error, {trap, _}} = wasm:call_function(I, "div", [1, 0]),
    ?eq({ok, [3]}, wasm:call_function(I, "div", [7, 2])),
    {error, {trap, _}} = wasm:call_function(I, "unreachable", []),
    ?eq({ok, [-3]}, wasm:call_function(I, "div", [-7, 2])).

%% Endless recursion: a trap, not a crash of the node.
test_stack_exhaustion() ->
    Types = vec([functype([], [])]),
    Body = body([], <<16#10, 0>>),                % call 0
    I = inst(module([section(1, Types), section(3, vec([uleb(0)])),
                     section(7, vec([export("f", 0, 0)])),
                     section(10, vec([Body]))])),
    {error, {trap, T}} = wasm:call_function(I, "f", []),
    contains(T, "stack"),
    %% And again.
    {error, {trap, _}} = wasm:call_function(I, "f", []),
    ok.

%%% Memory

test_memory() ->
    I = inst(memory_module(1, none)),
    ?eq({ok, 65536}, wasm:memory_size(I)),
    ?eq(ok, wasm:write_binary(I, 0, <<1, 2, 3>>)),
    ?eq({ok, <<1, 2, 3>>}, wasm:read_binary(I, 0, 3)),
    ?eq({ok, [16#030201]}, wasm:call_function(I, "load", [0])),
    %% The last bytes.
    ?eq(ok, wasm:write_binary(I, 65534, [<<9>>, 8])),
    ?eq({ok, <<9, 8>>}, wasm:read_binary(I, 65534, 2)),
    ?eq({ok, <<>>}, wasm:read_binary(I, 65536, 0)),
    ?eq({error, out_of_bounds}, wasm:read_binary(I, 65535, 2)),
    ?eq({error, out_of_bounds}, wasm:read_binary(I, 65537, 0)),
    ?eq({error, out_of_bounds}, wasm:read_binary(I, 0, 1 bsl 40)),
    ?eq({error, out_of_bounds}, wasm:write_binary(I, 65535, <<1, 2>>)),
    ?eq({error, out_of_bounds}, wasm:write_binary(I, 1 bsl 62, <<1>>)),
    %% A write that is out of bounds changes nothing.
    ?eq({ok, <<9, 8>>}, wasm:read_binary(I, 65534, 2)),
    expect_badarg(fun() -> wasm:read_binary(I, -1, 1) end),
    expect_badarg(fun() -> wasm:write_binary(I, 0, not_iodata) end).

%% memory.grow from WebAssembly: the new size is seen from Erlang.
test_memory_grow() ->
    I = inst(memory_module(1, 3)),
    ?eq({ok, [1]}, wasm:call_function(I, "grow", [1])),
    ?eq({ok, 131072}, wasm:memory_size(I)),
    ?eq(ok, wasm:write_binary(I, 131071, <<7>>)),
    ?eq({ok, <<7>>}, wasm:read_binary(I, 131071, 1)),
    %% Above the maximum: -1, and the size does not change.
    ?eq({ok, [-1]}, wasm:call_function(I, "grow", [5])),
    ?eq({ok, 131072}, wasm:memory_size(I)),
    %% The old data is still there.
    ?eq(ok, wasm:write_binary(I, 10, <<"x">>)),
    ?eq({ok, [2]}, wasm:call_function(I, "grow", [1])),
    ?eq({ok, <<"x">>}, wasm:read_binary(I, 10, 1)).

%% memory_grow from Erlang, as WebAssembly.Memory.grow(): the size
%% before, in pages.
test_memory_grow_erlang() ->
    I = inst(memory_module(1, 3)),
    ?eq({ok, 1}, wasm:memory_grow(I, 1)),
    ?eq({ok, 131072}, wasm:memory_size(I)),
    ?eq({ok, 2}, wasm:memory_grow(I, 0)),
    ?eq({error, out_of_bounds}, wasm:memory_grow(I, 5)),
    ?eq({ok, 131072}, wasm:memory_size(I)),
    %% The code sees the new size.
    ?eq({ok, [2]}, wasm:call_function(I, "grow", [0])),
    expect_badarg(fun() -> wasm:memory_grow(I, -1) end).

test_no_memory() ->
    I = inst(binop(i32, 16#6a)),
    ?eq({error, not_found}, wasm:memory_size(I)),
    ?eq({error, not_found}, wasm:read_binary(I, 0, 0)),
    ?eq({error, not_found}, wasm:write_binary(I, 0, <<>>)),
    ?eq({error, not_found}, wasm:memory_grow(I, 1)).

%%% Modules and instances

test_load_errors() ->
    {error, E1} = wasm:compile(<<"not wasm">>),
    true = is_binary(E1),
    {error, _} = wasm:compile(<<>>),
    %% A valid module, cut short.
    M = binop(i32, 16#6a),
    {error, _} = wasm:compile(binary:part(M, 0, byte_size(M) - 3)),
    %% A type error in the code.
    Bad = module([section(1, vec([functype([], [i32])])), section(3, vec([uleb(0)])),
                  section(10, vec([body([], <<>>)]))]),
    {error, _} = wasm:compile(Bad),
    expect_function_clause(fun() -> wasm:compile("a list") end),
    ok.

test_missing_import() ->
    Types = vec([functype([], [])]),
    Imports = vec([import("env", "host_fun", 0)]),
    {ok, M} = wasm:compile(module([section(1, Types), section(2, Imports)])),
    case wasm:instantiate(M) of
        {error, Msg} when is_binary(Msg) -> contains(Msg, "host_fun");
        %% WAMR can also accept it and trap at the call.
        {ok, _} -> ok
    end.

%% An instance keeps its module alive.
test_resource_lifetime() ->
    I = (fun() ->
                 {ok, M} = wasm:compile(binop(i32, 16#6a)),
                 {ok, Inst} = wasm:instantiate(M),
                 Inst
         end)(),
    erlang:garbage_collect(),
    [erlang:garbage_collect(P) || P <- processes()],
    ?eq({ok, [5]}, wasm:call_function(I, "f", [2, 3])),
    %% Two instances of one module are separate.
    {ok, M2} = wasm:compile(memory_module(1, none)),
    {ok, A} = wasm:instantiate(M2),
    {ok, B} = wasm:instantiate(M2),
    ok = wasm:write_binary(A, 0, <<"A">>),
    ok = wasm:write_binary(B, 0, <<"B">>),
    ?eq({ok, <<"A">>}, wasm:read_binary(A, 0, 1)),
    ?eq({ok, <<"B">>}, wasm:read_binary(B, 0, 1)).

%% Many processes call one instance: the calls are serialized, and each
%% result is correct.
test_concurrent_calls() ->
    I = inst(counter()),
    Self = self(),
    N = 50,
    Pids = [spawn_link(fun() ->
                               R = [wasm:call_function(I, "add", [K]) || K <- lists:seq(1, 100)],
                               Self ! {self(), R}
                       end) || _ <- lists:seq(1, N)],
    [receive {P, R} -> [{ok, [_]} = X || X <- R] end || P <- Pids],
    %% The counter has the sum of all additions: no lost update.
    ?eq({ok, [N * 5050]}, wasm:call_function(I, "add", [0])).

test_many_instances() ->
    {ok, M} = wasm:compile(memory_module(1, none)),
    [begin {ok, I} = wasm:instantiate(M), {ok, [0]} = wasm:call_function(I, "load", [0]) end
     || _ <- lists:seq(1, 500)],
    erlang:garbage_collect(),
    ok.

test_instantiate_options() ->
    {ok, M} = wasm:compile(binop(i32, 16#6a)),
    {ok, _} = wasm:instantiate(M, #{}, #{stack_size => 16384, heap_size => 0}),
    {ok, _} = wasm:instantiate(M, #{}, #{preopens => #{"/" => "."}}),
    {ok, _} = wasm:instantiate(M, #{}, #{preopens => [{"/", "."}]}),
    expect_badarg(fun() -> wasm:instantiate(M, #{}, #{stack_size => -1}) end),
    expect_badarg(fun() -> wasm:instantiate(M, #{}, #{args => not_a_list}) end),
    expect_badarg(fun() -> wasm:instantiate(M, #{}, #{args => [not_iodata]}) end),
    expect_badarg(fun() -> wasm:instantiate(M, #{}, #{env => [not_a_pair]}) end),
    expect_badarg(fun() -> wasm:instantiate(M, #{}, #{preopens => [{"/"}]}) end),
    expect_badarg(fun() -> wasm:instantiate(M, #{}, #{preopens => #{"/" => not_text}}) end),
    expect_function_clause(fun() -> wasm:instantiate(M, #{}, not_a_map) end),
    expect_function_clause(fun() -> wasm:instantiate(M, not_a_map) end).

%% The bytes of a module in place of a module, as WebAssembly.instantiate().
test_instantiate_bytes() ->
    {ok, I} = wasm:instantiate(binop(i32, 16#6a)),
    ?eq({ok, [3]}, wasm:call_function(I, "f", [1, 2])),
    {error, Msg} = wasm:instantiate(<<"bad">>),
    true = is_binary(Msg),
    ok.

%% Host functions are not supported yet: only empty imports.
test_imports() ->
    {ok, _} = wasm:instantiate(binop(i32, 16#6a), #{}),
    try wasm:instantiate(binop(i32, 16#6a), #{"env" => #{}}) of
        R -> error({no_error, R})
    catch error:{badarg, host_functions_not_supported} -> ok
    end.

test_function_exists() ->
    I = inst(binop(i32, 16#6a)),
    ?eq(true, wasm:function_exists(I, "f")),
    ?eq(true, wasm:function_exists(I, <<"f">>)),
    ?eq(false, wasm:function_exists(I, "nope")),
    ?eq(false, wasm:function_exists(I, lists:duplicate(300, $a))),
    expect_badarg(fun() -> wasm:function_exists(I, not_text) end).

%%% WASI

test_wasi_exit() ->
    ?eq({ok, 7}, wasm:run(wasi_module(exit, 7), #{args => ["prog"]})),
    ?eq({ok, 0}, wasm:run(wasi_module(exit, 0), #{args => ["prog"]})).

test_wasi_return() ->
    %% _start returns without proc_exit: exit code 0.
    ?eq({ok, 0}, wasm:run(wasi_module(return, 0), #{args => ["prog"]})).

%% args_sizes_get and environ_sizes_get: the counts that the program
%% sees are returned by _start with proc_exit (argc * 10 + envc).
test_wasi_args_env() ->
    Bytes = wasi_counts(),
    ?eq({ok, 10}, wasm:run(Bytes, #{args => ["prog"]})),
    ?eq({ok, 30}, wasm:run(Bytes, #{args => ["prog", "a", "b"]})),
    ?eq({ok, 32}, wasm:run(Bytes, #{args => ["prog", "a", "b"],
                                    env => [{"K", "V"}, {<<"K2">>, [<<"V">>, "2"]}]})),
    %% env as a map, as in node:wasi.
    ?eq({ok, 12}, wasm:run(Bytes, #{args => ["prog"], env => #{"A" => "1", <<"B">> => "2"}})),
    ?eq({ok, 10}, wasm:run(Bytes, #{args => ["unicode \x{65e5}\x{672c}"]})).

test_no_start() ->
    ?eq({error, not_found}, wasm:run(binop(i32, 16#6a), #{args => ["prog"]})),
    {error, Msg} = wasm:run(<<"bad">>, #{args => ["prog"]}),
    true = is_binary(Msg),
    ok.

%% start/1, as start() of node:wasi.
test_start() ->
    {ok, I} = wasm:instantiate(wasi_module(exit, 5), #{}, #{args => ["prog"]}),
    ?eq({ok, 5}, wasm:start(I)),
    {ok, J} = wasm:instantiate(wasi_module(return, 0)),
    ?eq({ok, 0}, wasm:start(J)),
    ?eq({error, not_found}, wasm:start(inst(binop(i32, 16#6a)))).

test_run_module() ->
    {ok, M} = wasm:compile(wasi_module(exit, 3)),
    ?eq({ok, 3}, wasm:run(M, #{args => ["a"]})),
    ?eq({ok, 3}, wasm:run(M, #{args => ["b"]})).

%%% Helpers

inst(Bytes) ->
    {ok, M} = wasm:compile(Bytes),
    {ok, I} = wasm:instantiate(M),
    I.

contains(Bin, Text) ->
    case binary:match(Bin, list_to_binary(Text)) of
        nomatch -> error({missing, Text, Bin});
        _ -> ok
    end.

expect_badarg(F) ->
    try F() of
        R -> error({no_badarg, R})
    catch
        error:badarg -> ok
    end.

expect_function_clause(F) ->
    try F() of
        R -> error({no_function_clause, R})
    catch
        error:function_clause -> ok
    end.

%%% Test modules

%% (func "f" (param T T) (result T) (OP (local.get 0) (local.get 1)))
binop(T, Op) ->
    module([section(1, vec([functype([T, T], [T])])),
            section(3, vec([uleb(0)])),
            section(7, vec([export("f", 0, 0)])),
            section(10, vec([body([], <<16#20, 0, 16#20, 1, Op>>)]))]).

traps() ->
    Types = vec([functype([], []), functype([i32, i32], [i32]), functype([i32], [i32])]),
    Funcs = vec([uleb(0), uleb(1), uleb(2)]),
    Memory = vec([<<0, 1>>]),
    Exports = vec([export("unreachable", 0, 0), export("div", 0, 1),
                   export("load", 0, 2)]),
    Code = vec([body([], <<16#00>>),
                body([], <<16#20, 0, 16#20, 1, 16#6d>>),          % i32.div_s
                body([], <<16#20, 0, 16#28, 2, 0>>)]),            % i32.load
    module([section(1, Types), section(3, Funcs), section(5, Memory),
            section(7, Exports), section(10, Code)]).

%% Memory of Min pages (and at most Max), with "load" (i32.load) and
%% "grow" (memory.grow).
memory_module(Min, Max) ->
    Limits = case Max of
                 none -> <<0, (uleb(Min))/binary>>;
                 _ -> <<1, (uleb(Min))/binary, (uleb(Max))/binary>>
             end,
    Types = vec([functype([i32], [i32])]),
    module([section(1, Types), section(3, vec([uleb(0), uleb(0)])),
            section(5, vec([Limits])),
            section(7, vec([export("load", 0, 0), export("grow", 0, 1),
                            export("memory", 2, 0)])),
            section(10, vec([body([], <<16#20, 0, 16#28, 2, 0>>),
                             body([], <<16#20, 0, 16#40, 0>>)]))]).

%% A global i32 counter: "add" adds its argument and returns the sum.
counter() ->
    Types = vec([functype([i32], [i32])]),
    Global = vec([<<16#7f, 1, 16#41, 0, 16#0b>>]),         % mut i32 = 0
    Body = body([], <<16#23, 0, 16#20, 0, 16#6a, 16#24, 0, 16#23, 0>>),
    module([section(1, Types), section(3, vec([uleb(0)])), section(6, Global),
            section(7, vec([export("add", 0, 0)])), section(10, vec([Body]))]).

%% _start calls proc_exit(Code), or returns.
wasi_module(Mode, Code) ->
    Types = vec([functype([i32], []), functype([], [])]),
    Imports = vec([import("wasi_snapshot_preview1", "proc_exit", 0)]),
    Start = case Mode of
                exit -> body([], <<16#41, (sleb(Code))/binary, 16#10, 0>>);
                return -> body([], <<>>)
            end,
    module([section(1, Types), section(2, Imports), section(3, vec([uleb(1)])),
            section(5, vec([<<0, 1>>])),
            section(7, vec([export("_start", 0, 1), export("memory", 2, 0)])),
            section(10, vec([Start]))]).

%% _start: args_sizes_get(0, 4), environ_sizes_get(8, 12), then
%% proc_exit(argc * 10 + envc).
wasi_counts() ->
    Types = vec([functype([i32, i32], [i32]), functype([i32], []), functype([], [])]),
    Imports = vec([import("wasi_snapshot_preview1", "args_sizes_get", 0),
                   import("wasi_snapshot_preview1", "environ_sizes_get", 0),
                   import("wasi_snapshot_preview1", "proc_exit", 1)]),
    Start = body([], <<16#41, 0, 16#41, 4, 16#10, 0, 16#1a,
                       16#41, 8, 16#41, 12, 16#10, 1, 16#1a,
                       16#41, 0, 16#28, 2, 0, 16#41, 10, 16#6c,
                       16#41, 8, 16#28, 2, 0, 16#6a,
                       16#10, 2>>),
    module([section(1, Types), section(2, Imports), section(3, vec([uleb(2)])),
            section(5, vec([<<0, 1>>])),
            section(7, vec([export("_start", 0, 3), export("memory", 2, 0)])),
            section(10, vec([Start]))]).

%%% A small WebAssembly encoder

module(Sections) ->
    iolist_to_binary([<<0, "asm", 1, 0, 0, 0>> | Sections]).

section(Id, Contents) ->
    <<Id, (bin_vec(Contents))/binary>>.

vec(Items) ->
    iolist_to_binary([uleb(length(Items)) | Items]).

bin_vec(Bin) ->
    <<(uleb(byte_size(Bin)))/binary, Bin/binary>>.

name(S) ->
    bin_vec(list_to_binary(S)).

functype(Params, Results) ->
    <<16#60, (vec([type(T) || T <- Params]))/binary,
      (vec([type(T) || T <- Results]))/binary>>.

type(i32) -> <<16#7f>>;
type(i64) -> <<16#7e>>;
type(f32) -> <<16#7d>>;
type(f64) -> <<16#7c>>.

export(Name, Kind, Index) ->
    <<(name(Name))/binary, Kind, (uleb(Index))/binary>>.

import(Module, Name, Type) ->
    <<(name(Module))/binary, (name(Name))/binary, 0, (uleb(Type))/binary>>.

body(Locals, Instrs) ->
    L = vec([<<(uleb(N))/binary, (type(T))/binary>> || {N, T} <- Locals]),
    bin_vec(<<L/binary, Instrs/binary, 16#0b>>).

uleb(N) when N < 128 -> <<N>>;
uleb(N) -> <<(N band 127 bor 128), (uleb(N bsr 7))/binary>>.

sleb(N) when N >= -64, N < 64 -> <<(N band 127)>>;
sleb(N) -> <<(N band 127 bor 128), (sleb(N bsr 7))/binary>>.
