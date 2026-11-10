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

-define(NPM, "https://registry.npmjs.org").
%% The metadata of one version of a package on npm has some KB.
-define(NPM_META_MAX, 1024 * 1024).
%% The tarball of @esbuild/win32-x64 has about 4 MB, and about 11 MB
%% without compression (0.25.4).
-define(ESBUILD_MAX, 64 * 1024 * 1024).
-define(ESBUILD_UNPACKED, 128 * 1024 * 1024).
%% The replacement of a byte that is not UTF-8 in the output of Mix.
-define(BAD_CHAR, <<16#FFFD/utf8>>).

-ifdef(TEST).
-export([reasons/2, releases/3, child_env/3, hex_deps/1, has_alias/2, no_input/1,
         asset_tools/2, esbuild_exe/3, esbuild_exe/4, verify_npm/4, npm_keys/0,
         windows_assets/2, steps/4, relay/1, status/1, watch_input/2]).
-endif.

%% The parts of a Mix project that only Mix can build: [] for a project
%% that the builder compiles itself (beam_com_elixir).
reasons(Dir) ->
    reasons(Dir, beam_com_elixir:mix_config(Dir)).

reasons(Dir, Config) ->
    All = dep_opts(proplists:get_value(deps, Config, [])),
    Deps = [Name || {Name, Opts} <- All, in_prod(Opts), not_hex(Opts)],
    %% The own Hex client gets only packages of hex.pm. A lock entry of
    %% another repository can be of a dep of a private package.
    NotProd = [Name || {Name, Opts} <- All, not in_prod(Opts)],
    Repo = lists:usort([Name || {Name, Opts} <- All, in_prod(Opts), other_repo(Opts)]
                       ++ (lock_repos(Dir) -- NotProd)),
    [runtime_exs || filelib:is_regular(filename:join([Dir, "config", "runtime.exs"]))]
        ++ [{deps, Deps} || Deps =/= []]
        ++ [{repo, Repo} || Repo =/= []]
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
                                    fun(_Module) ->
                                            steps(Config, fun run/2, fun hex/0,
                                                  fun() -> windows_assets(os:type(), Config) end)
                                    end).

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
%% Run(Task, Args) runs a Mix task, Hex() installs Hex, and Assets()
%% chooses the asset programs (windows_assets/2).
steps(Config, Run, Hex, Assets) ->
    Run("loadconfig", []),
    hex_deps(Config) andalso Hex(),
    %% deps.get also installs rebar3 for a dep that rebar3 builds.
    Run("deps.get", []),
    %% Before compile: compile removes the code paths of the
    %% applications that are not deps (beam_com_hex, inets).
    Assets(),
    Run("compile", []),
    has_alias(Config, 'assets.deploy') andalso Run("assets.deploy", []),
    Run("release", ["--overwrite", "--quiet"]).

%% On Windows, os:type() is {unix, windows}, so the Hex packages
%% tailwind and esbuild choose their programs for Linux. For a package
%% that the project does not configure, use the program for Windows:
%% tailwind gets the target "windows-x64.exe" (it downloads that
%% program itself), and esbuild gets the path of esbuild.exe from npm,
%% because esbuild has no setting for the target. Cosmopolitan runs
%% only x86-64 programs on Windows. Only the step assets.deploy runs
%% these programs: with no such alias, or with a dep that is not in the
%% environment of Mix, nothing changes, and nothing is downloaded.
windows_assets({_, windows}, Config) ->
    case has_alias(Config, 'assets.deploy') of
        true ->
            Get = fun(App, Key) -> application:get_env(App, Key, undefined) end,
            Env = 'Elixir.Mix':env(),
            Deps = [Name || {Name, Opts} <- dep_opts(proplists:get_value(deps, Config, [])),
                            in_env(Opts, Env)],
            lists:foreach(fun windows_asset/1, asset_tools(Get, Deps));
        false ->
            ok
    end;
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

