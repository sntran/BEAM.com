%% WebAssembly for Erlang, in beam.com.
%%
%% The runtime is linked into beam.com (a static NIF). The API does not
%% show the runtime, so that it can change later.
%%
%%   {ok, Mod} = wasm:load(Bytes),
%%   {ok, Inst} = wasm:instantiate(Mod),
%%   {ok, [3]} = wasm:call(Inst, "add", [1, 2]).
%%
%% WASI preview 1 programs (a "_start" function) run with run/2,3:
%%
%%   {ok, 0} = wasm:run(Bytes, ["hello", "arg"]).
-module(wasm).

-export([load/1, instantiate/1, instantiate/2, call/3, run/2, run/3,
         memory_size/1, memory_read/3, memory_write/3]).

-nifs([load_nif/1, instantiate_nif/2, call_nif/3, memory_size/1,
       memory_read/3, memory_write/3]).

-on_load(init/0).

-opaque wasm_module() :: reference().
-opaque instance() :: reference().
-type value() :: integer() | float().
-type options() :: #{stack_size => pos_integer(),
                     heap_size => non_neg_integer(),
                     args => [iodata()],
                     env => [{iodata(), iodata()}],
                     dirs => [{Guest :: iodata(), Host :: iodata()}]}.
-export_type([wasm_module/0, instance/0, value/0, options/0]).

init() ->
    %% The NIF is static: ERTS finds it by the name of this module, and
    %% does not read the file.
    Dir = case code:lib_dir(wasm) of
              {error, _} -> ".";
              LibDir -> LibDir
          end,
    erlang:load_nif(filename:join([Dir, "priv", "wasm"]), 0).

%% Load and validate a WebAssembly module (the bytes of a .wasm file).
-spec load(binary()) -> {ok, wasm_module()} | {error, binary()}.
load(Bytes) when is_binary(Bytes) ->
    load_nif(Bytes).

-spec instantiate(wasm_module()) -> {ok, instance()} | {error, term()}.
instantiate(Module) ->
    instantiate(Module, #{}).

%% Make an instance. The WASI options: args (argv, with the program
%% name first), env, and dirs: host directories that the program can
%% use, with the name that the program sees.
-spec instantiate(wasm_module(), options()) ->
          {ok, instance()} | {error, term()}.
instantiate(Module, Opts) when is_map(Opts) ->
    Env = [[K, "=", V] || {K, V} <- maps:get(env, Opts, [])],
    Dirs = [[G, "::", H] || {G, H} <- maps:get(dirs, Opts, [])],
    instantiate_nif(Module, Opts#{env => Env, dirs => Dirs}).

%% Call an exported function. The types of the arguments and results
%% come from the function type: i32 and i64 are integers, f32 and f64
%% are floats. {exit, Code} is returned when the code calls WASI
%% proc_exit.
-spec call(instance(), iodata(), [value()]) ->
          {ok, [value()]} | {exit, non_neg_integer()}
              | {error, not_found | badarg | {trap, binary()}}.
call(Instance, Name, Args) when is_list(Args) ->
    call_nif(Instance, Name, Args).

-spec run(binary() | wasm_module(), [iodata()]) ->
          {ok, non_neg_integer()} | {error, term()}.
run(Program, Args) ->
    run(Program, Args, #{}).

%% Run a WASI program: call its "_start" function, and give the exit
%% code. Args are argv (the program name first).
-spec run(binary() | wasm_module(), [iodata()], options()) ->
          {ok, non_neg_integer()} | {error, term()}.
run(Bytes, Args, Opts) when is_binary(Bytes) ->
    case load(Bytes) of
        {ok, Module} -> run(Module, Args, Opts);
        Error -> Error
    end;
run(Module, Args, Opts) ->
    case instantiate(Module, Opts#{args => Args}) of
        {ok, Instance} ->
            case call(Instance, "_start", []) of
                {ok, _} -> {ok, 0};
                {exit, Code} -> {ok, Code};
                Error -> Error
            end;
        Error ->
            Error
    end.

load_nif(_Bytes) -> erlang:nif_error(not_loaded).
instantiate_nif(_Module, _Opts) -> erlang:nif_error(not_loaded).
call_nif(_Instance, _Name, _Args) -> erlang:nif_error(not_loaded).

%% The size of the default memory, in bytes.
-spec memory_size(instance()) -> {ok, non_neg_integer()} | {error, not_found}.
memory_size(_Instance) -> erlang:nif_error(not_loaded).

-spec memory_read(instance(), non_neg_integer(), non_neg_integer()) ->
          {ok, binary()} | {error, not_found | out_of_bounds}.
memory_read(_Instance, _Offset, _Length) -> erlang:nif_error(not_loaded).

-spec memory_write(instance(), non_neg_integer(), iodata()) ->
          ok | {error, not_found | out_of_bounds}.
memory_write(_Instance, _Offset, _Data) -> erlang:nif_error(not_loaded).
