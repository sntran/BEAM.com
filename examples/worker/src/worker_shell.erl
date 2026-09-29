%% The Erlang shell (the module shell of stdlib) for a web page. Each
%% session is a process that is the group leader of its shell: it gives
%% the shell the lines of the page, and sends the page the output and
%% the prompts of the shell. The owner (the WebSocket process) gets
%% {shell, Session, {output, Text}}, {shell, Session, {prompt, Text}} and
%% {shell, Session, down}.
%%
%% The shell is a restricted shell (worker:start/2 sets it) for a public
%% page. It allows:
%% - the modules of data (lists, maps, binary, string, ...), io to the
%%   page, and some functions of erlang, crypto, timer, gen_tcp;
%% - erlang:process_info/1,2 only for a process of the same session, and
%%   erlang:system_info/1 only for the keys of ?SYSTEM_INFO;
%% - a message or an exit signal only to a process of the same session;
%% - spawn/1 until the VM has 20,000 processes.
%% It refuses other calls, "fun M:F/A" (an external fun can call any
%% function), and the shell commands that read files or other processes.
%% At the end of a session, its processes stop.
%%
%% Caution: this makes a public demo harder to misuse, but it is no
%% sandbox. Limit the hosts of outgoing connections in the runtime too
%% (BEAM_CONNECT, see docs/WORKERS.md).
%%
%% An evaluation stops after 10 s, or when its process has more than
%% 16 MB of heap. The time of a read (io:get_line/1 in the code of the
%% visitor) does not count.
-module(worker_shell).
-export([start/0, input/2, interrupt/1]).
-export([local_allowed/3, non_local_allowed/3, format_error/1]).

-define(TIMEOUT, 10000).         % ms for each evaluation
-define(MAX_HEAP, 4000000).      % words (16 MB on wasm32)
-define(MAX_OUTPUT, 65536).      % bytes of output for each evaluation
-define(MAX_PROCESSES, 20000).   % processes in the VM, for spawn/1
-define(TICK, 250).              % ms between the checks of an evaluation

%% The shell commands that a session can use (shell_default and c). The
%% commands of the shell itself (b(), f(), v(N), rr(), ...) are always
%% allowed.
-define(COMMANDS, [help, e, flush, uptime]).

%% The modules of data: all their functions.
-define(MODULES, [lists, maps, string, binary, unicode, math, proplists, sets, gb_sets,
                  gb_trees, orddict, ordsets, dict, queue, array, calendar, io_lib, base64,
                  uri_string, json, rand, filename]).

%% Other functions: {Module, Function} or {Module, Function, Arity}.
-define(FUNCTIONS,
        [{io, format, 1}, {io, format, 2}, {io, fwrite, 1}, {io, fwrite, 2},
         {io, put_chars, 1}, {io, nl, 0}, {io, get_line, 1},
         {timer, sleep, 1}, {timer, tc, 1}, {timer, tc, 2},
         {crypto, hash}, {crypto, mac}, {crypto, strong_rand_bytes},
         {gen_tcp, connect}, {gen_tcp, send}, {gen_tcp, recv}, {gen_tcp, close},
         {erlang, self}, {erlang, node, 0}, {erlang, make_ref}, {erlang, error},
         {erlang, throw}, {erlang, exit, 1}, {erlang, monotonic_time}, {erlang, system_time},
         {erlang, timestamp}, {erlang, time}, {erlang, date}, {erlang, localtime},
         {erlang, universaltime}, {erlang, unique_integer}, {erlang, phash2},
         {erlang, statistics}, {erlang, is_process_alive}, {erlang, monitor}, {erlang, demonitor},
         {erlang, term_to_binary}, {erlang, list_to_existing_atom},
         {erlang, binary_to_existing_atom}, {erlang, atom_to_list}, {erlang, atom_to_binary},
         {erlang, integer_to_list}, {erlang, integer_to_binary}, {erlang, list_to_integer},
         {erlang, binary_to_integer}, {erlang, float_to_list}, {erlang, float_to_binary},
         {erlang, list_to_float}, {erlang, binary_to_float}, {erlang, binary_to_list},
         {erlang, list_to_binary}, {erlang, iolist_to_binary}, {erlang, iolist_size},
         {erlang, tuple_to_list}, {erlang, list_to_tuple}, {erlang, pid_to_list},
         {erlang, garbage_collect, 0}, {erlang, max}, {erlang, min}, {erlang, append_element},
         {erlang, make_tuple}, {erlang, insert_element}, {erlang, delete_element},
         {erlang, setelement}, {erlang, split_binary}, {erlang, spawn, 1},
         {erlang, spawn_link, 1}, {erlang, spawn_monitor, 1}]).

