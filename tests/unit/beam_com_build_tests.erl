%% Unit tests for beam_com_build (beam.com INPUT -o OUTPUT).
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
           ".symtab.amd64", "licenses/NOTICE", "licenses/otp/MIT.txt"],
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
               ?_assertThrow({error, "~ts: not a .erl, .ex or .exs file, or a directory", _},
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
     {"Windows: a drive becomes /C/",
      [?_assertEqual("/C/a/b/c", beam_com_build:slashes("C:\\a\\b/c", {unix, windows})),
       ?_assertEqual("/d/x.com", beam_com_build:slashes("d:/x.com", {unix, windows})),
       ?_assertEqual("/D", beam_com_build:slashes("D:", {unix, windows})),
       ?_assertEqual("D:x", beam_com_build:slashes("D:x", {unix, windows}))]},
     {"other systems: no change",
      ?_assertEqual("a\\b", beam_com_build:slashes("a\\b", {unix, linux}))}].

%% .yrl, .xrl and ASN.1 files: the builder makes the .erl files.
generate_test_() ->
    {setup, fun tmp/0, fun rm/1,
     fun(Dir) ->
             [{"a parser, a scanner and an ASN.1 module", fun() -> generated(Dir) end},
              {"an .erl file next to the .yrl or .xrl file is used",
               fun() -> made_before(Dir) end},
              {"an application with generated code", fun() -> generated_app(Dir) end},
              {"errors", fun() -> generate_errors(Dir) end}]
     end}.

-define(YRL, "Nonterminals list elems.\nTerminals '[' ']' int.\nRootsymbol list.\n"
             "list -> '[' ']' : [].\nlist -> '[' elems ']' : '$2'.\n"
             "elems -> int : [v('$1')].\nelems -> int elems : [v('$1') | '$2'].\n"
             "Erlang code.\nv({int, _, V}) -> V.\n").
-define(XRL, "Definitions.\nD = [0-9]\nRules.\n{D}+ : {token, {int, TokenLine, "
             "list_to_integer(TokenChars)}}.\n[\\[\\]] : {token, {list_to_atom(TokenChars), "
             "TokenLine}}.\n[\\s]+ : skip_token.\nErlang code.\n").
-define(ASN1, "Pair DEFINITIONS AUTOMATIC TAGS ::= BEGIN\n"
              "P ::= SEQUENCE { a INTEGER, b INTEGER }\nEND\n").

generated(Dir) ->
    D = filename:join(Dir, "gen1"),
    write(filename:join(D, "src"), "lp.yrl", ?YRL),
    write(filename:join(D, "src"), "ls.xrl", ?XRL),
    write(filename:join(D, "asn1"), "pair.asn1", ?ASN1),
    Gen = filename:join(Dir, "gen1out"),
    Files = beam_com_build:generate(D, Gen),
    ?assertEqual(["Pair.erl", "lp.erl", "ls.erl"], lists:sort([filename:basename(F) || F <- Files])),
    ?assert(filelib:is_regular(filename:join(Gen, "Pair.hrl"))),
    [{ok, _} = compile:file(F, [{outdir, Gen}, {i, Gen}, report]) || F <- Files],
    true = code:add_patha(Gen),
    {ok, Tokens, _} = ls:string("[1 2 3]"),
    ?assertEqual({ok, [1, 2, 3]}, lp:parse(Tokens)),
    {ok, Ber} = 'Pair':encode('P', {'P', 1, 2}),
    ?assertEqual({ok, {'P', 1, 2}}, 'Pair':decode('P', Ber)),
    code:del_path(Gen).

made_before(Dir) ->
    D = filename:join(Dir, "gen2"),
    write(filename:join(D, "src"), "made.yrl", ?YRL),
    write(filename:join(D, "src"), "made.erl", "-module(made).\n"),
    write(filename:join(D, "src"), "scan.xrl", ?XRL),
    write(filename:join(D, "src"), "scan.erl", "-module(scan).\n"),
    ?assertEqual([], beam_com_build:generate(D, filename:join(Dir, "gen2out"))).

