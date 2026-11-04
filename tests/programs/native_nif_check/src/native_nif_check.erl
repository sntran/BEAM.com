%% The test of the native NIF objects (docs/NIFS.md): the NIF of
%% c_src/native_nif_check.c, from priv/native_nif_check.ARCH.o. main/1
%% runs the checks and writes "native_nif_check: all N passed".
-module(native_nif_check).
-export([main/1, run/0]).
-export([add/2, echo/1, upcase/1, iolist/1, map_keys/1, mul/2, counter_new/0,
         counter_add/2, dtor_count/0, watch/1, unwatch/1, send_self/1, raise/1,
         dirty_sum/1, dirty_io/1, yield_sum/1, thread_send/1, libc/0, code/1,
         info/1, big/0, tls_check/0, tls_check_dirty/0, tls_check_io/0, tls_thread/0]).
-nifs([add/2, echo/1, upcase/1, iolist/1, map_keys/1, mul/2, counter_new/0,
       counter_add/2, dtor_count/0, watch/1, unwatch/1, send_self/1, raise/1,
       dirty_sum/1, dirty_io/1, yield_sum/1, thread_send/1, libc/0, code/1,
       info/1, big/0, tls_check/0, tls_check_dirty/0, tls_check_io/0, tls_thread/0]).
-on_load(init/0).

init() ->
    erlang:load_nif(priv("native_nif_check"), 0).

priv(Name) ->
    Priv = case code:priv_dir(native_nif_check) of
               {error, _} -> filename:join(filename:dirname(filename:dirname(code:which(?MODULE))), "priv");
               Dir -> Dir
           end,
    filename:join(Priv, Name).

add(_, _) -> erlang:nif_error(not_loaded).
echo(_) -> erlang:nif_error(not_loaded).
upcase(_) -> erlang:nif_error(not_loaded).
iolist(_) -> erlang:nif_error(not_loaded).
map_keys(_) -> erlang:nif_error(not_loaded).
mul(_, _) -> erlang:nif_error(not_loaded).
counter_new() -> erlang:nif_error(not_loaded).
counter_add(_, _) -> erlang:nif_error(not_loaded).
dtor_count() -> erlang:nif_error(not_loaded).
watch(_) -> erlang:nif_error(not_loaded).
unwatch(_) -> erlang:nif_error(not_loaded).
send_self(_) -> erlang:nif_error(not_loaded).
raise(_) -> erlang:nif_error(not_loaded).
dirty_sum(_) -> erlang:nif_error(not_loaded).
dirty_io(_) -> erlang:nif_error(not_loaded).
yield_sum(_) -> erlang:nif_error(not_loaded).
thread_send(_) -> erlang:nif_error(not_loaded).
libc() -> erlang:nif_error(not_loaded).
code(_) -> erlang:nif_error(not_loaded).
info(_) -> erlang:nif_error(not_loaded).
big() -> erlang:nif_error(not_loaded).
tls_check() -> erlang:nif_error(not_loaded).
tls_check_dirty() -> erlang:nif_error(not_loaded).
tls_check_io() -> erlang:nif_error(not_loaded).
tls_thread() -> erlang:nif_error(not_loaded).

main(_) ->
    case run() of
        {ok, N} ->
            io:format("native_nif_check: all ~b passed~n", [N]);
        {failed, Failed} ->
            [io:format("native_nif_check: FAIL ~p~n", [F]) || F <- Failed],
            halt(1)
    end.

