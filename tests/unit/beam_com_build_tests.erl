%% Unit tests for beam_com_build (beam.com build).
%%
%% The tests use the real OTP applications of the Erlang that runs them
%% (linked into a temporary lib directory), so systools works on real
%% application files. run/1 is tested from end to end with a fake
%% executable.
-module(beam_com_build_tests).

-include_lib("eunit/include/eunit.hrl").

-define(END, 16#06054b50).

%%% Small functions

split_dir_test() ->
    ?assertEqual({kernel, "11.0.4"}, beam_com_build:split_dir("kernel-11.0.4")),
    ?assertEqual({beam_com, none}, beam_com_build:split_dir("beam_com")),
    ?assertEqual({'my-app', "1.0"}, beam_com_build:split_dir("my-app-1.0")).

default_output_test() ->
    ?assertEqual("hello.com", beam_com_build:default_output("src/hello.erl")),
    ?assertEqual("myapp.com", beam_com_build:default_output("apps/myapp")),
    ?assertEqual("x.com", beam_com_build:default_output("x")).

parents_test() ->
    ?assertEqual([], beam_com_build:parents("file")),
    ?assertEqual(["a/"], beam_com_build:parents("a/file")),
    ?assertEqual(["a/", "a/b/", "a/b/c/"], beam_com_build:parents("a/b/c/file")).

with_dirs_test() ->
    Files = [{"lib/a-1/ebin/a.beam", <<"1">>}, {"lib/a-1/ebin/b.beam", <<"2">>},
             {"releases/1/start.boot", <<"3">>}, {"top", <<"4">>}],
    ?assertEqual([{"lib/", <<>>}, {"lib/a-1/", <<>>}, {"lib/a-1/ebin/", <<>>},
                  {"releases/", <<>>}, {"releases/1/", <<>>}] ++ Files,
                 beam_com_build:with_dirs(Files)).

relocate_test() ->
    Tmp = "/tmp/x.tmp",
    Script = {script, {"n", "1"},
              [{path, ["$ROOT/lib/kernel-1/ebin", "/tmp/x.tmp/lib/app-1/ebin"]},
               {primLoad, [app]},
               {apply, {application, load, [{application, app, []}]}},
               {other, "/tmp/x.tmpfoo/not/this", 42, 'atom'}]},
    ?assertEqual({script, {"n", "1"},
                  [{path, ["$ROOT/lib/kernel-1/ebin", "$ROOT/lib/app-1/ebin"]},
                   {primLoad, [app]},
                   {apply, {application, load, [{application, app, []}]}},
                   {other, "/tmp/x.tmpfoo/not/this", 42, 'atom'}]},
                 beam_com_build:relocate(Script, Tmp)).

keep_test() ->
    Base = #{kernel => #{vsn => "11.0.4"}, ssl => #{vsn => "11.7.7"}},
    Keep = beam_com_build:keep([kernel, ssl], Base),
    Yes = ["lib/", "lib/kernel-11.0.4/", "lib/kernel-11.0.4/ebin/",
           "lib/kernel-11.0.4/ebin/kernel.app", "lib/ssl-11.7.7/priv/x/y",
           "bin/start_clean.boot", "usr/share/zoneinfo/UTC", ".cosmo",
           ".symtab.amd64"],
    No = ["lib/kernel-11.0.4/include/file.hrl", "lib/kernel-11.0.4/src/x.erl",
          "lib/kernel-11.0.40/ebin/kernel.app", "lib/stdlib-8.1/ebin/lists.beam",
          "lib/beam_com/ebin/beam_com.beam", "releases/", "releases/start_erl.data",
          ".args"],
    [?assert(Keep(N)) || N <- Yes],
    [?assertNot(Keep(N)) || N <- No].

executable_test() ->
    ?assertThrow({error, _, _}, beam_com_build:executable()).

%%% One .erl file

script_test_() ->
    {setup, fun tmp/0, fun rm/1,
     fun(Dir) ->
             [{"not a .erl file",
               ?_assertThrow({error, "~ts: not a .erl file or a directory", _},
                             beam_com_build:script(filename:join(Dir, "x.txt")))},
              {"missing file",
               ?_assertThrow({error, "~ts: no such file", _},
                             beam_com_build:script(filename:join(Dir, "none.erl")))},
              {"no main/1",
               fun() ->
                       F = write(Dir, "nomain.erl",
                                 "-module(nomain).\n-export([f/0]).\nf() -> ok.\n"),
                       ?assertThrow({error, "~ts: main/1 is not exported", _},
                                    beam_com_build:script(F))
               end},
              {"compile error",
               fun() ->
                       F = write(Dir, "bad.erl", "-module(bad).\nmain(_) -> x = .\n"),
                       ?assertThrow({error, "~ts: compilation failed", _},
                                    beam_com_build:script(F))
               end},
              {"a program",
               fun() ->
                       F = write(Dir, "prog.erl",
                                 "-module(prog).\n-export([main/1]).\n"
                                 "main(A) -> crypto:hash(sha256, A).\n"),
                       App = beam_com_build:script(F),
                       ?assertMatch(#{name := prog, vsn := "0.1.0", script := true,
                                      beams := [{prog, _}], priv := [],
                                      config := []}, App),
                       Props = maps:get(props, App),
                       ?assertEqual({beam_com_script, prog},
                                    proplists:get_value(mod, Props)),
                       ?assertEqual([kernel, stdlib, beam_com_script],
                                    proplists:get_value(applications, Props)),
                       ?assertEqual([prog], proplists:get_value(modules, Props))
               end}]
     end}.

