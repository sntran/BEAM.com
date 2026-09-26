%% beam.com build: make a new executable from Erlang source code.
%%
%% The input is one .erl file with main/1 (as for escript), or an
%% application directory (src/*.erl, src/NAME.app.src or ebin/NAME.app,
%% and optionally include/, priv/, config/sys.config and
%% config/vm.args; .yrl and .xrl files in src/, and ASN.1 files in asn1/
%% or src/). The builder compiles the code, makes an OTP release
%% with the applications that the code needs, and writes a copy of this
%% executable with the release in its zip. It needs no Erlang
%% installation: the compiler and the OTP applications are in the zip
%% of beam.com.
-module(beam_com_build).

-export([run/1, check_promises/1, check_unveil/1, check_native/1]).

-ifdef(TEST).
-export([split_dir/1, default_output/1, base_apps/1, script/1, app_dir/1,
         select_apps/3, app_files/1, release/5, relocate/2, with_dirs/1,
         parents/1, keep/2, executable/0, slashes/2, generate/2, native/2]).
-endif.

-define(ROOT, "/zip").
-define(DEFAULT_VSN, "0.1.0").

%% Opts: input, apps, and optionally output. root (the zip, "/zip") and
%% exe (the path of this executable) are for the tests.
run(#{input := Input0, apps := ExtraApps} = Opts) ->
    Input = string:trim(slashes(Input0, os:type()), trailing, "/\\"),
    Output = slashes(maps:get(output, Opts, default_output(Input)), os:type()),
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
    New = with_dirs(app_files(App) ++ Release ++ sandbox_files(Opts)),
    Keep = keep(Apps, Base),
    Data = case Opts of
               #{native := Target} ->
                   native(Target, iolist_to_binary(beam_com_zip:write(Bin, Keep, New)));
               _ ->
                   beam_com_zip:write(Bin, Keep, New)
           end,
    write_file(Output, Data),
    _ = file:change_mode(Output, 8#755),
    io:format("beam.com: wrote ~ts (~b bytes)~n"
              "  release: ~s ~s~n"
              "  applications: ~s~n",
              [Output, iolist_size(Data), maps:get(name, App),
               maps:get(vsn, App),
               lists:join(" ", [atom_to_list(A) || A <- Apps])]).

%% ERTS in BEAM.com is the Unix build also on Windows (os:type() is
%% {unix, windows}), so the filename module does not take "\\" as a
%% separator, but Windows does: "bin\\x.com" would be one file name in the
%% directory ".". Paths from the command line get "/" instead.
slashes(Path, {_, windows}) -> lists:flatten(string:replace(Path, "\\", "/", all));
slashes(Path, _) -> Path.

%% The sandbox of the program (see beam_com.c): /zip/.pledge has the
%% promises, /zip/.unveil one "PERMISSIONS PATH" rule on each line.
sandbox_files(Opts) ->
    [{".pledge", [P, "\n"]} || #{pledge := P} <- [Opts]]
        ++ [{".unveil", [[R, "\n"] || R <- Rules]}
            || #{unveil := Rules} <- [Opts], Rules =/= []].

-define(PROMISES, ["stdio", "rpath", "wpath", "cpath", "dpath", "flock",
                   "fattr", "inet", "anet", "unix", "dns", "tty", "recvfd",
                   "sendfd", "proc", "exec", "id", "unveil", "settime",
                   "prot_exec", "vminfo", "tmppath", "chown"]).

%% The promises of --pledge, checked (the names of Cosmopolitan's
%% pledge()), separated by one space.
check_promises(Promises) ->
    Words = string:lexemes(Promises, " \t"),
    case [W || W <- Words, not lists:member(W, ?PROMISES)] of
        [] -> lists:flatten(lists:join(" ", Words));
        [Bad | _] -> throw({error, "unknown promise ~ts (see beam.com help build)", [Bad]})
    end.

%% An --unveil rule, checked: "PERMISSIONS PATH".
check_unveil(Rule) ->
    case string:split(string:trim(Rule), " ") of
        [Perms, Path0] ->
            Path = string:trim(Path0),
            case Perms =/= "" andalso Path =/= ""
                andalso lists:all(fun(C) -> lists:member(C, "rwxc") end, Perms) of
                true -> Perms ++ " " ++ Path;
                false -> bad_unveil(Rule)
            end;
        _ ->
            bad_unveil(Rule)
    end.

bad_unveil(Rule) ->
    throw({error, "--unveil needs \"PERMISSIONS PATH\", with PERMISSIONS of "
           "r, w, x and c: ~ts", [Rule]}).

%% --native TARGET: a file for one system, as Cosmopolitan's assimilate
%% makes it. The APE file starts with a shell script, which has the
%% headers of the native formats: printf '...' writes the 64-byte ELF
%% header of each CPU, and a dd command copies the Mach-O header of
%% x86_64 from inside the file. The new file starts with that header; the
%% rest does not change, so the offsets of the zip stay correct. Apple
%% Silicon runs APE files only through the APE loader (no arm64 Mach-O).
-define(NATIVE, [{"linux-x86_64", {elf, 16#3e, sysv}},
                 {"linux-aarch64", {elf, 16#b7, sysv}},
                 {"freebsd-x86_64", {elf, 16#3e, freebsd}},
                 {"macos-x86_64", {macho, 16#01000007}}]).

check_native(Target) ->
    case lists:keymember(Target, 1, ?NATIVE) of
        true -> Target;
        false ->
            throw({error, "unknown native target ~ts (one of: ~ts)",
                   [Target, lists:join(", ", [T || {T, _} <- ?NATIVE])]})
    end.

native(Target, Bin) ->
    Head = case proplists:get_value(Target, ?NATIVE) of
               {elf, Machine, Abi} -> elf_header(Bin, Machine, Abi);
               {macho, Cpu} -> macho_header(Bin, Cpu)
           end,
    <<Head/binary, (binary:part(Bin, byte_size(Head), byte_size(Bin) - byte_size(Head)))/binary>>.

%% The ELF header in a printf '...' of the first 8 KB, for the CPU.
elf_header(Bin, Machine, Abi) ->
    Script = binary:part(Bin, 0, min(8192, byte_size(Bin))),
    Headers = [H || {Pos, Len} <- binary:matches(Script, <<"printf '">>),
                    H <- [printf_bytes(binary:part(Script, Pos + Len,
                                                   byte_size(Script) - Pos - Len), <<>>)],
                    byte_size(H) =:= 64,
                    match_elf(H, Machine)],
    case Headers of
        [<<Ident:7/binary, OsAbi, Rest/binary>> | _] ->
            %% The kernels other than FreeBSD do not look at the OS ABI;
            %% assimilate sets it to System V (0) for them.
            NewAbi = case {Abi, OsAbi} of
                         {sysv, 9} -> 0;
                         _ -> OsAbi
                     end,
            <<Ident/binary, NewAbi, Rest/binary>>;
        [] ->
            throw({error, "no ELF header for this CPU in the APE file", []})
    end.

match_elf(<<127, "ELF", 2, _:11/binary, _Type:16/little, M:16/little, _/binary>>, M) -> true;
match_elf(_, _) -> false.

%% The bytes of a printf format: \NNN is an octal byte, ' ends it.
printf_bytes(<<$', _/binary>>, Acc) -> Acc;
printf_bytes(<<$\\, A, B, C, Rest/binary>>, Acc)
  when A >= $0, A =< $7, B >= $0, B =< $7, C >= $0, C =< $7 ->
    printf_bytes(Rest, <<Acc/binary, ((A - $0) * 64 + (B - $0) * 8 + C - $0)>>);
printf_bytes(<<$\\, A, B, Rest/binary>>, Acc)
  when A >= $0, A =< $7, B >= $0, B =< $7 ->
    printf_bytes(Rest, <<Acc/binary, ((A - $0) * 8 + B - $0)>>);
printf_bytes(<<$\\, A, Rest/binary>>, Acc) when A >= $0, A =< $7 ->
    printf_bytes(Rest, <<Acc/binary, (A - $0)>>);
printf_bytes(<<C, Rest/binary>>, Acc) ->
    printf_bytes(Rest, <<Acc/binary, C>>);
printf_bytes(<<>>, _) ->
    <<>>.

%% The Mach-O header that a dd command of the script copies: bs, skip
%% and count give its place and size in the file.
macho_header(Bin, Cpu) ->
    Script = binary:part(Bin, 0, min(8192, byte_size(Bin))),
    Re = "bs=(['\"] *)?(\\$\\(\\( *)?([0-9]+)( *\\)\\))?( *['\"])? +"
         "skip=(['\"] *)?(\\$\\(\\( *)?([0-9]+)( *\\)\\))?( *['\"])? +"
         "count=(['\"] *)?(\\$\\(\\( *)?([0-9]+)",
    Matches = case re:run(Script, Re, [global, {capture, [3, 8, 13], list}]) of
                  {match, M} -> M;
                  nomatch -> []
              end,
    Headers = [binary:part(Bin, Offset, Size)
               || [Bs, Skip, Count] <- Matches,
                  Offset <- [list_to_integer(Skip) * list_to_integer(Bs)],
                  Size <- [list_to_integer(Count) * list_to_integer(Bs)],
                  Offset >= 64, Size >= 32, Offset + Size =< byte_size(Bin),
                  binary:part(Bin, Offset, 8) =:= <<16#feedfacf:32/little, Cpu:32/little>>],
    case Headers of
        [H | _] -> H;
        [] -> throw({error, "no Mach-O header for this CPU in the APE file", []})
    end.

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
    Gen = temp_dir("gen"),
    Beams = try
                Generated = generate(Dir, Gen),
                Includes = [{i, filename:join(Dir, "include")},
                            {i, filename:join(Dir, "src")},
                            {i, Gen}],
                Sources = filelib:wildcard(filename:join([Dir, "src", "**", "*.erl"]))
                    ++ Generated,
                [compile(Src, Includes ++ ErlOpts) || Src <- Sources]
            after
                file:del_dir_r(Gen)
            end,
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

%% The source files that are made from other files, into the directory
%% Gen: parsers (.yrl, yecc), scanners (.xrl, leex) and ASN.1 modules
%% (.asn1 and .asn in asn1/ or src/, asn1ct, with the BER encoding). A
%% .yrl or .xrl file with an .erl file of the same name next to it is left
%% out: the .erl file is used (rebar3 writes it there). The result is the
%% list of the .erl files in Gen.
generate(Dir, Gen) ->
    ok = filelib:ensure_path(Gen),
    Src = filename:join(Dir, "src"),
    Made = fun(File) -> filelib:is_regular(filename:rootname(File) ++ ".erl") end,
    Yrl = [F || F <- filelib:wildcard(filename:join([Src, "**", "*.yrl"])), not Made(F)],
    Xrl = [F || F <- filelib:wildcard(filename:join([Src, "**", "*.xrl"])), not Made(F)],
    Asn = lists:append([filelib:wildcard(filename:join(D, "*." ++ Ext))
                        || D <- [filename:join(Dir, "asn1"), Src],
                           Ext <- ["asn1", "asn"]]),
    [yecc(F, Gen) || F <- Yrl],
    [leex(F, Gen) || F <- Xrl],
    [asn1(F, Gen) || F <- Asn],
    filelib:wildcard(filename:join(Gen, "*.erl")).

yecc(File, Gen) ->
    Out = filename:join(Gen, filename:basename(File, ".yrl") ++ ".erl"),
    case yecc:file(File, [{parserfile, Out}, report_errors, report_warnings]) of
        {ok, _} -> ok;
        {ok, _, _} -> ok;
        _ -> throw({error, "~ts: yecc failed", [File]})
    end.

leex(File, Gen) ->
    Out = filename:join(Gen, filename:basename(File, ".xrl") ++ ".erl"),
    case leex:file(File, [{scannerfile, Out}, report_errors, report_warnings]) of
        {ok, _} -> ok;
        {ok, _, _} -> ok;
        _ -> throw({error, "~ts: leex failed", [File]})
    end.

%% asn1ct names the .erl and .hrl files after the file (pair.asn1:
%% pair.erl), but the module after the ASN.1 module ('Pair'), and the
%% .erl file includes "Pair.hrl". The files are renamed after the module.
asn1(File, Gen) ->
    case asn1ct:compile(File, [noobj, ber, {outdir, Gen}, {i, Gen}]) of
        ok -> ok;
        _ -> throw({error, "~ts: the ASN.1 compiler failed", [File]})
    end,
    Base = filename:join(Gen, filename:rootname(filename:basename(File))),
    {ok, Source} = file:read_file(Base ++ ".erl"),
    {match, [Module]} = re:run(Source, "^-module\\('?([^')]+)'?\\)\\.",
                               [multiline, {capture, all_but_first, list}]),
    New = filename:join(Gen, Module),
    case New =:= Base of
        true -> ok;
        false ->
            ok = file:rename(Base ++ ".erl", New ++ ".erl"),
            ok = file:rename(Base ++ ".hrl", New ++ ".hrl")
    end.

%% A new directory for temporary files.
temp_dir(What) ->
    Base = hd([D || V <- ["TMPDIR", "TMP", "TEMP"],
                    D <- [os:getenv(V)], D =/= false, D =/= ""] ++ ["/tmp"]),
    filename:join(Base, lists:concat(["beam_com_", What, "_", os:getpid(), "_",
                                      erlang:unique_integer([positive])])).

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
       (".pledge") -> false;
       (".unveil") -> false;
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