%% The keys of erlang:system_info/1 that a session can read. The other keys
%% can show the state of other sessions (procs, for example).
-define(SYSTEM_INFO,
        [system_architecture, otp_release, version, machine, emu_flavor, emu_type,
         wordsize, process_count, process_limit, port_count, port_limit, atom_count,
         atom_limit, ets_count, ets_limit, schedulers, schedulers_online,
         dirty_cpu_schedulers, dirty_io_schedulers, logical_processors, thread_pool_size,
         threads, smp_support, time_warp_mode, start_time]).

%% A new session for the calling process.
-spec start() -> pid().
start() ->
    Owner = self(),
    spawn(fun() -> init(Owner) end).

%% A line from the page.
-spec input(pid(), unicode:chardata()) -> ok.
input(Session, Text) ->
    Session ! {input, unicode:characters_to_list(Text)},
    ok.

%% Stops the evaluation that runs.
-spec interrupt(pid()) -> ok.
interrupt(Session) ->
    Session ! interrupt,
    ok.

%% The restricted shell. A local call is a shell command, or a function
%% that the visitor made in the shell.
local_allowed(F, Args, State) ->
    Arity = length(Args),
    Command = erlang:function_exported(shell_default, F, Arity)
        orelse erlang:function_exported(c, F, Arity),
    {not Command orelse lists:member(F, ?COMMANDS), State}.

non_local_allowed(Fun, _Args, State) when is_function(Fun) ->
    %% A fun of the shell runs its calls through this check. An external
    %% fun runs a function of a module: the same check as a call.
    {erlang:fun_info(Fun, type) =:= {type, local} orelse external_fun_allowed(Fun), State};
non_local_allowed({M, F}, Args, State) ->
    {allowed(M, F, Args), State}.

external_fun_allowed(Fun) ->
    {module, M} = erlang:fun_info(Fun, module),
    {name, F} = erlang:fun_info(Fun, name),
    {arity, A} = erlang:fun_info(Fun, arity),
    allowed(M, F, lists:duplicate(A, undefined)).

allowed(erlang, '!', [To, _Msg]) -> own(To);
allowed(erlang, send, [To, _Msg]) -> own(To);
allowed(erlang, send, [To, _Msg, _Opts]) -> own(To);
allowed(erlang, exit, [Pid, _Reason]) -> own(Pid);
allowed(erlang, link, [Pid]) -> own(Pid);
allowed(erlang, process_info, [Pid]) -> own(Pid);
allowed(erlang, process_info, [Pid, _Item]) -> own(Pid);
allowed(erlang, system_info, [Key]) -> lists:member(Key, ?SYSTEM_INFO);
allowed(erlang, unlink, [Pid]) -> own(Pid);
allowed(erlang, apply, [F, Args]) when is_function(F), is_list(Args) ->
    element(1, non_local_allowed(F, Args, []));
allowed(erlang, apply, [M, F, Args]) when is_atom(M), is_atom(F), is_list(Args) ->
    allowed(M, F, Args);
