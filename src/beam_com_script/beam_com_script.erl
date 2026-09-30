%% Runs a program that "beam.com build" made from one .erl file (or one
%% Elixir file).
%%
%% The application of the program has {mod, {beam_com_script, Module}}.
%% When the release has started, Module:main/1 gets the command line
%% arguments, as with escript. The program halts with status 0 when
%% main/1 returns, and with status 127 on an exception.
-module(beam_com_script).
-behaviour(application).
-behaviour(supervisor).

-export([start/2, stop/1, main/1, init/1]).

-ifdef(TEST).
-export([extract/2]).
-endif.

%% The entry of an application program ("beam.com build --main MODULE"):
%% vm.args has "-s beam_com_script main MODULE". init calls this during
%% the boot, so the program runs in its own process, after the boot.
main([Module]) ->
    _ = spawn(fun() -> run(Module) end),
    ok.

%% The application beam_com_script itself: it copies the priv
%% directories that other programs must read (see extract/2), and has an
%% empty supervisor.
start(_Type, boot) ->
    Cache = cache_dir(),
    [extract(Entry, Cache) || Entry <- application:get_env(beam_com_script, extract, [])],
    supervisor:start_link(?MODULE, []);
start(_Type, Module) ->
    {ok, spawn(fun() -> run(Module) end)}.

stop(_State) ->
    ok.

run(Module) ->
    wait_for_boot(),
    Elixir = lists:prefix("Elixir.", atom_to_list(Module)),
    Args = case Elixir of
               %% Elixir programs get binaries, as from System.argv/0.
               true -> [unicode:characters_to_binary(A) || A <- init:get_plain_arguments()];
               false -> init:get_plain_arguments()
           end,
    Status = try Module:main(Args) of
                 _ -> 0
             catch
                 Class:Reason:Stack ->
                     io:put_chars(standard_error,
                                  ["beam.com: ", format(Elixir, Class, Reason, Stack), "\n"]),
                     127
             end,
    erlang:halt(Status).

format(true, Class, Reason, Stack) ->
    'Elixir.Exception':format(Class, Reason, Stack);
format(false, Class, Reason, Stack) ->
    erl_error:format_exception(Class, Reason, Stack).

wait_for_boot() ->
    case init:get_status() of
        {started, _} ->
            ok;
        _ ->
            receive after 10 -> wait_for_boot() end
    end.

init([]) ->
    {ok, {#{}, []}}.

%% A priv directory as real files: other programs (sh, a port program,
%% a tool that reads a data file) cannot read /zip. The builder lists
%% the applications whose priv has an executable file, or that
%% --extract-priv names, as {App, Vsn, Hash, Executables}. The files are
%% copied once to CACHE/priv/HASH/APP-VSN/priv (read-only; executable
%% where they were), and the code path of App points there, so that
%% code:priv_dir(App) is that directory. The code stays in /zip: the
%% ebin/ of /zip stays in the code path, after the empty one.
extract({App, Vsn, Hash, Executables}, Cache) ->
    Name = atom_to_list(App) ++ "-" ++ Vsn,
    Dir = filename:join([Cache, "priv", Hash, Name]),
    Priv = filename:join(Dir, "priv"),
    ZipEbin = code:lib_dir(App) ++ "/ebin",
    From = filename:join(code:lib_dir(App), "priv"),
    case filelib:is_dir(Priv) of
        true -> ok;
        false -> copy(From, Dir, Executables)
    end,
    ok = filelib:ensure_path(filename:join(Dir, "ebin")),
    true = code:replace_path(App, filename:join(Dir, "ebin")),
    true = code:add_pathz(ZipEbin),
    ok.

%% Copy into a new directory, then rename it: two programs that start at
%% the same time do not see a half-copied directory.
copy(From, Dir, Executables) ->
    Tmp = Dir ++ ".tmp." ++ os:getpid(),
    TmpPriv = filename:join(Tmp, "priv"),
    ok = filelib:ensure_path(TmpPriv),
    Files = [F || F <- filelib:wildcard("**", From), filelib:is_regular(filename:join(From, F))],
    [begin
         Target = filename:join(TmpPriv, F),
         ok = filelib:ensure_dir(Target),
         {ok, _} = file:copy(filename:join(From, F), Target),
         Mode = case lists:member(F, Executables) of
                    true -> 8#555;
                    false -> 8#444
                end,
         case file:change_mode(Target, Mode) of
             ok -> ok;
             %% Cosmopolitan has no chmod() on Windows, where the modes
             %% do not decide what runs.
             {error, enosys} -> ok
         end
     end || F <- Files],
    case file:rename(Tmp, Dir) of
        ok -> ok;
        {error, _} ->
            %% Another program made it first.
            _ = file:del_dir_r(Tmp),
            ok
    end.

cache_dir() ->
    case os:getenv("BEAM_COM_CACHE") of
        Dir when is_list(Dir), Dir =/= "" -> Dir;
        _ -> filename:basedir(user_cache, "beam.com")
    end.
