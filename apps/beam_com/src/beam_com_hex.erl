%% Hex packages for "beam.com build": the deps of rebar.config, with the
%% versions of rebar.lock, fetched from the Hex repository.
%%
%% - The deps: Name, {Name, Requirement}, {Name, {pkg, Package}} and
%%   {Name, Requirement, {pkg, Package}}. A requirement is a version
%%   ("1.2.3", this version only) or a Hex requirement ("~> 1.2",
%%   ">= 1.0.0 and < 2.0.0", ... or ...). Git and other sources are not
%%   supported.
%% - rebar.lock: when it has all the deps of rebar.config, its versions
%%   are used, and nothing is resolved. Otherwise the versions are
%%   resolved (the highest version that matches, the locked version when
%%   it matches), and rebar.lock is written.
%% - The Hex API (HEX_API_URL, default https://hex.pm/api) gives the
%%   versions of a package and the checksum of a release. The repository
%%   (HEX_MIRROR, default https://repo.hex.pm) gives the tarballs. The
%%   tarballs are kept in the cache (filename:basedir(user_cache,
%%   "beam.com")), so a build with a lock file and a full cache does not
%%   use the network.
%% - Each tarball is checked: the outer checksum (SHA-256 of the file:
%%   pkg_hash_ext in rebar.lock, or the checksum of the API) and the
%%   inner checksum (the CHECKSUM file, and pkg_hash in rebar.lock).
-module(beam_com_hex).

-export([fetch/2, fetch/4]).

-ifdef(TEST).
-export([parse_version/1, compare/2, parse_requirement/1, matches/2,
         rebar_deps/1, read_lock/1, read_lock/2, lock_text/1, lock_text/2,
         unpack/3, resolve/3,
         registry/0]).
-endif.

-define(API, "https://hex.pm/api").
-define(REPO, "https://repo.hex.pm").

%% Fetch the deps of the application in Dir, and unpack each one into
%% LibDir/NAME-VSN. The result: the packages in the order to compile
%% them (a package after the packages that it needs), as
%% #{name := atom(), vsn := string(), dir := string()}.
fetch(Dir, LibDir) ->
    fetch(Dir, LibDir, rebar_deps(rebar_config(Dir)), rebar).

%% The same with the deps of a Mix project (Format mix: mix.lock) or of
%% rebar.config (rebar: rebar.lock).
fetch(_Dir, _LibDir, [], _Format) ->
    [];
fetch(Dir, LibDir, Deps, Format) ->
    fetch(Dir, LibDir, Deps, Format, registry()).

fetch(Dir, LibDir, Deps, Format, Registry) ->
    LockFile = filename:join(Dir, case Format of
                                      rebar -> "rebar.lock";
                                      mix -> "mix.lock"
                                  end),
    Lock = read_lock(Format, LockFile),
    Locked = [N || {N, _, _} <- Deps, is_map_key(N, Lock)],
    {Chosen, Resolved} = case length(Locked) =:= length(Deps) of
                             true -> {from_lock(Lock), false};
                             false -> {resolve(Deps, Lock, Registry), true}
                         end,
    Unpacked = [unpack_package(P, LibDir, Registry) || P <- maps:values(Chosen)],
    Resolved andalso write_lock(Format, LockFile, Chosen, Unpacked),
    order(Unpacked).

rebar_config(Dir) ->
    case file:consult(filename:join(Dir, "rebar.config")) of
        {ok, Terms} -> Terms;
        {error, enoent} -> [];
        {error, Reason} ->
            throw({error, "~ts/rebar.config: ~ts",
                   [Dir, file:format_error(Reason)]})
    end.

%%% The deps of rebar.config: [{Name, Package, Requirement}], with Name
%%% an atom, Package a binary and Requirement a string or any.

rebar_deps(Terms) ->
    [dep(D) || D <- proplists:get_value(deps, Terms, [])].

dep(Name) when is_atom(Name) -> {Name, atom_to_binary(Name), any};
dep({Name, Req}) when is_atom(Name), is_list(Req); is_atom(Name), is_binary(Req) ->
    {Name, atom_to_binary(Name), requirement(Name, Req)};
dep({Name, {pkg, Pkg}}) when is_atom(Name) ->
    {Name, to_binary(Pkg), any};
dep({Name, Req, {pkg, Pkg}}) when is_atom(Name) ->
    {Name, to_binary(Pkg), requirement(Name, Req)};
dep(Dep) when is_tuple(Dep), is_atom(element(1, Dep)) ->
    throw({error, "the dependency ~p is not a Hex package (only Hex "
           "packages are supported, not git)", [element(1, Dep)]});
dep(Dep) ->
    throw({error, "rebar.config: a bad dependency: ~p", [Dep]}).

requirement(Name, Req) ->
    String = unicode:characters_to_list(Req),
    case parse_requirement(String) of
        {ok, _} -> String;
        error -> throw({error, "~p: a bad version requirement: ~ts", [Name, String]})
    end.

to_binary(A) when is_atom(A) -> atom_to_binary(A);
to_binary(S) -> unicode:characters_to_binary(S).

%%% Versions (semantic versions, as Hex compares them).

%% "1.2.3-rc.1+build" -> {ok, {1, 2, 3, [<<"rc">>, 1]}}. The build
%% part is not compared.
parse_version(String) ->
    try
        [Main | _] = string:split(to_list(String), "+"),
        {Core, Pre} = case string:split(Main, "-") of
                          [C] -> {C, []};
                          [C, P] -> {C, [pre_part(X) || X <- string:split(P, ".", all)]}
                      end,
        Parts = string:split(Core, ".", all),
        [Major, Minor, Patch] = [list_to_integer(X) || X <- Parts, digits(X)],
        3 = length(Parts),
        {ok, {Major, Minor, Patch, Pre}}
    catch
        error:_ -> error
    end.

digits(X) -> X =/= "" andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end, X).

pre_part("") -> error(empty);
pre_part(X) ->
    case digits(X) of
        true -> list_to_integer(X);
        false -> list_to_binary(X)
    end.

%% compare(A, B): lt, eq or gt. A release is higher than its
%% pre-releases; in a pre-release, numbers are lower than words.
compare({Ma, Mi, Pa, PreA}, {Ma, Mi, Pa, PreB}) -> compare_pre(PreA, PreB);
compare({A1, A2, A3, _}, {B1, B2, B3, _}) when {A1, A2, A3} < {B1, B2, B3} -> lt;
compare(_, _) -> gt.

compare_pre([], []) -> eq;
compare_pre([], _) -> gt;
compare_pre(_, []) -> lt;
compare_pre(A, B) -> compare_ids(A, B).

compare_ids([], []) -> eq;
compare_ids([], _) -> lt;
compare_ids(_, []) -> gt;
compare_ids([X | A], [X | B]) -> compare_ids(A, B);
compare_ids([X | _], [Y | _]) when is_integer(X), is_binary(Y) -> lt;
compare_ids([X | _], [Y | _]) when is_binary(X), is_integer(Y) -> gt;
compare_ids([X | _], [Y | _]) when X < Y -> lt;
compare_ids(_, _) -> gt.

%%% Requirements: "~> 1.2", ">= 1.0.0 and < 2.0.0", "1.2.3", ... or ...
%%% -> {ok, [[{Op, Version}]]}: a list of alternatives, each a list of
%%% clauses that must all match.

parse_requirement(String) ->
    try
        Alts = [[clause(string:trim(C)) || C <- split_words(A, " and ")]
                || A <- split_words(string:trim(String), " or ")],
        {ok, expand_pessimistic(Alts)}
    catch
        throw:bad -> error
    end.

split_words(String, Sep) ->
    string:split(String, Sep, all).

clause(String) ->
    {Op, Rest} = operator(String),
    Vsn = string:trim(Rest),
    case Op of
        '~>' ->
            case string:split(Vsn, ".", all) of
                [_, _] -> {'~>', version(Vsn ++ ".0"), 2};
                [_, _, _ | _] -> {'~>', version(Vsn), 3};
                _ -> throw(bad)
            end;
        _ ->
            {Op, version(Vsn)}
    end.

operator("==" ++ R) -> {'==', R};
operator("!=" ++ R) -> {'!=', R};
operator(">=" ++ R) -> {'>=', R};
operator("<=" ++ R) -> {'<=', R};
operator("~>" ++ R) -> {'~>', R};
operator(">" ++ R) -> {'>', R};
operator("<" ++ R) -> {'<', R};
operator(R) -> {'==', R}.

version(String) ->
    case parse_version(String) of
        {ok, V} -> V;
        error -> throw(bad)
    end.

%% "~> 1.2" is ">= 1.2.0 and < 2.0.0"; "~> 1.2.3" is ">= 1.2.3 and
%% < 1.3.0".
expand_pessimistic(Alts) ->
    [[[C || C <- expand(Clause)] || Clause <- Alt] || Alt <- Alts].

expand({'~>', {Ma, Mi, Pa, Pre}, 2}) ->
    [{'>=', {Ma, Mi, Pa, Pre}}, {'<', {Ma + 1, 0, 0, [0]}}];
expand({'~>', {Ma, Mi, Pa, Pre}, 3}) ->
    [{'>=', {Ma, Mi, Pa, Pre}}, {'<', {Ma, Mi + 1, 0, [0]}}];
expand(Clause) ->
    [Clause].

%% matches(Version, Requirement): the version matches one alternative.
%% A pre-release matches only a requirement that names a pre-release.
matches({_, _, _, Pre}, any) -> Pre =:= [];
matches(Version, Req) when is_list(Req) ->
    {ok, Alts} = parse_requirement(Req),
    lists:any(fun(Alt) -> match_alt(Version, lists:append(Alt)) end, Alts).

match_alt({_, _, _, Pre} = V, Clauses) ->
    AllowPre = Pre =:= [] orelse
        lists:any(fun({_, {_, _, _, P}}) -> P =/= [] andalso P =/= [0] end, Clauses),
    AllowPre andalso lists:all(fun(C) -> match_clause(V, C) end, Clauses).

match_clause(V, {'==', W}) -> compare(V, W) =:= eq;
match_clause(V, {'!=', W}) -> compare(V, W) =/= eq;
match_clause(V, {'>=', W}) -> compare(V, W) =/= lt;
match_clause(V, {'<=', W}) -> compare(V, W) =/= gt;
match_clause(V, {'>', W}) -> compare(V, W) =:= gt;
match_clause(V, {'<', W}) -> compare(V, W) =:= lt.

%%% rebar.lock: #{Name => #{pkg, vsn, inner, outer}}, Name an atom.

read_lock(File) ->
    read_lock(rebar, File).

%% mix.lock: %{"name" => {:hex, :package, "vsn", "inner", managers, deps,
%% "hexpm", "outer"}}, read with the Elixir parser.
read_lock(mix, File) ->
    case filelib:is_regular(File) of
        false -> #{};
        true ->
            {Map, _} = 'Elixir.Code':eval_file(unicode:characters_to_binary(File)),
            maps:from_list(
              [case Entry of
                   {hex, Pkg, Vsn, Inner, _Managers, _Deps, _Repo, Outer} ->
                       {binary_to_atom(Name),
                        #{pkg => atom_to_binary(Pkg), vsn => binary_to_list(Vsn),
                          inner => Inner, outer => Outer}};
                   _ ->
                       throw({error, "mix.lock: ~ts is not a Hex package (only Hex "
                              "packages are supported)", [Name]})
               end || Name := Entry <- Map])
    end;
