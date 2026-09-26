%% beam.com build: make a new executable from Erlang source code.
%%
%% The input is one .erl file with main/1 (as for escript), or an
%% application directory (src/*.erl, src/NAME.app.src or ebin/NAME.app,
%% and optionally include/, priv/, config/sys.config and
%% config/vm.args). The builder compiles the code, makes an OTP release
%% with the applications that the code needs, and writes a copy of this
%% executable with the release in its zip. It needs no Erlang
%% installation: the compiler and the OTP applications are in the zip
%% of beam.com.
-module(beam_com_build).

-export([run/1]).

-ifdef(TEST).
-export([split_dir/1, default_output/1, base_apps/1, script/1, app_dir/1,
         select_apps/3, app_files/1, release/5, relocate/2, with_dirs/1,
         parents/1, keep/2, executable/0]).
-endif.

-define(ROOT, "/zip").
-define(DEFAULT_VSN, "0.1.0").

%% Opts: input, apps, and optionally output. root (the zip, "/zip") and
%% exe (the path of this executable) are for the tests.
run(#{input := Input0, apps := ExtraApps} = Opts) ->
    Input = string:trim(Input0, trailing, "/\\"),
    Output = maps:get(output, Opts, default_output(Input)),
    Root = maps:get(root, Opts, ?ROOT),
    Base = base_apps(Root),
    App = case filelib:is_dir(Input) of
              true -> app_dir(Input);
              false -> script(Input)
          end,
    Apps = select_apps(App, ExtraApps, Base),
    Exe = case Opts of
              #{exe := E} -> E;
              _ -> executable()
          end,
    {ok, Bin} = read_file(Exe),
    Tmp = filename:absname(filename:join(filename:dirname(Output),
                                         "." ++ filename:basename(Output)
                                         ++ ".tmp")),
    _ = file:del_dir_r(Tmp),
    Release = try release(App, Apps, Base, Tmp, Root)
              after file:del_dir_r(Tmp)
              end,
    New = with_dirs(app_files(App) ++ Release),
    Keep = keep(Apps, Base),
    Data = beam_com_zip:write(Bin, Keep, New),
    write_file(Output, Data),
    _ = file:change_mode(Output, 8#755),
    io:format("beam.com: wrote ~ts (~b bytes)~n"
              "  release: ~s ~s~n"
              "  applications: ~s~n",
              [Output, iolist_size(Data), maps:get(name, App),
               maps:get(vsn, App),
               lists:join(" ", [atom_to_list(A) || A <- Apps])]).

default_output(Input) ->
    filename:basename(Input, ".erl") ++ ".com".

%% The executable that runs, from beam_com.c.
executable() ->
    case init:get_argument(beam_com_exe) of
        {ok, [[Exe]]} -> Exe;
        _ -> throw({error, "the path of beam.com is not known", []})
    end.

%% The OTP applications in the zip of beam.com: #{Name => Info}.
base_apps(Root) ->
    LibDir = filename:join(Root, "lib"),
    {ok, Dirs} = file:list_dir(LibDir),
    maps:from_list(
      [{Name, #{vsn => Vsn, dir => filename:join(LibDir, Dir),
                props => Props}}
       || Dir <- Dirs,
          {Name, Vsn} <- [split_dir(Dir)], Vsn =/= none,
          {ok, [{application, _, Props}]}
              <- [file:consult(filename:join([LibDir, Dir, "ebin",
                                              atom_to_list(Name) ++ ".app"]))]]).

split_dir(Dir) ->
    case string:split(Dir, "-", trailing) of
        [Name, Vsn] -> {list_to_atom(Name), Vsn};
        _ -> {list_to_atom(Dir), none}
    end.

%% One .erl file with main/1.
script(File) ->
    filename:extension(File) =:= ".erl"
        orelse throw({error, "~ts: not a .erl file or a directory", [File]}),
    filelib:is_regular(File)
        orelse throw({error, "~ts: no such file", [File]}),
    {Mod, Beam} = compile(File, []),
    lists:member({main, 1}, exports(Beam))
        orelse throw({error, "~ts: main/1 is not exported", [File]}),
    Props = [{description, atom_to_list(Mod)},
             {vsn, ?DEFAULT_VSN},
             {modules, [Mod]},
             {registered, []},
             {applications, [kernel, stdlib, beam_com_script]},
             {mod, {beam_com_script, Mod}}],
    #{name => Mod, vsn => ?DEFAULT_VSN, props => Props,
      beams => [{Mod, Beam}], priv => [], config => [],
      script => true}.

%% An application directory.
app_dir(Dir) ->
    {Name, Props0} = app_file(Dir),
    ErlOpts = erl_opts(Dir),
    Includes = [{i, filename:join(Dir, "include")},
                {i, filename:join(Dir, "src")}],
    Sources = filelib:wildcard(filename:join([Dir, "src", "**", "*.erl"])),
    Beams = [compile(Src, Includes ++ ErlOpts) || Src <- Sources],
    Vsn = case proplists:get_value(vsn, Props0) of
              V when is_list(V) -> V;
              _ -> ?DEFAULT_VSN
          end,
    %% systools needs these keys. A minimal .app.src may not have them.
    Defaults = [{description, atom_to_list(Name)}, {registered, []},
                {applications, [kernel, stdlib]}],
    Props1 = Props0 ++ [D || {K, _} = D <- Defaults,
                             not lists:keymember(K, 1, Props0)],
    Props = lists:keystore(vsn, 1,
                           lists:keystore(modules, 1, Props1,
                                          {modules, [M || {M, _} <- Beams]}),
                           {vsn, Vsn}),
    PrivDir = filename:join(Dir, "priv"),
    Priv = [{File, element(2, {ok, _} = file:read_file(
                                          filename:join(PrivDir, File)))}
            || File <- filelib:wildcard("**", PrivDir),
               filelib:is_regular(filename:join(PrivDir, File))],
    Config = [{File, Data}
              || File <- ["sys.config", "vm.args"],
                 {ok, Data} <- [file:read_file(
                                  filename:join([Dir, "config", File]))]],
    #{name => Name, vsn => Vsn, props => Props, beams => Beams,
      priv => Priv, config => Config, script => false}.

app_file(Dir) ->
    Files = filelib:wildcard(filename:join([Dir, "src", "*.app.src"]))
        ++ filelib:wildcard(filename:join([Dir, "ebin", "*.app"])),
    case Files of
        [File | _] ->
            case file:consult(File) of
                {ok, [{application, Name, Props}]} -> {Name, Props};
                _ -> throw({error, "~ts: not an application file", [File]})
            end;
        [] ->
            throw({error, "~ts: no src/*.app.src or ebin/*.app", [Dir]})
    end.

%% The erl_opts of a rebar.config, when there is one.
erl_opts(Dir) ->
    case file:consult(filename:join(Dir, "rebar.config")) of
        {ok, Terms} -> proplists:get_value(erl_opts, Terms, []);
        _ -> []
    end.

compile(File, Opts) ->
    case compile:file(File, [binary, report_errors, report_warnings
                             | Opts]) of
        {ok, Mod, Beam} -> {Mod, Beam};
        {ok, Mod, Beam, _Warnings} -> {Mod, Beam};
        _ -> throw({error, "~ts: compilation failed", [File]})
    end.

exports(Beam) ->
    {ok, {_, [{exports, Exports}]}} = beam_lib:chunks(Beam, [exports]),
    Exports.

imports(Beam) ->
    {ok, {_, [{imports, Imports}]}} = beam_lib:chunks(Beam, [imports]),
    lists:usort([M || {M, _, _} <- Imports]).

%% The OTP applications of the release: the applications that the
%% program names, the applications of the modules that it calls, the
%% applications of the -a options, and all the applications that these
%% need.
select_apps(#{name := Name, props := Props, beams := Beams}, Extra, Base) ->
    Own = [M || {M, _} <- Beams],
    Index = maps:from_list(
              [{M, A} || A := #{props := P} <- Base, A =/= Name,
                         M <- proplists:get_value(modules, P, [])]),
    Imports = [{Mod, M} || {Mod, Beam} <- Beams, M <- imports(Beam),
                           not lists:member(M, Own)],
    Called = [maps:get(M, Index) || {_, M} <- Imports, is_map_key(M, Index)],
    %% A call to a module that is nowhere fails at run time (undef).
    Preloaded = erlang:pre_loaded(),
    [io:format(standard_error,
               "beam.com: warning: ~p calls ~p, which is not in beam.com~n",
               [Mod, M])
     || {Mod, M} <- lists:usort(Imports), not is_map_key(M, Index),
        not lists:member(M, Preloaded)],
    Roots = [kernel, stdlib] ++ deps(Props) ++ Extra ++ Called,
    closure(lists:usort(Roots) -- [Name], Base, Name, []).

deps(Props) ->
    proplists:get_value(applications, Props, [])
        ++ proplists:get_value(included_applications, Props, []).

closure([], _Base, _Name, Done) ->
    lists:reverse(Done);
closure([App | Rest], Base, Name, Done) ->
    case lists:member(App, Done) of
        true ->
            closure(Rest, Base, Name, Done);
        false ->
            case Base of
                #{App := #{props := Props}} ->
                    closure((deps(Props) -- [Name]) ++ Rest, Base, Name,
                            [App | Done]);
                _ ->
                    throw({error, "the application ~p is not in beam.com",
                           [App]})
            end
    end.

%% The files of the program application in the zip.
app_files(#{name := Name, vsn := Vsn, props := Props, beams := Beams,
            priv := Priv}) ->
    Dir = "lib/" ++ atom_to_list(Name) ++ "-" ++ Vsn,
    [{Dir ++ "/ebin/" ++ atom_to_list(Name) ++ ".app",
      io_lib:format("~tp.~n", [{application, Name, Props}])}]
        ++ [{Dir ++ "/ebin/" ++ atom_to_list(M) ++ ".beam", Beam}
            || {M, Beam} <- Beams]
        ++ [{Dir ++ "/priv/" ++ File, Data} || {File, Data} <- Priv].

%% Make the boot script with systools, and the files of releases/.
release(#{name := Name0, vsn := Vsn, props := Props, beams := Beams,
          config := Config}, Apps, Base, Tmp, Root) ->
    Name = atom_to_list(Name0),
    AppDir = filename:join([Tmp, "lib", Name ++ "-" ++ Vsn]),
    Ebin = filename:join(AppDir, "ebin"),
    ok = filelib:ensure_path(Ebin),
    write_file(filename:join(Ebin, Name ++ ".app"),
               io_lib:format("~tp.~n", [{application, Name0, Props}])),
    [write_file(filename:join(Ebin, atom_to_list(M) ++ ".beam"), Beam)
     || {M, Beam} <- Beams],
    ErtsVsn = erlang:system_info(version),
    Rel = {release, {Name, Vsn}, {erts, ErtsVsn},
           [{A, maps:get(vsn, maps:get(A, Base))} || A <- Apps]
           ++ [{Name0, Vsn}]},
    RelText = io_lib:format("~tp.~n", [Rel]),
    RelFile = filename:join(Tmp, Name),
    write_file(RelFile ++ ".rel", RelText),
    Path = [filename:join(maps:get(dir, maps:get(A, Base)), "ebin")
            || A <- Apps] ++ [Ebin],
    case systools:make_script(RelFile,
                              [{path, Path}, {outdir, Tmp}, silent,
                               no_warn_sasl,
                               {variables, [{"ROOT", Root}]}]) of
        ok -> ok;
        {ok, _, _Warnings} -> ok;
        {error, Mod, Error} ->
            throw({error, "systools: ~ts", [Mod:format_error(Error)]})
    end,
    %% The program application is in the temporary directory. In the
    %% executable it is in /zip, as the others.
    {ok, [Script]} = file:consult(RelFile ++ ".script"),
    Boot = term_to_binary(relocate(Script, Tmp)),
    Dir = "releases/" ++ Vsn ++ "/",
    VmArgs = proplists:get_value("vm.args", Config, <<"-noshell\n">>),
    [{Dir ++ "start.boot", Boot},
     {Dir ++ Name ++ ".rel", RelText},
     {Dir ++ "vm.args", VmArgs}]
        ++ [{Dir ++ "sys.config", Data}
            || {"sys.config", Data} <- Config]
        ++ [{"releases/start_erl.data", [ErtsVsn, " ", Vsn, "\n"]}].

relocate(Term, Tmp) when is_tuple(Term) ->
    list_to_tuple(relocate(tuple_to_list(Term), Tmp));
relocate(Term, Tmp) when is_list(Term) ->
    case io_lib:char_list(Term) andalso lists:prefix(Tmp ++ "/", Term) of
        true -> "$ROOT" ++ lists:nthtail(length(Tmp), Term);
        false -> [relocate(T, Tmp) || T <- Term]
    end;
relocate(Term, _Tmp) ->
    Term.

%% Add the directory entries of the new files.
with_dirs(Files) ->
    Dirs = lists:usort([D || {Name, _} <- Files, D <- parents(Name)]),
    [{D, <<>>} || D <- Dirs] ++ Files.

parents(Name) ->
    Parts = lists:droplast(string:split(Name, "/", all)),
    [lists:flatten(lists:join("/", lists:sublist(Parts, N))) ++ "/"
     || N <- lists:seq(1, length(Parts))].

%% The entries of beam.com that the new executable keeps: everything
%% except the releases, .args, and the applications that the release
%% does not use. Of the applications, only ebin/ and priv/ are needed.
keep(Apps, Base) ->
    Dirs = ["lib/" ++ atom_to_list(A) ++ "-" ++ maps:get(vsn, maps:get(A, Base))
            ++ "/" || A <- Apps],
    fun("lib/") -> true;
       ("lib/" ++ _ = Name) ->
            lists:any(fun(Dir) -> keep_app_file(Dir, Name) end, Dirs);
       ("releases/" ++ _) -> false;
       (".args") -> false;
       (_) -> true
    end.

keep_app_file(Dir, Name) ->
    case lists:prefix(Dir, Name) of
        true ->
            Rest = lists:nthtail(length(Dir), Name),
            Rest =:= "" orelse lists:prefix("ebin/", Rest)
                orelse lists:prefix("priv/", Rest);
        false ->
            false
    end.

read_file(File) ->
    case file:read_file(File) of
        {ok, Bin} -> {ok, Bin};
        {error, Reason} ->
            throw({error, "~ts: ~ts", [File, file:format_error(Reason)]})
    end.

write_file(File, Data) ->
    case file:write_file(File, Data) of
        ok -> ok;
        {error, Reason} ->
            throw({error, "~ts: ~ts", [File, file:format_error(Reason)]})
    end.
