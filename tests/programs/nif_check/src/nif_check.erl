%% The test of the NIF libraries in WebAssembly (docs/NIFS.md): the NIF
%% of c_src/nif_check.c, from priv/nif_check.wasm or an AOT file. main/1
%% runs the checks and writes "nif_check: all N passed".
-module(nif_check).
-export([main/1, run/0]).
-export([add/2, echo/1, is_ok/1, swap/1, reverse/1, upcase/1, concat/2,
         iolist/1, map_put/3, map_value/2, map_keys/1, charlist/1, mul/2,
         counter_new/0, counter_add/2, dtor_count/0, send_self/1,
         self_pid/0, raise/1, t2b/1, sum/1, dirty_sum/1, crash/0, loads/0,
         compare/2, types/1, big/0, unsupported/0, watch/1, unwatch/1, fmt/1, ioq/1,
         sub/3, bad/2, iter_keep/1, iter_use/0, four_results/0, four_params/0, i64_nif/0,
         bad_dtor_new/0, bad_dtor_count/0, dirty_port_command/2]).
-nifs([add/2, echo/1, is_ok/1, swap/1, reverse/1, upcase/1, concat/2,
       iolist/1, map_put/3, map_value/2, map_keys/1, charlist/1, mul/2,
       counter_new/0, counter_add/2, dtor_count/0, send_self/1,
       self_pid/0, raise/1, t2b/1, sum/1, dirty_sum/1, crash/0, loads/0,
       compare/2, types/1, big/0, unsupported/0, watch/1, unwatch/1, fmt/1, ioq/1,
       sub/3, bad/2, iter_keep/1, iter_use/0, four_results/0, four_params/0, i64_nif/0,
       bad_dtor_new/0, bad_dtor_count/0, dirty_port_command/2]).
-on_load(init/0).

init() ->
    erlang:load_nif(nif_file(), 1).

nif_file() ->
    Priv = case code:priv_dir(nif_check) of
               {error, _} -> filename:join(filename:dirname(filename:dirname(code:which(?MODULE))), "priv");
               Dir -> Dir
           end,
    filename:join(Priv, "nif_check").

add(_, _) -> erlang:nif_error(not_loaded).
echo(_) -> erlang:nif_error(not_loaded).
is_ok(_) -> erlang:nif_error(not_loaded).
swap(_) -> erlang:nif_error(not_loaded).
reverse(_) -> erlang:nif_error(not_loaded).
upcase(_) -> erlang:nif_error(not_loaded).
concat(_, _) -> erlang:nif_error(not_loaded).
iolist(_) -> erlang:nif_error(not_loaded).
map_put(_, _, _) -> erlang:nif_error(not_loaded).
map_value(_, _) -> erlang:nif_error(not_loaded).
map_keys(_) -> erlang:nif_error(not_loaded).
charlist(_) -> erlang:nif_error(not_loaded).
mul(_, _) -> erlang:nif_error(not_loaded).
counter_new() -> erlang:nif_error(not_loaded).
counter_add(_, _) -> erlang:nif_error(not_loaded).
dtor_count() -> erlang:nif_error(not_loaded).
send_self(_) -> erlang:nif_error(not_loaded).
self_pid() -> erlang:nif_error(not_loaded).
raise(_) -> erlang:nif_error(not_loaded).
t2b(_) -> erlang:nif_error(not_loaded).
sum(_) -> erlang:nif_error(not_loaded).
dirty_sum(_) -> erlang:nif_error(not_loaded).
crash() -> erlang:nif_error(not_loaded).
loads() -> erlang:nif_error(not_loaded).
compare(_, _) -> erlang:nif_error(not_loaded).
types(_) -> erlang:nif_error(not_loaded).
big() -> erlang:nif_error(not_loaded).
unsupported() -> erlang:nif_error(not_loaded).
watch(_) -> erlang:nif_error(not_loaded).
unwatch(_) -> erlang:nif_error(not_loaded).
fmt(_) -> erlang:nif_error(not_loaded).
ioq(_) -> erlang:nif_error(not_loaded).
sub(_, _, _) -> erlang:nif_error(not_loaded).
bad(_, _) -> erlang:nif_error(not_loaded).
iter_keep(_) -> erlang:nif_error(not_loaded).
iter_use() -> erlang:nif_error(not_loaded).
four_results() -> erlang:nif_error(not_loaded).
four_params() -> erlang:nif_error(not_loaded).
i64_nif() -> erlang:nif_error(not_loaded).
bad_dtor_new() -> erlang:nif_error(not_loaded).
bad_dtor_count() -> erlang:nif_error(not_loaded).
dirty_port_command(_, _) -> erlang:nif_error(not_loaded).