%%% Application directories

slashes_test_() ->
    [{"Windows: backslashes are separators",
      ?_assertEqual("bin/x.com", beam_com_build:slashes("bin\\x.com", {unix, windows}))},
     ?_assertEqual("C:/a/b/c", beam_com_build:slashes("C:\\a\\b/c", {unix, windows})),
     {"other systems: no change",
      ?_assertEqual("a\\b", beam_com_build:slashes("a\\b", {unix, linux}))}].

app_dir_test_() ->
    {setup, fun tmp/0, fun rm/1,
     fun(Dir) ->
             [{"a full application", fun() -> full_app(Dir) end},
              {"ebin/NAME.app", fun() -> ebin_app(Dir) end},
              {"no application file",
               fun() ->
                       D = filename:join(Dir, "noapp"),
                       ok = filelib:ensure_path(filename:join(D, "src")),
                       ?assertThrow({error, "~ts: no src/*.app.src or ebin/*.app", _},
                                    beam_com_build:app_dir(D))
               end},
              {"bad application file",
               fun() ->
                       D = filename:join(Dir, "badapp"),
                       write(filename:join(D, "src"), "badapp.app.src", "not a term"),
                       ?assertThrow({error, "~ts: not an application file", _},
                                    beam_com_build:app_dir(D))
               end},
              {"version from git",
               fun() ->
                       D = filename:join(Dir, "gitvsn"),
                       write(filename:join(D, "src"), "gitvsn.app.src",
                             "{application, gitvsn, [{vsn, git}, {modules, []}]}.\n"),
                       ?assertMatch(#{vsn := "0.1.0"}, beam_com_build:app_dir(D)),
                       Props = maps:get(props, beam_com_build:app_dir(D)),
                       ?assertEqual("0.1.0", proplists:get_value(vsn, Props))
               end}]
     end}.

full_app(Dir) ->
    D = filename:join(Dir, "full"),
    write(filename:join(D, "src"), "full.app.src",
          "{application, full, [{vsn, \"2.3.4\"}, {modules, []},\n"
          " {applications, [kernel, stdlib, crypto]}, {mod, {full_app, []}}]}.\n"),
    write(filename:join(D, "src"), "full_app.erl",
          "-module(full_app).\n-export([value/0]).\n-include(\"full.hrl\").\n"
          "value() -> {?FROM_INCLUDE, ?FROM_REBAR, full_sub:v()}.\n"),
    write(filename:join([D, "src", "sub"]), "full_sub.erl",
          "-module(full_sub).\n-export([v/0]).\n-include(\"local.hrl\").\n"
          "v() -> ?LOCAL.\n"),
    write(filename:join(D, "src"), "local.hrl", "-define(LOCAL, local).\n"),
    write(filename:join(D, "include"), "full.hrl", "-define(FROM_INCLUDE, include).\n"),
    write(D, "rebar.config", "{erl_opts, [{d, 'FROM_REBAR', rebar}]}.\n"),
    write(filename:join([D, "priv", "data"]), "file.txt", "priv data"),
    write(filename:join(D, "config"), "sys.config", "[{full, [{k, v}]}]."),
    write(filename:join(D, "config"), "vm.args", "-noshell\n+S 1\n"),
    App = beam_com_build:app_dir(D),
    ?assertMatch(#{name := full, vsn := "2.3.4", script := false}, App),
    Beams = maps:get(beams, App),
    ?assertEqual([full_app, full_sub], lists:sort([M || {M, _} <- Beams])),
    [{module, _} = code:load_binary(M, atom_to_list(M) ++ ".beam", B)
     || {M, B} <- Beams],
    ?assertEqual({include, rebar, local}, full_app:value()),
    Props = maps:get(props, App),
    ?assertEqual([full_app, full_sub],
                 lists:sort(proplists:get_value(modules, Props))),
    ?assertEqual({full_app, []}, proplists:get_value(mod, Props)),
    ?assertEqual([{"data/file.txt", <<"priv data">>}], maps:get(priv, App)),
    ?assertEqual([{"sys.config", <<"[{full, [{k, v}]}].">>},
                  {"vm.args", <<"-noshell\n+S 1\n">>}],
                 maps:get(config, App)),
    %% The files of the application in the zip.
    Files = beam_com_build:app_files(App),
    Names = [N || {N, _} <- Files],
    ?assertEqual(["lib/full-2.3.4/ebin/full.app",
                  "lib/full-2.3.4/ebin/full_app.beam",
                  "lib/full-2.3.4/ebin/full_sub.beam",
                  "lib/full-2.3.4/priv/data/file.txt"],
                 lists:sort(Names)),
    {_, AppText} = lists:keyfind("lib/full-2.3.4/ebin/full.app", 1, Files),
    {ok, [{application, full, AppProps}], _} =
        erl_scan_parse(iolist_to_binary(AppText)),
    ?assertEqual("2.3.4", proplists:get_value(vsn, AppProps)).

ebin_app(Dir) ->
    D = filename:join(Dir, "ebinapp"),
    write(filename:join(D, "ebin"), "ebinapp.app",
          "{application, ebinapp, [{vsn, \"1.0\"}, {modules, [old]}]}.\n"),
    write(filename:join(D, "src"), "ebinapp_m.erl", "-module(ebinapp_m).\n"),
    App = beam_com_build:app_dir(D),
    ?assertMatch(#{name := ebinapp, vsn := "1.0"}, App),
    %% The module list is the one of the compiled code.
    ?assertEqual([ebinapp_m],
                 proplists:get_value(modules, maps:get(props, App))).

%%% Selection of the applications

base() ->
    App = fun(Mods, Deps) ->
                  #{vsn => "1", dir => "/nowhere",
                    props => [{modules, Mods}, {applications, Deps}]}
          end,
    #{kernel => App([application, file], []),
      stdlib => App([lists, io], [kernel]),
      crypto => App([crypto], [kernel, stdlib]),
      asn1 => App([asn1rt_nif], [kernel, stdlib]),
      public_key => App([public_key], [asn1, crypto]),
      ssl => App([ssl], [crypto, public_key]),
      other => App([helper], [kernel]),
      hello => App([hello], [kernel]),
      incl => #{vsn => "1", dir => "/", props => [{modules, [incl]},
                                                  {included_applications, [inner]}]},
      inner => App([inner], [])}.