generated_app(Dir) ->
    D = filename:join(Dir, "genapp"),
    write(filename:join(D, "src"), "genapp.app.src",
          "{application, genapp, [{vsn, \"1.0\"}, {modules, []}]}.\n"),
    write(filename:join(D, "src"), "lp.yrl", ?YRL),
    write(filename:join(D, "src"), "ls.xrl", ?XRL),
    write(filename:join(D, "src"), "pair.asn", ?ASN1),
    write(filename:join(D, "src"), "genapp.erl",
          "-module(genapp).\n-export([f/0]).\n-include(\"Pair.hrl\").\n"
          "f() -> #'P'{a = 1, b = 2}.\n"),
    Before = temp_dirs(),
    #{beams := Beams, props := Props} = beam_com_build:app_dir(D),
    Mods = lists:sort([M || {M, _} <- Beams]),
    ?assertEqual(['Pair', genapp, lp, ls], Mods),
    ?assertEqual(Mods, lists:sort(proplists:get_value(modules, Props))),
    %% The temporary directory is removed.
    ?assertEqual(Before, temp_dirs()).

temp_dirs() ->
    Base = hd([T || V <- ["TMPDIR", "TMP", "TEMP"], T <- [os:getenv(V)],
                    T =/= false, T =/= ""] ++ ["/tmp"]),
    lists:sort(filelib:wildcard(filename:join(Base, "beam_com_gen_*"))).

