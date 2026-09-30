%% Unit tests for beam_com_hex: versions, requirements, rebar.config and
%% rebar.lock, tarballs, the resolution, and fetch/2 with a small HTTP
%% server in place of hex.pm (HEX_API_URL, HEX_MIRROR).
-module(beam_com_hex_tests).

-include_lib("eunit/include/eunit.hrl").

-export([serve/1, stop/1, requests/1, package/5, routes/1]).

v(S) -> {ok, V} = beam_com_hex:parse_version(S), V.

versions_test_() ->
    Sorted = ["0.9.9", "1.0.0-1", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-rc.1",
              "1.0.0", "1.2.0", "1.10.0"],
    Shuffled = ["1.10.0", "1.0.0", "0.9.9", "1.0.0-rc.1", "1.2.0", "1.0.0-alpha.1",
                "1.0.0-alpha", "1.0.0-1"],
    Sort = fun(L) -> lists:sort(fun(A, B) -> beam_com_hex:compare(v(A), v(B)) =/= gt end, L) end,
    [?_assertEqual({ok, {1, 2, 3, [<<"rc">>, 1]}}, beam_com_hex:parse_version("1.2.3-rc.1+build.5")),
     {"the order of semantic versions", ?_assertEqual(Sorted, Sort(Shuffled))},
     ?_assertEqual(eq, beam_com_hex:compare(v("1.0.0+a"), v("1.0.0+b"))),
     [?_assertEqual(error, beam_com_hex:parse_version(S))
      || S <- ["1.0", "1", "a.b.c", "1.0.0-", "1.0.0-a..b", ""]]].

matches_test_() ->
    M = fun(V, R) -> beam_com_hex:matches(v(V), R) end,
    Yes = [{"1.2.3", "1.2.3"}, {"1.2.3", "== 1.2.3"}, {"1.5.0", "~> 1.2"},
           {"1.2.0", "~> 1.2"}, {"1.2.9", "~> 1.2.3"}, {"2.0.0", ">= 1.0.0 and < 3.0.0"},
           {"1.0.0", "~> 0.9 or ~> 1.0"}, {"1.0.1", "!= 1.0.0"}, {"1.0.0", "<= 1.0.0"},
           {"2.0.0-rc.1", "~> 2.0.0-rc.0"}, {"9.9.9", any}],
    No = [{"1.2.4", "1.2.3"}, {"2.0.0", "~> 1.2"}, {"1.3.0", "~> 1.2.3"},
          {"1.1.0", "~> 1.2"}, {"3.0.0", ">= 1.0.0 and < 3.0.0"},
          {"2.0.0-rc.1", "~> 1.0"}, {"2.0.0-rc.1", ">= 1.0.0"},
          {"1.0.0", "> 1.0.0"}, {"1.0.0", "!= 1.0.0"}, {"1.0.0-rc.1", any}],
    [?_assert(M(V, R)) || {V, R} <- Yes] ++ [?_assertNot(M(V, R)) || {V, R} <- No]
        ++ [?_assertEqual(error, beam_com_hex:parse_requirement(R))
            || R <- ["~> 1", ">= x", "1.0", ">= 1.0.0 and"]].

rebar_deps_test_() ->
    D = fun(Deps) -> beam_com_hex:rebar_deps([{deps, Deps}]) end,
    [?_assertEqual([], beam_com_hex:rebar_deps([{erl_opts, []}])),
     ?_assertEqual([{jsx, <<"jsx">>, any}, {cowboy, <<"cowboy">>, "2.13.0"},
                    {x, <<"x_pkg">>, any}, {y, <<"y_pkg">>, "~> 1.0"}],
                   D([jsx, {cowboy, "2.13.0"}, {x, {pkg, x_pkg}},
                      {y, "~> 1.0", {pkg, <<"y_pkg">>}}])),
     {"git is not supported",
      ?_assertThrow({error, "the dependency ~p is not a Hex package (only Hex "
                     "packages are supported, not git)", [g]},
                    D([{g, {git, "https://example.com/g.git", {tag, "1.0"}}}]))},
     {"a bad requirement",
      ?_assertThrow({error, "~p: a bad version requirement: ~ts", [r, "~> x"]},
                    D([{r, "~> x"}]))}].

