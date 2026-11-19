%% The checks of the VM for Windows on ARM64 (docs/PLATFORMS.md), which
%% also run on each other system. On Windows on ARM64, beam.com starts
%% its aarch64 half with the loader ape-arm64.exe, and the line "cpu of
%% the process" shows ARM64. With BEAM_COM_NATIVE=0, the x86_64 half runs
%% under the emulation of Windows, and the line shows AMD64.
%%
%% Each check runs in its own process, with a limit of 30 seconds, and
%% prints one line. The exit status is the number of the checks that
%% fail.
-module(vm).
-export([main/1]).

main(Args) ->
    io:format("hello from the BEAM: ERTS ~s, flavor ~s, OTP ~s~n",
              [erlang:system_info(version), erlang:system_info(emu_flavor),
               erlang:system_info(otp_release)]),
    io:format("  os=~p cpu of the process=~s schedulers=~p args=~p~n",
              [os:type(), cpu(), erlang:system_info(schedulers_online), Args]),
    Checks =
        [{"1 integers: 100! has 158 digits", fun integers/0},
         {"2 lists, maps and binaries", fun data/0},
         {"3 floating point", fun floats/0},
         {"4 processes: a ring of 1000 processes", fun ring/0},
         {"5 schedulers: work on each scheduler", fun schedulers/0},
         {"6 ETS", fun ets/0},
         {"7 time: timer:sleep and the monotonic clock", fun clock/0},
         {"8 files: write, read, list and delete", fun files/0},
         {"9 code: compile a module from forms and run it", fun code/0},
         {"10 crypto: SHA-256 and random bytes (NIF, OpenSSL)", fun crypto/0},
         {"11 sockets: a TCP echo on the loopback address", fun tcp/0},
         {"12 ports: os:cmd gives the output of a program", fun port/0},
         {"13 environment: os:getenv and os:putenv", fun env/0}],
    Failed = lists:sum([check(Name, Fun) || {Name, Fun} <- Checks]),
    case Failed of
        0 -> io:format("all checks passed~n");
        _ -> io:format("~p checks failed~n", [Failed])
    end,
    halt(Failed).

%% The CPU type of this process on Windows: ARM64 for the native half,
%% AMD64 for the x86_64 half under the emulation.
cpu() ->
    case os:getenv("PROCESSOR_ARCHITECTURE") of
        false -> "not Windows";
        Cpu -> Cpu
    end.

check(Name, Fun) ->
    {Pid, Ref} = spawn_monitor(fun() -> exit({result, Fun()}) end),
    Result =
        receive
            {'DOWN', Ref, process, Pid, {result, true}} -> ok;
            {'DOWN', Ref, process, Pid, {result, Other}} -> {error, Other};
            {'DOWN', Ref, process, Pid, Reason} -> {error, Reason}
        after 30000 ->
            exit(Pid, kill),
            {error, timeout}
        end,
    case Result of
        ok ->
            io:format("PASS: ~s~n", [Name]),
            0;
        {error, Why} ->
            io:format("FAIL: ~s~n  ~0P~n", [Name, Why, 20]),
            1
    end.

integers() ->
    F = lists:foldl(fun(N, Acc) -> N * Acc end, 1, lists:seq(1, 100)),
    length(integer_to_list(F)) =:= 158 andalso F rem 97 =:= 0.

data() ->
    L = lists:seq(1, 100000),
    M = maps:from_list([{N, N * N} || N <- L]),
    B = << <<N:32>> || N <- L >>,
    lists:sum(lists:reverse(L)) =:= 5000050000
        andalso maps:get(777, M) =:= 603729
        andalso byte_size(B) =:= 400000
        andalso binary:decode_unsigned(binary:part(B, 399996, 4)) =:= 100000
        andalso string:uppercase(<<"grüße"/utf8>>) =:= <<"GRÜSSE"/utf8>>.

floats() ->
    abs(math:sqrt(2.0) - 1.4142135623730951) < 1.0e-15
        andalso float_to_binary(math:pi() * 1.0e3, [{decimals, 6}]) =:= <<"3141.592654">>
        andalso round(math:pow(2, 0.5) * 1.0e6) =:= 1414214
        andalso binary_to_float(<<"1.5e3">>) =:= 1500.0.