program(Name, Code) ->
    {ok, Mod, Beam} = compile:forms(forms(Code), [binary]),
    #{name => Name, props => [{applications, [kernel, stdlib]}],
      beams => [{Mod, Beam}]}.

forms(Code) ->
    {ok, Tokens, _} = erl_scan:string(Code),
    [begin {ok, F} = erl_parse:parse_form(T), F end
     || T <- split_forms(Tokens, [])].

split_forms([], []) -> [];
split_forms([{dot, _} = D | Rest], Acc) -> [lists:reverse([D | Acc]) | split_forms(Rest, [])];
split_forms([T | Rest], Acc) -> split_forms(Rest, [T | Acc]).

select_apps_test_() ->
    Select = fun(App, Extra) -> lists:sort(beam_com_build:select_apps(App, Extra, base())) end,
    [{"only kernel and stdlib",
      ?_assertEqual([kernel, stdlib],
                    Select(program(p, "-module(p). -export([f/0]). f() -> lists:reverse([]).\n"), []))},
     {"a called module adds its application and what it needs",
      ?_assertEqual([asn1, crypto, kernel, public_key, ssl, stdlib],
                    Select(program(p, "-module(p). -export([f/0]). f() -> ssl:start().\n"), []))},
     {"-a adds an application",
      ?_assertEqual([crypto, kernel, stdlib],
                    Select(program(p, "-module(p). -export([f/0]). f() -> ok.\n"), [crypto]))},
     {"included applications",
      ?_assertEqual([incl, inner, kernel, stdlib],
                    Select(program(p, "-module(p). -export([f/0]). f() -> incl:x().\n"), []))},
     {"a call to an own module does not add another application",
      fun() ->
              {ok, M1, B1} = compile:forms(forms("-module(helper). -export([x/0]). x() -> 1.\n"), [binary]),
              {ok, M2, B2} = compile:forms(forms("-module(p). -export([f/0]). f() -> helper:x().\n"), [binary]),
              App = #{name => p, props => [], beams => [{M1, B1}, {M2, B2}]},
              ?assertEqual([kernel, stdlib], Select(App, []))
      end},
     {"an application with the name of the program is not selected",
      fun() ->
              App = (program(hello, "-module(p). -export([f/0]). f() -> hello:x().\n")),
              ?assertEqual([kernel, stdlib], Select(App, []))
      end},
     {"an unknown application",
      ?_assertThrow({error, "the application ~p is not in beam.com", [nosuch]},
                    Select(program(p, "-module(p). -export([f/0]). f() -> ok.\n"), [nosuch]))},
     {"an unknown application in the .app file",
      fun() ->
              App = (program(p, "-module(p). -export([f/0]). f() -> ok.\n"))#{
                        props => [{applications, [kernel, missing]}]},
              ?assertThrow({error, _, [missing]}, Select(App, []))
      end},
     {"a call to a module of no application: a warning",
      fun() ->
              {Apps, Err} = stderr(fun() ->
                  Select(program(p, "-module(p). -export([f/0]). f() -> unknown_mod:x(), erlang:self(), prim_file:get_cwd().\n"), [])
              end),
              ?assertEqual([kernel, stdlib], Apps),
              ?assertEqual("beam.com: warning: p calls unknown_mod, which is not in beam.com\n",
                           Err)
      end}].

