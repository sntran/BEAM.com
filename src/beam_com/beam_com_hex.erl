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
%%   pkg_hash_ext in rebar.lock, else the checksum of the API) and the
%%   inner checksum (the CHECKSUM file, and pkg_hash in rebar.lock). When
%%   the lock has no outer checksum for a package (rebar.lock of the
%%   format 1.0.0, for example), the API gives it, and fetch/5 writes the
%%   lock again with the checksums.
%% - The limits: a tarball has at most ?MAX_TARBALL bytes, and its
%%   contents.tar.gz at most ?MAX_CONTENTS bytes without compression.
-module(beam_com_hex).

-export([fetch/2, fetch/4]).

-ifdef(TEST).
-export([parse_version/1, compare/2, parse_requirement/1, matches/2,
         rebar_deps/1, read_lock/1, read_lock/2, lock_text/1, lock_text/2,
         unpack/3, unpack/4, resolve/3, fetch/5, http_get/2, read_limited/2,
         registry/0, consult/1, meta_requirements/1]).
-endif.

-define(API, "https://hex.pm/api").
%% The requirements of one package, at most (see app_name/1).
-define(MAX_REQUIREMENTS, 256).
-define(REPO, "https://repo.hex.pm").

%% The size limits of a package. hex.pm takes a tarball of at most 16 MiB
%% (@tarball_max_size in lib/hexpm_web/controllers/api/release_controller.ex
%% of hexpm/hexpm), and hex_core refuses a contents.tar.gz of more than
%% 128 MiB without compression (tarball_max_uncompressed_size in
%% src/hex_core.erl of hexpm/hex_core). The limits here are two times
%% these values: each package of hex.pm fits, also after a small increase
%% of the limits of hex.pm. The limits stop a download or an unpack that
%% has no end before it fills the memory or the disk.
-define(MAX_TARBALL, 32 * 1024 * 1024).
-define(MAX_CONTENTS, 256 * 1024 * 1024).
%% The JSON of the API for one package or release, at most. The JSON of
%% phoenix, with all its releases, has less than 64 KB.
-define(MAX_JSON, 16 * 1024 * 1024).
%% The time limit of a request to the API or the repository (ms).
-define(HTTP_TIMEOUT, 60000).

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
    %% The lock gets the checksums that the API gave, so that the next
    %% build checks the same tarballs with no request.
    NoChecksum = [N || N := #{outer := undefined} <- Chosen],
    (Resolved orelse NoChecksum =/= []) andalso write_lock(Format, LockFile, Chosen, Unpacked),
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
            %% "~> 2.1" and "~> 2.1-dev" omit the patch number.
            [Core | Pre] = string:split(Vsn, "-"),
            case string:split(Core, ".", all) of
                [_, _] -> {'~>', version(lists:flatten(lists:join("-", [Core ++ ".0" | Pre]))), 2};
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
%% The rule of Hex (Version.match?/3 of Elixir with allow_pre: false): a
%% pre-release matches a ">", ">=" or "~>" clause only when the version
%% of that clause is a pre-release. No requirement matches no pre-release.
matches({_, _, _, Pre}, any) -> Pre =:= [];
matches(Version, Req) when is_list(Req) ->
    {ok, Alts} = parse_requirement(Req),
    lists:any(fun(Alt) -> match_alt(Version, lists:append(Alt)) end, Alts).

match_alt(V, Clauses) ->
    lists:all(fun(C) -> match_clause(V, C) end, Clauses).

match_clause(V, {'==', W}) -> compare(V, W) =:= eq;
match_clause(V, {'!=', W}) -> compare(V, W) =/= eq;
match_clause(V, {'>=', W}) -> compare(V, W) =/= lt andalso pre_allowed(V, W);
match_clause(V, {'<=', W}) -> compare(V, W) =/= gt;
match_clause(V, {'>', W}) -> compare(V, W) =:= gt andalso pre_allowed(V, W);
match_clause(V, {'<', W}) -> compare(V, W) =:= lt.

pre_allowed({_, _, _, []}, _) -> true;
pre_allowed(_, {_, _, _, ReqPre}) -> ReqPre =/= [].

%%% rebar.lock: #{Name => #{pkg, vsn, inner, outer}}, Name an atom. A
%%% checksum that the lock does not have is undefined. An entry of
%%% rebar.lock also has its level.

read_lock(File) ->
    read_lock(rebar, File).

%% mix.lock: %{"name": {:hex, :package, "vsn", "inner", managers, deps,
%% "hexpm", "outer"}}, read with the Elixir parser as Mix reads it. Mix
%% writes the keys as quoted atoms ("name": ...), and lock_text/2 writes
%% them as strings ("name" => ...). Older versions of Hex wrote shorter
%% entries, with no outer checksum or no checksum. Hex reads an element
%% that is not there as nil (destructure in Hex.Utils.lock/1), and so
%% does this function.
read_lock(mix, File) ->
    case file:read_file(File) of
        {error, _} -> #{};
        {ok, Text} ->
            Opts = [{file, unicode:characters_to_binary(File)}, {emit_warnings, false}],
            {ok, Quoted} = 'Elixir.Code':string_to_quoted(Text, Opts),
            {Map, _} = 'Elixir.Code':eval_quoted(Quoted, [], Opts),
            maps:from_list(
              [case Entry of
                   _ when is_tuple(Entry), tuple_size(Entry) >= 3,
                          element(1, Entry) =:= hex, is_atom(element(2, Entry)),
                          is_binary(element(3, Entry)) ->
                       {lock_name(Name), mix_entry(Name, Entry)};
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

lock_name(Name) when is_atom(Name) -> Name;
lock_name(Name) when is_binary(Name) -> binary_to_atom(Name).

mix_entry(Name, Entry) ->
    Get = fun(N) when N =< tuple_size(Entry) -> element(N, Entry);
             (_) -> nil
          end,
    #{pkg => atom_to_binary(Get(2)), vsn => binary_to_list(Get(3)),
      inner => lock_hash(Name, Get(4)), outer => lock_hash(Name, Get(8))}.

lock_hash(_Name, nil) -> undefined;
lock_hash(_Name, Hash) when is_binary(Hash) -> Hash;
lock_hash(Name, Hash) ->
    throw({error, "mix.lock: ~ts has a bad checksum: ~tp", [Name, Hash]}).

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
                #{pkg => Pkg, vsn => binary_to_list(Vsn), level => Level,
                  inner => proplists:get_value(Name, Inner),
                  outer => proplists:get_value(Name, Outer)}};
           {pkg, Pkg, Vsn, _Repo} ->
               {binary_to_atom(Name),
                #{pkg => Pkg, vsn => binary_to_list(Vsn), level => Level,
                  inner => proplists:get_value(Name, Inner),
                  outer => proplists:get_value(Name, Outer)}};
           _ ->
               throw({error, "rebar.lock: ~ts is not a Hex package (only Hex "
                      "packages are supported)", [Name]})
       end || {Name, Source, Level} <- Entries]).

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
              {hex, app_name(Pkg), list_to_binary(Vsn),
               string:lowercase(iolist_to_binary(I)),
               [binary_to_atom(T) || T <- Tools,
                                     lists:member(T, [<<"mix">>, <<"rebar3">>, <<"make">>])],
               [{DN, list_to_binary(DR), [{hex, app_name(DP)}, {repo, <<"hexpm">>},
                                          {optional, false}]}
                || {DN, DP, DR} <- Reqs],
               <<"hexpm">>, string:lowercase(iolist_to_binary(O))}}
             || #{name := N, pkg := Pkg, vsn := Vsn, inner := I, outer := O,
                  tools := Tools, reqs := Reqs} <- Packages]),
    ['Elixir.Kernel':inspect(Map, [{pretty, true}, {limit, infinity},
                                   {printable_limit, infinity}]), "\n"];