%% The esbuild.exe of the npm package for Windows x64 of esbuild, at
%% Dir/esbuild-win32-x64-VERSION.exe: the path. A second build uses the
%% file again. Http: the function of beam_com_hex:http/5. The checks are
%% the checks of Esbuild.NpmRegistry.fetch_package!/2 of the Hex package
%% esbuild (0.8.0 and later), and some more (see esbuild_package/3).
esbuild_exe(Version, Dir, Http) ->
    esbuild_exe(Version, Dir, Http, #{keys => npm_keys(), unpacked => ?ESBUILD_UNPACKED}).

esbuild_exe(Version, Dir, Http, Limits) ->
    Path = filename:join(Dir, "esbuild-win32-x64-" ++ Version ++ ".exe"),
    filelib:is_regular(Path) orelse write_exe(Path, esbuild_package(Version, Http, Limits)),
    Path.

%% The npm package of esbuild for Windows x64: @esbuild/win32-x64 since
%% esbuild 0.16.0, else esbuild-windows-64.
esbuild_name(Version) ->
    Legacy = try
                 [Major, Minor | _] = [list_to_integer(P) || P <- string:split(Version, ".", all)],
                 {Major, Minor} < {0, 16}
             catch
                 error:_ -> false
             end,
    case Legacy of
        true -> "esbuild-windows-64";
        false -> "@esbuild/win32-x64"
    end.

%% esbuild.exe of the package. The metadata of the version on npm gives
%% the integrity (the SHA-512 of the tarball) and the signatures of npm
%% over "ID:INTEGRITY". The signature must be valid for a key of
%% npm_keys/0, the ID must be the package and the version, and the
%% tarball must have the SHA-512 of the integrity. Thus TLS is not the
%% only check of the bytes. The tarball has at most ?ESBUILD_MAX bytes,
%% and at most Unpacked bytes without compression: erl_tar keeps all
%% the data in memory.
esbuild_package(Version, Http, #{keys := Keys, unpacked := Unpacked}) ->
    Name = esbuild_name(Version),
    Url = ?NPM ++ "/" ++ Name ++ "/" ++ Version,
    Meta = try json:decode(Http(get, Url, [], none, ?NPM_META_MAX))
           catch error:_ -> throw({error, "~ts: the metadata is not JSON", [Url]})
           end,
    {Id, Integrity, Signatures, TarUrl} =
        case Meta of
            #{<<"_id">> := I, <<"dist">> := #{<<"integrity">> := In, <<"signatures">> := S,
                                             <<"tarball">> := <<"https://", _/binary>> = T}}
              when is_binary(I), is_binary(In), is_list(S) ->
                {I, In, S, binary_to_list(T)};
            _ ->
                throw({error, "~ts: the metadata has no _id, integrity, signatures "
                       "or https tarball", [Url]})
        end,
    Id =:= unicode:characters_to_binary(Name ++ "@" ++ Version) orelse
        throw({error, "~ts: the metadata is for ~ts", [Url, Id]}),
    verify_npm(Url, <<Id/binary, ":", Integrity/binary>>, Signatures, Keys),
    Sum = case Integrity of
              <<"sha512-", Base64/binary>> ->
                  try base64:decode(Base64)
                  catch error:_ -> throw({error, "~ts: a bad integrity: ~ts", [Url, Integrity]})
                  end;
              _ ->
                  throw({error, "~ts: the integrity is not sha512: ~ts", [Url, Integrity]})
          end,
    Tgz = Http(get, TarUrl, [], none, ?ESBUILD_MAX),
    crypto:hash(sha512, Tgz) =:= Sum orelse
        throw({error, "~ts: the SHA-512 of the tarball is not the signed integrity", [TarUrl]}),
    case erl_tar:extract({binary, gunzip(TarUrl, Tgz, Unpacked)},
                         [memory, {files, ["package/esbuild.exe"]}]) of
        {ok, [{_, Data}]} -> Data;
        _ -> throw({error, "~ts: no package/esbuild.exe", [TarUrl]})
    end.

%% A signature of npm over Message, with a key of Keys: ok, else a throw.
verify_npm(Url, Message, Signatures, Keys) ->
    Known = [{maps:get(K, Keys), Sig} || #{<<"keyid">> := K, <<"sig">> := Sig} <- Signatures,
                                         is_map_key(K, Keys), is_binary(Sig)],
    Known =/= [] orelse
        throw({error, "~ts: no signature of a known key of npm", [Url]}),
    lists:any(fun({Key, Sig}) ->
                      try public_key:verify(Message, sha256, base64:decode(Sig), Key)
                      catch _:_ -> false
                      end
              end, Known) orelse
        throw({error, "~ts: the signature of npm is not valid", [Url]}),
    ok.

%% The data of a gzip file, with at most Max bytes.
gunzip(Url, Data, Max) ->
    Z = zlib:open(),
    try
        ok = zlib:inflateInit(Z, 31),
        inflate(Z, Data, Url, Max, 0, [])
    catch
        error:_ -> throw({error, "~ts: not a gzip file", [Url]})
    after
        zlib:close(Z)
    end.

inflate(Z, Data, Url, Max, Size, Parts) ->
    {Status, Part} = zlib:safeInflate(Z, Data),
    Size1 = Size + iolist_size(Part),
    Size1 =< Max orelse
        throw({error, "~ts: the tarball has more than ~b bytes without compression", [Url, Max]}),
    case Status of
        continue -> inflate(Z, <<>>, Url, Max, Size1, [Part | Parts]);
        finished -> iolist_to_binary(lists:reverse([Part | Parts]))
    end.

