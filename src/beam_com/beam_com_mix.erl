%% beam.com DIR -o FILE for a Mix project that needs Mix itself, such as
%% a new Phoenix app: Mix gets the deps, compiles the project, runs the
%% alias assets.deploy, and makes a release. The builder then reads the
%% directory of the release, as for "beam.com _build/prod/rel/NAME -o
%% FILE". The user runs no Mix task first.
%%
%% Mix runs in a child: this executable with "elixir -e" (child/0), in
%% the directory of the project and with the environment of the user
%% (git, the keys of SSH and Hex, the proxy). Thus the state of Mix
%% (the project stack, the compiled modules, the config of the
%% applications) stays out of the builder. The child writes deps/,
%% _build/ and mix.lock in the project, as Mix does, so a second build
%% gets the deps and the compiled code again.
%%
%% The release has include_erts: false, because Mix cannot copy ERTS
%% from /zip. The child sets it and the path of the release with
%% Mix.Project.in_project/4, so mix.exs does not change, and the other
%% options of the release stay.
-module(beam_com_mix).

-export([reasons/1, release/2, child/0]).

%% The tarball of @esbuild/win32-x64 has about 4 MB.
-define(ESBUILD_MAX, 64 * 1024 * 1024).
%% The replacement of a byte that is not UTF-8 in the output of Mix.
-define(BAD_CHAR, <<16#FFFD/utf8>>).

-ifdef(TEST).
-export([reasons/2, releases/3, child_env/3, hex_deps/1, has_alias/2, no_input/1,
         asset_tools/2, esbuild_exe/3, relay/1, status/1, watch_input/2]).
-endif.

%% The parts of a Mix project that only Mix can build: [] for a project
%% that the builder compiles itself (beam_com_elixir).
reasons(Dir) ->
    reasons(Dir, beam_com_elixir:mix_config(Dir)).

reasons(Dir, Config) ->
    Deps = [Name || {Name, Opts} <- dep_opts(proplists:get_value(deps, Config, [])),
                    in_prod(Opts), not_hex(Opts)],
    [runtime_exs || filelib:is_regular(filename:join([Dir, "config", "runtime.exs"]))]
        ++ [{deps, Deps} || Deps =/= []]
        ++ [compilers || proplists:is_defined(compilers, Config)]
        ++ ['assets.deploy' || has_alias(Config, 'assets.deploy')].

%% Make the release of the project Dir with Mix: the directory of the
%% release. Opts: out (the directory of the release, else a new
%% temporary directory), and exe (the path of this executable, for the
%% tests). On an error, this function closes the port (the child then
%% stops, see watch_input/2) and removes Out.
release(Dir0, Opts) ->
    %% The child starts in Dir, so a relative path is not correct there.
    Dir = filename:absname(Dir0),
    %% Not maps:get/3: it makes the default directory also when the
    %% caller gives one.
    Out = case Opts of
              #{out := O} -> O;
              _ -> beam_com_build:temp_dir("mix_release")
          end,
    Exe = case Opts of
              #{exe := E} -> E;
              _ -> beam_com_build:executable()
          end,
    try
        release(Dir0, Dir, Out, Exe)
    catch
        Class:Reason:Stack ->
            _ = file:del_dir_r(Out),
            erlang:raise(Class, Reason, Stack)
    end.

release(Dir0, Dir, Out, Exe) ->
    %% Not through /bin/sh: the sh of NetBSD and OpenBSD cannot start an
    %% APE file, and the execve() of this executable can.
    Port = open_port({spawn_executable, Exe},
                     [{args, ["elixir", "-e", ":beam_com_mix.child()"]},
                      {env, child_env(Dir, Out, os:getenv("MIX_ENV"))},
                      {cd, Dir}, exit_status, stderr_to_stdout, binary]),
    Status = try relay(Port)
             after
                 %% The port is closed after its exit status.
                 try port_close(Port) catch error:badarg -> ok end
             end,
    case Status of
        0 ->
            case file:list_dir(Out) of
                {ok, [Name]} -> filename:join(Out, Name);
                _ -> throw({error, "~ts: Mix made no release in ~ts", [Dir0, Out]})
            end;
        _ ->
            throw({error, "~ts: Mix did not make a release (exit status ~p)", [Dir0, Status]})
    end.

%% MIX_ENV of the user, else prod.
child_env(Dir, Out, MixEnv) ->
    [{"BEAM_COM_MIX_DIR", Dir}, {"BEAM_COM_MIX_OUT", Out}]
        ++ [{"MIX_ENV", "prod"} || MixEnv =:= false orelse MixEnv =:= ""].

%% The output of Mix, as it comes. A port read can divide a character
%% of UTF-8, so the incomplete end of a part waits for the next part. A
%% byte that is not UTF-8 (for example of a code page of Windows) becomes
%% U+FFFD: io:put_chars/1 refuses it.
relay(Port) ->
    relay(Port, <<>>).

relay(Port, Rest) ->
    receive
        {Port, {data, Data}} ->
            relay(Port, put_utf8(<<Rest/binary, Data/binary>>));
        {Port, {exit_status, Status}} ->
            Rest =:= <<>> orelse io:put_chars(?BAD_CHAR),
            Status
    end.

%% Print the UTF-8 of Data: the incomplete end that stays.
put_utf8(Data) ->
    case unicode:characters_to_binary(Data) of
        Good when is_binary(Good) ->
            io:put_chars(Good),
            <<>>;
        {incomplete, Good, Rest} ->
            io:put_chars(Good),
            Rest;
        {error, Good, <<_, Rest/binary>>} ->
            io:put_chars([Good, ?BAD_CHAR]),
            put_utf8(Rest)
    end.

%% In the child (beam.com elixir -e ":beam_com_mix.child()"). The child
%% reads no input: a question of Mix (for example "Shall I install
%% Hex?") gets the end of the input, thus "no", and the build stops with
%% the error of Mix. It does not wait for an answer that does not come.
%% The standard input of the child is the port of the builder: its end
%% stops the child (watch_input/2), so no child continues when the
%% builder stops.
child() ->
    Leader = group_leader(),
    _ = spawn(fun() -> watch_input(Leader, fun() -> erlang:halt(1) end) end),
    group_leader(no_input(Leader), self()),
    erlang:halt(status(fun() ->
                               build(os:getenv("BEAM_COM_MIX_DIR"), os:getenv("BEAM_COM_MIX_OUT"))
                       end)).

%% The exit status of Build, with the message of its error.
status(Build) ->
    try
        Build(),
        0
    catch
        error:#{'__struct__' := 'Elixir.Mix.Error', message := Message} ->
            io:format(standard_error, "beam.com: ~ts~n", [Message]),
            1;
        throw:{error, Format, Args} ->
            io:format(standard_error, "beam.com: " ++ Format ++ "~n", Args),
            1;
        Class:Reason:Stack ->
            io:format(standard_error, "beam.com: ~ts~n",
                      ['Elixir.Exception':format(Class, Reason, Stack)]),
            1
    end.

%% Read Leader until the end of the input, then Halt(). The builder
%% writes nothing to the port, so only its close (or the end of the
%% builder) ends the input.
watch_input(Leader, Halt) ->
    case io:get_line(Leader, "") of
        Line when is_list(Line); is_binary(Line) -> watch_input(Leader, Halt);
        _EofOrError -> Halt()
    end.

%% A group leader that gives each output request to Leader, and the end
%% of the input (eof) to each input request, after the output of its
%% prompt.
no_input(Leader) ->
    spawn_link(fun() -> no_input_loop(Leader) end).

no_input_loop(Leader) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            From ! {io_reply, ReplyAs, io_reply(Leader, Request)},
            no_input_loop(Leader)
    end.

io_reply(Leader, {requests, Requests}) ->
    lists:foldl(fun(R, ok) -> io_reply(Leader, R);
                   (_R, Error) -> Error
                end, ok, Requests);
io_reply(Leader, Request) ->
    case input_prompt(Request) of
        none ->
            forward(Leader, Request);
        Prompt ->
            _ = forward(Leader, {put_chars, unicode, io_lib:format("~ts", [prompt(Prompt)])}),
            eof
    end.

input_prompt({get_chars, _Enc, Prompt, _N}) -> Prompt;
input_prompt({get_line, _Enc, Prompt}) -> Prompt;
input_prompt({get_until, _Enc, Prompt, _M, _F, _A}) -> Prompt;
input_prompt({get_password, _Enc}) -> "";
input_prompt(_Output) -> none.

prompt(Prompt) when is_atom(Prompt) -> atom_to_list(Prompt);
prompt(Prompt) -> Prompt.

forward(Leader, Request) ->
    Ref = make_ref(),
    Leader ! {io_request, self(), Ref, Request},
    receive
        {io_reply, Ref, Reply} -> Reply
    end.

build(Dir, Out) when is_list(Dir), is_list(Out) ->
    Config = beam_com_elixir:mix_config(Dir),
    App = proplists:get_value(app, Config),
    {ok, _} = application:ensure_all_started(mix),
    'Elixir.Mix':env(list_to_atom(os:getenv("MIX_ENV"))),
    'Elixir.Mix.Local':append_archives(),
    'Elixir.Mix.Local':append_paths(),
    git_scm(os:getenv("BEAM_COM_GIT"), os:find_executable("git")),
    Releases = releases(App, proplists:get_value(releases, Config, []), Out),
    'Elixir.Mix.Project':in_project(App, unicode:characters_to_binary(Dir),
                                    [{releases, Releases}],
                                    fun(_Module) -> steps(Config) end).

%% The git client of beam.com (beam_com_git_scm) gets the git deps of an
%% https or SSH URL when PATH has no git, or with BEAM_COM_GIT=client. It
%% comes before Mix.SCM.Git, which gets the other git deps.
git_scm("client", _Git) ->
    'Elixir.Mix.SCM':prepend(beam_com_git_scm);
git_scm(_, false) ->
    io:format("beam.com: no git program: the git deps of an https or SSH URL come with "
              "the git client of beam.com~n"),
    'Elixir.Mix.SCM':prepend(beam_com_git_scm);
git_scm(_, _Git) ->
    ok.

%% The steps of "mix setup" and of a deploy: the config, the deps, the
%% code, the assets (when the project has the alias assets.deploy), and
%% the release.
steps(Config) ->
    run("loadconfig", []),
    hex_deps(Config) andalso hex(),
    %% deps.get also installs rebar3 for a dep that rebar3 builds.
    run("deps.get", []),
    %% Before compile: compile removes the code paths of the
    %% applications that are not deps (beam_com_hex, inets).
    windows_assets(os:type(), Config),
    run("compile", []),
    has_alias(Config, 'assets.deploy') andalso run("assets.deploy", []),
    run("release", ["--overwrite", "--quiet"]).

%% On Windows, os:type() is {unix, windows}, so the Hex packages
%% tailwind and esbuild choose their programs for Linux. For a package
%% that the project does not configure, use the program for Windows:
%% tailwind gets the target "windows-x64.exe" (it downloads that
%% program itself), and esbuild gets the path of esbuild.exe from npm,
%% because esbuild has no setting for the target. Cosmopolitan runs
%% only x86-64 programs on Windows.
windows_assets({_, windows}, Config) ->
    Get = fun(App, Key) -> application:get_env(App, Key, undefined) end,
    Deps = [Name || {Name, _} <- dep_opts(proplists:get_value(deps, Config, []))],
    lists:foreach(fun windows_asset/1, asset_tools(Get, Deps));
windows_assets(_Os, _Config) ->
    ok.

windows_asset(tailwind) ->
    io:format("beam.com: tailwind for Windows (target windows-x64.exe)~n"),
    set_env(tailwind, target, <<"windows-x64.exe">>);
windows_asset(esbuild) ->
    Version = unicode:characters_to_list(application:get_env(esbuild, version, <<>>)),
    Path = esbuild_exe(Version, filename:absname("_build"), fun beam_com_hex:http/5),
    io:format("beam.com: esbuild for Windows: ~ts~n", [Path]),
    set_env(esbuild, path, unicode:characters_to_binary(Path)).

set_env(App, Key, Value) ->
    application:set_env(App, Key, Value, [{persistent, true}]).

%% The deps of mix.exs (Deps) that get a program for Windows: tailwind
%% with no target and no path in its config (Get), and esbuild with a
%% version and no path.
asset_tools(Get, Deps) ->
    [tailwind || lists:member(tailwind, Deps), Get(tailwind, target) =:= undefined,
                 Get(tailwind, path) =:= undefined]
        ++ [esbuild || lists:member(esbuild, Deps), Get(esbuild, path) =:= undefined,
                       Get(esbuild, version) =/= undefined].

%% The esbuild.exe of the package @esbuild/win32-x64 of npm, at
%% Dir/esbuild-win32-x64-VERSION.exe: the path. A second build uses the
%% file again. Http: the function of beam_com_hex:http/5.
esbuild_exe(Version, Dir, Http) ->
    Path = filename:join(Dir, "esbuild-win32-x64-" ++ Version ++ ".exe"),
    filelib:is_regular(Path) orelse
        begin
            Url = "https://registry.npmjs.org/@esbuild/win32-x64/-/win32-x64-"
                ++ Version ++ ".tgz",
            Tgz = Http(get, Url, [], none, ?ESBUILD_MAX),
            Exe = case erl_tar:extract({binary, Tgz},
                                       [compressed, memory, {files, ["package/esbuild.exe"]}]) of
                      {ok, [{_, Data}]} -> Data;
                      _ -> throw({error, "~ts: no package/esbuild.exe", [Url]})
                  end,
            Temp = Path ++ ".new",
            ok = filelib:ensure_dir(Path),
            ok = file:write_file(Temp, Exe),
            ok = file:change_mode(Temp, 8#755),
            ok = file:rename(Temp, Path)
        end,
    Path.

run(Task, Args) ->
    'Elixir.Mix.Task':run(list_to_binary(Task), [list_to_binary(A) || A <- Args]),
    ok.

%% Hex, as "mix local.hex" installs it, when the project has a Hex dep
%% and no Hex is loaded (a custom build can have Hex in the zip).
hex() ->
    case 'Elixir.Code':'ensure_loaded?'('Elixir.Hex') of
        true ->
            ok;
        false ->
            io:format("beam.com: the deps need Hex: mix local.hex~n"),
            'Elixir.Mix.Hex':'ensure_installed?'(true) orelse
                throw({error, "Hex is not installed", []}),
            'Elixir.Mix.Hex':start()
    end.

%% The releases of mix.exs (or the default release, with the name of
%% the application), each with include_erts: false and its directory in
%% Out.
releases(App, [], Out) ->
    releases(App, [{App, []}], Out);
releases(_App, Releases, Out) ->
    [{Name, lists:keystore(path, 1,
                           lists:keystore(include_erts, 1, Opts, {include_erts, false}),
                           {path, unicode:characters_to_binary(
                                    filename:join(Out, atom_to_list(Name)))})}
     || {Name, Opts} <- Releases].

%% A dep from Hex: no git, github, path or in_umbrella.
hex_deps(Config) ->
    lists:any(fun({_, Opts}) -> in_prod(Opts) andalso not not_hex(Opts) end,
              dep_opts(proplists:get_value(deps, Config, []))).

has_alias(Config, Name) ->
    proplists:is_defined(Name, proplists:get_value(aliases, Config, [])).

dep_opts(Deps) ->
    [case D of
         {Name, Opts} when is_list(Opts) -> {Name, Opts};
         {Name, _Req} -> {Name, []};
         {Name, _Req, Opts} -> {Name, Opts}
     end || D <- Deps].

in_prod(Opts) ->
    case proplists:get_value(only, Opts, prod) of
        Only when is_list(Only) -> lists:member(prod, Only);
        Only -> Only =:= prod
    end.

not_hex(Opts) ->
    lists:any(fun(K) -> proplists:is_defined(K, Opts) end, [git, github, path, in_umbrella]).
