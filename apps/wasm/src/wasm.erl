%% WebAssembly for Erlang, in beam.com.
%%
%% The runtime is linked into beam.com (a static NIF). The API does not
%% show the runtime, so that it can change later. The names are those of
%% the WebAssembly JavaScript API (compile, instantiate), of wasmex
%% (call_function, function_exists, read_binary, write_binary) and of
%% node:wasi (args, env, preopens, start):
%%
%%   {ok, Mod} = wasm:compile(Bytes),
%%   {ok, Inst} = wasm:instantiate(Mod),
%%   {ok, [3]} = wasm:call_function(Inst, "add", [1, 2]).
%%
%% WASI preview 1 programs (a "_start" function) run with run/2, or with
%% start/1 on an instance:
%%
%%   {ok, 0} = wasm:run(Bytes, #{args => ["hello", "arg"]}).
-module(wasm).

-export([compile/1, instantiate/1, instantiate/2, instantiate/3,
         call_function/3, function_exists/2, start/1, run/2,
         memory_size/1, memory_grow/2, read_binary/3, write_binary/3]).

-nifs([compile_nif/1, instantiate_nif/2, call_function_nif/3,
       function_exists_nif/2, memory_size/1, memory_grow/2,
       read_binary/3, write_binary/3]).

-on_load(init/0).

-opaque wasm_module() :: reference().
-opaque instance() :: reference().
%% NaN and the infinities (not Erlang floats) are atoms.
-type value() :: integer() | float() | nan | infinity | '-infinity'.
%% The imports of the module, by module name and field name. Host
%% functions are not supported yet: only #{} is accepted.
-type imports() :: #{}.
%% Text is unicode:chardata() (as the arguments of a program), and the
%% program gets it in UTF-8. env and preopens are maps (or lists of
%% pairs): the name of a variable to its value, and the directory that
%% the program sees to the directory of the host.
-type text() :: unicode:chardata().
-type options() :: #{stack_size => pos_integer(),
                     heap_size => non_neg_integer(),
                     args => [text()],
                     env => #{text() => text()} | [{text(), text()}],
                     preopens => #{text() => text()} | [{text(), text()}]}.
-export_type([wasm_module/0, instance/0, value/0, imports/0, options/0]).

init() ->
    %% The NIF is static: ERTS finds it by the name of this module, and
    %% does not read the file.
    Dir = case code:lib_dir(wasm) of
              {error, _} -> ".";
              LibDir -> LibDir
          end,
    erlang:load_nif(filename:join([Dir, "priv", "wasm"]), 0).

%% Compile and validate a WebAssembly module (the bytes of a .wasm
%% file), as WebAssembly.compile().
-spec compile(binary()) -> {ok, wasm_module()} | {error, binary()}.
compile(Bytes) when is_binary(Bytes) ->
    compile_nif(Bytes).

-spec instantiate(wasm_module() | binary()) -> {ok, instance()} | {error, term()}.
instantiate(Module) ->
    instantiate(Module, #{}, #{}).

-spec instantiate(wasm_module() | binary(), imports()) ->
          {ok, instance()} | {error, term()}.
instantiate(Module, Imports) ->
    instantiate(Module, Imports, #{}).

%% Make an instance of a module, or of the bytes of a module, as
%% WebAssembly.instantiate(). The WASI options, as those of node:wasi:
%% args (argv, with the program name first), env, and preopens: the
%% directories of the host that the program can use, by the name that
%% the program sees.
-spec instantiate(wasm_module() | binary(), imports(), options()) ->
          {ok, instance()} | {error, term()}.
instantiate(Bytes, Imports, Opts) when is_binary(Bytes) ->
    case compile(Bytes) of
        {ok, Module} -> instantiate(Module, Imports, Opts);
        Error -> Error
    end;
instantiate(Module, Imports, Opts) when is_map(Imports), is_map(Opts) ->
    map_size(Imports) =:= 0 orelse error({badarg, host_functions_not_supported}),
    Args = [utf8(A) || A <- list(maps:get(args, Opts, []))],
    Env = [pair(E, "=") || E <- pairs(maps:get(env, Opts, []))],
    Preopens = [pair(D, "::") || D <- pairs(maps:get(preopens, Opts, []))],
    instantiate_nif(Module, Opts#{args => Args, env => Env, preopens => Preopens}).

pair({A, B}, Sep) -> utf8([A, Sep, B]);
pair(_, _) -> error(badarg).

pairs(M) when is_map(M) -> lists:sort(maps:to_list(M));
pairs(L) -> list(L).

list(L) when is_list(L) -> L;
list(_) -> error(badarg).

utf8(Chars) ->
    case unicode:characters_to_binary(Chars) of
        Bin when is_binary(Bin) -> Bin;
        _ -> error(badarg)
    end.

%% Call an exported function. The types of the arguments and results
%% come from the function type: i32 and i64 are integers, f32 and f64
%% are floats. {exit, Code} is returned when the code calls WASI
%% proc_exit.
-spec call_function(instance(), text(), [value()]) ->
          {ok, [value()]} | {exit, non_neg_integer()}
              | {error, not_found | badarg | {trap, binary()}}.
call_function(Instance, Name, Args) when is_list(Args) ->
    call_function_nif(Instance, utf8(Name), Args).

%% Whether the instance exports a function with this name.
-spec function_exists(instance(), text()) -> boolean().
function_exists(Instance, Name) ->
    function_exists_nif(Instance, utf8(Name)).

%% Start a WASI program, as start() of node:wasi: call its "_start"
%% function, and give the exit code.
-spec start(instance()) -> {ok, non_neg_integer()} | {error, term()}.
start(Instance) ->
    case call_function(Instance, "_start", []) of
        {ok, _} -> {ok, 0};
        {exit, Code} -> {ok, Code};
        Error -> Error
    end.

%% Run a WASI program (a module, or the bytes of a module) with the
%% options of instantiate/3, as "wasmtime run": instantiate, then start.
-spec run(wasm_module() | binary(), options()) ->
          {ok, non_neg_integer()} | {error, term()}.
run(Program, Opts) when is_map(Opts) ->
    case instantiate(Program, #{}, Opts) of
        {ok, Instance} -> start(Instance);
        Error -> Error
    end.

compile_nif(_Bytes) -> erlang:nif_error(not_loaded).
instantiate_nif(_Module, _Opts) -> erlang:nif_error(not_loaded).
call_function_nif(_Instance, _Name, _Args) -> erlang:nif_error(not_loaded).
function_exists_nif(_Instance, _Name) -> erlang:nif_error(not_loaded).

%% The size of the default memory, in bytes.
-spec memory_size(instance()) -> {ok, non_neg_integer()} | {error, not_found}.
memory_size(_Instance) -> erlang:nif_error(not_loaded).

%% Grow the default memory by a number of pages (64 KiB each), and give
%% the size before, in pages, as WebAssembly.Memory.grow().
-spec memory_grow(instance(), non_neg_integer()) ->
          {ok, non_neg_integer()} | {error, not_found | out_of_bounds}.
memory_grow(_Instance, _Pages) -> erlang:nif_error(not_loaded).

%% Read bytes of the default memory.
-spec read_binary(instance(), non_neg_integer(), non_neg_integer()) ->
          {ok, binary()} | {error, not_found | out_of_bounds}.
read_binary(_Instance, _Offset, _Length) -> erlang:nif_error(not_loaded).

%% Write bytes into the default memory.
-spec write_binary(instance(), non_neg_integer(), iodata()) ->
          ok | {error, not_found | out_of_bounds}.
write_binary(_Instance, _Offset, _Data) -> erlang:nif_error(not_loaded).