%% Run F, and give its result and what it wrote to standard_error.
stderr(F) ->
    Self = self(),
    Old = whereis(standard_error),
    Pid = spawn(fun() -> capture(Self, []) end),
    true = unregister(standard_error),
    true = register(standard_error, Pid),
    try F() of
        Result ->
            Pid ! {stop, self()},
            receive {text, Text} -> {Result, Text} end
    after
        _ = (try unregister(standard_error) catch _:_ -> true end),
        register(standard_error, Old)
    end.

capture(Parent, Acc) ->
    receive
        {io_request, From, Ref, Req} ->
            {Text, Reply} = io_text(Req),
            From ! {io_reply, Ref, Reply},
            capture(Parent, [Text | Acc]);
        {stop, Parent} ->
            Parent ! {text, lists:flatten(lists:reverse(Acc))}
    end.

io_text({put_chars, unicode, M, F, A}) -> {apply(M, F, A), ok};
io_text({put_chars, unicode, Chars}) -> {unicode:characters_to_list(Chars), ok};
io_text({put_chars, latin1, Chars}) -> {binary_to_list(iolist_to_binary(Chars)), ok};
io_text(_) -> {"", {error, enotsup}}.

%%% Releases and run/1 (with the real OTP applications)

release_test_() ->
    {setup, fun tmp/0, fun rm/1,
     fun(Dir) -> [{"release files", fun() -> release(Dir) end},
                  {"run/1 from end to end", {timeout, 120, fun() -> run(Dir) end}},
                  {"run/1 with an application directory",
                   {timeout, 120, fun() -> run_app_dir(Dir) end}},
                  {"run/1 with an error", fun() -> run_error(Dir) end},
                  {"run/1 with a sandbox", {timeout, 120, fun() -> run_sandbox(Dir) end}},
                  {"run/1 errors and warnings", {timeout, 120, fun() -> run_edges(Dir) end}}]
     end}.