ring() ->
    Self = self(),
    First = lists:foldl(fun(_, Next) -> spawn(fun() -> relay(Next) end) end,
                        Self, lists:seq(1, 1000)),
    First ! {token, 0},
    receive {token, 1000} -> true after 20000 -> timeout end.

relay(Next) ->
    receive {token, N} -> Next ! {token, N + 1} end.

schedulers() ->
    Self = self(),
    Count = erlang:system_info(schedulers_online),
    Pids = [spawn_opt(fun() -> Self ! {self(), fib(27), erlang:system_info(scheduler_id)} end,
                      [{scheduler, Id}]) || Id <- lists:seq(1, Count)],
    Results = [receive {Pid, Value, Id} -> {Value, Id} after 25000 -> timeout end || Pid <- Pids],
    lists:all(fun({196418, _}) -> true; (_) -> false end, Results)
        andalso length(lists:usort([Id || {_, Id} <- Results])) =:= Count.

fib(N) when N < 2 -> N;
fib(N) -> fib(N - 1) + fib(N - 2).

ets() ->
    T = ets:new(spike, [set, public]),
    true = ets:insert(T, [{N, integer_to_binary(N)} || N <- lists:seq(1, 50000)]),
    R = ets:lookup(T, 4242) =:= [{4242, <<"4242">>}] andalso ets:info(T, size) =:= 50000,
    ets:delete(T),
    R.

clock() ->
    T0 = erlang:monotonic_time(millisecond),
    timer:sleep(50),
    Slept = erlang:monotonic_time(millisecond) - T0,
    {{Year, _, _}, _} = calendar:universal_time(),
    Slept >= 45 andalso Slept < 5000 andalso Year >= 2026.

files() ->
    Name = "vm-" ++ os:getpid() ++ ".tmp",
    Data = binary:copy(<<"a line of text\n">>, 1000),
    ok = file:write_file(Name, Data),
    {ok, Data} = file:read_file(Name),
    {ok, Info} = file:read_file_info(Name),
    {ok, Names} = file:list_dir("."),
    {ok, Cwd} = file:get_cwd(),
    ok = file:delete(Name),
    element(2, Info) =:= 15000 andalso lists:member(Name, Names)
        andalso Cwd =/= "" andalso file:read_file(Name) =:= {error, enoent}.

code() ->
    Forms = [{attribute, 1, module, spike_made},
             {attribute, 2, export, [{twice, 1}]},
             {function, 3, twice, 1,
              [{clause, 3, [{var, 3, 'X'}], [],
                [{op, 3, '*', {var, 3, 'X'}, {integer, 3, 2}}]}]}],
    {ok, spike_made, Beam} = compile:forms(Forms),
    {module, Module} = code:load_binary(spike_made, "spike_made.beam", Beam),
    Module:twice(21) =:= 42.

crypto() ->
    Hash = crypto:hash(sha256, <<"abc">>),
    binary:encode_hex(Hash, lowercase)
        =:= <<"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad">>
        andalso byte_size(crypto:strong_rand_bytes(32)) =:= 32.

tcp() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}},
                                      {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Self = self(),
    spawn_link(fun() ->
                       {ok, Socket} = gen_tcp:accept(Listen, 10000),
                       {ok, Data} = gen_tcp:recv(Socket, 0, 10000),
                       ok = gen_tcp:send(Socket, <<"echo: ", Data/binary>>),
                       gen_tcp:close(Socket),
                       Self ! served
               end),
    {ok, Client} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 10000),
    ok = gen_tcp:send(Client, <<"hello">>),
    {ok, Reply} = gen_tcp:recv(Client, 0, 10000),
    gen_tcp:close(Client),
    gen_tcp:close(Listen),
    receive served -> ok after 10000 -> ok end,
    Reply =:= <<"echo: hello">>.

port() ->
    Output = os:cmd("echo hello from a port"),
    string:trim(Output) =:= "hello from a port".

env() ->
    true = os:putenv("SPIKE_VALUE", "42"),
    os:getenv("SPIKE_VALUE") =:= "42" andalso is_list(os:getenv("PATH")).
