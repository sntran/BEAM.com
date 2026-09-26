%% A one-file program for "beam.com build" that runs WebAssembly.
%%
%%   beam.com build wasm_check.erl
%%   ./wasm_check.com [PROGRAM.wasm ARG...]
%%
%% Without arguments, it makes small WebAssembly modules itself (so that
%% the test needs no WebAssembly compiler) and checks function calls,
%% memory, a trap, and a WASI program. With a .wasm file, it runs that
%% WASI program with the other arguments.
-module(wasm_check).
-export([main/1]).

main([File | Args]) ->
    {ok, Bytes} = file:read_file(File),
    {ok, Code} = wasm:run(Bytes, [filename:basename(File) | Args],
                          #{env => [{"BEAM_COM", "1"}],
                            dirs => [{"/", "."}]}),
    io:format("wasm: ~ts exited with ~b~n", [File, Code]),
    halt(Code);
main([]) ->
    {ok, Mod} = wasm:load(math_module()),
    {ok, Inst} = wasm:instantiate(Mod),
    {ok, [42]} = wasm:call(Inst, "add", [40, 2]),
    {ok, [-1]} = wasm:call(Inst, "add", [16#7fffffff, 16#80000000]),
    {ok, [7.5]} = wasm:call(Inst, "mul", [2.5, 3]),
    io:format("wasm: add(40, 2) = 42, mul(2.5, 3) = 7.5~n"),
    {error, {trap, Trap}} = wasm:call(Inst, "boom", []),
    {error, not_found} = wasm:call(Inst, "nope", []),
    io:format("wasm: trap: ~s~n", [Trap]),
    {ok, 65536} = wasm:memory_size(Inst),
    ok = wasm:memory_write(Inst, 100, <<"abc">>),
    {ok, [Sum]} = wasm:call(Inst, "sum", [100, 3]),
    Sum = $a + $b + $c,
    {ok, <<"abc">>} = wasm:memory_read(Inst, 100, 3),
    {error, out_of_bounds} = wasm:memory_read(Inst, 65535, 2),
    io:format("wasm: memory ok (sum of \"abc\" = ~b)~n", [Sum]),
    {error, _} = wasm:load(<<"not wasm">>),
    {ok, 7} = wasm:run(wasi_module(), ["hello"]),
    io:format("wasm: wasi exit code 7~n"),
    ok.

%% (func add (i32 i32) -> i32), (func mul (f64 f64) -> f64),
%% (func boom) with unreachable, (func sum (ptr len) -> i32) over memory.
math_module() ->
    Types = vec([functype([i32, i32], [i32]), functype([f64, f64], [f64]),
                 functype([], [])]),
    Funcs = vec([uleb(0), uleb(1), uleb(2), uleb(0)]),
    Memory = vec([<<0, 1>>]),                           % min 1 page
    Exports = vec([export("add", 0, 0), export("mul", 0, 1),
                   export("boom", 0, 2), export("sum", 0, 3),
                   export("memory", 2, 0)]),
    Add = body([], <<16#20, 0, 16#20, 1, 16#6a>>),       % i32.add
    Mul = body([], <<16#20, 0, 16#20, 1, 16#a2>>),       % f64.mul
    Boom = body([], <<16#00>>),                          % unreachable
    %% local 2: sum; loop while len > 0: sum += load8_u(ptr); ptr++; len--
    Sum = body([{1, i32}],
               <<16#02, 16#40,                           % block
                 16#03, 16#40,                           % loop
                 16#20, 1, 16#45, 16#0d, 1,              % br_if 1 (len == 0)
                 16#20, 2, 16#20, 0, 16#2d, 0, 0, 16#6a, 16#21, 2,
                 16#20, 0, 16#41, 1, 16#6a, 16#21, 0,
                 16#20, 1, 16#41, 1, 16#6b, 16#21, 1,
                 16#0c, 0,                               % br 0
                 16#0b, 16#0b,                           % end loop, block
                 16#20, 2>>),
    Code = vec([Add, Mul, Boom, Sum]),
    module([section(1, Types), section(3, Funcs), section(5, Memory),
            section(7, Exports), section(10, Code)]).

%% A WASI program: writes "hello from wasi\n" with fd_write, and calls
%% proc_exit(7).
wasi_module() ->
    Types = vec([functype([i32, i32, i32, i32], [i32]), functype([i32], []),
                 functype([], [])]),
    Imports = vec([import("wasi_snapshot_preview1", "fd_write", 0),
                   import("wasi_snapshot_preview1", "proc_exit", 1)]),
    Funcs = vec([uleb(2)]),
    Memory = vec([<<0, 1>>]),
    Exports = vec([export("_start", 0, 2), export("memory", 2, 0)]),
    Text = <<"hello from wasi\n">>,
    Start = body([], <<16#41, 1, 16#41, 0, 16#41, 1, 16#41, 16#e4, 0,
                       16#10, 0, 16#1a,                  % fd_write, drop
                       16#41, 7, 16#10, 1>>),            % proc_exit(7)
    Code = vec([Start]),
    %% iovec at 0: {8, len}; the text at 8.
    Data = vec([<<0, 16#41, 0, 16#0b, (bin_vec(<<8:32/little,
                                                (byte_size(Text)):32/little,
                                                Text/binary>>))/binary>>]),
    module([section(1, Types), section(2, Imports), section(3, Funcs),
            section(5, Memory), section(7, Exports), section(10, Code),
            section(11, Data)]).

%% A small WebAssembly encoder.
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