%% A lib directory with links to the real kernel, stdlib, sasl and crypto.
fake_root(Dir) ->
    Root = filename:join(Dir, "root"),
    Lib = filename:join(Root, "lib"),
    ok = filelib:ensure_path(Lib),
    Apps = [kernel, stdlib, sasl, crypto],
    [begin
         Vsn = app_vsn(A),
         Link = filename:join(Lib, atom_to_list(A) ++ "-" ++ Vsn),
         _ = file:make_symlink(code:lib_dir(A), Link)
     end || A <- Apps],
    %% The tool itself, which is not copied.
    write(filename:join([Lib, "beam_com", "ebin"]), "beam_com.app",
          "{application, beam_com, [{vsn, \"0.1.0\"}, {modules, []}]}.\n"),
    Root.

app_vsn(App) ->
    {ok, [{application, App, Props}]} =
        file:consult(filename:join([code:lib_dir(App), "ebin", atom_to_list(App) ++ ".app"])),
    proplists:get_value(vsn, Props).

release(Dir) ->
    Root = fake_root(Dir),
    Base = beam_com_build:base_apps(Root),
    ?assertEqual([crypto, kernel, sasl, stdlib], lists:sort(maps:keys(Base))),
    F = write(Dir, "relprog.erl", "-module(relprog).\n-export([main/1]).\nmain(_) -> ok.\n"),
    App = beam_com_build:script(F),
    %% beam_com_script is not in this fake root: give the release a
    %% program application without it.
    App1 = App#{props => lists:keystore(applications, 1, maps:get(props, App),
                                        {applications, [kernel, stdlib]})},
    Tmp = filename:join(Dir, "rel.tmp"),
    Files = beam_com_build:release(App1, [kernel, stdlib], Base, Tmp, Root),
    Names = [N || {N, _} <- Files],
    ?assertEqual(["releases/0.1.0/relprog.rel", "releases/0.1.0/start.boot",
                  "releases/0.1.0/vm.args", "releases/start_erl.data"],
                 lists:sort(Names)),
    {_, Boot} = lists:keyfind("releases/0.1.0/start.boot", 1, Files),
    {script, {"relprog", "0.1.0"}, Cmds} = binary_to_term(Boot),
    Paths = lists:append([P || {path, P} <- Cmds]),
    ?assert(length(Paths) >= 3),
    [?assertMatch("$ROOT/lib/" ++ _, P) || P <- Paths],
    ?assert(lists:member("$ROOT/lib/relprog-0.1.0/ebin", Paths)),
    {_, Data} = lists:keyfind("releases/start_erl.data", 1, Files),
    ?assertEqual(erlang:system_info(version) ++ " 0.1.0\n",
                 binary_to_list(iolist_to_binary(Data))),
    {_, VmArgs} = lists:keyfind("releases/0.1.0/vm.args", 1, Files),
    ?assertEqual(<<"-noshell\n">>, iolist_to_binary(VmArgs)),
    {_, RelText} = lists:keyfind("releases/0.1.0/relprog.rel", 1, Files),
    {ok, [{release, {"relprog", "0.1.0"}, {erts, _}, RelApps}], _} =
        erl_scan_parse(iolist_to_binary(RelText)),
    ?assertEqual([kernel, stdlib, relprog], [A || {A, _} <- RelApps]).