generate_errors(Dir) ->
    Bad = fun(Name, File, Content, Error) ->
                  D = filename:join(Dir, Name),
                  Path = write(filename:join(D, "src"), File, Content),
                  ?assertThrow({error, Error, [Path]},
                               silent(fun() -> beam_com_build:generate(D, filename:join(D, "out")) end))
          end,
    Bad("bady", "bad.yrl", "Nonterminals x.\nRootsymbol y.\n", "~ts: yecc failed"),
    Bad("badx", "bad.xrl", "Rules.\n[ : nothing.\n", "~ts: leex failed"),
    Bad("bada", "bad.asn1", "Bad DEFINITIONS ::= BEGIN\nX ::= NOTHING\nEND\n",
        "~ts: the ASN.1 compiler failed").

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
                  {"run/1 with Hex packages", {timeout, 120, fun() -> run_hex(Dir) end}},
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
                                {".allow", <<"all">>} | LibFiles])),
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
                                 ".args", ".allow"]],
    %% The old release was replaced, and stdlib reads the new file.
    {ok, Files} = zip:unzip(Bin, [memory]),
    ?assertEqual(<<(list_to_binary(erlang:system_info(version)))/binary, " 0.1.0\n">>,
                 proplists:get_value("releases/start_erl.data", Files)),
    ?assertEqual(<<"MZqFpD image bytes">>, binary:part(Bin, 0, 18)),
    {ok, Info} = file:read_file_info(Out),
    ?assertEqual(8#755, element(8, Info) band 8#777),
    %% No temporary directory is left.
    ?assertEqual([], filelib:wildcard(filename:join(Dir, ".*.tmp"))).

%% The --allow-* flags write /zip/.allow, which beam_com.c reads at
%% start.
run_sandbox(Dir) ->
    Root = fake_root(Dir),
    write(filename:join([Root, "lib", "beam_com_script-0.1.0", "ebin"]),
          "beam_com_script.app",
          "{application, beam_com_script, [{description, \"\"}, {vsn, \"0.1.0\"},"
          " {modules, []}, {registered, []}, {applications, [kernel, stdlib]}]}.\n"),
    Exe = fake_exe(Dir, Root),
    F = write(Dir, "boxed.erl", "-module(boxed).\n-export([main/1]).\nmain(_) -> ok.\n"),
    Out = filename:join(Dir, "boxed.com"),
    Build = fun(Allow) ->
                    ok = silent(fun() ->
                                        beam_com_build:run(#{input => F, apps => [], output => Out,
                                                             root => Root, exe => Exe,
                                                             allow => Allow})
                                end),
                    {ok, Files} = zip:unzip(element(2, file:read_file(Out)), [memory]),
                    proplists:get_value(".allow", Files)
            end,
    ?assertEqual(<<"read=/etc,/srv\nwrite\nnet\nrun=git\n">>,
                 Build(#{run => ["git"], net => true, write => all, read => ["/etc", "/srv"]})),
    ?assertEqual(<<"net\n">>, Build(#{net => true})),
    %% --allow-all wins over the others.
    ?assertEqual(<<"all\n">>, Build(#{all => true, net => true})),
    %% Without flags, no file (no sandbox).
    ok = silent(fun() ->
                        beam_com_build:run(#{input => F, apps => [], output => Out,
                                             root => Root, exe => Exe})
                end),
    {ok, Files2} = zip:unzip(element(2, file:read_file(Out)), [memory]),
    ?assertEqual(undefined, proplists:get_value(".allow", Files2)).

allow_test_() ->
    A = fun(Flags) -> lists:foldl(fun beam_com_build:allow/2, #{}, Flags) end,
    [?_assertEqual(#{read => all}, A(["--allow-read"])),
     ?_assertEqual(#{read => all}, A(["-R"])),
     {"a list, then all", ?_assertEqual(#{read => all}, A(["--allow-read=/a", "-R"]))},
     {"all, then a list", ?_assertEqual(#{read => all}, A(["-R", "--allow-read=/a"]))},
     {"lists add up, without duplicates",
      ?_assertEqual(#{write => ["/a", "/b"]}, A(["--allow-write=/a", "--allow-write=/b,/a"]))},
     ?_assertEqual(#{net => true}, A(["-N"])),
     ?_assertEqual(#{run => ["git", "/bin/sh"]}, A(["--allow-run=git,/bin/sh"])),
     ?_assertEqual(#{all => true}, A(["-A"])),
     {"--allow-all= is unknown",
      ?_assertThrow({error, "unknown option ~ts", ["--allow-all=x"]}, A(["--allow-all=x"]))}].

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

%% An application with deps of rebar.config, from a server in place of
%% hex.pm (beam_com_hex_tests): alpha needs beta, and the application
%% uses a header of alpha with include_lib.
run_hex(Dir) ->
    Root = filename:join(Dir, "root"),
    Exe = filename:join(Dir, "beam.com"),
    App = fun(N, V, Deps) ->
                  io_lib:format("{application, ~s, [{description, \"\"}, {vsn, ~p},"
                                " {registered, []}, {applications, [kernel, stdlib~s]}]}.~n",
                                [N, V, [", " ++ D || D <- Deps]])
          end,
    Beta = beam_com_hex_tests:package(
             <<"beta">>, "0.2.0",
             [{"src/beta.app.src", App("beta", "0.2.0", [])},
              {"src/beta.erl", "-module(beta).\n-export([f/0]).\nf() -> beta.\n"}],
             [], [<<"rebar3">>]),
    Alpha = beam_com_hex_tests:package(
              <<"alpha">>, "1.1.0",
              [{"src/alpha.app.src", App("alpha", "1.1.0", ["beta"])},
               {"src/alpha.erl", "-module(alpha).\n-export([f/0]).\nf() -> beta:f().\n"},
               {"include/alpha.hrl", "-define(ALPHA, alpha_macro).\n"},
               %% rebar3 options of the package: warnings are not errors.
               {"rebar.config", "{erl_opts, [warnings_as_errors]}.\n"},
               {"src/alpha_warn.erl", "-module(alpha_warn).\nf() -> ok.\n"}],
              [{<<"beta">>, "~> 0.2.0"}], [<<"rebar3">>]),
    {Pid, Port} = beam_com_hex_tests:serve(
                    beam_com_hex_tests:routes([{<<"alpha">>, "1.1.0", [{<<"beta">>, "~> 0.2.0"}], Alpha},
                                               {<<"beta">>, "0.2.0", [], Beta}])),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port),
    Env = [{"HEX_API_URL", Url ++ "/api"}, {"HEX_MIRROR", Url ++ "/repo"},
           {"BEAM_COM_CACHE", filename:join(Dir, "hexcache")}],
    [os:putenv(K, V) || {K, V} <- Env],
    try
        D = filename:join(Dir, "web"),
        write(D, "rebar.config", "{deps, [{alpha, \"~> 1.0\"}]}.\n"),
        write(filename:join(D, "src"), "web.app.src", App("web", "1.0.0", ["alpha"])),
        write(filename:join(D, "src"), "web.erl",
              "-module(web).\n-export([f/0]).\n-include_lib(\"alpha/include/alpha.hrl\").\n"
              "f() -> {?ALPHA, alpha:f()}.\n"),
        Out = filename:join(Dir, "web.com"),
        ok = silent(fun() -> beam_com_build:run(#{input => D, apps => [], output => Out,
                                                  root => Root, exe => Exe}) end),
        {ok, Files} = zip:unzip(element(2, file:read_file(Out)), [memory]),
        Beam = fun(P) -> proplists:get_value(P, Files) end,
        [?assert(is_binary(Beam(P)))
         || P <- ["lib/alpha-1.1.0/ebin/alpha.beam", "lib/alpha-1.1.0/ebin/alpha.app",
                  "lib/alpha-1.1.0/ebin/alpha_warn.beam", "lib/beta-0.2.0/ebin/beta.beam",
                  "lib/web-1.0.0/ebin/web.beam"]],
        {ok, [{release, _, _, Rel}], _} =
            erl_scan_parse(proplists:get_value("releases/1.0.0/web.rel", Files)),
        ?assertEqual({alpha, "1.1.0"}, lists:keyfind(alpha, 1, Rel)),
        ?assertEqual({beta, "0.2.0"}, lists:keyfind(beta, 1, Rel)),
        %% The code works: web uses the macro of alpha, and alpha calls beta.
        [{module, M} = code:load_binary(M, atom_to_list(M) ++ ".beam", Beam(P))
         || {M, P} <- [{beta, "lib/beta-0.2.0/ebin/beta.beam"},
                       {alpha, "lib/alpha-1.1.0/ebin/alpha.beam"},
                       {web, "lib/web-1.0.0/ebin/web.beam"}]],
        ?assertEqual({alpha_macro, beta}, web:f()),
        ?assert(filelib:is_regular(filename:join(D, "rebar.lock"))),
        %% No package is left in the code path.
        ?assertEqual([], [P || P <- code:get_path(), string:find(P, "beam_com_deps_") =/= nomatch])
    after
        [code:purge(M) andalso code:delete(M) || M <- [web, alpha, beta]],
        [os:unsetenv(K) || {K, _} <- Env],
        beam_com_hex_tests:stop(Pid)
    end.

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
                                      exe => filename:join(Dir, "missing.com")})),
    %% A native file (assimilated) as the base, without --target: an
    %% error before the compilation, and no output.
    {ok, Ape} = file:read_file(Exe),
    Elf = filename:join(Dir, "beam-elf.com"),
    ok = file:write_file(Elf, <<127, "ELF", 2, 1, 1, 0, 0:64, 2:16/little, 16#3e:16/little,
                                (binary:part(Ape, 20, byte_size(Ape) - 20))/binary>>),
    ?assertThrow({error, "this is a native file (~ts), not an APE file: a program built "
                  "from it runs only on this system." ++ _, [_]},
                 beam_com_build:run(#{input => F, apps => [], output => Out,
                                      root => Root, exe => Elf})),
    ?assertThrow({error, "this is a native file (~ts), not an APE file: it cannot make "
                  "a file for ~ts." ++ _, [_, "aarch64-unknown-linux-gnu"]},
                 beam_com_build:run(#{input => F, apps => [], output => Out, root => Root,
                                      exe => Elf, target => "aarch64-unknown-linux-gnu"})),
    ?assertNot(filelib:is_file(Out)).

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

%% --target: a small APE-like file with the parts of the shell script
%% that assimilate reads (tests/run.sh compares with real files).
target_test_() ->
    Elf = fun(Machine, Abi) ->
                  <<127, "ELF", 2, 1, 1, Abi, 0:64, 2:16/little, Machine:16/little,
                    1:32/little, 16#401000:64/little, 0:64, 64:64/little, 0:32,
                    64:16/little, 56:16/little, 1:16/little, 0:48>>
          end,
    Octal = fun(Bin) -> [io_lib:format("\\~.8b", [B]) || <<B>> <= Bin] end,
    MachO = <<16#feedfacf:32/little, 16#01000007:32/little, 3:32/little,
              2:32/little, 0:128>>,
    Script = iolist_to_binary(
               ["MZqFpD='\n'\n",
                "printf '", Octal(Elf(16#3e, 9)), "' >&7\n",
                "printf '", Octal(Elf(16#b7, 9)), "' >&7\n",
                "dd if=\"$o\" of=\"$o\" bs=1 skip=1024 count=", integer_to_list(byte_size(MachO)),
                " conv=notrunc\n"]),
    Pad = binary:copy(<<"#">>, 1024 - byte_size(Script)),
    Tail = <<"PK zip data">>,
    Ape = <<Script/binary, Pad/binary, MachO/binary, Tail/binary>>,
    Native = fun(T) -> beam_com_build:native(T, Ape) end,
    Rest = fun(Bin, N) -> binary:part(Bin, N, byte_size(Bin) - N) end,
    [{"x86_64 Linux: the ELF header with OS ABI 0, the rest the same",
      ?_assertEqual(<<(Elf(16#3e, 0))/binary, (Rest(Ape, 64))/binary>>,
                    Native("x86_64-unknown-linux-gnu"))},
     {"aarch64 Linux",
      ?_assertEqual(<<(Elf(16#b7, 0))/binary, (Rest(Ape, 64))/binary>>,
                    Native("aarch64-unknown-linux-gnu"))},
     {"FreeBSD keeps OS ABI 9",
      ?_assertEqual(<<(Elf(16#3e, 9))/binary, (Rest(Ape, 64))/binary>>,
                    Native("x86_64-unknown-freebsd"))},
     {"macOS x86_64: the Mach-O header from the dd command",
      ?_assertEqual(<<MachO/binary, (Rest(Ape, byte_size(MachO)))/binary>>,
                    Native("x86_64-apple-darwin"))},
     {"the same size: the offsets of the zip do not change",
      ?_assertEqual(byte_size(Ape), byte_size(Native("x86_64-apple-darwin")))},
     {"no header for the CPU",
      ?_assertThrow({error, "no ELF header for this CPU in the APE file", []},
                    beam_com_build:native("x86_64-unknown-linux-gnu", <<"MZqFpD='\n'\n">>))},
     {"no Mach-O header",
      ?_assertThrow({error, "no Mach-O header for this CPU in the APE file", []},
                    beam_com_build:native("x86_64-apple-darwin", Script))},
     {"the format of the base",
      [?_assertEqual(ape, beam_com_build:base_kind(Ape)),
       ?_assertEqual(ape, beam_com_build:base_kind(<<"jartsr='\n">>)),
       ?_assertEqual({elf, 16#3e, 0}, beam_com_build:base_kind(Elf(16#3e, 0))),
       ?_assertEqual({elf, 16#b7, 9}, beam_com_build:base_kind(Elf(16#b7, 9))),
       ?_assertEqual({macho, 16#01000007}, beam_com_build:base_kind(MachO)),
       ?_assertEqual(unknown, beam_com_build:base_kind(<<"PK zip">>)),
       ?_assertEqual(unknown, beam_com_build:base_kind(<<>>))]},
     {"a native base of the CPU of the target: the same file",
      [?_assertEqual(<<(Elf(16#3e, 0))/binary, Tail/binary>>,
                     beam_com_build:native("x86_64-unknown-linux-gnu",
                                           <<(Elf(16#3e, 0))/binary, Tail/binary>>)),
       ?_assertEqual(<<(Elf(16#3e, 0))/binary, Tail/binary>>,
                     beam_com_build:native("x86_64-unknown-linux-gnu",
                                           <<(Elf(16#3e, 9))/binary, Tail/binary>>)),
       ?_assertEqual(<<(Elf(16#3e, 9))/binary, Tail/binary>>,
                     beam_com_build:native("x86_64-unknown-freebsd",
                                           <<(Elf(16#3e, 0))/binary, Tail/binary>>)),
       ?_assertEqual(<<MachO/binary, Tail/binary>>,
                     beam_com_build:native("x86_64-apple-darwin", <<MachO/binary, Tail/binary>>))]},
     {"a native base: an error without --target, or for another CPU",
      [?_assertEqual(ok, beam_com_build:check_base(Ape, none)),
       ?_assertEqual(ok, beam_com_build:check_base(Ape, "x86_64-apple-darwin")),
       ?_assertEqual(ok, beam_com_build:check_base(<<"PK zip">>, none)),
       ?_assertEqual(ok, beam_com_build:check_base(Elf(16#3e, 0), "x86_64-unknown-linux-gnu")),
       ?_assertEqual(ok, beam_com_build:check_base(Elf(16#3e, 0), "x86_64-unknown-freebsd")),
       ?_assertEqual(ok, beam_com_build:check_base(MachO, "x86_64-apple-darwin")),
       ?_assertThrow({error, "this is a native file (~ts), not an APE file: a program built "
                      "from it runs only on this system. Build with the APE file of "
                      "beam.com, or give --target to make a native file",
                      [["ELF, ", "x86_64"]]},
                     beam_com_build:check_base(Elf(16#3e, 0), none)),
       ?_assertThrow({error, _, [["Mach-O, ", "x86_64"]]},
                     beam_com_build:check_base(MachO, none)),
       ?_assertThrow({error, "this is a native file (~ts), not an APE file: it cannot make "
                      "a file for ~ts. Build with the APE file of beam.com",
                      [["ELF, ", "x86_64"], "aarch64-unknown-linux-gnu"]},
                     beam_com_build:check_base(Elf(16#3e, 0), "aarch64-unknown-linux-gnu")),
       ?_assertThrow({error, _, [["ELF, ", "aarch64"], "x86_64-apple-darwin"]},
                     beam_com_build:check_base(Elf(16#b7, 0), "x86_64-apple-darwin")),
       ?_assertThrow({error, _, [["Mach-O, ", "x86_64"], "x86_64-unknown-linux-gnu"]},
                     beam_com_build:check_base(MachO, "x86_64-unknown-linux-gnu"))]},
     {"the triples, and the short names",
      [?_assertEqual(T, beam_com_build:check_target(N))
       || {N, T} <- [{"x86_64-unknown-linux-gnu", "x86_64-unknown-linux-gnu"},
                     {"x86_64-linux", "x86_64-unknown-linux-gnu"},
                     {"aarch64-linux", "aarch64-unknown-linux-gnu"},
                     {"x86_64-freebsd", "x86_64-unknown-freebsd"},
                     {"x86_64-macos", "x86_64-apple-darwin"},
                     {"x86_64-apple-darwin", "x86_64-apple-darwin"}]]},
     {"Apple Silicon",
      ?_assertThrow({error, "~ts: Apple Silicon has no native form" ++ _, ["aarch64-apple-darwin"]},
                    beam_com_build:check_target("aarch64-apple-darwin"))},
     {"an unknown target",
      ?_assertThrow({error, "unknown target ~ts (one of: ~ts)", ["linux-x86_64", _]},
                    beam_com_build:check_target("linux-x86_64"))}].

%% The entry of an application program (--main, rebar.config, mix.exs),
%% the priv directories that are copied at start, and the order of
%% compilation.
entry_test_() ->
    {setup, fun tmp/0, fun rm/1,
     fun(Dir) ->
             [{"the tool of a directory", fun() -> tool(Dir) end},
              {"the escript of rebar.config", fun() -> escript_main(Dir) end},
              {"the main module", fun main_module/0},
              {"vm.args runs main/1", fun with_main/0},
              {"priv files and executables", fun() -> priv_files(Dir) end},
              {"the priv directories to copy", fun extract/0},
              {"sys.config for beam_com_script", fun with_extract/0},
              {"behaviours and parse transforms first",
               {timeout, 60, fun() -> compile_all(Dir) end}},
              {"the docs are not in a program", fun() -> without_docs(Dir) end}]
     end}.

tool(Dir) ->
    Rebar = filename:join(Dir, "t_rebar"),
    write(Rebar, "rebar.config", "{erl_opts, []}.\n"),
    ?assertEqual(rebar, beam_com_build:tool(Rebar, #{})),
    Src = filename:join(Dir, "t_src"),
    write(filename:join(Src, "src"), "t.app.src", "{application, t, []}.\n"),
    ?assertEqual(rebar, beam_com_build:tool(Src, #{})),
    Mix = filename:join(Dir, "t_mix"),
    write(Mix, "mix.exs", "defmodule T.MixProject do\nend\n"),
    ?assertEqual(mix, beam_com_build:tool(Mix, #{})),
    %% Both: rebar, unless --tool mix.
    write(Rebar, "mix.exs", "defmodule T.MixProject do\nend\n"),
    ?assertEqual(rebar, beam_com_build:tool(Rebar, #{})),
    ?assertEqual(mix, beam_com_build:tool(Rebar, #{tool => mix})),
    ?assertEqual(rebar, beam_com_build:tool(filename:join(Dir, "none"), #{})).

escript_main(Dir) ->
    Main = fun(Config) ->
                   D = filename:join(Dir, "e" ++ integer_to_list(erlang:unique_integer([positive]))),
                   write(D, "rebar.config", Config),
                   beam_com_build:main(D, #{}, #{beams => [{m, beam(m, true)}, {app, beam(app, true)}]})
           end,
    ?assertEqual(m, Main("{escript_emu_args, \"%%! +sbtu -escript main m\\n\"}.\n")),
    ?assertEqual(app, Main("{escript_main_app, app}.\n")),
    %% escript_emu_args wins over escript_main_app, as in rebar3.
    ?assertEqual(m, Main("{escript_main_app, app}.\n{escript_emu_args, \"-escript main m\"}.\n")),
    ?assertEqual(none, Main("{erl_opts, []}.\n")),
    ?assertThrow({error, "the main module ~p is not in ~ts", [other, _]},
                 Main("{escript_main_app, other}.\n")).

main_module() ->
    Beams = #{beams => [{m, beam(m, true)}, {n, beam(n, false)}]},
    ?assertEqual(m, beam_com_build:main("d", #{main => m}, Beams)),
    ?assertThrow({error, "~p does not export main/1", [n]},
                 beam_com_build:main("d", #{main => n}, Beams)),
    ?assertThrow({error, "the main module ~p is not in ~ts", [o, "d"]},
                 beam_com_build:main("d", #{main => o}, Beams)),
    ?assertEqual(none, beam_com_build:main("a.erl", #{}, #{script => true})),
    ?assertThrow({error, "~ts: --main is for application directories", ["a.erl"]},
                 beam_com_build:main("a.erl", #{main => m}, #{script => true})).

with_main() ->
    VmArgs = fun(App) -> proplists:get_value("vm.args", maps:get(config, App)) end,
    ?assertEqual(<<"-noshell\n-s beam_com_script main m\n">>,
                 VmArgs(beam_com_build:with_main(#{config => []}, m))),
    ?assertEqual(<<"+S 1\n-noshell\n-s beam_com_script main m\n">>,
                 VmArgs(beam_com_build:with_main(
                          #{config => [{"vm.args", <<"+S 1\n-noshell\n\n">>}]}, m))).

priv_files(Dir) ->
    Priv = filename:join(Dir, "priv"),
    write(Priv, "data.txt", "data"),
    Run = write(filename:join(Priv, "bin"), "run.sh", "#!/bin/sh\n"),
    ok = file:change_mode(Run, 8#755),
    {Files, Exec} = beam_com_build:priv_files(Priv),
    ?assertEqual([{"bin/run.sh", <<"#!/bin/sh\n">>}, {"data.txt", <<"data">>}], lists:sort(Files)),
    case os:type() of
        {win32, _} -> ok;
        _ -> ?assertEqual(["bin/run.sh"], Exec)
    end,
    ?assertEqual({[], []}, beam_com_build:priv_files(filename:join(Dir, "nopriv"))).

extract() ->
    P1 = [{"run.sh", <<"x">>}],
    P2 = [{"data.txt", <<"y">>}],
    App = #{name => a, vsn => "1.0", priv => P1, priv_exec => ["run.sh"]},
    Deps = [#{name => b, vsn => "2.0", priv => P2, priv_exec => []},
            #{name => c, vsn => "3.0", priv => [], priv_exec => []}],
    H1 = beam_com_build:hash(P1),
    H2 = beam_com_build:hash(P2),
    ?assertEqual([{a, "1.0", H1, ["run.sh"]}], beam_com_build:extract(App, Deps, [])),
    ?assertEqual([{a, "1.0", H1, ["run.sh"]}, {b, "2.0", H2, []}],
                 beam_com_build:extract(App, Deps, [b])),
    ?assertThrow({error, "--extract-priv ~p: the program has no application ~p with a "
                  "priv directory", [c, c]},
                 beam_com_build:extract(App, Deps, [c])),
    ?assertThrow({error, _, [z, z]}, beam_com_build:extract(App, Deps, [z])),
    %% The hash: 16 hex digits; it changes with a name or the content.
    ?assertMatch({match, _}, re:run(H1, "^[0-9a-f]{16}$")),
    ?assertEqual(H1, beam_com_build:hash([{"run.sh", <<"x">>}])),
    ?assertNotEqual(H1, beam_com_build:hash([{"run.sh", <<"z">>}])),
    ?assertNotEqual(H1, beam_com_build:hash([{"run2.sh", <<"x">>}])),
    ?assertEqual(beam_com_build:hash([{"a", <<"1">>}, {"b", <<"2">>}]),
                 beam_com_build:hash([{"b", <<"2">>}, {"a", <<"1">>}])).

with_extract() ->
    X = [{a, "1.0", "0123456789abcdef", ["run.sh"]}],
    Config = fun(App) ->
                     Text = proplists:get_value("sys.config", maps:get(config, App)),
                     {ok, [Terms], _} = erl_scan_parse(iolist_to_binary(Text)),
                     Terms
             end,
    ?assertEqual(#{config => []}, beam_com_build:with_extract(#{config => []}, [])),
    ?assertEqual([{beam_com_script, [{extract, X}]}],
                 Config(beam_com_build:with_extract(#{config => []}, X))),
    ?assertEqual([{app, [{k, v}]}, {beam_com_script, [{extract, X}]}],
                 Config(beam_com_build:with_extract(
                          #{config => [{"sys.config", <<"[{app, [{k, v}]}].\n">>}]}, X))).

%% A module that uses a behaviour and a parse transform of the same
%% application: with warnings_as_errors, the build fails when the
%% behaviour is compiled after it, and the parse transform must exist.
compile_all(Dir) ->
    Src = filename:join(Dir, "order"),
    User = write(Src, "aa_user.erl",
                 "-module(aa_user).\n-behaviour(zz_beh).\n"
                 "-compile({parse_transform, zz_pt}).\n-export([cb/0, f/0]).\n"
                 "cb() -> ok.\nf() -> replaced_by_pt.\n"),
    Beh = write(Src, "zz_beh.erl", "-module(zz_beh).\n-callback cb() -> ok.\n"),
    Pt = write(Src, "zz_pt.erl",
               "-module(zz_pt).\n-export([parse_transform/2]).\n"
               "parse_transform(Forms, _) ->\n"
               "    [case F of {function, L, f, 0, _} ->\n"
               "         {function, L, f, 0, [{clause, L, [], [], [{atom, L, transformed}]}]};\n"
               "     _ -> F end || F <- Forms].\n"),
    ?assertEqual(["zz_beh", "zz_pt"], lists:sort(beam_com_build:first_names(User))),
    ?assertEqual([], beam_com_build:first_names(Beh)),
    Beams = beam_com_build:compile_all([User, Beh, Pt], [warnings_as_errors]),
    ?assertEqual([aa_user, zz_beh, zz_pt], lists:sort([M || {M, _} <- Beams])),
    {aa_user, B} = lists:keyfind(aa_user, 1, Beams),
    {module, aa_user} = code:load_binary(aa_user, "aa_user.beam", B),
    ?assertEqual(transformed, aa_user:f()),
    code:purge(aa_user), code:delete(aa_user),
    %% The temporary directory is not left in the code path.
    ?assertEqual(non_existing, code:which(zz_beh)),
    ?assertEqual(["mod_a"], beam_com_build:first_names(
                              write(Src, "q.erl", "-module(q).\n-behavior('mod_a').\n"))).

%% An application whose code has docs (as the Elixir applications in
%% beam.com), and one without them.
without_docs(Dir) ->
    Root = filename:join(Dir, "docroot"),
    Beam = fun(App, Src) ->
                   Ebin = filename:join([Root, "lib", App ++ "-1.0", "ebin"]),
                   File = write(Dir, "m_" ++ App ++ ".erl", Src),
                   {ok, _, B} = compile:file(File, [binary]),
                   write(Ebin, "m_" ++ App ++ ".beam", B)
           end,
    Beam("withdocs", "-module(m_withdocs).\n-moduledoc \"Docs.\".\n-vsn(\"7\").\n"
         "-export([f/0]).\n-doc \"F.\".\nf() -> ok.\n"),
    Beam("plain", "-module(m_plain).\n-export([f/0]).\nf() -> ok.\n"),
    Base = #{withdocs => #{vsn => "1.0"}, plain => #{vsn => "1.0"}},
    ?assertEqual([], beam_com_build:without_docs([plain], Base, Root)),
    [{Name, Stripped}] = beam_com_build:without_docs([plain, withdocs], Base, Root),
    ?assertEqual("lib/withdocs-1.0/ebin/m_withdocs.beam", Name),
    ?assertMatch({ok, {m_withdocs, [{"Docs", missing_chunk}]}},
                 beam_lib:chunks(Stripped, ["Docs"], [allow_missing_chunks])),
    %% No debug information; the attributes and the line numbers stay.
    ?assertMatch({ok, {m_withdocs, [{debug_info, _}]}},
                 beam_lib:chunks(Stripped, [debug_info], [allow_missing_chunks])),
    ?assertMatch({ok, {m_withdocs, [{"Dbgi", missing_chunk}, {"Line", <<_/binary>>}]}},
                 beam_lib:chunks(Stripped, ["Dbgi", "Line"], [allow_missing_chunks])),
    {module, m_withdocs} = code:load_binary(m_withdocs, "m_withdocs.beam", Stripped),
    ?assertEqual(ok, m_withdocs:f()),
    ?assertEqual("7", proplists:get_value(vsn, m_withdocs:module_info(attributes))),
    code:purge(m_withdocs), code:delete(m_withdocs).

beam(Module, Main) ->
    Exports = case Main of true -> "-export([main/1]).\nmain(_) -> ok.\n";
                  false -> "-export([f/0]).\nf() -> ok.\n"
              end,
    {ok, Tokens, _} = erl_scan:string("-module(" ++ atom_to_list(Module) ++ ").\n" ++ Exports),
    Forms = split_forms(Tokens, [], []),
    {ok, Module, Beam} = compile:forms(Forms, [binary]),
    Beam.

split_forms([], [], Acc) -> lists:reverse(Acc);
split_forms([{dot, _} = Dot | Rest], Cur, Acc) ->
    {ok, Form} = erl_parse:parse_form(lists:reverse([Dot | Cur])),
    split_forms(Rest, [], [Form | Acc]);
split_forms([T | Rest], Cur, Acc) -> split_forms(Rest, [T | Cur], Acc).

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