read_lock(rebar, File) ->
    case file:consult(File) of
        {ok, [{_LockVsn, Entries} | Rest]} -> lock_map(Entries, Rest);
        {ok, [Entries | Rest]} when is_list(Entries) -> lock_map(Entries, Rest);
        {ok, []} -> #{};
        {error, enoent} -> #{};
        {error, Reason} ->
            throw({error, "~ts: ~ts", [File, file:format_error(Reason)]})
    end.

lock_map(Entries, Rest) ->
    Hashes = case Rest of
                 [H | _] when is_list(H) -> H;
                 _ -> []
             end,
    Inner = proplists:get_value(pkg_hash, Hashes, []),
    Outer = proplists:get_value(pkg_hash_ext, Hashes, []),
    maps:from_list(
      [case Source of
           {pkg, Pkg, Vsn} ->
               {binary_to_atom(Name),
                #{pkg => Pkg, vsn => binary_to_list(Vsn),
                  inner => proplists:get_value(Name, Inner),
                  outer => proplists:get_value(Name, Outer)}};
           {pkg, Pkg, Vsn, _Repo} ->
               {binary_to_atom(Name),
                #{pkg => Pkg, vsn => binary_to_list(Vsn),
                  inner => proplists:get_value(Name, Inner),
                  outer => proplists:get_value(Name, Outer)}};
           _ ->
               throw({error, "rebar.lock: ~ts is not a Hex package (only Hex "
                      "packages are supported)", [Name]})
       end || {Name, Source, _Level} <- Entries]).