%% A fake executable with the zip of a beam.com: the files of the fake
%% root, a release, the tool, include files and the entries of the
%% emulator image.
fake_exe(Dir, Root) ->
    Lib = filename:join(Root, "lib"),
    {ok, Dirs} = file:list_dir(Lib),
    LibFiles = lists:append(
                 [[{"lib/" ++ D ++ "/ebin/" ++ F, <<"beam">>}
                   || F <- ebin_names(filename:join([Lib, D, "ebin"]))]
                  ++ [{"lib/" ++ D ++ "/include/x.hrl", <<"hrl">>}]
                  || D <- Dirs]),
    Seed = exe(<<"MZqFpD image bytes">>),
    Image = iolist_to_binary(beam_com_zip:write(Seed, fun(_) -> true end,
                                                [{".symtab.amd64", <<"sym">>},
                                                 {"usr/share/zoneinfo/UTC", <<"tz">>}])),
    Exe = iolist_to_binary(
            beam_com_zip:write(Image, fun(_) -> true end,
                               [{"bin/start_clean.boot", <<"boot">>},
                                {"releases/start_erl.data", <<"old">>},
                                {"releases/0.1.0/start.boot", <<"old">>},
                                {".args", <<"-x">>},
                                {".pledge", <<"old">>},
                                {".unveil", <<"r /old">>} | LibFiles])),
    File = filename:join(Dir, "beam.com"),
    ok = file:write_file(File, Exe),
    File.

ebin_names(Dir) ->
    {ok, Names} = file:list_dir(Dir),
    lists:sort(Names).

exe(Prefix) ->
    Size = byte_size(Prefix),
    <<Prefix/binary, ?END:32/little, 0:16, 0:16, 0:16, 0:16, 0:32,
      Size:32/little, 0:16>>.

run(Dir) ->
    Root = fake_root(Dir),
    %% beam_com_script is needed by one-file programs.
    write(filename:join([Root, "lib", "beam_com_script-0.1.0", "ebin"]),
          "beam_com_script.app",
          "{application, beam_com_script, [{description, \"\"}, {vsn, \"0.1.0\"},"
          " {modules, []}, {registered, []}, {applications, [kernel, stdlib]}]}.\n"),
    Exe = fake_exe(Dir, Root),
    F = write(Dir, "hasher.erl", "-module(hasher).\n-export([main/1]).\n"
              "main(A) -> crypto:hash(sha256, A).\n"),
    Out = filename:join(Dir, "hasher.com"),
    ok = silent(fun() -> beam_com_build:run(#{input => F, apps => [], output => Out,
                                              root => Root, exe => Exe}) end),
    {ok, Bin} = file:read_file(Out),
    Names = beam_com_zip:entries(Bin),
    Crypto = "lib/crypto-" ++ app_vsn(crypto) ++ "/",
    Kernel = "lib/kernel-" ++ app_vsn(kernel) ++ "/",
    Has = fun(Prefix) -> lists:any(fun(N) -> lists:prefix(Prefix, N) end, Names) end,
    [?assert(Has(P)) || P <- [Crypto ++ "ebin/", Kernel ++ "ebin/",
                              "lib/beam_com_script-0.1.0/ebin/",
                              "lib/hasher-0.1.0/ebin/hasher.beam",
                              "releases/0.1.0/start.boot", "releases/start_erl.data",
                              "bin/start_clean.boot", "usr/share/zoneinfo/UTC",
                              ".symtab.amd64"]],
    [?assertNot(Has(P)) || P <- ["lib/beam_com/", "lib/sasl-", Crypto ++ "include/",
                                 ".args", ".pledge", ".unveil"]],
    %% The old release was replaced, and stdlib reads the new file.
    {ok, Files} = zip:unzip(Bin, [memory]),
    ?assertEqual(<<(list_to_binary(erlang:system_info(version)))/binary, " 0.1.0\n">>,
                 proplists:get_value("releases/start_erl.data", Files)),
    ?assertEqual(<<"MZqFpD image bytes">>, binary:part(Bin, 0, 18)),
    {ok, Info} = file:read_file_info(Out),
    ?assertEqual(8#755, element(8, Info) band 8#777),
    %% No temporary directory is left.
    ?assertEqual([], filelib:wildcard(filename:join(Dir, ".*.tmp"))).

%% --pledge and --unveil write /zip/.pledge and /zip/.unveil, which
%% beam_com.c reads at start.
run_sandbox(Dir) ->
    Root = fake_root(Dir),
    write(filename:join([Root, "lib", "beam_com_script-0.1.0", "ebin"]),
          "beam_com_script.app",
          "{application, beam_com_script, [{description, \"\"}, {vsn, \"0.1.0\"},"
          " {modules, []}, {registered, []}, {applications, [kernel, stdlib]}]}.\n"),
    Exe = fake_exe(Dir, Root),
    F = write(Dir, "boxed.erl", "-module(boxed).\n-export([main/1]).\nmain(_) -> ok.\n"),
    Out = filename:join(Dir, "boxed.com"),
    ok = silent(fun() ->
                        beam_com_build:run(#{input => F, apps => [], output => Out,
                                             root => Root, exe => Exe,
                                             pledge => "inet dns",
                                             unveil => ["r /etc", "rwc /tmp/x"]})
                end),
    {ok, Bin} = file:read_file(Out),
    {ok, Files} = zip:unzip(Bin, [memory]),
    ?assertEqual(<<"inet dns\n">>, proplists:get_value(".pledge", Files)),
    ?assertEqual(<<"r /etc\nrwc /tmp/x\n">>, proplists:get_value(".unveil", Files)),
    %% An empty pledge is a pledge ("stdio rpath" only).
    ok = silent(fun() ->
                        beam_com_build:run(#{input => F, apps => [], output => Out,
                                             root => Root, exe => Exe, pledge => ""})
                end),
    {ok, Files2} = zip:unzip(element(2, file:read_file(Out)), [memory]),
    ?assertEqual(<<"\n">>, proplists:get_value(".pledge", Files2)),
    ?assertEqual(undefined, proplists:get_value(".unveil", Files2)).