lock_test_() ->
    {setup, fun tmp/0, fun rm/1,
     fun(Dir) ->
             File = filename:join(Dir, "rebar.lock"),
             Pkgs = [#{name => b, pkg => <<"b_pkg">>, vsn => "0.2.0", level => 1,
                       inner => <<"AA">>, outer => "BB"},
                     #{name => a, pkg => <<"a">>, vsn => "1.1.0", level => 0,
                       inner => <<"CC">>, outer => "DD"}],
             ok = file:write_file(File, beam_com_hex:lock_text(Pkgs)),
             [?_assertEqual(#{a => #{pkg => <<"a">>, vsn => "1.1.0", inner => <<"CC">>, outer => <<"DD">>},
                              b => #{pkg => <<"b_pkg">>, vsn => "0.2.0", inner => <<"AA">>, outer => <<"BB">>}},
                            beam_com_hex:read_lock(File)),
              {"the format of rebar3",
               ?_assertMatch({ok, [{<<"1.2.0">>, [{<<"a">>, {pkg, <<"a">>, <<"1.1.0">>}, 0},
                                                  {<<"b">>, {pkg, <<"b_pkg">>, <<"0.2.0">>}, 1}]},
                                   [{pkg_hash, [_, _]}, {pkg_hash_ext, [_, _]}]]},
                             file:consult(File))},
              ?_assertEqual(#{}, beam_com_hex:read_lock(filename:join(Dir, "none.lock")))]
     end}.

%%% Tarballs.

%% A Hex tarball (version 3): Files in contents.tar.gz, Reqs as
%% [{Dep, Requirement}].
package(Name, Vsn, Files, Reqs, Tools) ->
    Tmp = tmp(),
    try
        ContentsFile = filename:join(Tmp, "contents.tar.gz"),
        ok = erl_tar:create(ContentsFile, [{F, iolist_to_binary(C)} || {F, C} <- Files],
                            [compressed]),
        {ok, Contents} = file:read_file(ContentsFile),
        Meta = iolist_to_binary(
                 [io_lib:format("~tp.~n", [T])
                  || T <- [{<<"name">>, Name}, {<<"version">>, list_to_binary(Vsn)},
                           {<<"app">>, Name}, {<<"build_tools">>, Tools},
                           {<<"requirements">>,
                            [{D, [{<<"app">>, D}, {<<"optional">>, false},
                                  {<<"requirement">>, list_to_binary(R)},
                                  {<<"repository">>, <<"hexpm">>}]} || {D, R} <- Reqs]}]]),
        hex_tar(Meta, Contents)
    after
        rm(Tmp)
    end.

%% A Hex tarball of this metadata and contents, with its checksum.
hex_tar(Meta, Contents) ->
    Tmp = tmp(),
    try
        Version = <<"3">>,
        Sum = binary:encode_hex(crypto:hash(sha256, [Version, Meta, Contents])),
        TarFile = filename:join(Tmp, "p.tar"),
        ok = erl_tar:create(TarFile, [{"VERSION", Version}, {"CHECKSUM", Sum},
                                      {"metadata.config", Meta},
                                      {"contents.tar.gz", Contents}], []),
        {ok, Tar} = file:read_file(TarFile),
        Tar
    after
        rm(Tmp)
    end.

app_files(Name, Vsn, Deps, Code) ->
    N = binary_to_list(Name),
    [{"src/" ++ N ++ ".app.src",
      io_lib:format("{application, ~s, [{vsn, ~p}, {applications, [kernel, stdlib~s]}]}.~n",
                    [N, Vsn, [", " ++ binary_to_list(D) || D <- Deps]])},
     {"src/" ++ N ++ ".erl", ["-module(", N, ").\n-export([f/0]).\n", Code]}].

unpack_test_() ->
    {setup, fun tmp/0, fun rm/1,
     fun(Dir) ->
             Tar = package(<<"u">>, "1.0.0", app_files(<<"u">>, "1.0.0", [], "f() -> u.\n"),
                           [], [<<"rebar3">>]),
             Out = filename:join(Dir, "u-1.0.0"),
             [{"contents and checksums",
               fun() ->
                       #{inner := Inner} = beam_com_hex:unpack(Tar, undefined, Out),
                       ?assert(filelib:is_regular(filename:join([Out, "src", "u.erl"]))),
                       ?assertMatch(#{}, beam_com_hex:unpack(Tar, string:lowercase(Inner), Out))
               end},
              {"a checksum of rebar.lock that does not match",
               ?_assertThrow({error, "~ts: the checksum does not match rebar.lock", [Out]},
                             beam_com_hex:unpack(Tar, <<"00">>, Out))},
              {"a changed file",
               fun() ->
                       {ok, Files} = erl_tar:extract({binary, Tar}, [memory]),
                       Bad = lists:keystore("metadata.config", 1, Files,
                                            {"metadata.config", <<"{<<\"x\">>, 1}.\n">>}),
                       F = filename:join(Dir, "bad.tar"),
                       ok = erl_tar:create(F, Bad, []),
                       {ok, BadTar} = file:read_file(F),
                       ?assertThrow({error, "~ts: the inner checksum does not match", [Out]},
                                    beam_com_hex:unpack(BadTar, undefined, Out))
               end},
              {"not a tarball",
               ?_assertThrow({error, "~ts: not a Hex tarball", [Out]},
                             beam_com_hex:unpack(<<"junk">>, undefined, Out))},
              {"a link in the contents",
               fun() ->
                       Src = filename:join(Dir, "link-src"),
                       ok = filelib:ensure_path(Src),
                       ok = file:make_symlink("/etc/passwd", filename:join(Src, "evil")),
                       C = filename:join(Dir, "link.tar.gz"),
                       {ok, T} = erl_tar:open(C, [write, compressed]),
                       ok = erl_tar:add(T, filename:join(Src, "evil"), "evil", []),
                       ok = erl_tar:close(T),
                       {ok, Contents} = file:read_file(C),
                       Bad = hex_tar(<<"{<<\"name\">>, <<\"u\">>}.\n">>, Contents),
                       ?assertThrow({error, "~ts: the package has a file that is not a "
                                     "regular file: ~ts", [Out, "evil"]},
                                    beam_com_hex:unpack(Bad, undefined, Out))
               end},
              {"a name out of the package",
               fun() ->
                       C = filename:join(Dir, "up.tar.gz"),
                       {ok, T} = erl_tar:open(C, [write, compressed]),
                       ok = erl_tar:add(T, <<"x">>, "../up", []),
                       ok = erl_tar:close(T),
                       {ok, Contents} = file:read_file(C),
                       Bad = hex_tar(<<"{<<\"name\">>, <<\"u\">>}.\n">>, Contents),
                       ?assertThrow({error, "~ts: the package has an unsafe file name: ~ts",
                                     [Out, "../up"]},
                                    beam_com_hex:unpack(Bad, undefined, Out)),
                       ?assertNot(filelib:is_file(filename:join(Dir, "up")))
               end}]
     end}.

%% metadata.config: the same terms as file:consult/1, with no new atom.
consult_test_() ->
    Terms = [{<<"name">>, <<"pkg">>},
             {<<"description">>, <<"Été, \"quoted\" \\ and\ttab"/utf8>>},
             {<<"build_tools">>, [<<"rebar3">>, <<"mix">>]},
             {<<"requirements">>,
              [[{<<"name">>, <<"jason">>}, {<<"app">>, <<"jason">>},
                {<<"optional">>, false}, {<<"requirement">>, <<"~> 1.0">>}]]},
             {<<"files">>, [<<"lib">>, <<>>]},
             {<<"count">>, -12},
             {"a string", {nested, {tuple, []}}}],
    Text = unicode:characters_to_binary([io_lib:format("~tp.~n", [T]) || T <- Terms]),
    [{"the terms of io_lib:format ~tp",
      ?_assertEqual(Terms, beam_com_hex:consult(Text))},
     {"comments, escapes and segments",
      ?_assertEqual([<<"a\nb", 195, 169, "c">>, "x\x{e9}y", [true, false]],
                    beam_com_hex:consult(<<"% a comment\n<<\"a\\nb\", \"\\351\"/utf8, "
                                           "\"c\">>.\n\"x\\x{e9}y\" .\n[true,false].">>))},
     {"an atom that does not exist is refused, and not made",
      fun() ->
              Name = "beam_com_hex_test_no_such_atom_" ++ integer_to_list(erlang:unique_integer([positive])),
              Count = erlang:system_info(atom_count),
              ?assertThrow({error, "metadata.config is not a list of terms", []},
                           beam_com_hex:consult(list_to_binary(["{<<\"x\">>, ", Name, "}."]))),
              ?assertThrow({error, "metadata.config is not a list of terms", []},
                           beam_com_hex:consult(list_to_binary(["'", Name, " quoted'."]))),
              ?assertEqual(Count, erlang:system_info(atom_count))
      end},
     {"deep nesting",
      ?_assertThrow({error, "metadata.config is not a list of terms", []},
                    beam_com_hex:consult(list_to_binary([lists:duplicate(100, $[),
                                                         lists:duplicate(100, $]), "."])))},
     {"text that is not a term",
      [?_assertThrow({error, "metadata.config is not a list of terms", []},
                     beam_com_hex:consult(B))
       || B <- [<<"{a">>, <<"fun() -> ok end.">>, <<"1 + 2.">>, <<"<<1>>.">>, <<"x">>]]},
     {"not UTF-8",
      ?_assertThrow({error, "metadata.config is not UTF-8", []},
                    beam_com_hex:consult(<<255, 254>>))}].

meta_requirements_test_() ->
    Req = fun(App) -> {<<"p">>, [{<<"app">>, App}, {<<"requirement">>, <<"~> 1.0">>}]} end,
    [{"an app name",
      ?_assertEqual([{p_app, <<"p">>, "~> 1.0"}],
                    beam_com_hex:meta_requirements([{<<"requirements">>, [Req(<<"p_app">>)]}]))},
     {"not an app name",
      [?_assertThrow({error, _, _},
                     beam_com_hex:meta_requirements([{<<"requirements">>, [Req(A)]}]))
       || A <- [<<"Elixir.X">>, <<"1a">>, <<"a-b">>, <<>>, 42]]},
     {"too many requirements",
      ?_assertThrow({error, "a package has more than ~b requirements", [256]},
                    beam_com_hex:meta_requirements(
                      [{<<"requirements">>, lists:duplicate(257, Req(<<"p">>))}]))}].

%%% Resolution, with a registry in memory.

registry(Packages) ->
    #{versions => fun(P) -> [V || {Q, V, _} <- Packages, Q =:= P] end,
      release => fun(P, V) ->
                         {_, _, Reqs} = lists:keyfind(V, 2, [X || {Q, _, _} = X <- Packages, Q =:= P]),
                         #{requirements => [{binary_to_atom(D), D, R} || {D, R} <- Reqs]}
                 end,
      tarball => fun(_, _) -> error(not_used) end}.

resolve_test_() ->
    Reg = registry([{<<"a">>, "1.0.0", []}, {<<"a">>, "1.1.0", [{<<"b">>, "~> 0.2.0"}]},
                    {<<"a">>, "2.0.0", []}, {<<"a">>, "2.1.0-rc.1", []},
                    {<<"b">>, "0.2.0", []}, {<<"b">>, "0.2.5", []}, {<<"b">>, "0.3.0", []},
                    {<<"c">>, "1.0.0", [{<<"b">>, "~> 0.3"}]}]),
    R = fun(Deps, Lock) ->
                maps:map(fun(_, #{vsn := V}) -> V end, beam_com_hex:resolve(Deps, Lock, Reg))
        end,
    [{"the highest version that matches, and its deps",
      ?_assertEqual(#{a => "1.1.0", b => "0.2.5"}, R([{a, <<"a">>, "~> 1.0"}], #{}))},
     {"no pre-release without a pre-release in the requirement",
      ?_assertEqual(#{a => "2.0.0"}, R([{a, <<"a">>, any}], #{}))},
     {"the locked version, when it matches",
      ?_assertEqual(#{a => "1.1.0", b => "0.2.0"},
                    R([{a, <<"a">>, "~> 1.0"}], #{b => #{pkg => <<"b">>, vsn => "0.2.0"}}))},
     {"a conflict",
      ?_assertThrow({error, "version conflict: ~p ~ts (needed by ~ts) does not match ~ts "
                     "(needed by ~ts); give a version in rebar.config",
                     [b, "0.2.5", "a 1.1.0", "~> 0.3", "c 1.0.0"]},
                    R([{a, <<"a">>, "~> 1.0"}, {c, <<"c">>, any}], #{}))},
     {"no version",
      ?_assertThrow({error, "no version of the Hex package ~ts matches ~ts (for ~p)",
                     [<<"a">>, "~> 3.0", a]},
                    R([{a, <<"a">>, "~> 3.0"}], #{}))}].

%%% fetch/2 with a server in place of hex.pm.

%% The routes of the server for packages [{Name, Vsn, Reqs, Tar}]
%% (Tools in the API: rebar3).
routes(Packages) ->
    Names = lists:usort([N || {N, _, _, _} <- Packages]),
    maps:from_list(
      [{"/api/packages/" ++ binary_to_list(N),
        json:encode(#{<<"releases">> => [#{<<"version">> => list_to_binary(V)}
                                         || {M, V, _, _} <- Packages, M =:= N]})}
       || N <- Names]
      ++ [{"/api/packages/" ++ binary_to_list(N) ++ "/releases/" ++ V,
           json:encode(#{<<"checksum">> => string:lowercase(binary:encode_hex(crypto:hash(sha256, Tar))),
                         <<"meta">> => #{<<"build_tools">> => [<<"rebar3">>]},
                         <<"requirements">> =>
                             maps:from_list([{D, #{<<"app">> => D, <<"optional">> => false,
                                                   <<"requirement">> => list_to_binary(R)}}
                                             || {D, R} <- Reqs])})}
          || {N, V, Reqs, Tar} <- Packages]
      ++ [{"/repo/tarballs/" ++ binary_to_list(N) ++ "-" ++ V ++ ".tar", Tar}
          || {N, V, _, Tar} <- Packages]).

%% A small HTTP/1.1 server: GET of the paths of Routes, one request for
%% each connection. The result is {Pid, Port}.
serve(Routes) ->
    Self = self(),
    Pid = spawn(fun() ->
                        {ok, L} = gen_tcp:listen(0, [binary, {ip, {127, 0, 0, 1}},
                                                     {active, false}, {reuseaddr, true}]),
                        {ok, Port} = inet:port(L),
                        Self ! {self(), Port},
                        Server = self(),
                        spawn_link(fun() -> accept(L, Routes, Server) end),
                        server_loop([])
                end),
    receive {Pid, Port} -> {Pid, Port} end.

server_loop(Log) ->
    receive
        {request, Path} -> server_loop([Path | Log]);
        {requests, From} -> From ! {self(), lists:reverse(Log)}, server_loop(Log);
        stop -> exit(normal)
    end.

accept(L, Routes, Server) ->
    case gen_tcp:accept(L) of
        {ok, S} ->
            spawn(fun() -> answer(S, Routes, Server) end),
            accept(L, Routes, Server);
        {error, _} -> ok
    end.

answer(S, Routes, Server) ->
    {ok, Request} = read_head(S, <<>>),
    [Line | _] = binary:split(Request, <<"\r\n">>),
    [<<"GET">>, Path | _] = binary:split(Line, <<" ">>, [global]),
    P = binary_to_list(Path),
    Server ! {request, P},
    {Status, Body} = case Routes of
                         #{P := B} -> {"200 OK", iolist_to_binary(B)};
                         _ -> {"404 Not Found", <<"not found">>}
                     end,
    ok = gen_tcp:send(S, [<<"HTTP/1.1 ">>, Status, <<"\r\nContent-Length: ">>,
                          integer_to_list(byte_size(Body)),
                          <<"\r\nConnection: close\r\n\r\n">>, Body]),
    gen_tcp:close(S).

read_head(S, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        nomatch ->
            {ok, More} = gen_tcp:recv(S, 0, 5000),
            read_head(S, <<Acc/binary, More/binary>>);
        _ -> {ok, Acc}
    end.

requests(Pid) ->
    Pid ! {requests, self()},
    receive {Pid, Log} -> Log end.

stop(Pid) -> Pid ! stop.

fetch_test_() ->
    {setup,
     fun() ->
             Dir = tmp(),
             B = fun(V) -> package(<<"beta">>, V, app_files(<<"beta">>, V, [], "f() -> beta.\n"),
                                   [], [<<"rebar3">>]) end,
             A11 = package(<<"alpha">>, "1.1.0",
                           app_files(<<"alpha">>, "1.1.0", [<<"beta">>], "f() -> beta:f().\n"),
                           [{<<"beta">>, ">= 0.2.0"}], [<<"rebar3">>]),
             Pkgs = [{<<"alpha">>, "1.0.0", [], B("9.9.9")},
                     {<<"alpha">>, "1.1.0", [{<<"beta">>, ">= 0.2.0"}], A11},
                     {<<"alpha">>, "2.0.0", [], B("9.9.9")},
                     {<<"beta">>, "0.2.0", [], B("0.2.0")},
                     {<<"beta">>, "0.3.0-rc.1", [], B("0.3.0-rc.1")},
                     {<<"elixir_only">>, "1.0.0", [], B("1.0.0")}],
             {Pid, Port} = serve(routes(Pkgs)),
             Env = [{"HEX_API_URL", "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/api"},
                    {"HEX_MIRROR", "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/repo"},
                    {"BEAM_COM_CACHE", filename:join(Dir, "cache")}],
             [os:putenv(K, V) || {K, V} <- Env],
             {Dir, Pid}
     end,
     fun({Dir, Pid}) ->
             stop(Pid),
             [os:unsetenv(K) || K <- ["HEX_API_URL", "HEX_MIRROR", "BEAM_COM_CACHE"]],
             rm(Dir)
     end,
     fun({Dir, Pid}) ->
             App = filename:join(Dir, "app"),
             ok = filelib:ensure_path(App),
             ok = file:write_file(filename:join(App, "rebar.config"),
                                  "{deps, [{alpha, \"~> 1.0\"}]}.\n"),
             Lib = fun(N) -> filename:join(Dir, "lib" ++ integer_to_list(N)) end,
             [{"resolve, download, check and unpack; write rebar.lock",
               fun() ->
                       Got = silent(fun() -> beam_com_hex:fetch(App, Lib(1)) end),
                       ?assertEqual([#{name => beta, vsn => "0.2.0", dir => filename:join(Lib(1), "beta-0.2.0")},
                                     #{name => alpha, vsn => "1.1.0", dir => filename:join(Lib(1), "alpha-1.1.0")}],
                                    Got),
                       ?assert(filelib:is_regular(filename:join([Lib(1), "alpha-1.1.0", "src", "alpha.erl"]))),
                       {ok, [{_, Entries}, _]} = file:consult(filename:join(App, "rebar.lock")),
                       ?assertEqual([{<<"alpha">>, {pkg, <<"alpha">>, <<"1.1.0">>}, 0},
                                     {<<"beta">>, {pkg, <<"beta">>, <<"0.2.0">>}, 1}], Entries)
               end},
              {"with rebar.lock and the cache: no request",
               fun() ->
                       Before = length(requests(Pid)),
                       Got = beam_com_hex:fetch(App, Lib(2)),
                       ?assertEqual([beta, alpha], [N || #{name := N} <- Got]),
                       ?assertEqual(Before, length(requests(Pid)))
               end},
              {"a tarball in the cache that does not match is downloaded again",
               fun() ->
                       Cache = filename:join([Dir, "cache", "hex", "tarballs", "beta-0.2.0.tar"]),
                       ok = file:write_file(Cache, <<"changed">>),
                       _ = beam_com_hex:fetch(App, Lib(3)),
                       ?assertEqual("/repo/tarballs/beta-0.2.0.tar", lists:last(requests(Pid)))
               end},
              {"a package that is not on the server",
               fun() ->
                       NoApp = filename:join(Dir, "noapp"),
                       ok = filelib:ensure_path(NoApp),
                       ok = file:write_file(filename:join(NoApp, "rebar.config"),
                                            "{deps, [nosuch]}.\n"),
                       ?assertThrow({error, "~ts: not found", [_]},
                                    beam_com_hex:fetch(NoApp, Lib(4)))
               end}]
     end}.

%%% Helpers

tmp() ->
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; T -> T end,
    Dir = filename:join(Base, "beam_com_hex_tests." ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_path(Dir),
    Dir.

rm(Dir) -> file:del_dir_r(Dir).

silent(F) ->
    {ok, Dev} = file:open("/dev/null", [write]),
    Old = group_leader(),
    group_leader(Dev, self()),
    try F() after group_leader(Old, self()), file:close(Dev) end.
