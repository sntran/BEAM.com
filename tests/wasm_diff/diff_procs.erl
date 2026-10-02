%% Processes, links, monitors, timers, and ETS. The output has no pid and
%% no time, so it must be the same in each runtime.
-module(diff_procs).
-export([main/1]).

main(_Dir) ->
    %% A crash report has a time and a pid, so the logger stays off.
    ok = logger:set_primary_config(level, none),
    process_flag(trap_exit, true),
    %% A chain of 2000 processes passes one message.
    Last = lists:foldl(fun(_, Next) -> spawn_link(fun() -> relay(Next) end) end,
                       self(), lists:seq(1, 2000)),
    Last ! {token, 0},
    receive {token, Hops} -> p(chain, Hops) end,
    %% The exit reasons that a monitor and a link get.
    Reasons = [normal, kill, {shutdown, x}, badarith_error, throw_it],
    p(down, [watch(R) || R <- Reasons]),
    Pid = spawn_link(fun() -> exit(oops) end),
    receive {'EXIT', Pid, Why} -> p(link, Why) end,
    %% The timers fire in the order of their times.
    Self = self(),
    [erlang:send_after(T, Self, {tick, T}) || T <- [50, 10, 30, 20, 40]],
    p(timers, [receive {tick, T} -> T end || _ <- lists:seq(1, 5)]),
    Ref = erlang:start_timer(10000, self(), never),
    p(cancel, is_integer(erlang:cancel_timer(Ref))),
    p(after_zero, receive nothing -> yes after 0 -> no end),
    %% A selective receive keeps the order of the other messages.
    [Self ! {m, N} || N <- lists:seq(1, 10)],
    Five = receive {m, 5} -> 5 end,
    p(selective, [Five | [receive {m, N} -> N end || _ <- lists:seq(1, 9)]]),
    %% Many processes that work at the same time, with a fixed result.
    Pids = [spawn_monitor(fun() -> exit({sum, lists:sum(lists:seq(1, N * 1000))}) end)
            || N <- lists:seq(1, 50)],
    p(workers, [receive {'DOWN', M, process, P, {sum, S}} -> S end || {P, M} <- Pids]),
    %% ETS.
    Ord = ets:new(ord, [ordered_set]),
    ets:insert(Ord, [{K, v} || K <- [5, 3.0, b, "a", {1}, 1 bsl 70, -1]]),
    p(ets_order, ets:tab2list(Ord)),
    p(ets_select, ets:select(Ord, [{{'$1', '_'}, [{is_integer, '$1'}, {'>', '$1', 0}], ['$1']}])),
    Bag = ets:new(bag, [bag]),
    ets:insert(Bag, [{k, N} || N <- [3, 1, 2, 1]]),
    p(ets_bag, ets:lookup(Bag, k)),
    p(ets_info, [ets:info(Ord, size), ets:info(Bag, size)]),
    %% Persistent terms and counters.
    persistent_term:put({?MODULE, k}, [1, 2]),
    C = counters:new(2, [atomics]),
    counters:add(C, 1, 40), counters:sub(C, 2, 2),
    p(shared, [persistent_term:get({?MODULE, k}), counters:get(C, 1), counters:get(C, 2)]),
    %% Errors and their stack frames (without lines).
    p(errors, [err(fun() -> lists:nth(0, []) end), err(fun() -> element(3, o({a})) end),
               err(fun() -> binary_to_atom(<<0:300/unit:8>>) end),
               err(fun() -> list_to_atom(lists:duplicate(256, $a)) end)]).

relay(Next) ->
    receive {token, N} -> Next ! {token, N + 1} end.

watch(How) ->
    {P, M} = spawn_monitor(fun() ->
        receive go ->
            case How of
                normal -> ok;
                kill -> receive never -> ok end;
                badarith_error -> _ = 1 / zero(), ok;
                throw_it -> throw(t);
                R -> exit(R)
            end
        end
    end),
    case How of kill -> exit(P, kill); _ -> P ! go end,
    receive {'DOWN', M, process, P, R} -> strip(R) end.

zero() -> 0.

strip({Reason, Stack}) when is_list(Stack) -> {Reason, [{M, F} || {M, F, _, _} <- Stack]};
strip(R) -> R.

%% The compiler cannot see the value, so it gives no warning.
o(X) -> binary_to_term(term_to_binary(X)).

err(F) ->
    try F() catch C:R:S -> {C, R, [{M, Fn} || {M, Fn, _, _} <- lists:sublist(S, 1)]} end.

p(Label, Term) ->
    io:format("~s: ~w~n", [Label, Term]).