%% Write the program at Path: a new file, then a rename.
write_exe(Path, Exe) ->
    Temp = Path ++ ".new",
    Check = fun(ok, _File) -> ok;
               ({error, Reason}, File) ->
                    throw({error, "~ts: ~ts", [File, file:format_error(Reason)]})
            end,
    Check(filelib:ensure_dir(Path), filename:dirname(Path)),
    Check(file:write_file(Temp, Exe), Temp),
    Check(file:change_mode(Temp, 8#755), Temp),
    Check(file:rename(Temp, Path), Path).

%% The public keys of the npm registry, by key id. The source:
%% https://registry.npmjs.org/-/npm/v1/keys, the same keys as @public_keys
%% in lib/esbuild/npm_registry.ex of the Hex package esbuild. When npm
%% adds a key, add it here from that URL: the key id, and the key in PEM.
npm_keys() ->
    maps:from_list(
      [{Id, public_key:pem_entry_decode(hd(public_key:pem_decode(Pem)))}
       || {Id, Pem} <- [{<<"SHA256:jl3bwswu80PjjokCgh0o2w5c2U4LhQAE57gj9cz1kzA">>,
                         <<"-----BEGIN PUBLIC KEY-----\n"
                           "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE1Olb3zMAFFxXKHiIkQO5cJ3Yhl5i\n"
                           "6UPp+IhuteBJbuHcA5UogKo0EWtlWwW6KSaKoTNEYL7JlCQiVnkhBktUgg==\n"
                           "-----END PUBLIC KEY-----\n">>},
                        {<<"SHA256:DhQ8wR5APBvFHLF/+Tc+AYvPOdTpcIDqOhxsBHRwC7U">>,
                         <<"-----BEGIN PUBLIC KEY-----\n"
                           "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEY6Ya7W++7aUPzvMTrezH6Ycx3c+H\n"
                           "OKYCcNGybJZSCJq/fd7Qa8uuAKtdIkUQtQiEKERhAmE5lMMJhP8OkDOa2g==\n"
                           "-----END PUBLIC KEY-----\n">>}]]).

run(Task, Args) ->
    'Elixir.Mix.Task':run(list_to_binary(Task), [list_to_binary(A) || A <- Args]),
    ok.

%% Hex, as "mix local.hex" installs it, when the project has a dep and
%% no Hex is loaded (a custom build can have Hex in the zip). deps.get
%% gets the deps of each environment, and a git or path dep can have
%% Hex deps too.
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
    [{Name, release_opts(Name, Opts, Out)} || {Name, Opts} <- Releases].

%% Mix also takes a function of arity 0 that gives the options: the
%% result is a function too, and Mix calls it when it makes the release.
release_opts(Name, Fun, Out) when is_function(Fun, 0) ->
    fun() -> release_opts(Name, Fun(), Out) end;
release_opts(Name, Opts, Out) ->
    lists:keystore(path, 1,
                   lists:keystore(include_erts, 1, Opts, {include_erts, false}),
                   {path, unicode:characters_to_binary(filename:join(Out, atom_to_list(Name)))}).

%% A dep that can need Hex: each dep.
hex_deps(Config) ->
    proplists:get_value(deps, Config, []) =/= [].

has_alias(Config, Name) ->
    proplists:is_defined(Name, proplists:get_value(aliases, Config, [])).

%% The deps of mix.exs as {Name, Opts}. Another form is not a dep of
%% Mix: the error comes from Mix, or from beam_com_elixir:mix_dep/1.
dep_opts(Deps) ->
    lists:append([case D of
                      {Name, Opts} when is_atom(Name), is_list(Opts) -> [{Name, Opts}];
                      {Name, _Req} when is_atom(Name) -> [{Name, []}];
                      {Name, _Req, Opts} when is_atom(Name), is_list(Opts) -> [{Name, Opts}];
                      _ -> []
                  end || D <- Deps]).

in_prod(Opts) ->
    in_env(Opts, prod).

in_env(Opts, Env) ->
    case proplists:get_value(only, Opts, Env) of
        Only when is_list(Only) -> lists:member(Env, Only);
        Only -> Only =:= Env
    end.

%% A Hex package of an organization, or of a repository other than
%% hex.pm.
other_repo(Opts) ->
    proplists:is_defined(organization, Opts)
        orelse lists:member(proplists:get_value(repo, Opts, <<"hexpm">>), [<<"hexpm">>, "hexpm"])
        =:= false.

%% The entries of mix.lock in Dir of a Hex repository other than hex.pm
%% (the element 7 of an entry, for example "hexpm:acme"). A lock that
%% Mix cannot read gives [], and the build gives the error.
lock_repos(Dir) ->
    try
        {ok, Text} = file:read_file(filename:join(Dir, "mix.lock")),
        {ok, Quoted} = 'Elixir.Code':string_to_quoted(Text, [{emit_warnings, false}]),
        {Map, _} = 'Elixir.Code':eval_quoted(Quoted, []),
        [case Name of
             _ when is_atom(Name) -> Name;
             _ -> binary_to_atom(Name)
         end || Name := Entry <- Map, is_tuple(Entry), tuple_size(Entry) >= 7,
                element(1, Entry) =:= hex, not lists:member(element(7, Entry), [<<"hexpm">>, nil])]
    catch
        _:_ -> []
    end.

not_hex(Opts) ->
    lists:any(fun(K) -> proplists:is_defined(K, Opts) end, [git, github, path, in_umbrella]).
