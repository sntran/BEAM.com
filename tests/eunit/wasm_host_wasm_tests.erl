%% Unit tests for wasm_host_wasm, the application wasm in the WebAssembly
%% runtime (the parts that need no host).
-module(wasm_host_wasm_tests).

-include_lib("eunit/include/eunit.hrl").

wire_test_() ->
    W = fun wasm_host_wasm:wire/1,
    U = fun wasm_host_wasm:unwire/1,
    [?_assertEqual(3, W(3)),
     ?_assertEqual(-9007199254740991, W(-9007199254740991)),
     ?_assertEqual(#{i => <<"9223372030926249001">>}, W(9223372030926249001)),
     ?_assertEqual(1.5, W(1.5)),
     ?_assertEqual(<<"nan">>, W(nan)),
     ?_assertEqual(<<"-infinity">>, W('-infinity')),
     ?_assertError(badarg, W(<<"x">>)),
     ?_assertEqual(9223372030926249001, U(#{<<"i">> => <<"9223372030926249001">>})),
     ?_assertEqual(infinity, U(<<"infinity">>)),
     ?_assertEqual(nan, U(<<"nan">>)),
     ?_assertEqual(7, U(7))].

options_test_() ->
    M = {wasm_module, <<"m1">>},
    [?_assertError({badarg, host_functions_not_supported},
                   wasm_host_wasm:instantiate(M, #{<<"env">> => #{}}, #{})),
     ?_assertError({badarg, preopens_not_supported},
                   wasm_host_wasm:instantiate(M, #{}, #{preopens => #{"/" => "/tmp"}})),
     ?_assertError(badarg, wasm_host_wasm:instantiate(M, #{}, #{args => not_a_list}))].

%% Offsets and lengths are integers of 0 or more, before any request.
bounds_test_() ->
    I = {wasm_instance, <<"i1">>},
    [?_assertError(function_clause, wasm_host_wasm:read_binary(I, -1, 4)),
     ?_assertError(function_clause, wasm_host_wasm:read_binary(I, 0, -4)),
     ?_assertError(function_clause, wasm_host_wasm:read_binary(I, 1.5, 4)),
     ?_assertError(function_clause, wasm_host_wasm:write_binary(I, -1, <<"x">>)),
     ?_assertError(function_clause, wasm_host_wasm:memory_grow(I, -1))].
