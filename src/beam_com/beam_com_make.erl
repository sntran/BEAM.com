%% make for elixir_make, in the tools of Elixir (mix.com, iex.com,
%% elixir.com, elixirc.com). The tools set MAKE to a program "make" that
%% is beam.com (make_link() in c_src/cosmo/beam_com.c), and beam.com runs this
%% module for it.
%%
%% elixir_make runs make in the directory of a package that has C code (a
%% NIF), with the build directory of the package in MIX_APP_PATH
%% (_build/dev/lib/APP). The NIFs of some packages are linked into
%% beam.com (the env nifs of the beam_com application, which the
%% step bundle of scripts/steps.sh sets: [{exqlite, "0.41.0"}, {bcrypt_elixir, "3.3.2"},
%% {argon2_elixir, "4.1.3"}]). ERTS finds a
%% static NIF by the name of its module, before it opens the file that
%% load_nif/2 gets, so these packages need no make and no C compiler:
%%
%%   - A package with a linked NIF, of the same version: nothing to do.
%%   - A package with a linked NIF, of another version: an error (the NIF
%%     functions of the two versions can be different).
%%   - A package with NIF files in beam.com: the directory
%%     priv/nifs/APP-VSN of beam_com holds files of the priv directory of
%%     the package. They are a NIF library in WebAssembly (lazy_html,
%%     scripts/lazy_html.sh), or native NIF objects (LIB.x86_64.o and
%%     LIB.aarch64.o, a program assembled from parts, docs/NIFS.md). make
%%     copies the files into the priv directory of the package, and
%%     load_nif/2 then loads them. Of another version: an error. The
%%     list of these packages comes from the directory, so a program
%%     with more files in its zip needs no other build.
%%   - Another package: the make of PATH (gmake or make) runs, with the
%%     same arguments. Without make, an error.
%%
%% elixir_make runs make for a package with a precompiled NIF only when
%% the package is in the env force_build of elixir_make. Else it gets a
%% native library for the system, which beam.com cannot load. So the
%% tools of Elixir run force_build/0 at their start (beam_com.c).
-module(beam_com_make).

-export([main/0, force_build/0, nif_files/2, nif_files/3, file_nifs/0, file_nifs/1,
         priv/0, linked_nifs/0, nif_dirs/1, match_nifs/2, source_text/1]).

-ifdef(TEST).
-export([run/2, dep_version/1, force_build/1, app_file_nifs/1, source/1, url/1,
         source_match/5]).
-endif.

main() ->
    Priv = priv(),
    Env = #{app_path => os:getenv("MIX_APP_PATH", ""),
            cwd => element(2, file:get_cwd()),
            nifs => nifs(),
            file_nifs => file_nifs(Priv),
            priv => Priv,
            make => os:getenv("MAKE", "")},
    Status = try run(init:get_plain_arguments(), Env) of
                 ok -> 0;
                 {make, Make, Args} -> make(Make, Args)
             catch
                 throw:{error, Format, Args} ->
                     io:format(standard_error, "~ts: make: " ++ Format ++ "~n",
                               [name() | Args]),
                     1
             end,
    erlang:halt(Status).

