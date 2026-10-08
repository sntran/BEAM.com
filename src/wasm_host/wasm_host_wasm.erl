%% The API of the application wasm of beam.com (WebAssembly and WASI) in
%% the WebAssembly runtime, where WAMR is not: the engine of the host runs
%% the modules (worker.js, WasmHost). "beam.com INPUT -o DIR --target
%% wasm32" puts a module wasm in the release that calls this one, so a
%% program calls wasm:run/2 as it does natively.
%%
%% The differences from the native application:
%% - The standard output and the standard error of a WASI program go to
%%   the group leader of the caller (in Livebook, the output of the cell),
%%   when the call returns.
%% - stdin is empty, and there are no preopens (no files).
%% - A Cloudflare Worker cannot compile WebAssembly at run time: there,
%%   compile/1 gives {error, Reason}. A web page and Deno can.
%% - The code of a module runs on the thread of the host: a function that
%%   does not return stops the VM.
%% - The host keeps a module or an instance until release/1, or until the
%%   process that made it stops, and at most 1024 of them at one time.
%%
%% A request is {"t":"wasm","id":ID,"op":OP} and a JSON body (with the
%% bytes of a module in base64); the reply is {"t":"wasm_reply","id":ID}
%% and a JSON body: {"ok": ...}, {"exit": Code} or {"error": ...}, and
%% "stdout" and "stderr" in base64.
-module(wasm_host_wasm).

-export([compile/1, instantiate/1, instantiate/2, instantiate/3,
         call_function/3, function_exists/2, start/1, run/2,
         memory_size/1, memory_grow/2, read_binary/3, write_binary/3]).
-export([release/1]).
-export([wire/1, unwire/1]).

-define(TIMEOUT, 60000).
%% The key of the watcher of the handles of a process, in its dictionary.
-define(WATCHER, {?MODULE, watcher}).