allowed(erlang, F, [_] = Args) when F =:= spawn; F =:= spawn_link; F =:= spawn_monitor ->
    listed(erlang, F, Args) andalso erlang:system_info(process_count) < ?MAX_PROCESSES;
allowed(erlang, F, [_, _] = Args) when is_atom(F) ->
    erl_internal:arith_op(F, 2) orelse erl_internal:comp_op(F, 2)
        orelse erl_internal:bool_op(F, 2) orelse erl_internal:list_op(F, 2)
        orelse erl_internal:guard_bif(F, 2) orelse listed(erlang, F, Args);
allowed(erlang, F, [_] = Args) when is_atom(F) ->
    erl_internal:arith_op(F, 1) orelse erl_internal:bool_op(F, 1)
        orelse erl_internal:guard_bif(F, 1) orelse listed(erlang, F, Args);
allowed(M, F, Args) ->
    lists:member(M, ?MODULES) orelse listed(M, F, Args).

listed(M, F, Args) ->
    lists:member({M, F}, ?FUNCTIONS) orelse lists:member({M, F, length(Args)}, ?FUNCTIONS).

%% A process of this session: the calling process shares its group leader.
own(Pid) when is_pid(Pid), node(Pid) =:= node() ->
    process_info(Pid, group_leader) =:= {group_leader, group_leader()};
own(_) ->
    false.

format_error(external_fun) ->
    "\"fun M:F/A\" is not allowed in this shell: use fun(X) -> M:F(X) end".

%% The session: the group leader of its shell.
-record(s, {owner :: pid(),
            shell :: pid(),
            buffer = [] :: string(),          % input that no request took yet
            pending = none,                   % the request that waits for input
            since = none,                     % the start of the evaluation (ms)
            output = 0 :: non_neg_integer()}). % bytes of output of the evaluation