from_lock(Lock) ->
    maps:map(fun(Name, P) -> P#{name => Name} end, Lock).

%% The text of rebar.lock (the format of rebar3), from the unpacked
%% packages.
lock_text(Packages) ->
    Sorted = lists:keysort(1, [{atom_to_binary(N), P} || #{name := N} = P <- Packages]),
    Entries = [{Name, {pkg, Pkg, list_to_binary(Vsn)}, Level}
               || {Name, #{pkg := Pkg, vsn := Vsn, level := Level}} <- Sorted],
    Hashes = [{pkg_hash, [{Name, iolist_to_binary(I)} || {Name, #{inner := I}} <- Sorted]},
              {pkg_hash_ext, [{Name, iolist_to_binary(O)} || {Name, #{outer := O}} <- Sorted]}],
    io_lib:format("~tp.~n~tp.~n", [{<<"1.2.0">>, Entries}, Hashes]).

%% The text of mix.lock, in the format of Mix (Kernel.inspect/2 of the
%% map). The deps of an entry are the requirements of the package.
lock_text(mix, Packages) ->
    Map = maps:from_list(
            [{atom_to_binary(N),
              {hex, binary_to_atom(Pkg), list_to_binary(Vsn),
               string:lowercase(iolist_to_binary(I)),
               [binary_to_atom(T) || T <- Tools],
               [{DN, list_to_binary(DR), [{hex, binary_to_atom(DP)}, {repo, <<"hexpm">>},
                                          {optional, false}]}
                || {DN, DP, DR} <- Reqs],
               <<"hexpm">>, string:lowercase(iolist_to_binary(O))}}
             || #{name := N, pkg := Pkg, vsn := Vsn, inner := I, outer := O,
                  tools := Tools, reqs := Reqs} <- Packages]),
    ['Elixir.Kernel':inspect(Map, [{pretty, true}, {limit, infinity},
                                   {printable_limit, infinity}]), "\n"];
lock_text(rebar, Packages) ->
    lock_text(Packages).

write_lock(Format, File, Chosen, Unpacked) ->
    Levels = levels(Chosen, Unpacked),
    Text = lock_text(Format, [P#{level => maps:get(N, Levels)} || #{name := N} = P <- Unpacked]),
    case file:write_file(File, Text) of
        ok -> io:format("beam.com: wrote ~ts~n", [File]);
        {error, Reason} ->
            throw({error, "~ts: ~ts", [File, file:format_error(Reason)]})
    end.

%% The level of each package in rebar.lock: 0 for the deps of
%% rebar.config, 1 for their deps, and so on.
levels(Chosen, Unpacked) ->
    Needs = maps:from_list([{N, R} || #{name := N, requires := R} <- Unpacked]),
    Top = [N || N := #{top := true} <- Chosen],
    levels(Top, 0, Needs, #{}).

levels([], _, _, Acc) -> Acc;
levels(Names, L, Needs, Acc) ->
    New = [N || N <- lists:usort(Names), not is_map_key(N, Acc)],
    Acc1 = maps:merge(Acc, maps:from_list([{N, L} || N <- New])),
    Next = lists:append([maps:get(N, Needs, []) || N <- New]),
    levels(Next, L + 1, Needs, Acc1).

%%% Resolution: the highest version of each package that matches all the
%%% requirements seen so far (the locked version first, when it
%%% matches). There is no backtracking: a conflict is an error, with the
%%% two requirements, and a version in rebar.config can solve it.

resolve(Deps, Lock, Registry) ->
    Queue = [{Name, Pkg, Req, "rebar.config", true} || {Name, Pkg, Req} <- Deps],
    resolve(Queue, Lock, Registry, #{}).

resolve([], _Lock, _Registry, Chosen) ->
    Chosen;
resolve([{Name, Pkg, Req, From, Top} | Rest], Lock, Registry, Chosen) ->
    case Chosen of
        #{Name := #{vsn := Vsn, from := Other} = P} ->
            {ok, V} = parse_version(Vsn),
            matches(V, Req) orelse
                throw({error, "version conflict: ~p ~ts (needed by ~ts) does not "
                       "match ~ts (needed by ~ts); give a version in rebar.config",
                       [Name, Vsn, Other, req_text(Req), From]}),
            resolve(Rest, Lock, Registry,
                    Chosen#{Name := P#{top => Top orelse maps:get(top, P)}});
        _ ->
            Vsn = choose(Name, Pkg, Req, maps:get(Name, Lock, none), Registry),
            #{requirements := Requires} = Info = (maps:get(release, Registry))(Pkg, Vsn),
            P = #{name => Name, pkg => Pkg, vsn => Vsn, from => From, top => Top,
                  outer => maps:get(checksum, Info, undefined),
                  inner => undefined},
            Next = [{N, NPkg, NReq, atom_to_list(Name) ++ " " ++ Vsn, false}
                    || {N, NPkg, NReq} <- Requires],
            resolve(Rest ++ Next, Lock, Registry, Chosen#{Name => P})
    end.

req_text(any) -> "any version";
req_text(Req) -> Req.

choose(Name, Pkg, Req, Locked, Registry) ->
    case Locked of
        #{pkg := Pkg, vsn := LVsn} ->
            {ok, LV} = parse_version(LVsn),
            case matches(LV, Req) of
                true -> LVsn;
                false -> highest(Name, Pkg, Req, Registry)
            end;
        _ ->
            highest(Name, Pkg, Req, Registry)
    end.

highest(Name, Pkg, Req, Registry) ->
    Versions = [{V, S} || S <- (maps:get(versions, Registry))(Pkg),
                          {ok, V} <- [parse_version(S)], matches(V, Req)],
    case lists:sort(fun({A, _}, {B, _}) -> compare(A, B) =/= lt end, Versions) of
        [{_, Best} | _] -> Best;
        [] -> throw({error, "no version of the Hex package ~ts matches ~ts (for ~p)",
                     [Pkg, req_text(Req), Name]})
    end.

%%% The tarballs.

unpack_package(#{name := Name, pkg := Pkg, vsn := Vsn} = P, LibDir, Registry) ->
    Tar = tarball(Pkg, Vsn, maps:get(outer, P, undefined), Registry),
    Dir = filename:join(LibDir, atom_to_list(Name) ++ "-" ++ Vsn),
    #{inner := Inner, metadata := Meta} = unpack(Tar, maps:get(inner, P, undefined), Dir),
    tools(Pkg, Meta),
    Reqs = meta_requirements(Meta),
    P#{dir => Dir, inner => Inner, outer => sha256(Tar),
       requires => [N || {N, _, _} <- Reqs], reqs => Reqs,
       tools => proplists:get_value(<<"build_tools">>, Meta, [])}.

%% The tarball of a release: from the cache, or downloaded. Expected is
%% the outer checksum (hex), when it is known.
tarball(Pkg, Vsn, Expected, Registry) ->
    Name = binary_to_list(Pkg) ++ "-" ++ Vsn ++ ".tar",
    Cache = filename:join([cache_dir(), "hex", "tarballs", Name]),
    Checked = fun(Tar) -> Expected =:= undefined orelse
                              string:uppercase(to_list(Expected)) =:= sha256(Tar) end,
    case file:read_file(Cache) of
        {ok, Tar} ->
            case Checked(Tar) of
                true -> Tar;
                false -> download(Pkg, Vsn, Cache, Checked, Registry)
            end;
        _ ->
            download(Pkg, Vsn, Cache, Checked, Registry)
    end.

download(Pkg, Vsn, Cache, Checked, Registry) ->
    Tar = (maps:get(tarball, Registry))(Pkg, Vsn),
    Checked(Tar) orelse
        throw({error, "~ts ~ts: the checksum of the tarball does not match",
               [Pkg, Vsn]}),
    _ = filelib:ensure_dir(Cache),
    _ = file:write_file(Cache, Tar),
    Tar.

%% Check a tarball and unpack its contents into Dir. Inner is the inner
%% checksum of rebar.lock, when it is known.
unpack(Tar, Inner, Dir) ->
    Files = case erl_tar:extract({binary, Tar}, [memory]) of
                {ok, F} -> F;
                {error, _} -> throw({error, "~ts: not a Hex tarball", [Dir]})
            end,
    Get = fun(Name) ->
                  case lists:keyfind(Name, 1, Files) of
                      {_, Data} -> Data;
                      false -> throw({error, "~ts: not a Hex tarball (no ~s)", [Dir, Name]})
                  end
          end,
    Version = Get("VERSION"),
    Meta = Get("metadata.config"),
    Contents = Get("contents.tar.gz"),
    Sum = string:uppercase(string:trim(binary_to_list(Get("CHECKSUM")))),
    Sum =:= sha256([Version, Meta, Contents]) orelse
        throw({error, "~ts: the inner checksum does not match", [Dir]}),
    Inner =:= undefined orelse string:uppercase(to_list(Inner)) =:= Sum orelse
        throw({error, "~ts: the checksum does not match rebar.lock", [Dir]}),
    _ = file:del_dir_r(Dir),
    ok = filelib:ensure_path(Dir),
    case erl_tar:extract({binary, Contents}, [compressed, {cwd, Dir}]) of
        ok -> ok;
        {error, E} -> throw({error, "~ts: ~p", [Dir, E]})
    end,
    #{inner => list_to_binary(Sum), metadata => consult(Meta)}.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) -> L.

%% A package for Mix only (Elixir) needs the Elixir compiler.
tools(Pkg, Meta) ->
    mix_only(Pkg, proplists:get_value(<<"build_tools">>, Meta, [])).

mix_only(Pkg, [<<"mix">>]) ->
    beam_com_elixir:available() orelse
        throw({error, "~ts is an Elixir package (mix), and Elixir is not in "
               "this beam.com", [Pkg]});
mix_only(_, _) ->
    true.

%% The requirements in metadata.config: [{AppName, Package, Requirement}]
%% of the deps that are not optional.
meta_requirements(Meta) ->
    [{binary_to_atom(proplists:get_value(<<"app">>, R, Pkg)), Pkg,
      binary_to_list(proplists:get_value(<<"requirement">>, R))}
     || {Pkg, R} <- requirement_list(proplists:get_value(<<"requirements">>, Meta, [])),
        proplists:get_value(<<"optional">>, R, false) =/= true].

%% Two layouts: [{Name, Props}] and [[{<<"name">>, Name} | Props]].
requirement_list(Reqs) ->
    [case R of
         {Name, Props} when is_binary(Name) -> {Name, Props};
         Props when is_list(Props) -> {proplists:get_value(<<"name">>, Props), Props}
     end || R <- Reqs].

consult(Bin) ->
    {ok, Tokens, _} = erl_scan:string(unicode:characters_to_list(Bin)),
    terms(Tokens, []).

terms([], Acc) -> lists:append(lists:reverse(Acc));
terms(Tokens, Acc) ->
    {Term, Rest} = lists:splitwith(fun(T) -> element(1, T) =/= dot end, Tokens),
    [Dot | Rest1] = Rest,
    {ok, T} = erl_parse:parse_term(Term ++ [Dot]),
    terms(Rest1, [[T] | Acc]).

%% The packages in the order to compile them.
order(Packages) ->
    ByName = maps:from_list([{N, P} || #{name := N} = P <- Packages]),
    Sorted = lists:sort(fun(#{name := A}, #{name := B}) -> A =< B end, Packages),
    {Order, _} = lists:foldl(fun(#{name := N}, Acc) -> visit(N, ByName, Acc) end,
                             {[], #{}}, Sorted),
    [maps:with([name, vsn, dir], P) || P <- lists:reverse(Order)].

visit(N, ByName, {Order, Seen} = Acc) ->
    case Seen of
        #{N := _} -> Acc;
        _ ->
            case ByName of
                #{N := #{requires := R} = P} ->
                    {O1, S1} = lists:foldl(fun(D, A) -> visit(D, ByName, A) end,
                                           {Order, Seen#{N => true}}, R),
                    {[P | O1], S1};
                _ -> Acc
            end
    end.

sha256(Data) ->
    binary_to_list(binary:encode_hex(crypto:hash(sha256, Data))).

cache_dir() ->
    case os:getenv("BEAM_COM_CACHE") of
        Dir when is_list(Dir), Dir =/= "" -> Dir;
        _ -> filename:basedir(user_cache, "beam.com")
    end.

%%% The registry: the Hex API and repository, with httpc.

registry() ->
    #{versions => fun api_versions/1,
      release => fun api_release/2,
      tarball => fun repo_tarball/2}.

api_versions(Pkg) ->
    #{<<"releases">> := Releases} = json:decode(http_get(api_url(["packages", Pkg]))),
    [binary_to_list(V) || #{<<"version">> := V} <- Releases].

api_release(Pkg, Vsn) ->
    Info = json:decode(http_get(api_url(["packages", Pkg, "releases", Vsn]))),
    case Info of
        #{<<"meta">> := #{<<"build_tools">> := Tools}} -> mix_only(Pkg, Tools);
        _ -> ok
    end,
    Reqs = maps:get(<<"requirements">>, Info, #{}),
    #{checksum => binary_to_list(maps:get(<<"checksum">>, Info)),
      requirements =>
          [{binary_to_atom(maps:get(<<"app">>, R, P)), P,
            binary_to_list(maps:get(<<"requirement">>, R))}
           || P := R <- Reqs, maps:get(<<"optional">>, R, false) =/= true]}.

repo_tarball(Pkg, Vsn) ->
    Base = env("HEX_MIRROR", ?REPO),
    http_get(Base ++ "/tarballs/" ++ binary_to_list(Pkg) ++ "-" ++ Vsn ++ ".tar").

api_url(Parts) ->
    env("HEX_API_URL", ?API) ++ lists:append(["/" ++ uri_string:quote(to_list(P)) || P <- Parts]).

env(Name, Default) ->
    case os:getenv(Name) of
        V when is_list(V), V =/= "" -> string:trim(V, trailing, "/");
        _ -> Default
    end.

http_get(Url) ->
    ok = start_http(),
    Tls = [{verify, verify_peer}, {cacerts, public_key:cacerts_get()},
           {customize_hostname_check,
            [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
    Headers = [{"user-agent", "beam.com"}, {"accept", "application/json"}],
    case httpc:request(get, {Url, Headers}, [{ssl, Tls}, {timeout, 60000}],
                       [{body_format, binary}], beam_com) of
        {ok, {{_, 200, _}, _, Body}} -> Body;
        {ok, {{_, 404, _}, _, _}} -> throw({error, "~ts: not found", [Url]});
        {ok, {{_, Code, _}, _, _}} -> throw({error, "~ts: HTTP ~b", [Url, Code]});
        {error, Reason} -> throw({error, "~ts: ~p", [Url, Reason]})
    end.

%% httpc in its own profile, with the proxy of HTTPS_PROXY.
start_http() ->
    {ok, _} = application:ensure_all_started([ssl, inets]),
    case inets:start(httpc, [{profile, beam_com}]) of
        {ok, _} -> set_proxy();
        {error, {already_started, _}} -> ok
    end.

set_proxy() ->
    case [P || V <- ["HTTPS_PROXY", "https_proxy"],
               P <- [os:getenv(V)], P =/= false, P =/= ""] of
        [Proxy | _] ->
            #{host := Host, port := Port} = uri_string:parse(Proxy),
            NoProxy = ["localhost", "127.0.0.1"]
                ++ [string:trim(H) || V <- ["NO_PROXY", "no_proxy"],
                                      L <- [os:getenv(V)], L =/= false,
                                      H <- string:split(L, ",", all), H =/= ""],
            ok = httpc:set_options([{https_proxy, {{Host, Port}, NoProxy}},
                                    {proxy, {{Host, Port}, NoProxy}}], beam_com);
        [] ->
            ok
    end.
