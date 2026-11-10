%% New code in a running program, from a new file in the place of its
%% file (docs/PROGRAMS.md, "New code in a running program").
%%
%% A program reads its code from /zip, and Cosmopolitan maps that zip one
%% time, at the start (C52 of docs/UPSTREAM.md). So a change of the file
%% does not change /zip. This process watches the path of the file of the
%% program (-beam_com_exe). When a new file takes its place (zip writes a
%% new file and renames it), the process reads the zip of the new file as
%% a plain file:
%%
%%   zip -r my_app.com lib/my_app-0.1.0
%%
%% - The .beam files of lib/APP-VSN/ebin/ and releases/VSN/consolidated/
%%   load, when their directory is in the code path, and only when their
%%   code changed (module_info(md5)). They load together
%%   (code:atomic_load/1). When a process still runs old code of a
%%   module, the load waits, and it never kills a process.
%% - A new or changed lib/APP-VSN/ebin/APP.appup gives the instructions
%%   of OTP for the processes: {update, Mod, {advanced, Extra}} suspends
%%   each process of Mod, loads the code, calls code_change/3, and
%%   resumes the process (see instructions/2).
%% - A new file in lib/APP-VSN/priv/ of a running application: the
%%   process copies the files of the application to the cache directory,
%%   moves the code path of the application there (code:replace_path/2),
%%   and calls config_change/3 of its application module. Thus
%%   code:priv_dir/1 gives the new files (Plug.Static, and the static
%%   manifest of Phoenix).
%% - Another runtime (the bytes before the zip) loads nothing. Other files
%%   need a restart; the log names them.
%%
%% beam.com starts it for a program with -beam_com_reload MS (the time
%% between two checks, 0 for none) and boot/0 (c_src/cosmo/beam_com.c).
-module(beam_com_reload).
-behaviour(gen_server).