%% ok, {make, Make, Args} (run the make of PATH), or an error (throw).
%% The arguments (the targets, "all" or "clean") do not change what is
%% done for a linked NIF.
run(Args, #{app_path := AppPath, cwd := Cwd, nifs := Nifs} = Env) ->
    App = case AppPath of
              "" -> filename:basename(Cwd);
              _ -> filename:basename(AppPath)
          end,
    case [V || {A, V} <- maps:get(file_nifs, Env, []), atom_to_list(A) =:= App] of
        [_ | _] = Vsns -> file_nif(Args, App, Vsns, Env);
        [] -> run(Args, App, Nifs, Env)
    end.

run(Args, App, Nifs, #{cwd := Cwd} = Env) ->
    case lists:keyfind(list_to_atom(App), 1, Nifs) of
        {_, Vsn} ->
            case dep_version(Cwd) of
                Other when is_list(Other), Other =/= Vsn ->
                    throw({error, "~ts ~ts has a NIF, and ~ts has the NIF of ~ts ~ts "
                           "(which it always uses). Use ~ts ~ts (in the deps of "
                           "mix.exs: {:~ts, \"~ts\"})",
                           [App, Other, name(), App, Vsn, App, Vsn, App, Vsn]});
                _ ->
                    %% "all" or "clean": the NIF is in beam.com.
                    ok
            end;
        false ->
            case find_make(maps:get(make, Env)) of
                false ->
                    throw({error, "~ts has C code (a NIF) that is not in ~ts, and there "
                           "is no make in PATH. The NIFs in ~ts: ~ts",
                           [App, name(), name(),
                            case Nifs of
                                [] -> "none";
                                _ -> lists:join(", ", [[atom_to_list(A), " ", V]
                                                       || {A, V} <- Nifs])
                            end]});
                Make ->
                    {make, Make, Args}
            end
    end.

%% A package with NIF files in beam.com (Vsns: the versions in
%% priv/nifs): "all" (or no target) copies its files into
%% MIX_APP_PATH/priv, "clean" does nothing.
file_nif(Args, App, Vsns, #{app_path := AppPath, cwd := Cwd, priv := Priv}) ->
    Vsn = case dep_version(Cwd) of
              Other when is_list(Other) ->
                  case lists:member(Other, Vsns) of
                      true -> Other;
                      false -> throw({error, "~ts ~ts has a NIF, and ~ts has the NIF of ~ts "
                                      "~ts. Use ~ts ~ts (in the deps of mix.exs: "
                                      "{:~ts, \"~ts\"})",
                                      [App, Other, name(), App, hd(Vsns), App, hd(Vsns),
                                       App, hd(Vsns)]})
                  end;
              undefined ->
                  hd(Vsns)
          end,
    case lists:member("clean", Args) of
        true ->
            ok;
        false ->
            Dst = filename:join(case AppPath of "" -> Cwd; _ -> AppPath end, "priv"),
            Files = case nif_files(list_to_atom(App), Vsn, Priv) of
                        [_ | _] = Fs -> Fs;
                        [] -> throw({error, "~ts: no NIF files of ~ts ~ts",
                                     [filename:join([Priv, "nifs", App ++ "-" ++ Vsn]), App, Vsn]})
                    end,
            write_files(Dst, Files)
    end.

%% Writes the files [{Name, Data}] (Name can have directories) into Dir.
write_files(Dir, Files) ->
    [begin
         Path = filename:join(Dir, F),
         ok = filelib:ensure_dir(Path),
         ok = file:write_file(Path, Data)
     end || {F, Data} <- Files],
    ok.

%% The NIF files of the Hex package App in beam.com, for the version Vsn:
%% [{Name, Data}], with Name relative to the priv directory of App, or []
%% for another package, version or source. beam_com_build adds them to
%% the priv directory of App in a program, and beam_com_rustler copies
%% them.
nif_files(App, Vsn) ->
    nif_files(App, Vsn, priv()).

nif_files(App, Vsn, Priv) ->
    Dir = nif_dir(Priv, App, Vsn),
    case is_hex(App, source(Dir)) of
        true -> dir_files(Dir);
        false -> []
    end.

%% True for the source of the Hex package App.
is_hex(_App, hex) -> true;
is_hex(App, {hex, Package}) -> Package =:= atom_to_list(App);
is_hex(_App, _Source) -> false.

%% The files of a directory of priv/nifs, with no SOURCE.
dir_files(Dir) ->
    [{N, element(2, {ok, _} = file:read_file(filename:join(Dir, N)))}
     || N <- lists:sort(filelib:wildcard("**", Dir)), N =/= "SOURCE",
        filelib:is_regular(filename:join(Dir, N))].

nif_dir(Priv, App, Vsn) ->
    filename:join([Priv, "nifs", atom_to_list(App) ++ "-" ++ Vsn]).

%% The Hex packages with NIF files in beam.com: [{App, Vsn}], from the
%% names APP-VSN of the directories of priv/nifs with no SOURCE (or the
%% source hex). The hooks of make and Rustler, and the builder of a plain
%% Mix project, are for the Hex packages.
file_nifs() ->
    file_nifs(priv()).

file_nifs(Priv) ->
    [{A, V} || {A, V, Source} <- nif_dirs(Priv), is_hex(A, Source)].

%% Each directory APP-VSN of priv/nifs: [{App, Vsn, Source}]. The file
%% SOURCE of the directory names the package of the files (source/1).
nif_dirs(Priv) ->
    case file:list_dir(filename:join(Priv, "nifs")) of
        {ok, Names} ->
            [{list_to_atom(A), V, source(filename:join([Priv, "nifs", N]))}
             || N <- lists:sort(Names),
                [A, V] <- [string:split(N, "-")],
                A =/= "", V =/= "",
                filelib:is_dir(filename:join([Priv, "nifs", N]))];
        {error, _} ->
            []
    end.

%% The source of the NIF files of the directory Dir: the package that
%% they are for, from the file Dir/SOURCE. With no file, or with the line
%% "hex": hex, the Hex package of the name and the version of the
%% directory (hex.pm). "hex PACKAGE": {hex, PACKAGE}, the Hex package
%% PACKAGE for the application of the directory (the option hex: of a
%% dep). The line "git URL" is the git dep of URL, of the
%% version of the directory; {git, URL, []}. With "commit=SHA" (7 to 40
%% hexadecimal digits) or "tag=TAG" after URL, the version is not
%% checked: the dep must be at that commit, or have that tag in mix.exs;
%% {git, URL, [{commit, SHA} | {tag, TAG}]}. A file of another form gives
%% invalid, which no dep matches.
source(Dir) ->
    case file:read_file(filename:join(Dir, "SOURCE")) of
        {error, enoent} ->
            hex;
        {ok, Bin} ->
            case unicode:characters_to_list(Bin) of
                Text when is_list(Text) ->
                    Lines = [L || L0 <- string:split(Text, "\n", all),
                                  L <- [string:trim(L0)], L =/= "", hd(L) =/= $#],
                    case Lines of
                        [Line] -> parse_source(string:lexemes(Line, " \t"));
                        _ -> invalid
                    end;
                _ ->
                    invalid
            end;
        {error, _} ->
            invalid
    end.

parse_source(["hex"]) ->
    hex;
parse_source(["hex", Package]) ->
    {hex, Package};
parse_source(["git", Url | Revs]) ->
    Parsed = [rev(R) || R <- Revs],
    case lists:member(invalid, Parsed) orelse url(Url) =:= invalid of
        true -> invalid;
        false -> {git, url(Url), Parsed}
    end;
parse_source(_) ->
    invalid.

rev("commit=" ++ Sha) ->
    case length(Sha) >= 7 andalso length(Sha) =< 40
        andalso lists:all(fun(C) -> lists:member(C, "0123456789abcdefABCDEF") end, Sha) of
        true -> {commit, string:lowercase(Sha)};
        false -> invalid
    end;
rev("tag=" ++ Tag) when Tag =/= "" ->
    {tag, Tag};
rev(_) ->
    invalid.

%% The URL of a git repository in one form, so that the URLs of mix.exs
%% compare: the scheme and the host in lower case, and no "/" or ".git"
%% at the end (Mix writes github: NAME as https://github.com/NAME.git).
url(Url0) ->
    Url = case unicode:characters_to_list(Url0) of
              L when is_list(L) -> L;
              _ -> ""
          end,
    case string:split(Url, "://") of
        [Scheme, Rest] when Scheme =/= "", Rest =/= "" ->
            {Host, Path} = case string:split(Rest, "/") of
                               [H, P] -> {H, "/" ++ P};
                               [H] -> {H, ""}
                           end,
            string:lowercase(Scheme) ++ "://" ++ string:lowercase(Host) ++ trim_path(Path);
        _ ->
            invalid
    end.

trim_path(Path) ->
    P = string:trim(Path, trailing, "/"),
    case lists:suffix(".git", P) of
        true -> string:trim(lists:sublist(P, length(P) - 4), trailing, "/");
        false -> P
    end.

%% True when the NIF files of the directory of App, of version DirVsn and
%% source Source, are for the dep App of version DepVsn and source
%% DepSource: {hex, PACKAGE} (a package of hex.pm), {git, URL, Commit,
%% Opts} (the lock entry of a git dep), or other.
source_match(Source, App, DirVsn, DepVsn, {hex, Package}) ->
    Own = case Source of
              hex -> atom_to_list(App);
              {hex, P} -> P;
              _ -> none
          end,
    Own =:= Package andalso DirVsn =:= DepVsn;
source_match({git, Url, []}, _App, DirVsn, DepVsn, {git, DepUrl, _Commit, _Opts}) ->
    Url =:= url(DepUrl) andalso DirVsn =:= DepVsn;
source_match({git, Url, Revs}, _App, _DirVsn, _DepVsn, {git, DepUrl, Commit, Opts}) ->
    Url =:= url(DepUrl) andalso
        lists:any(fun({commit, Sha}) -> lists:prefix(Sha, string:lowercase(Commit));
                     ({tag, Tag}) -> proplists:get_value(tag, Opts) =:= Tag
                  end, Revs);
source_match(_Source, _App, _DirVsn, _DepVsn, _DepSource) ->
    false.

%% The NIF files of beam.com (in Priv) for the deps [{App, Vsn, Source}]
%% (source_match/4): [{App, DirVsn, Files}], one for each dep that has
%% NIF files. A directory with a commit or a tag comes before one with
%% none. Also [{App, nomatch, Dirs}] for a dep of an application that has
%% NIF files of no matching version or source.
match_nifs(Priv, Deps) ->
    Dirs = nif_dirs(Priv),
    lists:append(
      [case [{V, Src} || {A, V, Src} <- Dirs, A =:= App] of
           [] ->
               [];
           Own ->
               Sorted = lists:sort(fun({_, S1}, {_, S2}) -> specific(S1) >= specific(S2) end,
                                   Own),
               case [V || {V, Src} <- Sorted, source_match(Src, App, V, Vsn, DepSource)] of
                   [V | _] -> [{App, V, dir_files(nif_dir(Priv, App, V))}];
                   [] -> [{App, nomatch, Own}]
               end
       end || {App, Vsn, DepSource} <- Deps]).

specific({git, _, [_ | _]}) -> 1;
specific(_) -> 0.

%% The text of a source, for the messages and beam.com --version.
source_text(hex) -> "hex";
source_text({hex, Package}) -> ["hex ", Package];
source_text(invalid) -> "an invalid SOURCE";
source_text({git, Url, Revs}) ->
    lists:join(" ", ["git", Url | [case R of
                                       {commit, Sha} -> "commit=" ++ Sha;
                                       {tag, Tag} -> "tag=" ++ Tag
                                   end || R <- Revs]]).

%% The priv directory of beam_com, also when beam_com is not loaded (it
%% is in the code path). Mix removes beam_com from the code path before
%% it compiles: beam_com_rustler keeps this directory from the start.
priv() ->
    case code:lib_dir(beam_com) of
        Dir when is_list(Dir) -> filename:join(Dir, "priv");
        {error, _} -> "/nonexistent"
    end.

%% The env force_build of elixir_make, with each package with NIF files
%% and each linked NIF (a package such as vix gets a precompiled NIF
%% without it), before Mix loads the configuration of the project.
%% persistent: a later load of elixir_make keeps it. The same for the
%% NIFs of Rust (beam_com_rustler).
force_build() ->
    Nifs = start_nifs(),
    beam_com_rustler:force_build(Nifs),
    force_build(file_nifs() ++ Nifs).

%% The linked NIFs ([{App, Vsn}]), also when beam_com is not loaded.
linked_nifs() ->
    start_nifs().

%% The linked NIFs at the start of a tool of Elixir. When beam_com is not
%% loaded, they come from its .app file, and beam_com stays not loaded:
%% Mix loads the application of the project, and keeps an application
%% that is already loaded (the beam_com of the runtime, in the tests of
%% beam_com).
start_nifs() ->
    case lists:keymember(beam_com, 1, application:loaded_applications()) of
        true -> nifs();
        false -> app_file_nifs(code:where_is_file("beam_com.app"))
    end.

%% The env nifs of the .app file File. [] when the file cannot be read.
app_file_nifs(File) when is_list(File) ->
    case file:consult(File) of
        {ok, [{application, _, Props}]} when is_list(Props) ->
            case proplists:get_value(nifs, proplists:get_value(env, Props, [])) of
                Nifs when is_list(Nifs) -> Nifs;
                _ -> []
            end;
        _ ->
            []
    end;
app_file_nifs(non_existing) ->
    [].

force_build(FileNifs) ->
    Old = case application:get_env(elixir_make, force_build) of
              {ok, L} when is_list(L) -> L;
              _ -> []
          end,
    New = Old ++ [{A, true} || {A, _} <- lists:ukeysort(1, FileNifs),
                              not lists:keymember(A, 1, Old)],
    application:set_env(elixir_make, force_build, New, [{persistent, true}]).

%% The version of the package in the directory Dir: from
%% hex_metadata.config (a package of hex.pm), else from "@version" or
%% "version:" in mix.exs. undefined when it is not found.
dep_version(Dir) ->
    case file:consult(filename:join(Dir, "hex_metadata.config")) of
        {ok, Terms} when is_list(Terms) ->
            case lists:keyfind(<<"version">>, 1, Terms) of
                {_, Vsn} when is_binary(Vsn) -> binary_to_list(Vsn);
                _ -> mix_version(Dir)
            end;
        _ ->
            mix_version(Dir)
    end.

mix_version(Dir) ->
    case file:read_file(filename:join(Dir, "mix.exs")) of
        {ok, Bin} ->
            case re:run(Bin, "(?:@version\\s+|\\bversion:\\s*)\"([^\"]+)\"",
                        [{capture, all_but_first, list}]) of
                {match, [Vsn]} -> Vsn;
                nomatch -> undefined
            end;
        {error, _} ->
            undefined
    end.

%% The make of PATH, not this program (the value of MAKE). elixir_make
%% uses gmake on the BSDs (the make there is not GNU make).
find_make(Self) ->
    Names = case os:type() of
                {unix, OS} when OS =:= freebsd; OS =:= openbsd; OS =:= netbsd;
                                OS =:= dragonfly -> ["gmake", "make"];
                _ -> ["make", "gmake"]
            end,
    Found = [F || N <- Names, F <- [os:find_executable(N)], F =/= false,
                  filename:absname(F) =/= filename:absname(Self)],
    case Found of
        [Make | _] -> Make;
        [] -> false
    end.

%% Run Make with Args, with its output on standard output. Returns its
%% exit status. Without MAKE: GNU make takes $(MAKE) from the environment,
%% so a Makefile that runs $(MAKE) would start this program again.
make(Make, Args) ->
    Port = open_port({spawn_executable, Make},
                     [{args, Args}, {env, [{"MAKE", false}]}, exit_status, binary,
                      stream, stderr_to_stdout]),
    make_loop(Port).

make_loop(Port) ->
    receive
        {Port, {data, Data}} ->
            ok = file:write(standard_io, Data),
            make_loop(Port);
        {Port, {exit_status, Status}} ->
            Status
    end.

%% The name of beam.com for the messages. This program is a link named
%% make to it (a script on macOS, which starts the file itself).
name() ->
    case init:get_argument(beam_com_exe) of
        {ok, [[Exe | _] | _]} ->
            case file:read_link_all(Exe) of
                {ok, Target} -> filename:rootname(filename:basename(Target)) ++ ".com";
                {error, _} -> beam_com:name()
            end;
        _ ->
            beam_com:name()
    end.

nifs() ->
    _ = application:load(beam_com),
    case application:get_env(beam_com, nifs) of
        {ok, Nifs} when is_list(Nifs) -> Nifs;
        _ -> []
    end.