sandbox_options_test_() ->
    Unknown = fun(W) -> {error, "unknown promise ~ts (see beam.com help build)", [W]} end,
    Bad = fun(R) -> {error, "--unveil needs \"PERMISSIONS PATH\", with PERMISSIONS of "
                     "r, w, x and c: ~ts", [R]} end,
    UnknownBogus = Unknown("bogus"),
    UnknownThread = Unknown("thread"),
    BadQ = Bad("q /etc"),
    BadNoPath = Bad("r"),
    BadEmpty = Bad(""),
    [?_assertEqual("inet dns", beam_com_build:check_promises("inet   dns")),
     ?_assertEqual("", beam_com_build:check_promises("")),
     ?_assertEqual("stdio rpath wpath cpath dpath flock fattr inet anet unix dns tty "
                   "recvfd sendfd proc exec id unveil settime prot_exec vminfo tmppath chown",
                   beam_com_build:check_promises(
                     "stdio rpath wpath cpath dpath flock fattr inet anet unix dns tty "
                     "recvfd sendfd proc exec id unveil settime prot_exec vminfo tmppath chown")),
     {"an unknown promise", ?_assertThrow(UnknownBogus, beam_com_build:check_promises("inet bogus"))},
     {"not a promise of Cosmopolitan",
      ?_assertThrow(UnknownThread, beam_com_build:check_promises("thread"))},
     ?_assertEqual("r /etc", beam_com_build:check_unveil("r /etc")),
     ?_assertEqual("rwxc /a b", beam_com_build:check_unveil("  rwxc /a b ")),
     {"a path with spaces", ?_assertEqual("r /a b", beam_com_build:check_unveil("r /a b"))},
     {"a wrong permission", ?_assertThrow(BadQ, beam_com_build:check_unveil("q /etc"))},
     {"no path", ?_assertThrow(BadNoPath, beam_com_build:check_unveil("r"))},
     {"nothing", ?_assertThrow(BadEmpty, beam_com_build:check_unveil(""))}].

run_app_dir(Dir) ->
    Root = filename:join(Dir, "root"),
    Exe = filename:join(Dir, "beam.com"),
    D = filename:join(Dir, "svc"),
    write(filename:join(D, "src"), "svc.app.src",
          %% A minimal .app.src: no description, registered or applications.
          "{application, svc, [{vsn, \"1.2.0\"}]}.\n"),
    write(filename:join(D, "src"), "svc.erl", "-module(svc).\n"),
    write(filename:join(D, "config"), "sys.config", "[]."),
    Out = filename:join(Dir, "svc.com"),
    ok = silent(fun() -> beam_com_build:run(#{input => D ++ "/", apps => [],
                                              output => Out, root => Root,
                                              exe => Exe}) end),
    {ok, Bin} = file:read_file(Out),
    {ok, Files} = zip:unzip(Bin, [memory]),
    ?assertEqual(<<"[].">>, proplists:get_value("releases/1.2.0/sys.config", Files)),
    ?assertEqual(<<"-noshell\n">>, proplists:get_value("releases/1.2.0/vm.args", Files)),
    ?assertNot(lists:keymember("lib/crypto-" ++ app_vsn(crypto) ++ "/ebin/crypto.app",
                               1, Files)).