main(_) ->
    case run() of
        {ok, N} ->
            io:format("nif_check: all ~b passed~n", [N]);
        {failed, Failed} ->
            [io:format("nif_check: FAIL ~p~n", [F]) || F <- Failed],
            halt(1)
    end.

%% {ok, Count} or {failed, [{Name, Got}]}.
run() ->
    Term = {a, [1, 2.5, <<"bin">>, "str"], #{k => v}, self(), make_ref(), -12345678901234567890},
    Checks =
        [{add, fun() -> add(40, 2) end, 42},
         {add_big, fun() -> add(1 bsl 61, 1 bsl 61) end, 1 bsl 62},
         {add_badarg, fun() -> add(a, 1) end, {error, badarg}},
         {echo, fun() -> echo(Term) end, Term},
         {echo_small, fun() -> [echo(I) || I <- [0, -1, 1 bsl 26, -(1 bsl 26), 1 bsl 40, -(1 bsl 59)]] end,
          [0, -1, 1 bsl 26, -(1 bsl 26), 1 bsl 40, -(1 bsl 59)]},
         {is_ok, fun() -> {is_ok(ok), is_ok(error), is_ok(<<"ok">>)} end, {true, false, false}},
         {swap, fun() -> swap({1, "two"}) end, {"two", 1}},
         {reverse, fun() -> reverse([1, b, "c"]) end, {3, ["c", b, 1]}},
         {upcase, fun() -> upcase(<<"hello, wasm">>) end, {ok, <<"HELLO, WASM">>}},
         {upcase_large, fun() -> upcase(binary:copy(<<"ab">>, 300000)) end,
          {ok, binary:copy(<<"AB">>, 300000)}},
         {concat, fun() -> concat(<<"abc">>, <<"def">>) end, <<"abcdef">>},
         {iolist, fun() -> iolist([<<"x">>, "yz", [$w]]) end, <<"yzw">>},
         {map_put, fun() -> map_put(#{a => 1}, b, 2) end, #{a => 1, b => 2}},
         {map_value, fun() -> {map_value(#{a => 1}, a), map_value(#{}, a)} end, {{ok, 1}, error}},
         {map_keys, fun() -> {S, Ks} = map_keys(#{x => 1, y => 2, z => 3}), {S, lists:sort(Ks)} end,
          {3, [x, y, z]}},
         {charlist, fun() -> {charlist(<<"abc">>), charlist("an_atom")} end, {"abc", an_atom}},
         {mul, fun() -> mul(1.5, 4.0) end, 6.0},
         {counter, fun() -> C = counter_new(), counter_add(C, 5), counter_add(C, 37) end, 42},
         {counter_badarg, fun() -> counter_add(make_ref(), 1) end, {error, badarg}},
         {dtor, fun dtor/0, true},
         {send_self, fun() -> ok = send_self(Term), receive {sent, T} -> T after 5000 -> timeout end end, Term},
         {self_pid, fun() -> self_pid() =:= self() end, true},
         {raise, fun() -> try raise(my_reason) catch error:R -> R end end, my_reason},
         {t2b, fun() -> {T, B} = t2b(Term), {T, binary_to_term(B)} end, {Term, Term}},
         {sum, fun() -> sum(100000) end, 5000050000},
         {dirty_sum, fun() -> dirty_sum(1000000) end, 500000500000},
         {crash, fun() -> try crash() catch error:{wasm_trap, M} when is_binary(M) -> trap end end, trap},
         {after_crash, fun() -> add(1, 2) end, 3},
         {loads, fun() -> loads() end, 1},
         {compare, fun() -> compare(<<"a">>, <<"a">>) end, {0, true, erlang:phash2(<<"a">>)}},
         {compare_lt, fun() -> element(1, compare(1, a)) end, -1},
         {types, fun() -> [types(X) || X <- [a, <<>>, make_ref(), fun() -> ok end, self(), #{}, {}, [], [1], 1.0]] end,
          [atom, binary, ref, 'fun', pid, map, tuple, nil, list, number]},
         {big, fun() -> [U, I, L, R] = big(), {U, I, L, is_reference(R)} end,
          {18446744073709551615, -9223372036854775808, -2147483648, true}},
         {unsupported, fun() -> try unsupported() catch error:{wasm_trap, M} when is_binary(M) -> trap end end, trap},
         {after_unsupported, fun() -> add(2, 3) end, 5},
         {monitor_down, fun monitor_down/0, ok},
         {monitor_dead, fun() -> P = spawn(fun() -> ok end), wait_dead(P), element(1, watch(P)) end, 1},
         {demonitor, fun demonitor/0, ok},
         {fmt, fun() -> {F, D, S} = fmt({a, 1}), {F, D =:= length(F) - 10, S} end,
          {"42| 3.14|str|ff|1099511627776|{a,1}|z%|7   |abc", true, "0123456"}},
         {ioq, fun() -> ioq([<<"abc">>, <<"defg">>, <<"h">>]) end, {13, 13, <<"defghabcdefgh">>, <<"defg">>}},
         {parallel, fun parallel/0, ok}
        | bad_checks()],
    Failed = [{Name, Got} || {Name, F, Want} <- Checks, Got <- [run(F)], Got =/= Want],
    case Failed of
        [] -> {ok, length(Checks)};
        _ -> {failed, Failed}
    end.

run(F) ->
    try F() catch C:R -> {C, R} end.

%% The calls that ERTS checks only with ASSERT (in a debug build), and
%% the functions of other types: the bridge stops each one with
%% error:{wasm_trap, Message}, where ERTS gives Erlang memory of the VM or
%% stops it. The library still works after them.
bad_checks() ->
    Bin = <<"0123456789">>,
    Bits = <<1, 2, 3, 4:4>>,
    Map = #{a => 1, b => [2]},
    [{sub, fun() -> {sub(Bin, 2, 3), sub(Bin, 10, 0), sub(Bits, 0, 3)} end, {<<"234">>, <<>>, <<1, 2, 3>>}},
     {sub_range, fun() -> trap(fun() -> sub(Bin, 0, 1 bsl 20) end) end, trap},
     {sub_pos, fun() -> trap(fun() -> sub(Bin, 11, 0) end) end, trap},
     {sub_wrap, fun() -> trap(fun() -> sub(Bin, 5, 16#ffffffff) end) end, trap},
     {sub_bits, fun() -> trap(fun() -> sub(Bits, 1, 3) end) end, trap},
     {sub_atom, fun() -> trap(fun() -> sub(an_atom, 0, 0) end) end, trap}]
    ++ [{Case, fun() -> trap(fun() -> bad(Case, Arg) end) end, Want}
        || {Case, Arg, Want} <-
               [{env_tuple, {x, "y"}, trap},
                {env_list, {x, "y"}, trap},
                {env_map, {x, "y"}, trap},
                {env_sub, Bin, trap},
                {env_result, {x, "y"}, trap},
                {env_send, {x, "y"}, trap},
                {valid_env, {x, "y"}, {returned, {{x, "y"}}}},
                {valid_exception, x, {error, badarg}},
                {exception_type, x, trap},
                {exception_copy, x, trap},
                {exception_format, x, trap},
                {exception_send, x, trap},
                {pid, not_a_pid, trap},
                {port, not_a_port, trap},
                {monitor_pid, not_a_pid, trap},
                {release_twice, x, trap},
                {keep_released, x, trap},
                {term_released, x, trap},
                {release_of_term, counter_new(), trap},
                {alive, x, trap},
                {timeslice, x, trap},
                {schedule, x, trap},
                {iter_clear, Map, trap},
                {iter_free, Map, trap},
                {schedule_type, x, trap}]]
    ++ [{valid_keep, fun() -> C = counter_new(), {ok, C2} = bad(valid_keep, C), C2 =:= C end, true},
        {iter_kept, fun() -> ok = iter_keep(Map), trap(fun() -> iter_use() end) end, trap},
        {four_results, fun() -> trap(fun() -> four_results() end) end, trap},
        {four_params, fun() -> trap(fun() -> four_params() end) end, trap},
        {i64_nif, fun() -> trap(fun() -> i64_nif() end) end, trap},
        {bad_dtor, fun bad_dtor/0, 0},
        {dirty_port, fun dirty_port/0, 0},
        {after_bad, fun() -> {add(1, 2), echo(Map), counter_add(counter_new(), 3)} end, {3, Map, 3}},
        {refused_loads, fun refused_loads/0, {[bad_lib], true, 3}}].

trap(F) ->
    try F() of
        R -> {returned, R}
    catch
        error:{wasm_trap, _} -> trap;
        C:R -> {C, R}
    end.

%% The destructor of the type bad_dtor has an other type: it does not run
%% (the counter of its calls stays 0), and the VM goes on.
bad_dtor() ->
    {Pid, Ref} = spawn_monitor(fun() -> [bad_dtor_new() || _ <- lists:seq(1, 10)] end),
    receive {'DOWN', Ref, process, Pid, _} -> ok end,
    erlang:garbage_collect(),
    receive after 300 -> ok end,
    bad_dtor_count().

%% enif_port_command of a dirty NIF to a closed port: ERTS 29.1.1 stops
%% the VM (O26 of docs/UPSTREAM.md), and the bridge gives 0. Only where a
%% UDP socket (a port) opens.
dirty_port() ->
    try gen_udp:open(0) of
        {ok, S} when is_port(S) ->
            ok = gen_udp:close(S),
            dirty_port_command(S, <<"x">>);
        _ ->
            0
    catch
        _:_ -> 0
    end.

%% ERTS refuses a load_nif/2 of the library by an other module (bad_lib)
%% after the loader loaded its module. The loader then frees the module:
%% 20 refused loads do not keep 20 linear memories (on Linux, each one has
%% 4 GiB of address space; /proc/self/status gives it, else 0).
refused_loads() ->
    File = nif_file(),
    Before = vm_size(),
    Results = [nif_check_other:load(File) || _ <- lists:seq(1, 20)],
    After = vm_size(),
    {lists:usort([element(1, Reason) || {error, Reason} <- Results] ++
                 [R || R <- Results, not is_tuple(R) orelse element(1, R) =/= error]),
     After - Before < 2 bsl 30 orelse {grew, After - Before}, add(1, 2)}.

vm_size() ->
    case file:read_file("/proc/self/status") of
        {ok, Status} ->
            case re:run(Status, "VmSize:\\s+(\\d+) kB", [{capture, all_but_first, list}]) of
                {match, [Kb]} -> list_to_integer(Kb) * 1024;
                nomatch -> 0
            end;
        _ ->
            0
    end.

%% The destructor of a counter runs when its process ends.
dtor() ->
    Before = dtor_count(),
    {Pid, Ref} = spawn_monitor(fun() -> [counter_new() || _ <- lists:seq(1, 10)] end),
    receive {'DOWN', Ref, process, Pid, _} -> ok end,
    wait(fun() -> dtor_count() >= Before + 10 end, 100).

wait(F, 0) -> F();
wait(F, N) ->
    case F() of
        true -> true;
        false -> receive after 50 -> wait(F, N - 1) end
    end.

%% The down callback of a watcher sends {down, Pid}.
monitor_down() ->
    P = spawn(fun() -> receive stop -> ok end end),
    {0, _W} = watch(P),
    P ! stop,
    receive {down, P} -> ok after 5000 -> timeout end.

%% After the demonitor, the down callback does not run.
demonitor() ->
    P = spawn(fun() -> receive stop -> ok end end),
    {0, W} = watch(P),
    {0, Term, 0} = unwatch(W),
    true = is_reference(Term),
    P ! stop,
    receive {down, P} -> down after 300 -> ok end.

wait_dead(P) ->
    case is_process_alive(P) of
        true -> receive after 10 -> wait_dead(P) end;
        false -> ok
    end.

%% Many processes call the library at the same time.
parallel() ->
    Self = self(),
    Pids = [spawn_link(fun() ->
                               C = counter_new(),
                               [counter_add(C, 1) || _ <- lists:seq(1, 200)],
                               R = {counter_add(C, 0), sum(5000), dirty_sum(1000),
                                    upcase(<<"abc">>), echo([I, #{I => <<"v">>}])},
                               Self ! {self(), R}
                       end) || I <- lists:seq(1, 32)],
    Want = fun(I) -> {200, 12502500, 500500, {ok, <<"ABC">>}, [I, #{I => <<"v">>}]} end,
    Got = [receive {P, R} -> R after 20000 -> timeout end || P <- Pids],
    case Got =:= [Want(I) || I <- lists:seq(1, 32)] of
        true -> ok;
        false -> Got
    end.