-export([boot/0, start_link/1, status/0, check/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).
-export([index/1, classify/2, read_entry/2, instructions/2, appup/3, interval/1, alive/1]).
-endif.

-include_lib("kernel/include/file.hrl").
-include_lib("kernel/include/logger.hrl").

-define(EOCD, 16#06054b50).
-define(EOCD64, 16#06064b50).
-define(EOCD64_LOCATOR, 16#07064b50).
-define(CDIR, 16#02014b50).
-define(LOCAL, 16#04034b50).
%% The longest wait for sys:suspend/2 and sys:change_code/5.
-define(SYS_TIMEOUT, 5000).
%% The wait before the delete of the copy before of a moved application:
%% a request that found a path of that copy can still open its file.
-define(GRACE, 60000).

%% The start from beam.com (-eval of beam_com.c, after the boot): a
%% temporary child of kernel_safe_sup, so an error of the reload never
%% stops the node. Nothing without -beam_com_exe, or with 0 for
%% -beam_com_reload.
boot() ->
    case {init:get_argument(beam_com_exe), interval(init:get_argument(beam_com_reload))} of
        {{ok, [[Path] | _]}, Ms} when Ms > 0 ->
            Spec = #{id => ?MODULE,
                     start => {?MODULE, start_link, [#{path => Path, interval => Ms}]},
                     restart => temporary,
                     shutdown => 2000,
                     type => worker,
                     modules => [?MODULE]},
            try supervisor:start_child(kernel_safe_sup, Spec) of
                {ok, _} -> ok;
                Error -> ?LOG_WARNING("beam.com: no reload of new code: ~tp", [Error])
            catch
                exit:Reason -> ?LOG_WARNING("beam.com: no reload of new code: ~tp", [Reason])
            end;
        _ ->
            ok
    end.

%% The last -beam_com_reload MS: a later value (the vm.args of the
%% release) wins over the value of beam.com. Do not use
%% string:to_integer/1 here: its first call adds about 18 ms to the
%% start of each program.
interval({ok, Values}) ->
    try list_to_integer(lists:last(lists:last(Values))) of
        Ms when Ms >= 0 -> Ms;
        _ -> 0
    catch
        error:badarg -> 0
    end;
interval(error) ->
    0.

%% Opts: path, interval, and for the tests code_path (a fun that gives
%% the code path), cache (the cache directory), root (the directory of
%% the zip in the code path, /zip) and grace (the wait before the delete
%% of an old copy, in ms).
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

%% The result of the last check, and the modules that wait.
status() ->
    gen_server:call(?MODULE, status, infinity).

%% A check now, without the wait for the next tick.
check() ->
    gen_server:call(?MODULE, check, infinity).

%% The start does only a stat and an open of the file, because it runs
%% before the program goes on (the -eval of beam.com). The open file
%% keeps the bytes of this file after zip renames a new file into its
%% place, so the index and the runtime of this file are read only at the
%% first change. The sweep of the cache occurs at the first check.
init(#{path := Path, interval := Ms} = Opts) ->
    process_flag(trap_exit, true),
    Reload = filename:join(maps:get(cache, Opts, cache_dir()), "reload"),
    State = #{path => Path, interval => Ms, stat => undefined, seen => undefined,
              index => undefined, prefix => undefined, base => undefined,
              swept => false, reload => Reload,
              pending => [], plan => #{},
              notify => [], last => none, moved => #{},
              cache => filename:join(Reload, os:getpid()),
              code_path => maps:get(code_path, Opts, fun code:get_path/0),
              root => maps:get(root, Opts, "/zip"),
              grace => maps:get(grace, Opts, ?GRACE)},
    {ok, tick(case {stat(Path), file:open(Path, [read, raw, binary])} of
                  {{ok, Stat}, {ok, Fd}} ->
                      State#{stat := Stat, seen := Stat, base := Fd};
                  {{ok, Stat}, {error, Reason}} ->
                      ?LOG_WARNING("beam.com: no reload of new code: ~ts: ~tp", [Path, Reason]),
                      State#{stat := Stat, seen := Stat, index := #{}};
                  {{error, Reason}, _} ->
                      ?LOG_WARNING("beam.com: no reload of new code: ~ts: ~tp", [Path, Reason]),
                      State#{index := #{}}
              end)}.

handle_call(status, _From, #{last := Last, pending := Pending} = State) ->
    {reply, #{last => Last, pending => [M || {M, _, _} <- Pending]}, State};
handle_call(check, _From, State0) ->
    State = safe_run(safe_run(State0#{seen := undefined})),
    {reply, maps:get(last, State), State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    {noreply, tick(safe_run(State))};
handle_info({delete, Dir}, State) ->
    _ = file:del_dir_r(Dir),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

%% The copies of the cache are for this process only.
terminate(_Reason, #{cache := Cache} = State) ->
    _ = file:del_dir_r(Cache),
    _ = close_base(State),
    ok.

%% The copies of an earlier process with the same OS process id, and of
%% the processes that stopped with no terminate/2 (a kill): one time, at
%% the first check.
clean(#{swept := true} = State) ->
    State;
clean(#{reload := Reload, cache := Cache} = State) ->
    _ = file:del_dir_r(Cache),
    _ = sweep(Reload),
    State#{swept := true}.

%% The index and the runtime of the file at the start, from its open
%% file, before the first change uses them.
base(#{index := undefined, base := Fd, path := Path} = State) ->
    Result = try directory(Fd) of
                 {ok, Index, DirOffset} -> {Index, prefix(Fd, Index, DirOffset)};
                 {error, Reason} -> {error, Reason}
             catch
                 Class:Error -> {error, {Class, Error}}
             end,
    case Result of
        {error, Why} ->
            ?LOG_WARNING("beam.com: ~ts: ~tp", [Path, Why]),
            close_base(State#{index := #{}});
        {Index1, Prefix} ->
            close_base(State#{index := Index1, prefix := Prefix})
    end;
base(State) ->
    State.

close_base(#{base := undefined} = State) ->
    State;
close_base(#{base := Fd} = State) ->
    _ = file:close(Fd),
    State#{base := undefined}.

%% Delete each directory reload/PID of a process that does not run. A
%% directory whose process may run stays.
sweep(Reload) ->
    Own = os:getpid(),
    case file:list_dir(Reload) of
        {ok, Names} ->
            [file:del_dir_r(filename:join(Reload, N))
             || N <- Names, N =/= Own, N =/= "", lists:all(fun(C) -> C >= $0 andalso C =< $9 end, N),
                not alive(N)];
        {error, _} ->
            []
    end.

%% True when the OS process Pid may run: on Linux /proc/Pid, else
%% kill -0 Pid, with no shell. When kill does not start (for example in
%% a sandbox), the process may run.
alive(Pid) ->
    case filelib:is_dir("/proc/self") of
        true ->
            filelib:is_dir("/proc/" ++ Pid);
        false ->
            case os:find_executable("kill") of
                false ->
                    true;
                Kill ->
                    try open_port({spawn_executable, Kill},
                                  [{args, ["-0", Pid]}, exit_status, stderr_to_stdout]) of
                        Port -> exit_status(Port) =:= 0
                    catch
                        _:_ -> true
                    end
            end
    end.

exit_status(Port) ->
    receive
        {Port, {exit_status, Status}} -> Status;
        {Port, {data, _}} -> exit_status(Port)
    after 5000 ->
            %% No answer: the process may run.
            try port_close(Port) catch _:_ -> ok end,
            0
    end.

cache_dir() ->
    case os:getenv("BEAM_COM_CACHE") of
        Dir when is_list(Dir), Dir =/= "" -> Dir;
        _ -> filename:basedir(user_cache, "beam.com")
    end.

tick(#{interval := Ms} = State) ->
    erlang:send_after(Ms, self(), tick),
    State.

%% An error of a check stops only that check: the program goes on with
%% its code, and the next new file tries again.
safe_run(State) ->
    try
        run(State)
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR("beam.com: the check of new code failed: ~tp", [{Class, Reason, Stack}]),
            Stat = case stat(maps:get(path, State)) of
                       {ok, S} -> S;
                       {error, _} -> maps:get(stat, State)
                   end,
            State#{stat := Stat, seen := Stat, last := {error, {Class, Reason}}}
    end.

%% One check. A new file loads only when its stat did not change since
%% the check before: a file that a program still writes waits. The
%% modules that wait load first.
run(State0) ->
    #{path := Path, stat := Old, seen := Seen} = State = retry(clean(State0)),
    case stat(Path) of
        {ok, Old} -> State#{seen := Old};
        {ok, New} when New =:= Seen -> update(New, State);
        {ok, New} -> State#{seen := New};
        {error, _} -> State
    end.

update(Stat, State00) ->
    #{path := Path, index := Old, prefix := Prefix} = State0 = base(State00),
    case snapshot(Path) of
        {ok, _, New, Prefix} ->
            State = State0#{stat := Stat, index := New},
            {ok, Fd} = file:open(Path, [read, raw, binary]),
            try
                changes(Fd, classify(Old, New), State)
            after
                file:close(Fd)
            end;
        {ok, _, New, _} ->
            ?LOG_WARNING("beam.com: ~ts has another runtime: restart the program "
                         "for its new code", [Path]),
            State0#{stat := Stat, index := New, last := {error, runtime_changed}};
        {error, Reason} ->
            ?LOG_WARNING("beam.com: ~ts: ~tp", [Path, Reason]),
            State0#{stat := Stat}
    end.

%% The changed beams and the other changed files of two indexes: a file
%% with another CRC-32 or size, or a new file. zip moves the files after a
%% changed file, so the offset is not a change. A directory and a removed
%% file are not changes: the module of a removed file stays loaded.
classify(Old, New) ->
    Changed = [Name || {Name, Entry} <- maps:to_list(New),
                       lists:last(Name) =/= $/,
                       content(maps:get(Name, Old, none)) =/= content(Entry)],
    lists:partition(fun beam/1, lists:sort(Changed)).

content({Crc, _CompSize, Size, _Method, _Offset}) -> {Crc, Size};
content(none) -> none.

beam(Name) ->
    case filename:split(Name) of
        ["lib", _, "ebin", File] -> filename:extension(File) =:= ".beam";
        ["releases", _, "consolidated", File] -> filename:extension(File) =:= ".beam";
        _ -> false
    end.

%% The work of one new file: the files of priv/ first (the new code can
%% read them), then the instructions of the appup files, then the beams.
changes(Fd, {Beams, Other}, #{path := Path} = State0) ->
    {Moved, State1} = move_apps(Fd, Beams ++ Other, State0),
    MovedDirs = [Dir || {Dir, _} <- Moved],
    Appups = [N || N <- Other, appup_name(N)],
    %% The native program does not read .wasm/ (the part of the WebAssembly
    %% runtime), so a new file there gets no notice.
    Rest = [N || N <- Other, not appup_name(N), not lists:member(app_dir(N), MovedDirs),
                 not lists:prefix(".wasm/", N)],
    Rest =:= [] orelse
        ?LOG_NOTICE("beam.com: ~ts has new files that a restart uses: ~ts",
                    [Path, names(Rest)]),
    CodePath = code_path(State1),
    {InPath, Out} = lists:partition(fun(N) -> in_code_path(N, CodePath, State1) end, Beams),
    Out =:= [] orelse
        ?LOG_WARNING("beam.com: ~ts has beams outside the code path of the program, so a "
                     "restart does not use them, and they do not load: ~ts",
                     [Path, names(Out)]),
    case plan(Fd, Appups, State1) of
        {ok, Plan} ->
            case read_beams(Fd, InPath, State1) of
                {ok, Mods} ->
                    Apps = [App || {_, App} <- Moved],
                    swap(Mods, Plan, State1#{notify := lists:usort(Apps ++ notify(State1))});
                {error, Bad} ->
                    ?LOG_WARNING("beam.com: ~ts: cannot read ~tp", [Path, Bad]),
                    State1#{last := {error, {bad_entries, Bad}}}
            end;
        {error, Reason} ->
            ?LOG_WARNING("beam.com: ~ts: the appup cannot be used, so no new code loads: ~tp",
                         [Path, Reason]),
            State1#{last := {error, Reason}}
    end.

notify(#{notify := Apps}) -> Apps.

read_beams(Fd, Names, #{root := Root} = State) ->
    Read = [{Name, read_name(Fd, Name, State)} || Name <- Names],
    case [{Name, Reason} || {Name, {error, Reason}} <- Read] of
        [] ->
            {ok, [{list_to_atom(filename:basename(Name, ".beam")), Root ++ "/" ++ Name, Bin}
                  || {Name, {ok, Bin}} <- Read]};
        Bad ->
            {error, Bad}
    end.

%% The data of a name of the new file (the index of the state).
read_name(Fd, Name, #{index := Index}) ->
    read_entry(Fd, maps:get(Name, Index)).

code_path(#{code_path := CodePath}) ->
    [string:trim(P, trailing, "/") || P <- CodePath()].

%% A beam loads only from a directory of the code path: a restart reads
%% the code from there. The code path of a moved application is in the
%% cache, for the same directory of the zip.
in_code_path(Name, CodePath, #{moved := Moved, root := Root}) ->
    lists:member(Root ++ "/" ++ filename:dirname(Name), CodePath)
        orelse maps:is_key(app_dir(Name), Moved).

%% "lib/APP-VSN" of a name under lib/, else none.
app_dir(Name) ->
    case filename:split(Name) of
        ["lib", App | _] -> "lib/" ++ App;
        _ -> none
    end.

appup_name(Name) ->
    case filename:split(Name) of
        ["lib", AppVsn, "ebin", File] ->
            {App, _} = split_app(AppVsn),
            File =:= App ++ ".appup";
        _ ->
            false
    end.

%% "phoenix-1.9.0-dev" -> {"phoenix", "1.9.0-dev"}.
split_app(AppVsn) ->
    case re:run(AppVsn, "^(.+?)-([0-9].*)$", [{capture, all_but_first, list}, unicode]) of
        {match, [App, Vsn]} -> {App, Vsn};
        nomatch -> {AppVsn, ""}
    end.

%% The plan of the new appup files: #{updates => #{Mod => Change},
%% applies => [MFA]}.
plan(Fd, Appups, State) ->
    lists:foldl(fun(_, {error, _} = Error) -> Error;
                   (Name, {ok, Acc}) -> plan_one(Fd, Name, Acc, State)
                end, {ok, #{updates => #{}, applies => []}}, Appups).

plan_one(Fd, Name, #{updates := U, applies := A} = Acc, State) ->
    {App, _} = split_app(lists:nth(2, filename:split(Name))),
    case read_name(Fd, Name, State) of
        {ok, Bin} ->
            case appup(list_to_atom(App), Bin, running_vsn(list_to_atom(App))) of
                {ok, Instructions} ->
                    case instructions(Instructions, {U, A}) of
                        {ok, {U1, A1}} -> {ok, Acc#{updates := U1, applies := A1}};
                        {error, _} = Error -> Error
                    end;
                none ->
                    {ok, Acc};
                {error, _} = Error ->
                    Error
            end;
        {error, Reason} ->
            {error, {Name, Reason}}
    end.

running_vsn(App) ->
    case application:get_key(App, vsn) of
        {ok, Vsn} -> Vsn;
        undefined -> undefined
    end.

%% The instructions of an appup ({Vsn, UpFrom, DownTo}) for the running
%% version Vsn: the entry of UpFrom whose version is Vsn, or a binary
%% that matches all of Vsn (a regular expression, as in OTP). The
%% application keeps its version in a deploy with no new release.
appup(_App, _Bin, undefined) ->
    none;
appup(App, Bin, Vsn) ->
    case parse(Bin) of
        {ok, {_NewVsn, UpFrom, _DownTo}} when is_list(UpFrom) ->
            Match = fun({From, _}) when is_list(From) -> From =:= Vsn;
                       ({From, _}) when is_binary(From) ->
                            re:run(Vsn, <<"^(?:", From/binary, ")$">>, [{capture, none}]) =:= match;
                       (_) -> false
                    end,
            case lists:search(Match, UpFrom) of
                {value, {_, Instructions}} when is_list(Instructions) -> {ok, Instructions};
                {value, Bad} -> {error, {appup, App, Bad}};
                false -> none
            end;
        {ok, Other} ->
            {error, {appup, App, Other}};
        {error, Reason} ->
            {error, {appup, App, Reason}}
    end.

%% A term, with no code: erl_parse:parse_term/1 takes only data.
parse(Bin) ->
    case erl_scan:string(unicode:characters_to_list(Bin)) of
        {ok, Tokens, _} ->
            case erl_parse:parse_term(Tokens) of
                {ok, Term} -> {ok, Term};
                {error, _} -> {error, bad_term}
            end;
        _ ->
            {error, bad_term}
    end.

%% The instructions of OTP that a reload can do:
%%
%% - {update, Mod}, {update, Mod, soft}, {update, Mod, {advanced, Extra}}
%%   and {update, Mod, supervisor}, also with a timeout, a purge and the
%%   dependent modules (these change nothing here): the processes of Mod
%%   stop while the code loads. advanced calls code_change/3 with Extra,
%%   and supervisor reads init/1 of the supervisor again.
%% - {load_module, Mod, ...} and {add_module, Mod}: a load, as with no
%%   appup.
%% - {apply, {M, F, A}}: a call after the load.
%%
%% Another instruction (a new application, a restart) needs a restart of
%% the program: the reload refuses the whole file.
instructions([], Acc) ->
    {ok, Acc};
instructions([I | Rest], {Updates, Applies} = Acc) ->
    case instruction(I) of
        {update, Mod, Change} -> instructions(Rest, {Updates#{Mod => Change}, Applies});
        {apply, MFA} -> instructions(Rest, {Updates, Applies ++ [MFA]});
        load -> instructions(Rest, Acc);
        error -> {error, {not_supported, I}}
    end.

instruction({update, Mod}) when is_atom(Mod) -> {update, Mod, soft};
instruction({update, Mod, supervisor}) when is_atom(Mod) -> {update, Mod, supervisor};
instruction({update, Mod, Change}) when is_atom(Mod) -> change(Mod, Change);
instruction({update, Mod, Change, Deps}) when is_atom(Mod), is_list(Deps) -> change(Mod, Change);
instruction({update, Mod, Timeout, Change, _Pre, _Post, Deps})
  when is_atom(Mod), is_list(Deps), (Timeout =:= default orelse Timeout =:= infinity
                                     orelse is_integer(Timeout)) ->
    change(Mod, Change);
instruction({update, Mod, ModType, Timeout, Change, _Pre, _Post, Deps})
  when is_atom(Mod), (ModType =:= static orelse ModType =:= dynamic), is_list(Deps),
       (Timeout =:= default orelse Timeout =:= infinity orelse is_integer(Timeout)) ->
    change(Mod, Change);
instruction({load_module, Mod}) when is_atom(Mod) -> load;
instruction({load_module, Mod, Deps}) when is_atom(Mod), is_list(Deps) -> load;
instruction({load_module, Mod, _Pre, _Post, Deps}) when is_atom(Mod), is_list(Deps) -> load;
instruction({add_module, Mod}) when is_atom(Mod) -> load;
instruction({add_module, Mod, Deps}) when is_atom(Mod), is_list(Deps) -> load;
instruction({apply, {M, F, A}}) when is_atom(M), is_atom(F), is_list(A) -> {apply, {M, F, A}};
instruction(_) -> error.

change(Mod, soft) -> {update, Mod, soft};
change(Mod, {advanced, Extra}) -> {update, Mod, {advanced, Extra}};
change(_Mod, _) -> error.

%% The modules whose code changed join the modules that wait from before.
swap(Mods0, Plan, #{pending := Pending, plan := Old} = State) ->
    Mods = [M || {Mod, _, Bin} = M <- Mods0, changed(Mod, Bin)],
    Names = [Mod || {Mod, _, _} <- Mods],
    Waiting = [P || {Mod, _, _} = P <- Pending, not lists:member(Mod, Names)],
    New = #{updates => maps:merge(maps:get(updates, Old, #{}), maps:get(updates, Plan, #{})),
            applies => maps:get(applies, Old, []) ++ maps:get(applies, Plan, [])},
    case Waiting ++ Mods of
        [] -> config_changes(State#{last := {ok, []}, plan := #{}});
        All -> retry(State#{pending := All, plan := New})
    end.

changed(Mod, Bin) ->
    case code:is_loaded(Mod) of
        false ->
            true;
        _ ->
            case beam_lib:md5(Bin) of
                {ok, {_, Md5}} -> Md5 =/= erlang:get_module_info(Mod, md5);
                _ -> true
            end
    end.

%% The load of the modules that wait, when no process runs their old
%% code: the processes of the modules with an update stop (sys:suspend/2),
%% the code loads, code_change/3 runs, and the processes go on.
retry(#{pending := []} = State) ->
    State;
retry(#{pending := Pending, last := Last} = State) ->
    Busy = [Mod || {Mod, _, _} <- Pending, not code:soft_purge(Mod)],
    case Busy of
        [] ->
            load(State);
        _ ->
            %% One line for each new set of modules that wait.
            Last =:= {waiting, Busy} orelse
                ?LOG_NOTICE("beam.com: new code waits for the processes that run "
                            "the old code of ~ts", [names(Busy)]),
            State#{last := {waiting, Busy}}
    end.

load(#{pending := Pending, plan := Plan} = State) ->
    Mods = [Mod || {Mod, _, _} <- Pending],
    Updates = maps:with(Mods, maps:get(updates, Plan, #{})),
    OldVsns = maps:map(fun(Mod, _) -> old_vsn(Mod) end, Updates),
    Procs = [{P, Mod, Change} || {Mod, Change} <- maps:to_list(Updates),
                                 P <- processes(Mod, Change)],
    %% The children of each supervisor before its code change: a call, so
    %% before the suspend.
    Before = [{P, child_ids(P)} || {P, _, supervisor} <- Procs],
    Suspended = [S || {P, _, _} = S <- Procs, suspend(P)],
    %% code_change/3 runs only after a load, and each process goes on.
    Result = try
                 R = load_code(Pending),
                 element(1, R) =:= ok andalso
                     [code_change(P, Mod, maps:get(Mod, OldVsns), Change)
                      || {P, Mod, Change} <- Suspended],
                 R
             after
                 [resume(P) || {P, _, _} <- Suspended]
             end,
    case Result of
        {ok, Failed} ->
            Loaded = [M || M <- Mods, not lists:keymember(M, 1, Failed)],
            ?LOG_NOTICE("beam.com: loaded the new code of ~ts", [names(Loaded)]),
            Failed =:= [] orelse
                ?LOG_WARNING("beam.com: cannot load the new code of ~tp", [Failed]),
            [start_new_children(P, Ids) || {P, Ids} <- Before],
            [apply_mfa(MFA) || MFA <- maps:get(applies, Plan, [])],
            config_changes(State#{pending := [], plan := #{}, last := {ok, Loaded}});
        {error, Errors} ->
            ?LOG_WARNING("beam.com: cannot load the new code: ~tp", [Errors]),
            State#{pending := [], plan := #{}, last := {error, Errors}}
    end.

%% All the modules in one atomic load. atomic_load/1 refuses a module
%% with -on_load: such a module loads by itself, after the others.
load_code(Pending) ->
    case code:atomic_load(Pending) of
        ok ->
            {ok, []};
        {error, Errors} ->
            case lists:all(fun({_, Why}) -> Why =:= on_load_not_allowed end, Errors) of
                true ->
                    OnLoad = [M || {M, _} <- Errors],
                    Rest = [P || {M, _, _} = P <- Pending, not lists:member(M, OnLoad)],
                    case Rest =:= [] orelse code:atomic_load(Rest) of
                        {error, Errors2} ->
                            {error, Errors2};
                        _ ->
                            Results = [{M, code:load_binary(M, F, B)}
                                       || {M, F, B} <- Pending, lists:member(M, OnLoad)],
                            {ok, [{M, R} || {M, R} <- Results, element(1, R) =/= module]}
                    end;
                false ->
                    {error, Errors}
            end
    end.

child_ids(Sup) ->
    try supervisor:which_children(Sup) of
        Children -> [Id || {Id, _, _, _} <- Children]
    catch
        _:_ -> []
    end.

%% After {update, Mod, supervisor}, the supervisor has the specification
%% of each new child of init/1, with no process (supervisor:code_change/3
%% of OTP). Start each new child, as at the start of the supervisor. A
%% child that is not new, and has no process, stays as it is (for example
%% a transient child that stopped). A child that init/1 no longer gives
%% goes on: stop it with an apply of supervisor:terminate_child/2.
start_new_children(Sup, Before) ->
    New = [Id || {Id, undefined, _, _} <- try supervisor:which_children(Sup) catch _:_ -> [] end,
                 not lists:member(Id, Before)],
    [case restart_child(Sup, Id) of
         {ok, _} -> ?LOG_NOTICE("beam.com: started the new child ~tp of ~p", [Id, Sup]);
         {ok, _, _} -> ?LOG_NOTICE("beam.com: started the new child ~tp of ~p", [Id, Sup]);
         Error -> ?LOG_WARNING("beam.com: cannot start the new child ~tp of ~p: ~tp",
                               [Id, Sup, Error])
     end || Id <- New],
    ok.

restart_child(Sup, Id) ->
    try supervisor:restart_child(Sup, Id)
    catch Class:Reason -> {Class, Reason}
    end.

%% The version of the old code, for code_change/3: the vsn attribute.
old_vsn(Mod) ->
    case code:is_loaded(Mod) of
        false -> undefined;
        _ -> proplists:get_value(vsn, erlang:get_module_info(Mod, attributes), undefined)
    end.

%% The processes of a callback module: a gen_server or a gen_statem of
%% Mod, or a supervisor of Mod for supervisor (the initial call of
%% proc_lib).
processes(Mod, Change) ->
    [P || P <- erlang:processes(), P =/= self(), process_of(P, Mod, Change)].

process_of(P, Mod, Change) ->
    case erlang:process_info(P, dictionary) of
        {dictionary, Dict} ->
            case {lists:keyfind('$initial_call', 1, Dict), Change} of
                {{_, {supervisor, Mod, 1}}, supervisor} -> true;
                {{_, {Mod, init, 1}}, _} when Change =/= supervisor -> true;
                _ -> false
            end;
        undefined ->
            false
    end.

suspend(P) ->
    try sys:suspend(P, ?SYS_TIMEOUT) of
        ok -> true
    catch
        _:Reason ->
            ?LOG_WARNING("beam.com: cannot suspend ~p for the new code: ~tp", [P, Reason]),
            false
    end.

resume(P) ->
    try sys:resume(P, ?SYS_TIMEOUT)
    catch _:Reason -> ?LOG_WARNING("beam.com: cannot resume ~p: ~tp", [P, Reason])
    end.

code_change(_P, _Mod, _OldVsn, soft) ->
    ok;
code_change(P, Mod, OldVsn, Change) ->
    Extra = case Change of {advanced, E} -> E; supervisor -> [] end,
    try sys:change_code(P, Mod, OldVsn, Extra, ?SYS_TIMEOUT) of
        ok -> ok;
        Error -> ?LOG_WARNING("beam.com: code_change of ~p (~w) failed: ~tp", [P, Mod, Error])
    catch
        _:Reason -> ?LOG_WARNING("beam.com: code_change of ~p (~w) failed: ~tp", [P, Mod, Reason])
    end.

apply_mfa({M, F, A}) ->
    try apply(M, F, A)
    catch Class:Reason ->
            ?LOG_WARNING("beam.com: the apply of the appup failed: ~tp", [{M, F, A, Class, Reason}])
    end.

%% config_change/3 of the application module of each application with
%% new files of priv/: it reads its files again (for example the static
%% manifest of a Phoenix endpoint). It runs after the new code loads.
config_changes(#{notify := Apps} = State) ->
    [config_change(App) || App <- Apps],
    State#{notify := []}.

config_change(App) ->
    case application:get_key(App, mod) of
        {ok, {Mod, _}} ->
            case erlang:function_exported(Mod, config_change, 3)
                orelse (code:ensure_loaded(Mod) =:= {module, Mod}
                        andalso erlang:function_exported(Mod, config_change, 3)) of
                true ->
                    try Mod:config_change([], [], [])
                    catch Class:Reason ->
                            ?LOG_WARNING("beam.com: config_change of ~w failed: ~tp",
                                         [App, {Class, Reason}])
                    end;
                false ->
                    ok
            end;
        _ ->
            ok
    end.

%% The applications with new files in priv/: each one is a running
%% application, and its code path goes to a copy of its directory in the
%% cache. A moved application moves again for each new file that changes
%% one of its files. Gives [{Dir, App}], and the new state.
move_apps(Fd, Changed, #{moved := Moved} = State) ->
    Dirs = lists:usort([app_dir(N) || N <- Changed, app_dir(N) =/= none,
                                      priv_name(N) orelse maps:is_key(app_dir(N), Moved)]),
    lists:foldl(fun(Dir, {Done, S}) ->
                        case move_app(Fd, Dir, S) of
                            {ok, App, S1} -> {[{Dir, App} | Done], S1};
                            none -> {Done, S}
                        end
                end, {[], State}, Dirs).

priv_name(Name) ->
    case filename:split(Name) of
        ["lib", _, "priv" | _] -> true;
        _ -> false
    end.

move_app(Fd, Dir, #{cache := Cache, moved := Moved, index := Index, path := Path,
                    root := Root} = State) ->
    {AppName, _} = split_app(lists:nthtail(4, Dir)),
    App = list_to_atom(AppName),
    Running = lists:keymember(App, 1, application:which_applications()),
    case Running andalso lists:member(code:lib_dir(App), [Root ++ "/" ++ Dir, maps:get(Dir, Moved, none)]) of
        true ->
            To = filename:join([Cache, integer_to_list(erlang:unique_integer([positive])), Dir]),
            Prefix = Dir ++ "/",
            Names = [N || N <- maps:keys(Index), lists:prefix(Prefix, N), lists:last(N) =/= $/],
            [copy(Fd, maps:get(N, Index), filename:join(To, lists:nthtail(length(Prefix), N)))
             || N <- Names],
            ok = filelib:ensure_path(filename:join(To, "ebin")),
            true = code:replace_path(App, filename:join(To, "ebin")),
            %% The copy before (CACHE/N/lib/APP-VSN) goes after the grace
            %% time: a request that found one of its paths can still read
            %% the file.
            case maps:get(Dir, Moved, none) of
                none ->
                    ok;
                Before ->
                    erlang:send_after(maps:get(grace, State), self(),
                                      {delete, filename:dirname(filename:dirname(Before))})
            end,
            ?LOG_NOTICE("beam.com: new files of ~w from ~ts, in ~ts", [App, Path, To]),
            {ok, App, State#{moved := Moved#{Dir => To}}};
        false ->
            none
    end.

copy(Fd, Entry, File) ->
    {ok, Data} = read_entry(Fd, Entry),
    ok = filelib:ensure_dir(File),
    ok = file:write_file(File, Data).

names(Names) ->
    lists:join(", ", [io_lib:format("~ts", [N]) || N <- Names]).

stat(Path) ->
    case file:read_file_info(Path, [raw, {time, posix}]) of
        {ok, #file_info{inode = Ino, size = Size, mtime = Mtime}} -> {ok, {Ino, Size, Mtime}};
        {error, _} = Error -> Error
    end.

%% The stat, the index and the runtime (the length and the CRC-32 of the
%% bytes before the first entry) of the file at Path.
snapshot(Path) ->
    case stat(Path) of
        {ok, Stat} ->
            case file:open(Path, [read, raw, binary]) of
                {ok, Fd} ->
                    try directory(Fd) of
                        {ok, Index, DirOffset} ->
                            {ok, Stat, Index, prefix(Fd, Index, DirOffset)};
                        {error, _} = Error ->
                            Error
                    after
                        file:close(Fd)
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% The bytes before the first entry, or before the central directory of a
%% zip with no entry.
prefix(Fd, Index, DirOffset) ->
    Start = lists:min([DirOffset | [Offset || {_, _, _, _, Offset} <- maps:values(Index)]]),
    {ok, Bin} = pread(Fd, 0, Start),
    {Start, erlang:crc32(Bin)}.

%% The central directory of the zip of Fd: #{Name => {Crc, CompSize, Size,
%% Method, Offset}}. The offsets count from the start of the file, as in
%% an APE file.
-ifdef(TEST).
index(Fd) ->
    case directory(Fd) of
        {ok, Index, _DirOffset} -> {ok, Index};
        {error, _} = Error -> Error
    end.
-endif.

directory(Fd) ->
    {ok, Size} = file:position(Fd, eof),
    Tail = min(Size, 65557),
    case pread(Fd, Size - Tail, Tail) of
        {ok, Bin} ->
            case eocd(Bin, Tail - 22) of
                {ok, Pos, Count, DirSize, DirOffset} ->
                    case zip64(Fd, Size - Tail + Pos, {Count, DirSize, DirOffset}) of
                        {ok, {_, DirSize64, DirOffset64}} ->
                            case pread(Fd, DirOffset64, DirSize64) of
                                {ok, Dir} ->
                                    case entries(Dir, #{}) of
                                        {ok, Index} -> {ok, Index, DirOffset64};
                                        {error, _} = Error -> Error
                                    end;
                                {error, _} = Error ->
                                    Error
                            end;
                        {error, _} = Error ->
                            Error
                    end;
                error ->
                    {error, no_central_directory}
            end;
        {error, _} = Error ->
            Error
    end.

eocd(_Bin, Pos) when Pos < 0 ->
    error;
eocd(Bin, Pos) ->
    case Bin of
        <<_:Pos/binary, ?EOCD:32/little, _:16, _:16, _:16, Count:16/little,
          DirSize:32/little, DirOffset:32/little, Len:16/little, _/binary>>
          when byte_size(Bin) - Pos - 22 =:= Len ->
            {ok, Pos, Count, DirSize, DirOffset};
        _ ->
            eocd(Bin, Pos - 1)
    end.

%% The zip64 end record, when the end record has no room for a value.
zip64(Fd, EocdPos, {Count, DirSize, DirOffset} = Values) ->
    case Count =:= 16#FFFF orelse DirSize =:= 16#FFFFFFFF orelse DirOffset =:= 16#FFFFFFFF of
        false ->
            {ok, Values};
        true when EocdPos >= 20 ->
            case pread(Fd, EocdPos - 20, 20) of
                {ok, <<?EOCD64_LOCATOR:32/little, _:32, At:64/little, _:32>>} ->
                    case pread(Fd, At, 56) of
                        {ok, <<?EOCD64:32/little, _:64, _:16, _:16, _:32, _:32, _:64,
                               Count64:64/little, DirSize64:64/little, DirOffset64:64/little>>} ->
                            {ok, {Count64, DirSize64, DirOffset64}};
                        _ ->
                            {error, bad_zip64}
                    end;
                _ ->
                    {error, bad_zip64}
            end;
        true ->
            {error, bad_zip64}
    end.

entries(<<?CDIR:32/little, _:32, _:16, Method:16/little, _:32, Crc:32/little,
          CompSize:32/little, Size:32/little, NameLen:16/little, ExtraLen:16/little,
          CommentLen:16/little, _:16, _:16, _:32, Offset:32/little,
          Name:NameLen/binary, Extra:ExtraLen/binary, _:CommentLen/binary, Rest/binary>>,
        Acc) ->
    {Size1, CompSize1, Offset1} = extra64(Extra, Size, CompSize, Offset),
    Entry = {Crc, CompSize1, Size1, Method, Offset1},
    entries(Rest, Acc#{unicode:characters_to_list(Name) => Entry});
entries(<<>>, Acc) ->
    {ok, Acc};
entries(_, _) ->
    {error, bad_central_directory}.

%% The zip64 extra field (0x0001): the values that are 0xFFFFFFFF in the
%% record, in this sequence.
extra64(<<1:16/little, Len:16/little, Data:Len/binary, _/binary>>, Size, CompSize, Offset) ->
    {Size1, D1} = big(Size, Data),
    {CompSize1, D2} = big(CompSize, D1),
    {Offset1, _} = big(Offset, D2),
    {Size1, CompSize1, Offset1};
extra64(<<_:16/little, Len:16/little, _:Len/binary, Rest/binary>>, Size, CompSize, Offset) ->
    extra64(Rest, Size, CompSize, Offset);
extra64(_, Size, CompSize, Offset) ->
    {Size, CompSize, Offset}.

big(16#FFFFFFFF, <<V:64/little, Rest/binary>>) -> {V, Rest};
big(V, Rest) -> {V, Rest}.

%% The data of one entry, checked with its CRC-32.
read_entry(Fd, {Crc, CompSize, Size, Method, Offset}) ->
    case pread(Fd, Offset, 30) of
        {ok, <<?LOCAL:32/little, _:22/binary, NameLen:16/little, ExtraLen:16/little>>} ->
            case pread(Fd, Offset + 30 + NameLen + ExtraLen, CompSize) of
                {ok, Comp} ->
                    case inflate(Method, Comp) of
                        {ok, Data} when byte_size(Data) =:= Size ->
                            case erlang:crc32(Data) of
                                Crc -> {ok, Data};
                                _ -> {error, bad_crc}
                            end;
                        {ok, _} ->
                            {error, bad_size};
                        {error, _} = Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        _ ->
            {error, bad_local_header}
    end.

inflate(0, Data) ->
    {ok, Data};
inflate(8, Data) ->
    try {ok, zlib:unzip(Data)}
    catch _:_ -> {error, bad_deflate}
    end;
inflate(Method, _) ->
    {error, {method, Method}}.

pread(_Fd, _At, 0) ->
    {ok, <<>>};
pread(Fd, At, Len) ->
    case file:pread(Fd, At, Len) of
        {ok, Bin} when byte_size(Bin) =:= Len -> {ok, Bin};
        {ok, _} -> {error, short_read};
        eof -> {error, short_read};
        {error, _} = Error -> Error
    end.