%% {ok, Count} or {failed, [{Name, Got}]}. The upgrade is the last check:
%% after it, this code is old code.
run() ->
    Term = {a, [1, 2.5, <<"bin">>, "str"], #{k => v}, self(), make_ref(), -12345678901234567890},
    Checks =
        [{add, fun() -> add(40, 2) end, 42},
         {add_big, fun() -> add(1 bsl 61, 1 bsl 61) end, 1 bsl 62},
         {add_badarg, fun() -> add(a, 1) end, {error, badarg}},
         {echo, fun() -> echo(Term) end, Term},
         {upcase, fun() -> upcase(<<"hello, native">>) end, {ok, <<"HELLO, NATIVE">>}},
         {upcase_large, fun() -> upcase(binary:copy(<<"ab">>, 300000)) end,
          {ok, binary:copy(<<"AB">>, 300000)}},
         {iolist, fun() -> iolist([<<"x">>, "yz", [$w]]) end, <<"xyzw!">>},
         {map_keys, fun() -> {S, Ks, M} = map_keys(#{x => 1, y => 2, z => 3}), {S, lists:sort(Ks), M} end,
          {3, [x, y, z], #{x => 1, y => 2, z => 3, added => 3}}},
         {mul, fun() -> mul(1.5, 4.0) end, 6.0},
         {counter, fun() -> C = counter_new(), counter_add(C, 5), counter_add(C, 37) end, 42},
         {counter_badarg, fun() -> counter_add(make_ref(), 1) end, {error, badarg}},
         {dtor, fun dtor/0, true},
         {monitor_down, fun monitor_down/0, ok},
         {demonitor, fun demonitor/0, ok},
         {send_self, fun() -> ok = send_self(Term), receive {sent, T} -> T after 5000 -> timeout end end, Term},
         {raise, fun() -> try raise(my_reason) catch error:R -> R end end, my_reason},
         {dirty_cpu, fun() -> dirty_sum(1000000) end, {500000500000, 1}},
         {dirty_io, fun() -> dirty_io(Term) end, {Term, 1}},
         {yield, fun() -> yield_sum(1000000) end, {500000500000, 1}},
         {thread, fun thread/0, ok},
         {libc, fun() -> {S, D, E, L, F, Ok} = libc(), {S, D, E, L, abs(F - 1024.25) < 1.0e-9, Ok} end,
          {"42| 3.14|str|ff|1099511627776|z", 2500.0, 1, [-2, 0, 3, 3, 5, 9], true, 1}},
         {code, fun() -> [{R, A, N, C} || Op <- lists:seq(0, 8), {R, A, N, _, C} <- [code(Op)]] end,
          [{R, 420709, N, 7} || {R, N} <- lists:zip([10, 21, 32, 43, 54, 65, 76, 87, -1],
                                                   ["zero", "one", "two", "three", "many",
                                                    "zero", "one", "two", "three"])]},
         {bss, fun() -> {_, _, _, B1, _} = code(0), {_, _, _, B2, _} = code(0), B2 - B1 end, 1},
         {info, fun() -> {L, N, S, T, U} = info({a, 1}), {L, N, S, T, U > 0} end, {1, 1, "{a,1}", 1, true}},
         {big, fun() -> [U, I, R] = big(), {U, I, is_reference(R)} end,
          {18446744073709551615, -9223372036854775808, true}},
         {parallel, fun parallel/0, ok},
         {tls_schedulers, fun tls_schedulers/0, [0]},
         {tls_dirty, fun() -> tls_many(fun tls_check_dirty/0) end, [0]},
         {tls_dirty_io, fun() -> tls_many(fun tls_check_io/0) end, [0]},
         {tls_threads, fun() -> lists:usort([tls_thread() || _ <- lists:seq(1, 20)]) end, [0]},
         {other_module, fun other_module/0, {[bad_lib], true, 3}},
         {broken, fun() -> refused("broken") end, {load_failed, true}},
         {missing, fun() -> refused("missing") end, {load_failed, true}},
         {absent, fun() -> element(1, element(2, native_nif_check_other:load(priv("absent")))) end, load_failed},
         {upgrade, fun upgrade/0, {2, 2, 7}}],
    Failed = [{Name, Got} || {Name, F, Want} <- Checks, Got <- [run(F)], Got =/= Want],
    case Failed of
        [] -> {ok, length(Checks)};
        _ -> {failed, Failed}
    end.

run(F) ->
    try F() catch C:R -> {C, R} end.

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
    0 = unwatch(W),
    P ! stop,
    receive {down, P} -> down after 300 -> ok end.

%% A thread of the object sends 100 messages, in order.
thread() ->
    1 = thread_send(100),
    Got = [receive {thread, I} -> I after 5000 -> timeout end || _ <- lists:seq(1, 100)],
    case Got =:= lists:seq(0, 99) of
        true -> ok;
        false -> Got
    end.

%% Many processes call the object at the same time.
parallel() ->
    Self = self(),
    Pids = [spawn_link(fun() ->
                               C = counter_new(),
                               [counter_add(C, 1) || _ <- lists:seq(1, 200)],
                               R = {counter_add(C, 0), dirty_sum(1000), yield_sum(100000),
                                    upcase(<<"abc">>), echo([I, #{I => <<"v">>}])},
                               Self ! {self(), R}
                       end) || I <- lists:seq(1, 32)],
    Want = fun(I) -> {200, {500500, 1}, {5000050000, 1}, {ok, <<"ABC">>}, [I, #{I => <<"v">>}]} end,
    Got = [receive {P, R} -> R after 20000 -> timeout end || P <- Pids],
    case Got =:= [Want(I) || I <- lists:seq(1, 32)] of
        true -> ok;
        false -> Got
    end.

%% Thread-local data: the first call on each scheduler thread checks the
%% initial values (the threads started before the load).
tls_schedulers() ->
    Self = self(),
    N = erlang:system_info(schedulers),
    Pids = [spawn_opt(fun() -> Self ! {self(), tls_check()} end, [{scheduler, I}])
            || I <- lists:seq(1, N)],
    lists:usort([receive {P, R} -> R after 5000 -> timeout end || P <- Pids]).

%% Many calls at the same time: they go to each dirty scheduler.
tls_many(F) ->
    Self = self(),
    Pids = [spawn(fun() -> Self ! {self(), F()} end) || _ <- lists:seq(1, 200)],
    lists:usort([receive {P, R} -> R after 20000 -> timeout end || P <- Pids]).

%% ERTS refuses a load of the object by an other module (bad_lib). The
%% loader keeps one copy of each object: 20 such loads do not take 20
%% copies of its memory (on Linux, /proc/self/status gives it, else 0).
other_module() ->
    File = priv("native_nif_check"),
    Before = vm_size(),
    Results = [native_nif_check_other:load(File) || _ <- lists:seq(1, 20)],
    After = vm_size(),
    {lists:usort([element(1, Reason) || {error, Reason} <- Results] ++
                 [R || R <- Results, not is_tuple(R) orelse element(1, R) =/= error]),
     After - Before < 64 bsl 20 orelse {grew, After - Before}, add(1, 2)}.

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

%% A broken object (priv/broken.ARCH.o is not an ELF object), and an
%% object that needs a function that the program does not have
%% (priv/missing.ARCH.o): load_nif/2 fails, and the error tells why.
refused(Name) ->
    Want = #{"broken" => "not an ELF object",
             "missing" => "the program has no symbol no_such_function"},
    case native_nif_check_other:load(priv(Name)) of
        {error, {load_failed, Text}} ->
            {load_failed, string:find(Text, maps:get(Name, Want)) =/= nomatch orelse Text};
        Other ->
            Other
    end.

%% A new load of the module: the upgrade callback of the object gets the
%% data of the first load. As with dlopen(), the second load_nif/2 of the
%% same file gives the same copy of the object, so its static data stays
%% (2 loads), and its constructor ran one time (7).
upgrade() ->
    {module, ?MODULE} = code:load_file(?MODULE),
    {L, N, _, _, _} = ?MODULE:info(x),
    {_, _, _, _, C} = ?MODULE:code(0),
    {L, N, C}.