init(Owner) ->
    erlang:monitor(process, Owner),
    group_leader(self(), self()),
    Shell = shell:start(true, false),
    erlang:monitor(process, Shell),
    erlang:send_after(?TICK, self(), tick),
    loop(#s{owner = Owner, shell = Shell, since = now_ms()}).

loop(S) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            loop(request(From, ReplyAs, Request, S));
        {input, Line} ->
            loop(take(S#s{buffer = S#s.buffer ++ Line ++ "\n"}));
        interrupt ->
            loop(stop_evaluation(<<"** interrupted\n">>, S));
        tick ->
            erlang:send_after(?TICK, self(), tick),
            loop(check(S));
        {'DOWN', _, process, Pid, _} when Pid =:= S#s.owner ->
            %% The end of the session: its shell and the processes that it
            %% started (they have this group leader) stop.
            exit(S#s.shell, kill),
            [exit(P, kill) || P <- processes(), P =/= self(),
                              process_info(P, group_leader) =:= {group_leader, self()}],
            ok;
        {'DOWN', _, process, Pid, _} when Pid =:= S#s.shell ->
            S#s.owner ! {shell, self(), down};
        _ ->
            loop(S)
    end.

%% The functions that a request of the I/O protocol can name: those that
%% the modules io and shell use. The code of the visitor can send a
%% request to this process (its group leader), and the session runs the
%% function of the request, with no check of allowed/3 and outside the
%% limits of an evaluation.
-define(READ_FUNCTIONS, [{erl_scan, tokens}, {io_lib, fread}]).
-define(WRITE_FUNCTIONS, [{io_lib, format}, {io_lib, fwrite}, {io_lib, write}]).

%% The requests of the I/O protocol.
request(From, ReplyAs, {get_until, Encoding, Prompt, M, F, Xs}, S) ->
    until(From, ReplyAs, {until, Encoding, Prompt, M, F, Xs, []}, S);
request(From, ReplyAs, {get_until, Prompt, M, F, Xs}, S) ->
    until(From, ReplyAs, {until, latin1, Prompt, M, F, Xs, []}, S);
request(From, ReplyAs, {get_line, Encoding, Prompt}, S) ->
    wait(From, ReplyAs, {line, Encoding, Prompt}, S);
request(From, ReplyAs, {get_line, Prompt}, S) ->
    wait(From, ReplyAs, {line, latin1, Prompt}, S);
request(From, ReplyAs, {get_chars, Encoding, Prompt, N}, S) ->
    wait(From, ReplyAs, {chars, Encoding, Prompt, N}, S);
request(From, ReplyAs, {get_chars, Prompt, N}, S) ->
    wait(From, ReplyAs, {chars, latin1, Prompt, N}, S);
request(From, ReplyAs, Request, S) ->
    {Reply, S1} = simple(Request, S),
    From ! {io_reply, ReplyAs, Reply},
    S1.

simple({put_chars, Encoding, Chars}, S) ->
    case unicode:characters_to_binary(Chars, Encoding) of
        Bin when is_binary(Bin) -> {ok, output(Bin, S)};
        _ -> {{error, put_chars}, S}
    end;
simple({put_chars, Encoding, M, F, A}, S) when is_list(A) ->
    case lists:member({M, F}, ?WRITE_FUNCTIONS) of
        true ->
            try simple({put_chars, Encoding, apply(M, F, A)}, S)
            catch _:_ -> {{error, F}, S}
            end;
        false ->
            {{error, request}, S}
    end;
simple({put_chars, Chars}, S) ->
    simple({put_chars, latin1, Chars}, S);
simple({put_chars, M, F, A}, S) ->
    simple({put_chars, latin1, M, F, A}, S);
simple({requests, Requests}, S) ->
    lists:foldl(fun(R, {ok, Acc}) -> simple(R, Acc);
                   (_, Error) -> Error
                end, {ok, S}, Requests);
simple(getopts, S) ->
    {[{binary, false}, {encoding, unicode}, {echo, false}], S};
simple({setopts, _Opts}, S) ->
    {ok, S};
simple({get_geometry, columns}, S) ->
    {80, S};
simple({get_geometry, rows}, S) ->
    {24, S};
simple(_Request, S) ->
    {{error, request}, S}.

until(From, ReplyAs, {until, _, _, M, F, Xs, _} = Read, S) when is_list(Xs) ->
    case lists:member({M, F}, ?READ_FUNCTIONS) of
        true -> wait(From, ReplyAs, Read, S);
        false -> From ! {io_reply, ReplyAs, {error, request}}, S
    end;
until(From, ReplyAs, _Read, S) ->
    From ! {io_reply, ReplyAs, {error, request}},
    S.

%% A read waits for input. The time of the evaluation stops meanwhile.
wait(From, ReplyAs, Read, #s{pending = none} = S) ->
    take(S#s{pending = {From, ReplyAs, Read, true}, since = none});
wait(From, ReplyAs, _Read, S) ->
    From ! {io_reply, ReplyAs, {error, busy}},
    S.

%% Gives the input to the read that waits, or asks the page for a line.
take(#s{pending = none} = S) ->
    S;
take(#s{pending = {From, ReplyAs, Read, First}, buffer = Buffer} = S) ->
    case read(Read, Buffer) of
        {done, Reply, Rest} ->
            From ! {io_reply, ReplyAs, Reply},
            S#s{pending = none, buffer = Rest, since = now_ms(), output = 0};
        {more, Read1, Rest} ->
            S#s.owner ! {shell, self(), {prompt, prompt(Read, First)}},
            S#s{pending = {From, ReplyAs, Read1, false}, buffer = Rest}
    end.

%% A read of the buffer: {done, Reply, Rest}, or {more, Read, Rest} when it
%% needs more input. A get_until keeps the input that it took in its
%% continuation.
read({until, Encoding, Prompt, M, F, Xs, Cont}, Buffer) ->
    case Buffer of
        [] -> {more, {until, Encoding, Prompt, M, F, Xs, Cont}, []};
        _ ->
            case apply(M, F, [Cont, Buffer | Xs]) of
                {done, Result, Rest} ->
                    case no_external_fun(Result) of
                        Result -> {done, Result, rest(Rest)};
                        %% The shell skips the rest of the line after an
                        %% error (io:get_line/1): give it the end of the line.
                        Error -> {done, Error, "\n" ++ rest(Rest)}
                    end;
                {more, Cont1} -> {more, {until, Encoding, Prompt, M, F, Xs, Cont1}, []}
            end
    end;
read({line, _Encoding, _Prompt} = Read, Buffer) ->
    case string:split(Buffer, "\n") of
        [Line, Rest] -> {done, Line ++ "\n", Rest};
        _ -> {more, Read, Buffer}
    end;
read({chars, _Encoding, _Prompt, N} = Read, Buffer) ->
    case length(Buffer) >= N of
        true -> {done, lists:sublist(Buffer, N), lists:nthtail(N, Buffer)};
        false -> {more, Read, Buffer}
    end.

%% The tokens of an expression, with no "fun M:F/A".
no_external_fun({ok, Tokens, End} = Result) ->
    case external_fun(Tokens) of
        {true, Anno} -> {error, {erl_anno:location(Anno), ?MODULE, external_fun}, End};
        false -> Result
    end;
no_external_fun(Result) ->
    Result.

external_fun([{'fun', Anno}, {Kind, _, _}, {':', _} | _]) when Kind =:= atom; Kind =:= var ->
    {true, Anno};
external_fun([_ | Rest]) ->
    external_fun(Rest);
external_fun([]) ->
    false.

rest(eof) -> [];
rest(Rest) -> Rest.

%% The prompt of a read: the prompt of the request, then the prompt of a
%% continued expression.
prompt(Read, First) ->
    Prompt = unicode:characters_to_list(io_lib:format_prompt(element(3, Read), unicode)),
    case First of
        true -> unicode:characters_to_binary(Prompt);
        false -> unicode:characters_to_binary(shell:default_multiline_prompt(Prompt))
    end.

%% Output to the page, with a limit for each evaluation.
output(Bin, #s{output = Size} = S) ->
    New = Size + byte_size(Bin),
    if
        New =< ?MAX_OUTPUT -> S#s.owner ! {shell, self(), {output, Bin}};
        Size =< ?MAX_OUTPUT -> S#s.owner ! {shell, self(), {output, <<"\n... (output cut)\n">>}};
        true -> ok
    end,
    S#s{output = New}.

%% The limits of an evaluation.
check(#s{since = none} = S) ->
    S;
check(#s{since = Since} = S) ->
    case now_ms() - Since > ?TIMEOUT of
        true -> stop_evaluation(<<"** the evaluation took more than 10 s\n">>, S);
        false ->
            case [P || P <- evaluators(S), heap(P) > ?MAX_HEAP] of
                [] -> S;
                _ -> stop_evaluation(<<"** the evaluation used more than 16 MB of heap\n">>, S)
            end
    end.

%% The shell runs an expression in its evaluator, a process linked to it.
%% The shell prints the exit, and starts a new evaluator with the same
%% variables.
stop_evaluation(_Message, #s{since = none} = S) ->
    S;
stop_evaluation(Message, S) ->
    S#s.owner ! {shell, self(), {output, Message}},
    [exit(P, kill) || P <- evaluators(S)],
    S#s{since = none}.

evaluators(#s{shell = Shell}) ->
    case process_info(Shell, links) of
        {links, Links} -> [P || P <- Links, is_pid(P), P =/= self()];
        undefined -> []
    end.

heap(Pid) ->
    case process_info(Pid, total_heap_size) of
        {total_heap_size, Words} -> Words;
        undefined -> 0
    end.

now_ms() ->
    erlang:monotonic_time(millisecond).
