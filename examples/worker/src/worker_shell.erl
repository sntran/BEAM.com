%% The Erlang shell (the module shell of stdlib) for a web page. Each
%% session is a process that is the group leader of its shell: it gives
%% the shell the lines of the page, and sends the page the output and
%% the prompts of the shell. The owner (the WebSocket process) gets
%% {shell, Session, {output, Text}}, {shell, Session, {prompt, Text}} and
%% {shell, Session, down}.
%%
%% The shell is a restricted shell (worker:start/2 sets it): it refuses
%% q(), halt() and init:stop(), which stop the VM for all the visitors of
%% an isolate. This is no sandbox: other code can still stop the VM.
%%
%% An evaluation stops after 10 s, or when its process has more than
%% 16 MB of heap. The time of a read (io:get_line/1 in the code of the
%% visitor) does not count.
-module(worker_shell).
-export([start/0, input/2, interrupt/1]).
-export([local_allowed/3, non_local_allowed/3]).

-define(TIMEOUT, 10000).         % ms for each evaluation
-define(MAX_HEAP, 4000000).      % words (16 MB on wasm32)
-define(MAX_OUTPUT, 65536).      % bytes of output for each evaluation
-define(TICK, 250).              % ms between the checks of an evaluation

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

%% The restricted shell: all calls, except those that stop the VM.
local_allowed(F, _Args, State) when F =:= q; F =:= halt ->
    {false, State};
local_allowed(_F, _Args, State) ->
    {true, State}.

non_local_allowed({erlang, halt}, _Args, State) ->
    {false, State};
non_local_allowed({init, F}, _Args, State) when F =:= stop; F =:= restart; F =:= reboot ->
    {false, State};
non_local_allowed({M, q}, _Args, State) when M =:= c; M =:= shell_default ->
    {false, State};
non_local_allowed(_FuncSpec, _Args, State) ->
    {true, State}.

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
            exit(S#s.shell, kill);
        {'DOWN', _, process, Pid, _} when Pid =:= S#s.shell ->
            S#s.owner ! {shell, self(), down};
        _ ->
            loop(S)
    end.

%% The requests of the I/O protocol.
request(From, ReplyAs, {get_until, Encoding, Prompt, M, F, Xs}, S) ->
    wait(From, ReplyAs, {until, Encoding, Prompt, M, F, Xs, []}, S);
request(From, ReplyAs, {get_until, Prompt, M, F, Xs}, S) ->
    wait(From, ReplyAs, {until, latin1, Prompt, M, F, Xs, []}, S);
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
simple({put_chars, Encoding, M, F, A}, S) ->
    try simple({put_chars, Encoding, apply(M, F, A)}, S)
    catch _:_ -> {{error, F}, S}
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
                {done, Result, Rest} -> {done, Result, rest(Rest)};
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