lock_text(rebar, Packages) ->
    lock_text(Packages).

%% With no resolution, each package keeps the level of rebar.lock.
write_lock(Format, File, Chosen, Unpacked) ->
    Levels = levels(Chosen, Unpacked),
    Text = lock_text(Format, [P#{level => maps:get(N, Levels, maps:get(level, P, 0))}
                              || #{name := N} = P <- Unpacked]),
    case file:write_file(File, Text) of
        ok -> io:format("~ts: wrote ~ts~n", [beam_com:name(), File]);
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
    Tar = tarball(Pkg, Vsn, outer_checksum(P, Registry), Registry),
    Dir = filename:join(LibDir, atom_to_list(Name) ++ "-" ++ Vsn),
    #{inner := Inner, metadata := Meta} = unpack(Tar, maps:get(inner, P, undefined), Dir),
    tools(Pkg, Meta),
    Reqs = meta_requirements(Meta),
    P#{dir => Dir, inner => Inner, outer => sha256(Tar),
       requires => [N || {N, _, _} <- Reqs], reqs => Reqs,
       tools => proplists:get_value(<<"build_tools">>, Meta, [])}.

%% The outer checksum of a release: from the lock, else from the Hex API.
%% The check of each tarball, also of a tarball of the cache or of
%% HEX_MIRROR, uses a checksum from one of them. The CHECKSUM file of a
%% tarball only checks the tarball itself.
outer_checksum(#{pkg := Pkg, vsn := Vsn} = P, Registry) ->
    case maps:get(outer, P, undefined) of
        undefined ->
            case (maps:get(release, Registry))(Pkg, Vsn) of
                #{checksum := Sum} when Sum =/= undefined -> Sum;
                _ -> throw({error, "~ts ~ts: the Hex API gives no checksum", [Pkg, Vsn]})
            end;
        Outer ->
            Outer
    end.

%% The tarball of a release: from the cache, or downloaded. Expected is
%% the outer checksum (hex). When the file of the cache is larger than
%% ?MAX_TARBALL, or does not match, this function downloads the tarball
%% again.
tarball(Pkg, Vsn, Expected, Registry) ->
    Name = binary_to_list(Pkg) ++ "-" ++ Vsn ++ ".tar",
    Cache = filename:join([cache_dir(), "hex", "tarballs", Name]),
    Checked = fun(Tar) -> string:uppercase(to_list(Expected)) =:= sha256(Tar) end,
    case read_limited(Cache, ?MAX_TARBALL) of
        {ok, Tar} ->
            case Checked(Tar) of
                true -> Tar;
                false -> download(Pkg, Vsn, Cache, Checked, Registry)
            end;
        _ ->
            download(Pkg, Vsn, Cache, Checked, Registry)
    end.

%% The data of File, when it has at most Max bytes. The read stops after
%% Max + 1 bytes: a large file is never all in memory.
read_limited(File, Max) ->
    case file:open(File, [read, raw, binary]) of
        {ok, F} ->
            try read_limited(F, Max, 0, [])
            after file:close(F)
            end;
        {error, _} = Error ->
            Error
    end.

read_limited(F, Max, Size, Parts) ->
    case file:read(F, min(Max - Size + 1, 1 bsl 20)) of
        {ok, Data} when Size + byte_size(Data) =< Max ->
            read_limited(F, Max, Size + byte_size(Data), [Data | Parts]);
        {ok, _} -> {error, too_large};
        eof -> {ok, iolist_to_binary(lists:reverse(Parts))};
        {error, _} = Error -> Error
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
%% checksum of rebar.lock, when it is known. Max is the limit of the
%% size of contents.tar.gz without compression.
unpack(Tar, Inner, Dir) ->
    unpack(Tar, Inner, Dir, ?MAX_CONTENTS).

unpack(Tar, Inner, Dir, Max) ->
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
    check_size(Contents, Max, Dir),
    safe_entries(Contents, Dir),
    _ = file:del_dir_r(Dir),
    ok = filelib:ensure_path(Dir),
    case erl_tar:extract({binary, Contents}, [compressed, {cwd, Dir}]) of
        ok -> ok;
        {error, E} -> throw({error, "~ts: ~p", [Dir, E]})
    end,
    #{inner => list_to_binary(Sum), metadata => consult(Meta)}.

%% contents.tar.gz has at most Max bytes without compression. A small
%% gzip file can have many GB without compression, and erl_tar keeps all
%% the data in memory, so this check comes first. It reads the data in
%% parts and keeps no part. As erl_tar, it reads only the first gzip
%% member (cut). The tar data has the files, so their size and their
%% number also have a limit.
check_size(Contents, Max, Dir) ->
    Z = zlib:open(),
    try
        ok = zlib:inflateInit(Z, 31, cut),
        inflated_size(Z, Contents, Max, Dir, 0)
    catch
        error:_ -> throw({error, "~ts: not a Hex tarball (contents)", [Dir]})
    after
        zlib:close(Z)
    end.

inflated_size(Z, Data, Max, Dir, Size) ->
    {Status, Part} = zlib:safeInflate(Z, Data),
    Size1 = Size + iolist_size(Part),
    Size1 =< Max orelse
        throw({error, "~ts: contents.tar.gz has more than ~b bytes without compression",
               [Dir, Max]}),
    case Status of
        continue -> inflated_size(Z, <<>>, Max, Dir, Size1);
        finished -> Size1
    end.

%% The files of contents.tar.gz: regular files and directories, with
%% relative names in the package. A Hex package has no links, and a link
%% or a name such as "../x" could write outside Dir.
safe_entries(Contents, Dir) ->
    Entries = case erl_tar:table({binary, Contents}, [compressed, verbose]) of
                  {ok, E} -> E;
                  {error, _} -> throw({error, "~ts: not a Hex tarball (contents)", [Dir]})
              end,
    lists:foreach(
      fun({Name, Type, _, _, _, _, _}) ->
              lists:member(Type, [regular, directory]) orelse
                  throw({error, "~ts: the package has a file that is not a regular file: ~ts",
                         [Dir, Name]}),
              safe_name(Name) orelse
                  throw({error, "~ts: the package has an unsafe file name: ~ts", [Dir, Name]})
      end, Entries).

safe_name(Name) ->
    filename:pathtype(Name) =:= relative andalso
        not lists:member("..", filename:split(Name)).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) -> L.

%% A package for Mix only (Elixir) needs the Elixir compiler.
tools(Pkg, Meta) ->
    mix_only(Pkg, proplists:get_value(<<"build_tools">>, Meta, [])).

mix_only(Pkg, [<<"mix">>]) ->
    beam_com_elixir:available() orelse
        throw({error, "~ts is an Elixir package (mix), and Elixir is not in "
               "this ~ts (built with ELIXIR=0)", [Pkg, beam_com:name()]});
mix_only(_, _) ->
    true.

%% The requirements in metadata.config: [{AppName, Package, Requirement}]
%% of the deps that are not optional.
%% An app name becomes an atom only when it is a valid name, and a
%% package has at most ?MAX_REQUIREMENTS requirements.

meta_requirements(Meta) ->
    Reqs = requirement_list(proplists:get_value(<<"requirements">>, Meta, [])),
    length(Reqs) =< ?MAX_REQUIREMENTS orelse
        throw({error, "a package has more than ~b requirements", [?MAX_REQUIREMENTS]}),
    [{app_name(proplists:get_value(<<"app">>, R, Pkg)), Pkg,
      binary_to_list(proplists:get_value(<<"requirement">>, R))}
     || {Pkg, R} <- Reqs,
        proplists:get_value(<<"optional">>, R, false) =/= true].

app_name(Name) when is_binary(Name), byte_size(Name) =< 255 ->
    case re:run(Name, "^[a-z][a-z0-9_]*$", [{capture, none}]) of
        match -> binary_to_atom(Name);
        nomatch -> throw({error, "~ts is not an application name", [Name]})
    end;
app_name(Name) ->
    throw({error, "~tp is not an application name", [Name]}).

%% Two layouts: [{Name, Props}] and [[{<<"name">>, Name} | Props]].
requirement_list(Reqs) ->
    [case R of
         {Name, Props} when is_binary(Name) -> {Name, Props};
         Props when is_list(Props) -> {proplists:get_value(<<"name">>, Props), Props}
     end || R <- Reqs].

%% The terms of metadata.config. The file comes from the package, so it
%% is read without erl_scan: erl_scan makes an atom of each name, and a
%% package could fill the atom table. This reader takes binaries
%% (<<"text">> and <<"text"/utf8>>), strings, integers, lists, tuples,
%% and only the atoms that exist already.
consult(Bin) ->
    Chars = case unicode:characters_to_list(Bin) of
                L when is_list(L) -> L;
                _ -> throw({error, "metadata.config is not UTF-8", []})
            end,
    try consult_terms(Chars, [])
    catch error:_ -> throw({error, "metadata.config is not a list of terms", []})
    end.

consult_terms(Chars, Acc) ->
    case skip(Chars) of
        [] -> lists:reverse(Acc);
        Rest ->
            {T, Rest1} = term(Rest, 0),
            [$. | Rest2] = skip(Rest1),
            true = end_dot(Rest2),
            consult_terms(Rest2, [T | Acc])
    end.

%% As in erl_scan, a dot ends a term only before white space, a comment
%% or the end of the text. So "1.5." is not the terms 1 and 5: it is a
%% float, and this reader refuses it.
end_dot([]) -> true;
end_dot([C | _]) -> C =:= $\s orelse C =:= $\t orelse C =:= $\n orelse C =:= $\r orelse C =:= $%.

-define(MAX_DEPTH, 64).

term(Chars, Depth) when Depth < ?MAX_DEPTH ->
    case skip(Chars) of
        "<<" ++ Rest -> bin(skip(Rest));
        [$" | Rest] -> quoted(Rest, $", []);
        [$[ | Rest] -> seq(Rest, $], Depth, []);
        [${ | Rest] ->
            {Items, Rest1} = seq(Rest, $}, Depth, []),
            {list_to_tuple(Items), Rest1};
        [$' | Rest] ->
            {Name, Rest1} = quoted(Rest, $', []),
            {list_to_existing_atom(Name), skip(Rest1)};
        [C | _] = Rest when C >= $a, C =< $z ->
            {Name, Rest1} = lists:splitwith(fun name_char/1, Rest),
            {list_to_existing_atom(Name), skip(Rest1)};
        [C | _] = Rest when C =:= $-; C >= $0, C =< $9 ->
            {Sign, Rest1} = case Rest of
                                [$- | R] -> {-1, R};
                                R -> {1, R}
                            end,
            {Digits, Rest2} = lists:splitwith(fun(D) -> D >= $0 andalso D =< $9 end, Rest1),
            {Sign * list_to_integer(Digits), skip(Rest2)}
    end.

%% A list or a tuple: terms with commas, up to the closing character.
seq(Chars, Close, Depth, Acc) ->
    case skip(Chars) of
        [Close | Rest] when Acc =:= [] -> {[], skip(Rest)};
        Rest ->
            {T, Rest1} = term(Rest, Depth + 1),
            case skip(Rest1) of
                [$, | Rest2] -> seq(Rest2, Close, Depth, [T | Acc]);
                [Close | Rest2] -> {lists:reverse([T | Acc]), skip(Rest2)}
            end
    end.

%% A binary: <<>>, <<"text">>, <<"text"/utf8>>, bytes (<<1,255>>), and
%% segments with commas. io_lib:format/2 writes bytes when the binary
%% has a character that it does not print.
bin(">>" ++ Rest) ->
    {<<>>, skip(Rest)};
bin(Chars) ->
    bin(Chars, []).

bin([$" | Rest], Acc) ->
    {Text, Rest1} = quoted(Rest, $", []),
    case skip(Rest1) of
        "/utf8" ++ R -> bin_next(skip(R), unicode:characters_to_binary(Text), Acc);
        R -> bin_next(R, << <<C:8>> || C <- Text >>, Acc)
    end;
bin([C | _] = Chars, Acc) when C >= $0, C =< $9 ->
    {Digits, Rest} = lists:splitwith(fun(D) -> D >= $0 andalso D =< $9 end, Chars),
    Byte = list_to_integer(Digits),
    Byte =< 255 orelse error(badarg),
    bin_next(skip(Rest), <<Byte>>, Acc).

bin_next([$, | Rest], Seg, Acc) -> bin(skip(Rest), [Seg | Acc]);
bin_next(">>" ++ Rest, Seg, Acc) -> {iolist_to_binary(lists:reverse([Seg | Acc])), skip(Rest)}.

%% The text of a quoted string or atom, with the escapes of Erlang.
quoted([Q | Rest], Q, Acc) -> {lists:reverse(Acc), Rest};
quoted([$\\, $x, ${ | Rest], Q, Acc) ->
    {Hex, [$} | Rest1]} = lists:splitwith(fun(C) -> C =/= $} end, Rest),
    quoted(Rest1, Q, [list_to_integer(Hex, 16) | Acc]);
quoted([$\\, $x, H1, H2 | Rest], Q, Acc) ->
    quoted(Rest, Q, [list_to_integer([H1, H2], 16) | Acc]);
quoted([$\\, C | Rest], Q, Acc) when C >= $0, C =< $7 ->
    {Octal, Rest1} = lists:splitwith(fun(D) -> D >= $0 andalso D =< $7 end, [C | Rest]),
    {Oct, More} = lists:split(min(3, length(Octal)), Octal),
    quoted(More ++ Rest1, Q, [list_to_integer(Oct, 8) | Acc]);
quoted([$\\, C | Rest], Q, Acc) ->
    quoted(Rest, Q, [escape(C) | Acc]);
quoted([C | Rest], Q, Acc) ->
    quoted(Rest, Q, [C | Acc]).

escape($n) -> $\n;
escape($t) -> $\t;
escape($r) -> $\r;
escape($s) -> $\s;
escape($e) -> $\e;
escape($d) -> $\d;
escape($b) -> $\b;
escape($f) -> $\f;
escape($v) -> $\v;
escape(C) -> C.

name_char(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)
        orelse (C >= $0 andalso C =< $9) orelse C =:= $_ orelse C =:= $@.

%% White space and comments.
skip([C | Rest]) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r -> skip(Rest);
skip([$% | Rest]) -> skip(lists:dropwhile(fun(C) -> C =/= $\n end, Rest));
skip(Chars) -> Chars.

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
    #{<<"releases">> := Releases} =
        json:decode(http_get(api_url(["packages", Pkg]), ?MAX_JSON)),
    [binary_to_list(V) || #{<<"version">> := V} <- Releases].

api_release(Pkg, Vsn) ->
    Info = json:decode(http_get(api_url(["packages", Pkg, "releases", Vsn]), ?MAX_JSON)),
    case Info of
        #{<<"meta">> := #{<<"build_tools">> := Tools}} -> mix_only(Pkg, Tools);
        _ -> ok
    end,
    Reqs = maps:get(<<"requirements">>, Info, #{}),
    map_size(Reqs) =< ?MAX_REQUIREMENTS orelse
        throw({error, "a package has more than ~b requirements", [?MAX_REQUIREMENTS]}),
    #{checksum => case Info of
                      #{<<"checksum">> := Sum} when is_binary(Sum) -> binary_to_list(Sum);
                      _ -> undefined
                  end,
      requirements =>
          [{app_name(maps:get(<<"app">>, R, P)), P,
            binary_to_list(maps:get(<<"requirement">>, R))}
           || P := R <- Reqs, maps:get(<<"optional">>, R, false) =/= true]}.

repo_tarball(Pkg, Vsn) ->
    Base = env("HEX_MIRROR", ?REPO),
    http_get(Base ++ "/tarballs/" ++ binary_to_list(Pkg) ++ "-" ++ Vsn ++ ".tar", ?MAX_TARBALL).

api_url(Parts) ->
    env("HEX_API_URL", ?API) ++ lists:append(["/" ++ uri_string:quote(to_list(P)) || P <- Parts]).

env(Name, Default) ->
    case os:getenv(Name) of
        V when is_list(V), V =/= "" -> string:trim(V, trailing, "/");
        _ -> Default
    end.

%% The body of a GET of Url, with at most Max bytes. httpc gives the body
%% of a 200 in parts (stream), and the next part only after stream_next/1,
%% so the request stops after Max bytes and one part. max_body_size stops
%% a body whose length (Content-Length, or a chunk) is more than Max
%% before it comes. httpc does not limit the body of another status when
%% it has no length: see O25 in docs/UPSTREAM.md.
http_get(Url, Max) ->
    ok = start_http(),
    Tls = [{verify, verify_peer}, {cacerts, public_key:cacerts_get()},
           {customize_hostname_check,
            [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
    Headers = [{"user-agent", "beam.com"}, {"accept", "application/json"}],
    case httpc:request(get, {Url, Headers}, [{ssl, Tls}, {timeout, ?HTTP_TIMEOUT}],
                       [{sync, false}, {stream, {self, once}}, {body_format, binary},
                        {max_body_size, Max}], beam_com) of
        {ok, Ref} -> body(Ref, Url, Max, undefined, 0, []);
        {error, Reason} -> throw({error, "~ts: ~p", [Url, Reason]})
    end.

body(Ref, Url, Max, Handler, Size, Parts) ->
    receive
        {http, {Ref, stream_start, _Headers, Pid}} ->
            ok = httpc:stream_next(Pid),
            body(Ref, Url, Max, Pid, Size, Parts);
        {http, {Ref, stream, Part}} when Size + byte_size(Part) =< Max ->
            ok = httpc:stream_next(Handler),
            body(Ref, Url, Max, Handler, Size + byte_size(Part), [Part | Parts]);
        {http, {Ref, stream, _}} ->
            ok = httpc:cancel_request(Ref, beam_com),
            flush(Ref),
            too_large(Url, Max);
        {http, {Ref, stream_end, _Headers}} ->
            iolist_to_binary(lists:reverse(Parts));
        {http, {Ref, {{_, 404, _}, _, _}}} -> throw({error, "~ts: not found", [Url]});
        {http, {Ref, {{_, Code, _}, _, _}}} -> throw({error, "~ts: HTTP ~b", [Url, Code]});
        {http, {Ref, {error, body_too_big}}} -> too_large(Url, Max);
        {http, {Ref, {error, {body_too_long, _}}}} -> too_large(Url, Max);
        {http, {Ref, {error, Reason}}} -> throw({error, "~ts: ~p", [Url, Reason]})
    after 2 * ?HTTP_TIMEOUT ->
            %% httpc answers at its timeout: this is only a guard.
            ok = httpc:cancel_request(Ref, beam_com),
            throw({error, "~ts: ~p", [Url, timeout]})
    end.

too_large(Url, Max) ->
    throw({error, "~ts: the response has more than ~b bytes", [Url, Max]}).

%% A request can still send a message after cancel_request/2.
flush(Ref) ->
    receive
        {http, Message} when element(1, Message) =:= Ref -> flush(Ref)
    after 0 ->
            ok
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
