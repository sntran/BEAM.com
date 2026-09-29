%% The evaluator of the REPL: Erlang expressions, with the bindings of one
%% session. Each evaluation runs in a new process, with a time limit, a
%% limit of heap, and its own group leader: the output of io goes to the
%% owner as {Ref, output, Text}, and the result as {Ref, result, Result}.
%%
%% Shell commands: b() shows the bindings, f() forgets all of them, f(X)
%% forgets X, and help() shows the commands.
-module(worker_repl).
-export([parse/1, start/3, format/1]).

-define(TIMEOUT, 10000).         % ms for each evaluation
-define(MAX_HEAP, 4000000).      % words (16 MB on wasm32)
-define(MAX_OUTPUT, 65536).      % bytes of output for each evaluation
-define(DEPTH, 60).              % depth of a printed term

%% The expressions of Text. A final dot is optional.
-spec parse(unicode:chardata()) -> {ok, [erl_parse:abstract_expr()]} | {error, binary()}.
parse(Text) ->
    case erl_scan:string(unicode:characters_to_list(Text)) of
        {ok, [], _} ->
            {error, <<"no expression">>};
        {ok, Tokens, End} ->
            Dotted = case lists:last(Tokens) of
                         {dot, _} -> Tokens;
                         _ -> Tokens ++ [{dot, End}]
                     end,
            case erl_parse:parse_exprs(Dotted) of
                {ok, Exprs} -> {ok, Exprs};
                {error, {Loc, Mod, Desc}} -> {error, error_text(Loc, Mod, Desc)}
            end;
        {error, {Loc, Mod, Desc}, _} ->
            {error, error_text(Loc, Mod, Desc)}
    end.

%% Evaluates Exprs with Bindings in a new process. The owner gets the
%% messages of Ref; it calls this again only after {Ref, result, _}.
-spec start(reference(), [erl_parse:abstract_expr()], erl_eval:binding_struct()) -> pid().
start(Ref, Exprs, Bindings) ->
    Owner = self(),
    spawn(fun() -> supervise(Owner, Ref, Exprs, Bindings) end).

supervise(Owner, Ref, Exprs, Bindings) ->
    Out = spawn_link(fun() -> output(Owner, Ref, 0) end),
    Sup = self(),
    {Pid, Mon} = spawn_opt(fun() -> evaluate(Sup, Ref, Out, Exprs, Bindings) end,
                           [monitor, {max_heap_size, #{size => ?MAX_HEAP, kill => true,
                                                       error_logger => false}}]),
    Result = receive
                 {'DOWN', Mon, process, Pid, normal} ->
                     receive {Ref, done, R} -> R end;
                 {'DOWN', Mon, process, Pid, killed} ->
                     {error, <<"** the evaluation used more than 16 MB of heap\n">>, Bindings};
                 {'DOWN', Mon, process, Pid, Reason} ->
                     {error, iolist_to_binary(io_lib:format("** stopped: ~tP~n", [Reason, ?DEPTH])),
                      Bindings};
                 {Ref, interrupt} ->
                     exit(Pid, kill),
                     {error, <<"** interrupted\n">>, Bindings}
             after ?TIMEOUT ->
                     exit(Pid, kill),
                     {error, <<"** the evaluation took more than 10 s\n">>, Bindings}
             end,
    %% The output of the evaluation goes before its result. Then the group
    %% leader stops: a process that the evaluation started has no output.
    Out ! {stop, self()},
    receive {stopped, Out} -> ok after 1000 -> ok end,
    Owner ! {Ref, result, Result}.

evaluate(Sup, Ref, Out, Exprs, Bindings) ->
    group_leader(Out, self()),
    R = try erl_eval:exprs(Exprs, Bindings, {eval, fun local/3}) of
            {value, Value, New} -> {value, format(Value), New}
        catch
            Class:Reason:Stack ->
                {error, exception(Class, Reason, Stack), Bindings}
        end,
    Sup ! {Ref, done, R},
    ok.

%% A term as the shell prints it.
-spec format(term()) -> binary().
format(Term) ->
    cut(unicode:characters_to_binary(io_lib:format("~tP", [Term, ?DEPTH]))).

exception(Class, Reason, Stack) ->
    Trim = fun(M, _F, _A) -> lists:member(M, [erl_eval, ?MODULE]) end,
    Text = erl_error:format_exception(Class, Reason, Stack, #{stack_trim_fun => Trim}),
    cut(unicode:characters_to_binary(["** ", Text, "\n"])).

cut(Bin) when byte_size(Bin) > ?MAX_OUTPUT ->
    <<(string:slice(Bin, 0, ?MAX_OUTPUT div 4))/binary, "... (cut)">>;
cut(Bin) ->
    Bin.

error_text(Loc, Mod, Desc) ->
    Line = case Loc of {L, _} -> L; L -> L end,
    iolist_to_binary(io_lib:format("** syntax error on line ~p: ~ts~n", [Line, Mod:format_error(Desc)])).

%% The shell commands.
local(b, [], Bindings) ->
    [io:format("~ts = ~tP~n", [K, V, ?DEPTH]) || {K, V} <- lists:sort(erl_eval:bindings(Bindings))],
    {value, ok, Bindings};
local(f, [], _Bindings) ->
    {value, ok, erl_eval:new_bindings()};
local(f, [{var, _, Name}], Bindings) ->
    {value, ok, erl_eval:del_binding(Name, Bindings)};
local(help, [], Bindings) ->
    io:put_chars("Erlang expressions end at a dot (optional here). Each session\n"
                 "keeps its variables. Commands: b() shows the variables, f()\n"
                 "forgets all of them, f(X) forgets X, help() shows this text.\n"
                 "An evaluation stops after 10 s or 16 MB of heap.\n"),
    {value, ok, Bindings};
local(Name, Args, _Bindings) ->
    erlang:raise(error, undef, [{shell, Name, length(Args), []}]).

%% The group leader of an evaluation: output to the owner, no input.
output(Owner, Ref, Size) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            {Reply, Text} = io_request(Request),
            From ! {io_reply, ReplyAs, Reply},
            New = Size + byte_size(Text),
            if
                Text =:= <<>> -> ok;
                New =< ?MAX_OUTPUT -> Owner ! {Ref, output, Text};
                Size =< ?MAX_OUTPUT -> Owner ! {Ref, output, <<"\n... (output cut)\n">>};
                true -> ok
            end,
            output(Owner, Ref, New);
        {stop, From} ->
            From ! {stopped, self()}
    end.

io_request({put_chars, Encoding, Chars}) ->
    {ok, unicode:characters_to_binary(Chars, Encoding)};
io_request({put_chars, Encoding, M, F, A}) ->
    try io_request({put_chars, Encoding, apply(M, F, A)})
    catch _:_ -> {{error, F}, <<>>}
    end;
io_request({requests, Requests}) ->
    lists:foldl(fun(R, {_, Acc}) ->
                        {Reply, Text} = io_request(R),
                        {Reply, <<Acc/binary, Text/binary>>}
                end, {ok, <<>>}, Requests);
io_request(getopts) ->
    {[{binary, false}, {encoding, unicode}], <<>>};
io_request({get_geometry, columns}) ->
    {80, <<>>};
io_request({get_geometry, _}) ->
    {{error, enotsup}, <<>>};
io_request(Request) when element(1, Request) =:= get_line; element(1, Request) =:= get_chars;
                         element(1, Request) =:= get_until; element(1, Request) =:= get_password ->
    {eof, <<>>};
io_request(_) ->
    {{error, request}, <<>>}.