run_error(Dir) ->
    Root = filename:join(Dir, "root"),
    Exe = filename:join(Dir, "beam.com"),
    F = write(Dir, "needs.erl", "-module(needs).\n-export([main/1]).\n"
              "main(_) -> ssl:start().\n"),
    Out = filename:join(Dir, "needs.com"),
    ?assertThrow({error, "the application ~p is not in beam.com", [nosuch]},
                 beam_com_build:run(#{input => F, apps => [nosuch], output => Out,
                                      root => Root, exe => Exe})),
    ?assertNot(filelib:is_file(Out)),
    ?assertEqual([], filelib:wildcard(filename:join(Dir, ".*.tmp"))),
    ?assertThrow({error, "~ts: ~ts", _},
                 beam_com_build:run(#{input => write(Dir, "ok.erl",
                                                     "-module(ok).\n-export([main/1]).\nmain(_) -> 1.\n"),
                                      apps => [], output => Out, root => Root,
                                      exe => filename:join(Dir, "missing.com")})).

run_edges(Dir) ->
    Root = filename:join(Dir, "root"),
    Exe = filename:join(Dir, "beam.com"),
    Ok = write(Dir, "edge.erl", "-module(edge).\n-export([main/1]).\nmain(_) -> ok.\n"),
    %% Without the path of the executable (it comes from beam_com.c).
    ?assertThrow({error, "the path of beam.com is not known", []},
                 beam_com_build:run(#{input => Ok, apps => [], root => Root,
                                      output => filename:join(Dir, "edge.com")})),
    %% The output is a directory.
    OutDir = filename:join(Dir, "outdir"),
    ok = filelib:ensure_path(OutDir),
    ?assertThrow({error, "~ts: ~ts", [OutDir, _]},
                 silent(fun() -> beam_com_build:run(#{input => Ok, apps => [],
                                                      output => OutDir, root => Root,
                                                      exe => Exe}) end)),
    %% A module with the name of an OTP module: systools refuses it.
    Clash = filename:join(Dir, "clash"),
    write(filename:join(Clash, "src"), "clash.app.src", "{application, clash, [{vsn, \"1\"}]}.\n"),
    write(filename:join(Clash, "src"), "lists.erl", "-module(lists).\n"),
    ?assertThrow({error, "systools: ~ts", _},
                 silent(fun() -> beam_com_build:run(#{input => Clash, apps => [],
                                                      output => filename:join(Dir, "clash.com"),
                                                      root => Root, exe => Exe}) end)),
    %% Compiler warnings, returned (return_warnings in rebar.config).
    Warn = filename:join(Dir, "warn"),
    write(filename:join(Warn, "src"), "warn.app.src", "{application, warn, [{vsn, \"1\"}]}.\n"),
    write(filename:join(Warn, "src"), "warn.erl", "-module(warn).\n-export([f/0]).\nf() -> X = 1, ok.\n"),
    write(Warn, "rebar.config", "{erl_opts, [return_warnings]}.\n"),
    App = silent(fun() -> beam_com_build:app_dir(Warn) end),
    ?assertMatch(#{beams := [{warn, _}]}, App).

%%% Helpers

tmp() ->
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; T -> T end,
    Dir = filename:join(Base, "beam_com_build_tests." ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_path(Dir),
    Dir.

rm(Dir) ->
    file:del_dir_r(Dir).

write(Dir, Name, Content) ->
    ok = filelib:ensure_path(Dir),
    File = filename:join(Dir, Name),
    ok = file:write_file(File, Content),
    File.

erl_scan_parse(Bin) ->
    {ok, Tokens, End} = erl_scan:string(binary_to_list(Bin)),
    {ok, Term} = erl_parse:parse_term(Tokens),
    {ok, [Term], End}.

%% Run F without its standard output (the summary of run/1).
silent(F) ->
    {ok, Dev} = file:open("/dev/null", [write]),
    Old = group_leader(),
    group_leader(Dev, self()),
    try F() after group_leader(Old, self()), file:close(Dev) end.