-spec compile(binary()) -> {ok, {wasm_module, binary()}} | {error, binary()}.
compile(Bytes) when is_binary(Bytes) ->
    case request(compile, #{bytes => base64:encode(Bytes)}) of
        {ok, Id} -> {ok, {wasm_module, owned(Id)}};
        Error -> Error
    end.

instantiate(Module) -> instantiate(Module, #{}, #{}).
instantiate(Module, Imports) -> instantiate(Module, Imports, #{}).

instantiate(Bytes, Imports, Opts) when is_binary(Bytes) ->
    %% The module of the bytes has no handle for the caller: the host
    %% keeps it only for this instance.
    case compile(Bytes) of
        {ok, Module} ->
            try instantiate(Module, Imports, Opts)
            after release(Module)
            end;
        Error -> Error
    end;
instantiate({wasm_module, Id}, Imports, Opts) when is_map(Imports), is_map(Opts) ->
    map_size(Imports) =:= 0 orelse error({badarg, host_functions_not_supported}),
    Args = [utf8(A) || A <- list(maps:get(args, Opts, []))],
    Env = [[utf8(K), utf8(V)] || {K, V} <- pairs(maps:get(env, Opts, []))],
    pairs(maps:get(preopens, Opts, [])) =:= [] orelse error({badarg, preopens_not_supported}),
    case request(instantiate, #{module => Id, args => Args, env => Env}) of
        {ok, Instance} -> {ok, {wasm_instance, owned(Instance)}};
        Error -> Error
    end.

call_function({wasm_instance, Id}, Name, Args) when is_list(Args) ->
    case request(call, #{instance => Id, name => utf8(Name), args => [wire(A) || A <- Args]}) of
        {ok, Results} -> {ok, [unwire(R) || R <- Results]};
        Other -> Other
    end.

function_exists({wasm_instance, Id}, Name) ->
    {ok, Exists} = request(exists, #{instance => Id, name => utf8(Name)}),
    Exists.

start(Instance) ->
    case call_function(Instance, "_start", []) of
        {ok, _} -> {ok, 0};
        {exit, Code} -> {ok, Code};
        Error -> Error
    end.

run(Program, Opts) when is_map(Opts) ->
    case instantiate(Program, #{}, Opts) of
        {ok, Instance} ->
            try start(Instance)
            after release(Instance)
            end;
        Error -> Error
    end.

memory_size({wasm_instance, Id}) ->
    request(memory_size, #{instance => Id}).

memory_grow({wasm_instance, Id}, Pages) when is_integer(Pages), Pages >= 0 ->
    request(memory_grow, #{instance => Id, pages => Pages}).

read_binary({wasm_instance, Id}, Offset, Length)
  when is_integer(Offset), Offset >= 0, is_integer(Length), Length >= 0 ->
    case request(read, #{instance => Id, offset => Offset, length => Length}) of
        {ok, Data} -> {ok, base64:decode(Data)};
        Error -> Error
    end.

write_binary({wasm_instance, Id}, Offset, Data) when is_integer(Offset), Offset >= 0 ->
    case request(write, #{instance => Id, offset => Offset,
                          data => base64:encode(iolist_to_binary(Data))}) of
        {ok, _} -> ok;
        Error -> Error
    end.

%% The host forgets a module or an instance: the handle does not work
%% after this. The watcher of the caller forgets it too.
-spec release({wasm_module, binary()} | {wasm_instance, binary()}) -> ok.
release({_, Id}) when is_binary(Id) ->
    release_host(Id),
    forget(Id).

release_host(Id) ->
    _ = request(release, #{id => Id}),
    ok.

%% A handle belongs to the process that made it: the host forgets it when
%% that process stops. One watcher for each owner keeps the handles of the
%% owner, and waits for its end. The watcher stops when release/1 of the
%% owner forgets the last handle, so a process that calls run/2 many times
%% leaves no process behind.
owned(Id) ->
    Watcher = case get(?WATCHER) of
        undefined ->
            Owner = self(),
            W = spawn(fun() -> watch(erlang:monitor(process, Owner), []) end),
            put(?WATCHER, W),
            W;
        W ->
            W
    end,
    Watcher ! {own, Id},
    Id.

watch(Ref, Ids) ->
    receive
        {own, Id} ->
            watch(Ref, [Id | Ids]);
        {forget, From, Tag, Id} ->
            case lists:delete(Id, Ids) of
                [] -> From ! {Tag, last};
                Left -> From ! {Tag, more}, watch(Ref, Left)
            end;
        {'DOWN', Ref, process, _, _} ->
            lists:foreach(fun release_host/1, Ids)
    end.

%% The watcher of the caller forgets Id. After the last handle, the caller
%% waits for the end of its watcher.
forget(Id) ->
    case get(?WATCHER) of
        undefined ->
            ok;
        W ->
            Tag = erlang:monitor(process, W),
            W ! {forget, self(), Tag, Id},
            receive
                {Tag, more} ->
                    erlang:demonitor(Tag, [flush]),
                    ok;
                {Tag, last} ->
                    erase(?WATCHER),
                    receive {'DOWN', Tag, process, _, _} -> ok end;
                {'DOWN', Tag, process, _, _} ->
                    erase(?WATCHER),
                    ok
            end
    end.

%% --- the host ---------------------------------------------------------

request(Op, Body) ->
    Id = iolist_to_binary(["w", integer_to_binary(erlang:unique_integer([positive]))]),
    wasm_host_server:register(Id),
    try
        wasm_host_server:send_host(#{t => wasm, id => Id, op => Op}, json:encode(Body)),
        receive
            {wasm_host, <<"wasm_reply">>, #{<<"id">> := Id}, Reply} -> reply(json:decode(Reply))
        after ?TIMEOUT ->
                {error, <<"the host did not answer">>}
        end
    after
        wasm_host_server:unregister(Id)
    end.

reply(R) ->
    output(standard_io, maps:get(<<"stdout">>, R, <<>>)),
    output(standard_io, maps:get(<<"stderr">>, R, <<>>)),
    case R of
        #{<<"exit">> := Code} -> {exit, Code};
        #{<<"trap">> := Msg} -> {error, {trap, Msg}};
        #{<<"error">> := <<"not_found">>} -> {error, not_found};
        #{<<"error">> := <<"out_of_bounds">>} -> {error, out_of_bounds};
        #{<<"error">> := Msg} -> {error, Msg};
        #{<<"ok">> := V} -> {ok, V}
    end.

output(_, <<>>) -> ok;
output(Device, Data) -> io:put_chars(Device, base64:decode(Data)).

%% The values on the wire (JSON): an integer out of the safe range of
%% JavaScript as {"i": "123"}, and nan and the infinities as strings.
wire(I) when is_integer(I), abs(I) =< 9007199254740991 -> I;
wire(I) when is_integer(I) -> #{i => integer_to_binary(I)};
wire(F) when is_float(F) -> F;
wire(A) when A =:= nan; A =:= infinity; A =:= '-infinity' -> atom_to_binary(A);
wire(_) -> error(badarg).

unwire(#{<<"i">> := I}) -> binary_to_integer(I);
unwire(<<"nan">>) -> nan;
unwire(<<"infinity">>) -> infinity;
unwire(<<"-infinity">>) -> '-infinity';
unwire(V) -> V.

pairs(M) when is_map(M) -> lists:sort(maps:to_list(M));
pairs(L) when is_list(L) -> L;
pairs(_) -> error(badarg).

list(L) when is_list(L) -> L;
list(_) -> error(badarg).

utf8(Chars) ->
    case unicode:characters_to_binary(Chars) of
        Bin when is_binary(Bin) -> Bin;
        _ -> error(badarg)
    end.
