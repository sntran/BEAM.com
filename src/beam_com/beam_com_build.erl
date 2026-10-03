%% beam.com INPUT -o OUTPUT: make a new executable from Erlang source code.
%%
%% The input is one .erl file with main/1 (as for escript), or an
%% application directory (src/*.erl, src/NAME.app.src or ebin/NAME.app,
%% and optionally include/, priv/, config/sys.config and
%% config/vm.args; .yrl and .xrl files in src/, and ASN.1 files in asn1/
%% or src/). The builder compiles the code, makes an OTP release
%% with the applications that the code needs, and writes a copy of this
%% executable with the release in its zip. It needs no Erlang
%% installation: the compiler and the OTP applications are in the zip
%% of beam.com. The input can also be a release directory
%% (_build/prod/rel/NAME of "mix release", or of rebar3).
%%
%% The zip of the new file also has its edge part (.wasm/, see
%% beam_com_wasm:overlay/4), unless --no-edge: then the same file runs in
%% the WebAssembly runtime too (Workers, Deno, a web page).
-module(beam_com_build).

-export([run/1, allow/2, check_target/1, split_dir/1, temp_dir/1, executable/0]).

-ifdef(TEST).
-export([default_output/1, base_apps/1, script/1, app_dir/1,
         select_apps/3, app_files/1, release/5, relocate/2, with_dirs/1,
         parents/1, keep/2, slashes/2, generate/2, native/2,
         base_kind/1, check_base/2,
         tool/2, main/3, with_main/2, priv_files/1, extract/3, hash/1,
         without_docs/3,
         with_extract/2, compile_all/2, first_names/1]).
-endif.

-include_lib("kernel/include/file.hrl").

-define(ROOT, "/zip").
-define(DEFAULT_VSN, "0.1.0").
-define(WASM, "wasm32-unknown-emscripten").

%% Opts: input, apps, and optionally output. root (the zip, "/zip") and
%% exe (the path of this executable) are for the tests.
run(#{input := Input0, apps := ExtraApps} = Opts) ->
    Wasm = maps:get(target, Opts, none) =:= ?WASM,
    Wasm andalso maps:get(edge, Opts, true) =:= false andalso
        throw({error, "--no-edge is for native files, not for --target wasm32", []}),
    Input = string:trim(slashes(Input0, os:type()), trailing, "/\\"),
    Output = slashes(maps:get(output, Opts, default_output(Input)), os:type()),
    Root = maps:get(root, Opts, ?ROOT),
    Base = base_apps(Root),
    case {Wasm, Wasm andalso beam_com_wasm:app_com(Input)} of
        {true, App} when is_binary(App) ->
            %% A native app.com: its edge part has the release.
            maps:is_key(cacerts, Opts) andalso
                throw({error, "--cacerts is for a build; ~ts has its certificates", [Input]}),
            beam_com_wasm:write_app(Output, Input, App, Opts#{root => Root});
        _ ->
            run(Input, Output, Opts, ExtraApps, Base, Root, Wasm)
    end.

run(Input, Output, Opts, ExtraApps, Base, Root, Wasm) ->
    case {Wasm, beam_com_wasm:release_dir(Input, Root)} of
        {_, false} -> build_input(Input, Output, Opts, ExtraApps, Base, Root);
        {true, Rel} -> beam_com_wasm:write(Output, Rel, Opts#{root => Root});
        {false, Rel} -> release_exe(Input, Output, Opts, Rel, Root)
    end.

build_input(Input, Output, Opts, ExtraApps, Base, Root) ->
    DepsLib = temp_dir("deps"),
    try build(Input, Output, Opts, ExtraApps, Base, Root, DepsLib)
    after
        [code:del_path(P) || P <- code:get_path(), lists:prefix(DepsLib, P)],
        file:del_dir_r(DepsLib)
    end.

build(Input, Output, Opts, ExtraApps0, Base0, Root, DepsLib) ->
    Wasm = maps:get(target, Opts, none) =:= ?WASM,
    %% The new file is a copy of this executable: check its format first.
    Wasm orelse check_base(Opts),
    Wasm andalso maps:is_key(allow, Opts) andalso
        throw({error, "--allow-* is for native files, not for --target wasm32", []}),
    {App0, Deps} = case filelib:is_dir(Input) of
                       true ->
                           Tool = tool(Input, Opts),
                           Ds = deps(Input, DepsLib, Tool),
                           {app_dir(Input, #{tool => Tool}), Ds};
                       false ->
                           {script(Input), []}
                   end,
    {App, ExtraApps} = case main(Input, Opts, App0) of
                           none -> {App0, ExtraApps0};
                           Main -> {with_main(App0, Main), ExtraApps0 ++ [beam_com_script]}
                       end,
    Base = maps:merge(Base0, maps:from_list([{N, D} || #{name := N} = D <- Deps])),
    Apps0 = select_apps(App, ExtraApps, Base),
    %% The priv directories that must be real files (beam_com_script).
    Extract = extract(App, [D || #{name := N} = D <- Deps, lists:member(N, Apps0)],
                      maps:get(extract_priv, Opts, [])),
    Apps = case Extract =/= [] andalso not lists:member(beam_com_script, Apps0) of
               true -> select_apps(App, ExtraApps ++ [beam_com_script], Base);
               false -> Apps0
           end,
    AppX = with_extract(App, Extract),
    DepFiles = lists:append([app_files(D) || #{name := N} = D <- Deps,
                                             lists:member(N, Apps)]),
    Tmp = new_dir(filename:absname(filename:dirname(Output)),
                  "." ++ filename:basename(Output) ++ ".tmp."),
    Release = try release(AppX, Apps, Base, Tmp, Root)
              after file:del_dir_r(Tmp)
              end,
    Kept = [A || A <- Apps, is_map_key(A, Base0)],
    case Wasm of
        true ->
            %% The applications of the zip, all their files (ebin, priv).
            Zip = [{"lib/" ++ Dir ++ "/" ++ F, D}
                   || A <- Kept, Dir <- [atom_to_list(A) ++ "-" ++ maps:get(vsn, maps:get(A, Base0))],
                      {F, D} <- zip_app_files(filename:join([Root, "lib", Dir]))],
            beam_com_wasm:write(Output, #{name => atom_to_list(maps:get(name, App)),
                                          vsn => maps:get(vsn, App), kind => beam_com,
                                          files => app_files(App) ++ DepFiles ++ Release ++ Zip},
                                Opts#{root => Root});
        false ->
            write_exe(Output, Opts, App, Apps, Kept, DepFiles, Release, Base0, Root)
    end.

zip_app_files(Dir) ->
    Len = length(filename:split(Dir)),
    [{filename:join(Rel), case filename:extension(F) of
                              ".beam" -> strip(Data);
                              _ -> Data
                          end}
     || Sub <- ["ebin", "priv"], F <- filelib:wildcard(filename:join([Dir, Sub, "**"])),
        filelib:is_regular(F), Rel <- [lists:nthtail(Len, filename:split(F))],
        {ok, Data} <- [read_file(F)]].

write_exe(Output, Opts, App, Apps, Kept, DepFiles, Release, Base0, Root) ->
    Exe = case Opts of
              #{exe := E} -> E;
              _ -> executable()
          end,
    {ok, Bin} = read_file(Exe),
    Files = app_files(App) ++ DepFiles ++ Release ++ without_docs(Kept, Base0, Root),
    Keep = keep(Kept, Base0),
    Rel = #{name => atom_to_list(maps:get(name, App)), vsn => maps:get(vsn, App), kind => beam_com},
    Edge = edge(Files, [], Bin, Keep, Rel, Opts, Root),
    Data = exe_data(Bin, Keep, with_dirs(Files ++ sandbox_files(Opts)) ++ Edge, Opts),
    write_output(Output, Data),
    summary(Output, Data, Rel, Apps, Edge, Opts).

%% A release directory: the new file has the applications of the release,
%% and the applications of the zip of beam.com that the release names but
%% does not have, in the versions of the zip (beam_com_wasm:release_files/2
%% checked them). A Mix release also gets the variables of its start
%% script (native_release/3).
release_exe(Dir, Output, Opts, #{name := Name, vsn := Vsn, kind := Kind, files := Files0} = Rel,
            Root) ->
    check_base(Opts),
    Base0 = base_apps(Root),
    RelApps = rel_apps(Dir, Name, Vsn),
    InZip = [{A, V} || {A, V} <- RelApps,
                       not filelib:is_dir(filename:join([Dir, "lib", atom_to_list(A) ++ "-" ++ V, "ebin"]))],
    Kept = [A || {A, _} <- InZip],
    ZipDirs = ["lib/" ++ atom_to_list(A) ++ "-" ++ V ++ "/" || {A, V} <- InZip],
    Own = [F || {P, _} = F <- Files0, not lists:prefix("tmp/", P),
                not lists:any(fun(D) -> lists:prefix(D, P) end, ZipDirs)],
    {Native, Changed} = native_release(Own, Kind, Rel),
    Kind =:= mix andalso env_warning(Dir, Vsn, Opts),
    %% The runtime reads the files of the release as they are, and
    %% tmp/run.runtime.config of a Mix release (beam_com_wasm:meta/1).
    Originals = [F || {P, _} = F <- Own, lists:member(P, Changed)]
        ++ [F || {"tmp/" ++ _, _} = F <- Files0],
    Exe = case Opts of
              #{exe := E} -> E;
              _ -> executable()
          end,
    {ok, Bin} = read_file(Exe),
    Files = Native ++ without_docs(Kept, Base0, Root),
    Keep = keep(Kept, Base0),
    Edge = edge(Files, Originals, Bin, Keep, maps:with([name, vsn, kind], Rel), Opts, Root),
    Data = exe_data(Bin, Keep, with_dirs(Files ++ sandbox_files(Opts)) ++ Edge, Opts),
    write_output(Output, Data),
    summary(Output, Data, Rel, [A || {A, _} <- RelApps], Edge, Opts).

%% The applications of the .rel file of a release directory: [{App, Vsn}].
rel_apps(Dir, Name, Vsn) ->
    File = filename:join([Dir, "releases", Vsn, Name ++ ".rel"]),
    case file:consult(File) of
        {ok, [{release, _, _, Apps}]} -> [{element(1, A), element(2, A)} || A <- Apps];
        _ -> throw({error, "~ts: not a .rel file", [File]})
    end.

%% The files of a release directory in a native file. The start script of
%% a Mix release sets RELEASE_ROOT, RELEASE_SYS_CONFIG and other
%% variables, and gives -noshell and -boot_var RELEASE_LIB ("bin/NAME
%% start"). A native file has no start script: its boot script sets the
%% variables (os:putenv/2, before the config providers), and its vm.args
%% gives the flags. The files of a rebar3 release do not change. Returns
%% the files, and the paths of the files that changed.
native_release(Files, beam_com, _Rel) ->
    {Files, []};
native_release(Files, mix, #{name := Name, vsn := Vsn}) ->
    Dir = "releases/" ++ Vsn ++ "/",
    Env = [{"RELEASE_ROOT", ?ROOT}, {"RELEASE_NAME", Name}, {"RELEASE_VSN", Vsn},
           {"RELEASE_PROG", Name}, {"RELEASE_MODE", "interactive"},
           {"RELEASE_SYS_CONFIG", ?ROOT ++ "/" ++ Dir ++ "sys"}],
    Put = [{apply, {os, putenv, [K, V]}} || {K, V} <- Env],
    Boot = Dir ++ "start.boot",
    VmArgs = Dir ++ "vm.args",
    Change = fun({P, D}) when P =:= Boot ->
                     {script, Id, Cmds} = binary_to_term(iolist_to_binary(D)),
                     {P, term_to_binary({script, Id, with_env(Cmds, Put)})};
                ({P, D}) when P =:= VmArgs ->
                     {P, [D, "\n-noshell\n-boot_var RELEASE_LIB ", ?ROOT, "/lib\n"]};
                (F) -> F
             end,
    {[Change(F) || F <- Files], [Boot, VmArgs]}.

%% The start script of a Mix release runs releases/VSN/env.sh, and a
%% native file has no start script: a warning when env.sh has a line that
%% is not a comment.
env_warning(Dir, Vsn, Opts) ->
    File = filename:join([Dir, "releases", Vsn, "env.sh"]),
    Commands = case file:read_file(File) of
                   {ok, Data} ->
                       [L || L0 <- string:split(unicode:characters_to_list(Data), "\n", all),
                             L <- [string:trim(L0)], L =/= "", hd(L) =/= $#];
                   {error, _} ->
                       []
               end,
    Commands =:= [] orelse maps:get(quiet, Opts, false) orelse
        io:format(standard_error,
                  "~ts: warning: ~ts has commands, and the file does not run them: "
                  "set its variables when you start the file~n",
                  [beam_com:name(), File]).

%% The commands of the variables, before the config providers of Elixir,
%% else after the start of stdlib.
with_env(Cmds, Put) ->
    Provider = {apply, {'Elixir.Config.Provider', boot, []}},
    After = case lists:member(Provider, Cmds) of
                true -> fun(C) -> C =:= Provider end;
                false -> fun(C) -> element(1, C) =:= apply andalso
                                       element(2, C) =:= {application, start_boot, [stdlib, permanent]} end
            end,
    lists:flatmap(fun(C) ->
                          case {After(C), C =:= Provider} of
                              {true, true} -> Put ++ [C];
                              {true, false} -> [C | Put];
                              {false, _} -> [C]
                          end
                  end, Cmds).

%% The edge part of the new file (beam_com_wasm:overlay/4), at the end of
%% its zip: a reader gets it with the central directory. The runtime sees
%% the files of the zip, with Originals in their place. A file that the
%% zip of beam.com gives has no data here (the runtime reads it as it
%% is), but the NIF module of exqlite, which the edge part replaces.
edge(Files, Originals, Bin, Keep, Rel, Opts, Root) ->
    case maps:get(edge, Opts, true) of
        false ->
            [];
        true ->
            Names = sets:from_list([P || {P, _} <- Files], [{version, 2}]),
            InZip = [{N, kept_data(N, Root)} || N <- beam_com_zip:entries(Bin), Keep(N),
                                                lists:prefix("lib/", N), lists:last(N) =/= $/,
                                                not sets:is_element(N, Names)],
            Native = Files ++ InZip,
            Release = fun(P) -> lists:prefix("lib/", P) orelse lists:prefix("releases/", P) end,
            View = [{P, proplists:get_value(P, Originals, D)} || {P, D} <- Native, Release(P)]
                ++ [F || {P, _} = F <- Originals, not lists:keymember(P, 1, Native)],
            beam_com_wasm:overlay(View, Native, Rel, Opts#{root => Root})
    end.

kept_data(Name, Root) ->
    case lists:suffix("/ebin/Elixir.Exqlite.Sqlite3NIF.beam", Name) of
        true ->
            {ok, Data} = read_file(filename:join(Root, Name)),
            Data;
        false ->
            <<>>
    end.

exe_data(Bin, Keep, New, Opts) ->
    case Opts of
        #{target := Target} ->
            native(Target, iolist_to_binary(beam_com_zip:write(Bin, Keep, New)));
        _ ->
            beam_com_zip:write(Bin, Keep, New)
    end.

summary(Output, Data, #{name := Name, vsn := Vsn}, Apps, Edge, Opts) ->
    maps:get(quiet, Opts, false) orelse
        io:format("~ts: wrote ~ts (~b bytes)~n"
                  "  release: ~ts ~ts~n"
                  "  applications: ~ts~n"
                  "  ~ts~n",
                  [beam_com:name(), Output, iolist_size(Data), Name, Vsn,
                   lists:join(" ", [atom_to_list(A) || A <- Apps]),
                   case {Edge, maps:get(edge, Opts, true)} of
                       {[], false} -> "edge: none (--no-edge)";
                       {[], true} -> ["edge: none (no WebAssembly runtime in ", beam_com:name(), ")"];
                       _ -> io_lib:format("edge: ~b files (~b bytes) for the WebAssembly runtime",
                                          [length(Edge), iolist_size([D || {_, D} <- Edge])])
                   end]).

%% ERTS in BEAM.com is the Unix build also on Windows (os:type() is
%% {unix, windows}), so the filename module does not take "\\" as a
%% separator, but Windows does: "bin\\x.com" would be one file name in the
%% directory ".". Paths from the command line get "/" instead. A drive
%% ("C:\\x") becomes the form of Cosmopolitan ("/C/x"): for the filename
%% module, "C:/x" is a relative path, and filename:absname/1 would put
%% the working directory in front of it.
slashes(Path, {_, windows}) ->
    case lists:flatten(string:replace(Path, "\\", "/", all)) of
        [L, $:, $/ | Rest] when L >= $A, L =< $Z; L >= $a, L =< $z -> [$/, L, $/ | Rest];
        [L, $:] when L >= $A, L =< $Z; L >= $a, L =< $z -> [$/, L];
        P -> P
    end;
slashes(Path, _) -> Path.

%% The sandbox of the program (see beam_com.c): /zip/.allow has one
%% permission on each line, as the --allow-* flags without "--allow-":
%% "read", "read=/etc,/srv", "write=/tmp", "net", "run=git", or "all".
sandbox_files(#{allow := Allow}) ->
    [{".allow", allow_lines(Allow)}];
sandbox_files(_) ->
    [].

allow_lines(#{all := true}) ->
    "all\n";
allow_lines(Allow) ->
    [[allow_line(K, V), "\n"] || K <- [read, write, net, run],
                                 V <- [maps:get(K, Allow, none)], V =/= none].

allow_line(K, all) -> atom_to_list(K);
allow_line(net, true) -> "net";
allow_line(K, List) -> [atom_to_list(K), "=", lists:join(",", List)].

%% One --allow-* flag (or -R, -W, -N, -A), as the permission flags of
%% Deno, added to the permissions so far. A flag without a list allows
%% all; lists add up.
allow(Flag, Allow) ->
    case allow_flag(Flag) of
        {all, _} -> Allow#{all => true};
        {net, none} -> Allow#{net => true};
        {net, _} ->
            throw({error, "--allow-net takes no hosts: the sandbox cannot "
                   "filter the network by host", []});
        {K, none} when K =:= read; K =:= write; K =:= run -> Allow#{K => all};
        {K, Value} when K =:= read; K =:= write; K =:= run ->
            case {maps:get(K, Allow, []), string:lexemes(Value, ",")} of
                {_, []} -> throw({error, "~ts needs a list after \"=\"", [Flag]});
                {all, _} -> Allow;
                {Old, New} -> Allow#{K => Old ++ [N || N <- New, not lists:member(N, Old)]}
            end;
        unsupported ->
            throw({error, "~ts is not supported: the sandbox cannot enforce it "
                   "(see beam.com --help)", [Flag]});
        unknown ->
            throw({error, "unknown option ~ts", [Flag]})
    end.

allow_flag("-R") -> {read, none};
allow_flag("-W") -> {write, none};
allow_flag("-N") -> {net, none};
allow_flag("-A") -> {all, none};
allow_flag("--deny-" ++ _) -> unsupported;
allow_flag("--allow-" ++ Rest) ->
    {Name, Value} = case string:split(Rest, "=") of
                        [N] -> {N, none};
                        [N, V] -> {N, V}
                    end,
    case Name of
        "read" -> {read, Value};
        "write" -> {write, Value};
        "net" -> {net, Value};
        "run" -> {run, Value};
        "all" when Value =:= none -> {all, none};
        _ when Name =:= "env"; Name =:= "sys"; Name =:= "ffi";
               Name =:= "import"; Name =:= "hrtime" -> unsupported;
        _ -> unknown
    end;
allow_flag(_) ->
    unknown.

%% --target TARGET: a file for one system, as Cosmopolitan's assimilate
%% makes it. The APE file starts with a shell script, which has the
%% headers of the native formats: printf '...' writes the 64-byte ELF
%% header of each CPU, and a dd command copies the Mach-O header of
%% x86_64 from inside the file. The new file starts with that header; the
%% rest does not change, so the offsets of the zip stay correct. Apple
%% Silicon runs APE files only through the APE loader (no arm64 Mach-O).
%%
%% The names are the target triples of Rust (as deno compile uses them),
%% and the shorter ones of Zig: {Triple, Aliases, Header}.
-define(TARGETS,
        [{"x86_64-unknown-linux-gnu", ["x86_64-linux"], {elf, 16#3e, sysv}},
         {"aarch64-unknown-linux-gnu", ["aarch64-linux"], {elf, 16#b7, sysv}},
         {"x86_64-unknown-freebsd", ["x86_64-freebsd"], {elf, 16#3e, freebsd}},
         {"x86_64-apple-darwin", ["x86_64-macos"], {macho, 16#01000007}},
         %% Not a native file: a directory with the Workers of Cloudflare
         %% (beam_com_wasm).
         {"wasm32-unknown-emscripten", ["wasm32"], wasm}]).

%% The triple of a target name (or of an alias).
check_target(Name) ->
    case [T || {T, Aliases, _} <- ?TARGETS, Name =:= T orelse lists:member(Name, Aliases)] of
        [Triple] -> Triple;
        [] when Name =:= "aarch64-apple-darwin"; Name =:= "aarch64-macos" ->
            throw({error, "~ts: Apple Silicon has no native form; the APE file "
                   "runs there with the APE loader (build without --target)", [Name]});
        [] ->
            throw({error, "unknown target ~ts (one of: ~ts)",
                   [Name, lists:join(", ", [[T, " (", lists:join(", ", A), ")"]
                                            || {T, A, _} <- ?TARGETS])]})
    end.

native(Target, Bin) ->
    {_, _, Header} = lists:keyfind(Target, 1, ?TARGETS),
    case {base_kind(Bin), Header} of
        {{elf, Machine, _}, {elf, Machine, Abi}} ->
            %% A native file of this CPU (see check_base/2): only the OS
            %% ABI can be different.
            <<Ident:7/binary, OsAbi, Rest/binary>> = Bin,
            <<Ident/binary, (native_abi(Abi, OsAbi)), Rest/binary>>;
        {{macho, Cpu}, {macho, Cpu}} ->
            Bin;
        _ ->
            Head = case Header of
                       {elf, Machine, Abi} -> elf_header(Bin, Machine, Abi);
                       {macho, Cpu} -> macho_header(Bin, Cpu)
                   end,
            <<Head/binary, (binary:part(Bin, byte_size(Head), byte_size(Bin) - byte_size(Head)))/binary>>
    end.

%% The kernels other than FreeBSD do not look at the OS ABI; assimilate
%% sets it to System V (0) for them. FreeBSD needs its own (9).
native_abi(sysv, 9) -> 0;
native_abi(sysv, OsAbi) -> OsAbi;
native_abi(freebsd, _) -> 9.

%% The format of the file that the new file is a copy of (this
%% executable): an APE file, or a native file (made with --target, or
%% with --assimilate of the APE loader), or unknown.
base_kind(<<"MZqFpD", _/binary>>) -> ape;
base_kind(<<"jartsr", _/binary>>) -> ape;
base_kind(<<127, "ELF", 2, _, _, OsAbi, _:8/binary, _Type:16/little, Machine:16/little,
            _/binary>>) -> {elf, Machine, OsAbi};
base_kind(<<16#feedfacf:32/little, Cpu:32/little, _/binary>>) -> {macho, Cpu};
base_kind(_) -> unknown.

%% The first bytes of this executable, when it can be read (else the
%% error comes later, from read_file/1).
check_base(Opts) ->
    Exe = case Opts of
              #{exe := E} -> E;
              _ ->
                  case init:get_argument(beam_com_exe) of
                      {ok, [[E]]} -> E;
                      _ -> none
                  end
          end,
    case Exe =/= none andalso file:open(Exe, [read, binary, raw]) of
        {ok, File} ->
            Head = file:read(File, 64),
            ok = file:close(File),
            case Head of
                {ok, Bin} -> check_base(Bin, maps:get(target, Opts, none));
                _ -> ok
            end;
        _ ->
            ok
    end.

%% A native base gives a native file, which runs only on one system.
%% Without --target, the user did not ask for that: stop, with what to do.
%% With --target, the base must be a file for the CPU of the target. An
%% APE base, or one of unknown format, is not checked.
check_base(Bin, Target) ->
    case {base_kind(Bin), Target} of
        {ape, _} -> ok;
        {unknown, _} -> ok;
        {Kind, none} ->
            throw({error, "this is a native file (~ts), not an APE file: a program built "
                   "from it runs only on this system. Build with the APE file of beam.com, "
                   "or give --target to make a native file", [kind_name(Kind)]});
        {Kind, _} ->
            {_, _, Header} = lists:keyfind(Target, 1, ?TARGETS),
            case {Kind, Header} of
                {{elf, Machine, _}, {elf, Machine, _}} -> ok;
                {{macho, Cpu}, {macho, Cpu}} -> ok;
                _ ->
                    throw({error, "this is a native file (~ts), not an APE file: it cannot "
                           "make a file for ~ts. Build with the APE file of beam.com",
                           [kind_name(Kind), Target]})
            end
    end.

kind_name({elf, Machine, _}) -> ["ELF, ", cpu_name(Machine)];
kind_name({macho, Cpu}) -> ["Mach-O, ", cpu_name(Cpu)].

cpu_name(16#3e) -> "x86_64";
cpu_name(16#b7) -> "aarch64";
cpu_name(16#01000007) -> "x86_64";
cpu_name(16#0100000c) -> "arm64";
cpu_name(N) -> io_lib:format("CPU ~.16#", [N]).

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

%% The layout of an application directory: rebar3 (src/*.app.src) or
%% Mix (mix.exs). A directory with both is a rebar3 one, unless
%% --tool mix.
tool(Dir, Opts) ->
    case Opts of
        #{tool := Tool} -> Tool;
        _ ->
            Rebar = filelib:is_regular(filename:join(Dir, "rebar.config"))
                orelse filelib:wildcard(filename:join([Dir, "src", "*.app.src"])) =/= [],
            case {Rebar, beam_com_elixir:is_mix(Dir)} of
                {false, true} -> mix;
                _ -> rebar
            end
    end.

%% The module whose main/1 runs after the start of an application
%% program: --main, or the escript of rebar.config ("-escript main M" in
%% escript_emu_args, or escript_main_app) or of mix.exs
%% (escript: [main_module: M]). One-file programs have their own.
main(Input, Opts, #{script := true}) ->
    maps:get(main, Opts, none) =:= none orelse
        throw({error, "~ts: --main is for application directories", [Input]}),
    none;
main(Input, Opts, #{beams := Beams}) ->
    Main = case Opts of
               #{main := M} -> M;
               _ -> escript_main(Input, tool(Input, Opts))
           end,
    case Main =:= none orelse lists:keyfind(Main, 1, Beams) of
        true -> none;
        false -> throw({error, "the main module ~p is not in ~ts", [Main, Input]});
        {Main, Beam} ->
            lists:member({main, 1}, exports(Beam)) orelse
                throw({error, "~p does not export main/1", [Main]}),
            Main
    end.

escript_main(Dir, rebar) ->
    Terms = case file:consult(filename:join(Dir, "rebar.config")) of
                {ok, T} -> T;
                _ -> []
            end,
    Emu = proplists:get_value(escript_emu_args, Terms, ""),
    case re:run(Emu, "-escript\\s+main\\s+([A-Za-z0-9_@.]+)", [{capture, all_but_first, list}]) of
        {match, [M]} -> list_to_atom(M);
        nomatch -> proplists:get_value(escript_main_app, Terms, none)
    end;
escript_main(Dir, mix) ->
    #{escript := Escript} = beam_com_elixir:mix_project(Dir),
    proplists:get_value(main_module, Escript, none).

%% The program runs Main:main/1 after the start: vm.args gets
%% "-s beam_com_script main Main" (see beam_com_script:main/1).
with_main(#{config := Config} = App, Main) ->
    VmArgs = proplists:get_value("vm.args", Config, <<"-noshell\n">>),
    Line = ["-s beam_com_script main ", atom_to_list(Main), "\n"],
    New = iolist_to_binary([string:trim(VmArgs, trailing), "\n", Line]),
    App#{config := lists:keystore("vm.args", 1, Config, {"vm.args", New})}.

%% The files of a priv directory, and the ones that are executable.
priv_files(PrivDir) ->
    Files = [F || F <- filelib:wildcard("**", PrivDir),
                  filelib:is_regular(filename:join(PrivDir, F))],
    Priv = [{F, element(2, {ok, _} = file:read_file(filename:join(PrivDir, F)))} || F <- Files],
    Exec = [F || F <- Files,
                 {ok, #file_info{mode = Mode}} <- [file:read_file_info(filename:join(PrivDir, F))],
                 Mode band 8#111 =/= 0],
    {Priv, Exec}.

%% The priv directories that the program copies to real files at start
%% (beam_com_script:extract/2): the ones with an executable file, and
%% the ones of --extract-priv. [{App, Vsn, Hash, Executables}]; the hash
%% of the files names the directory in the cache.
extract(App, Deps, Named) ->
    All = [App | Deps],
    HasPriv = fun(Name) ->
                      lists:any(fun(#{name := N, priv := P}) -> N =:= Name andalso P =/= [] end, All)
              end,
    [throw({error, "--extract-priv ~p: the program has no application ~p with a "
            "priv directory", [Name, Name]}) || Name <- Named, not HasPriv(Name)],
    [{N, V, hash(Priv), Exec}
     || #{name := N, vsn := V, priv := Priv, priv_exec := Exec} <- All,
        Priv =/= [], Exec =/= [] orelse lists:member(N, Named)].

hash(Priv) ->
    Data = [[F, 0, integer_to_list(byte_size(D)), 0, D] || {F, D} <- lists:sort(Priv)],
    string:lowercase(binary_to_list(binary:part(binary:encode_hex(crypto:hash(sha256, Data)), 0, 16))).

%% sys.config with the list for beam_com_script.
with_extract(App, []) ->
    App;
with_extract(#{config := Config} = App, Extract) ->
    Terms = case proplists:get_value("sys.config", Config) of
                undefined -> [];
                Data ->
                    {ok, Tokens, _} = erl_scan:string(unicode:characters_to_list(Data)),
                    {ok, T} = erl_parse:parse_term(Tokens),
                    T
            end,
    New = Terms ++ [{beam_com_script, [{extract, Extract}]}],
    App#{config := lists:keystore("sys.config", 1, Config,
                                  {"sys.config", io_lib:format("~tp.~n", [New])})}.

default_output(Input) ->
    filename:rootname(filename:basename(Input), filename:extension(Input)) ++ ".com".

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

%% "NAME-VSN": the version starts at the first "-" before a digit, so a
%% version can have a "-" ("phoenix-1.9.0-dev", "ecto-3.0.0-rc.1"). With no
%% digit after a "-", the version starts at the last "-".
split_dir(Dir) ->
    case re:run(Dir, "^(.+?)-([0-9].*)$", [{capture, all_but_first, list}, unicode]) of
        {match, [Name, Vsn]} -> {list_to_atom(Name), Vsn};
        nomatch ->
            case string:split(Dir, "-", trailing) of
                [Name, Vsn] -> {list_to_atom(Name), Vsn};
                _ -> {list_to_atom(Dir), none}
            end
    end.

%% One .erl file with main/1.
script(File) ->
    case filename:extension(File) of
        ".erl" -> erl_script(File);
        Ext when Ext =:= ".ex"; Ext =:= ".exs" -> elixir_script(File);
        _ -> throw({error, "~ts: not a .erl, .ex or .exs file, or a directory", [File]})
    end.

%% One Elixir file (beam_com_elixir): the modules of the file, and the
%% one that exports main/1 runs. The application takes the name of the
%% file.
elixir_script(File) ->
    #{beams := Beams, main := Main} = beam_com_elixir:script(File),
    Name = list_to_atom(filename:rootname(filename:basename(File))),
    Props = [{description, atom_to_list(Name)},
             {vsn, ?DEFAULT_VSN},
             {modules, [M || {M, _} <- Beams]},
             {registered, []},
             {applications, [kernel, stdlib, elixir, beam_com_script]},
             {mod, {beam_com_script, Main}}],
    #{name => Name, vsn => ?DEFAULT_VSN, props => Props, beams => Beams,
      priv => [], priv_exec => [], config => [], script => true}.

erl_script(File) ->
    filelib:is_regular(File)
        orelse throw({error, "~ts: no such file", [File]}),
    {Mod, Beam} = compile(File, [report_warnings]),
    lists:member({main, 1}, exports(Beam))
        orelse throw({error, "~ts: main/1 is not exported", [File]}),
    Props = [{description, atom_to_list(Mod)},
             {vsn, ?DEFAULT_VSN},
             {modules, [Mod]},
             {registered, []},
             {applications, [kernel, stdlib, beam_com_script]},
             {mod, {beam_com_script, Mod}}],
    #{name => Mod, vsn => ?DEFAULT_VSN, props => Props,
      beams => [{Mod, Beam}], priv => [], priv_exec => [], config => [],
      script => true}.

%% An application directory.
app_dir(Dir) ->
    app_dir(Dir, #{}).

%% Options: vsn (the version of a Hex package, which wins over the one
%% of the .app file) and dep (a dependency: warnings are not errors).
app_dir(Dir, Options) ->
    case maps:get(tool, Options, tool(Dir, #{})) of
        mix -> mix_dir(Dir, Options);
        rebar -> rebar_dir(Dir, Options)
    end.

rebar_dir(Dir, Options) ->
    {Name, Props0} = app_file(Dir),
    ErlOpts = case Options of
                  #{dep := true} -> erl_opts(Dir) -- [warnings_as_errors];
                  _ -> erl_opts(Dir)
              end,
    Gen = temp_dir("gen"),
    Beams = try
                Generated = generate(Dir, Gen),
                Includes = [{i, filename:join(Dir, "include")},
                            {i, filename:join(Dir, "src")},
                            {i, Gen}],
                Sources = filelib:wildcard(filename:join([Dir, "src", "**", "*.erl"]))
                    ++ Generated,
                %% The warnings of a dependency are not shown (as rebar3).
                Report = case Options of
                             #{dep := true} -> [];
                             _ -> [report_warnings]
                         end,
                compile_all(Sources, Report ++ Includes ++ ErlOpts)
            after
                file:del_dir_r(Gen)
            end,
    Vsn = case {Options, proplists:get_value(vsn, Props0)} of
              {#{vsn := PkgVsn}, _} -> PkgVsn;
              {_, V} when is_list(V) -> V;
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
    {Priv, PrivExec} = priv_files(PrivDir),
    Config = [{File, Data}
              || File <- ["sys.config", "vm.args"],
                 {ok, Data} <- [file:read_file(
                                  filename:join([Dir, "config", File]))]],
    #{name => Name, vsn => Vsn, props => Props, beams => Beams,
      priv => Priv, priv_exec => PrivExec, config => Config, script => false}.

%% The Hex packages of rebar.config (beam_com_hex), compiled in order.
%% Each one is written to its directory (ebin/ with the .app file), and
%% its ebin/ goes into the code path, for the parse transforms and the
%% include_lib of the packages and of the program that come after it.
deps(Dir, LibDir, Tool) ->
    [begin
         App = app_dir(PkgDir, #{vsn => Vsn, dep => true}),
         Ebin = filename:join(PkgDir, "ebin"),
         ok = filelib:ensure_path(Ebin),
         #{props := Props, beams := Beams} = App,
         write_file(filename:join(Ebin, atom_to_list(Name) ++ ".app"),
                    io_lib:format("~tp.~n", [{application, Name, Props}])),
         [write_file(filename:join(Ebin, atom_to_list(M) ++ ".beam"), B)
          || {M, B} <- Beams],
         true = code:add_patha(Ebin),
         App#{dir => PkgDir}
     end || #{name := Name, vsn := Vsn, dir := PkgDir} <- fetch(Dir, LibDir, Tool)].

fetch(Dir, LibDir, Tool) ->
    case Tool =:= mix of
        true ->
            #{deps := Deps} = beam_com_elixir:mix_project(Dir),
            beam_com_hex:fetch(Dir, LibDir, Deps, mix);
        false ->
            beam_com_hex:fetch(Dir, LibDir)
    end.

%% A Mix project (beam_com_elixir): the Erlang files of erlc_paths, then
%% the Elixir files of elixirc_paths, which can call them. The .app file
%% is made as Mix makes it: the applications are kernel, stdlib, elixir,
%% the extra_applications and the deps (or :applications of
%% application/0), with the :mod, :env and :registered of application/0.
mix_dir(Dir, Options) ->
    #{app := Name, version := Vsn0, runtime_deps := DepApps, elixirc_paths := ExPaths,
      erlc_paths := ErlPaths, erlc_options := ErlcOpts, application := AppConf}
        = beam_com_elixir:mix_project(Dir),
    Vsn = maps:get(vsn, Options, Vsn0),
    Out = temp_dir("mix"),
    ok = filelib:ensure_path(Out),
    true = code:add_patha(Out),
    Beams = try
                Report = case Options of
                             #{dep := true} -> [];
                             _ -> [report_warnings]
                         end,
                Includes = [{i, filename:join(Dir, "include")}]
                    ++ [{i, filename:join(Dir, P)} || P <- ErlPaths],
                ErlFiles = lists:append([filelib:wildcard(filename:join([Dir, P, "**", "*.erl"]))
                                         || P <- ErlPaths]),
                ErlBeams = compile_all(ErlFiles, Report ++ Includes ++ ErlcOpts),
                [write_file(filename:join(Out, atom_to_list(M) ++ ".beam"), B)
                 || {M, B} <- ErlBeams],
                ExFiles = lists:append([filelib:wildcard(filename:join([Dir, P, "**", "*.ex"]))
                                        || P <- ExPaths]),
                ErlBeams ++ beam_com_elixir:compile(ExFiles, Out, Dir)
            after
                code:del_path(Out),
                file:del_dir_r(Out)
            end,
    Get = fun(K, D) -> proplists:get_value(K, AppConf, D) end,
    Apps = case Get(applications, undefined) of
               undefined -> [kernel, stdlib, elixir] ++ Get(extra_applications, []) ++ DepApps;
               Explicit -> [kernel, stdlib, elixir] ++ Explicit
           end,
    Props = [{description, atom_to_list(Name)},
             {vsn, Vsn},
             {modules, [M || {M, _} <- Beams]},
             {registered, Get(registered, [])},
             {applications, lists:usort(Apps)},
             {included_applications, Get(included_applications, [])},
             {env, Get(env, [])}]
        ++ [{mod, M} || M <- [Get(mod, undefined)], M =/= undefined],
    PrivDir = filename:join(Dir, "priv"),
    {Priv, PrivExec} = priv_files(PrivDir),
    Config = case maps:get(dep, Options, false) of
                 true -> [];
                 false -> [{"sys.config", C} || C <- [beam_com_elixir:sys_config(Dir)], C =/= none]
             end,
    #{name => Name, vsn => Vsn, props => Props, beams => Beams,
      priv => Priv, priv_exec => PrivExec, config => Config, script => false}.

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

%% A new directory for temporary files, in TMPDIR (or /tmp).
temp_dir(What) ->
    Base = hd([D || V <- ["TMPDIR", "TMP", "TEMP"],
                    D <- [os:getenv(V)], D =/= false, D =/= ""] ++ ["/tmp"]),
    new_dir(Base, "beam_com_" ++ What ++ "_").

%% A new directory in Parent, with a random name, that only this user
%% can use. The build puts code of the program in it, and /tmp is
%% shared: the directory must not exist before (another user could have
%% made it), so make_dir/1 must make it.
new_dir(Parent, Prefix) ->
    Dir = filename:join(Parent, Prefix ++ binary_to_list(
                                           binary:encode_hex(crypto:strong_rand_bytes(12), lowercase))),
    case file:make_dir(Dir) of
        ok ->
            _ = file:change_mode(Dir, 8#700),
            Dir;
        {error, Reason} ->
            throw({error, "~ts: ~ts", [Dir, file:format_error(Reason)]})
    end.

%% Compile the files of one application. The modules that other files
%% of it name as a behaviour or a parse transform are compiled first and
%% put in the code path, as rebar3 does, so that the compiler checks the
%% callbacks and can run the parse transforms.
compile_all(Files, Opts) ->
    Needed = lists:usort(lists:append([first_names(F) || F <- Files])),
    {First, Rest} = lists:partition(
                      fun(F) -> lists:member(filename:basename(F, ".erl"), Needed) end, Files),
    case First of
        [] ->
            [compile(F, Opts) || F <- Files];
        _ ->
            Ebin = temp_dir("first"),
            ok = filelib:ensure_path(Ebin),
            true = code:add_patha(Ebin),
            try
                FirstBeams = [compile(F, Opts) || F <- First],
                [write_file(filename:join(Ebin, atom_to_list(M) ++ ".beam"), B)
                 || {M, B} <- FirstBeams],
                FirstBeams ++ [compile(F, Opts) || F <- Rest]
            after
                %% The compiler loads the behaviours (for the callbacks)
                %% and the parse transforms; they must not stay loaded.
                [begin code:purge(M), code:delete(M), code:purge(M) end
                 || {M, File} <- code:all_loaded(), is_list(File),
                    lists:prefix(Ebin, File)],
                code:del_path(Ebin),
                file:del_dir_r(Ebin)
            end
    end.

%% The modules that a file names in -behaviour, -behavior or
%% {parse_transform, M}.
first_names(File) ->
    {ok, Text} = file:read_file(File),
    Re = "(?:^-behaviou?r\\(\\s*'?([A-Za-z0-9_@]+)'?\\s*\\)|parse_transform\\s*,\\s*'?([A-Za-z0-9_@]+))",
    case re:run(Text, Re, [global, multiline, {capture, all_but_first, list}]) of
        {match, Ms} -> [N || M <- Ms, N <- M, N =/= ""];
        nomatch -> []
    end.

compile(File, Opts) ->
    case compile:file(File, [binary, report_errors | Opts]) of
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
               "~ts: warning: ~p calls ~p, which is not in ~ts~n",
               [beam_com:name(), Mod, M, beam_com:name()])
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
    %% beam_com_script starts first: it makes the priv directories that
    %% other applications use when they start.
    First = [A || A <- [kernel, stdlib, beam_com_script], lists:member(A, Apps)],
    Rel = {release, {Name, Vsn}, {erts, ErtsVsn},
           [{A, maps:get(vsn, maps:get(A, Base))} || A <- First ++ (Apps -- First)]
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

%% A program does not need the docs and the debug information of the
%% code: the beam files of OTP 29 and of Elixir in beam.com have both (for h/1
%% and the debugger). For the applications of the zip whose code has docs
%% (the first beam file tells), the program gets the beam files without
%% them, in place of the entries of the zip, as "mix release" strips
%% them (strip_beams): it keeps the chunks that the loader uses, the line
%% numbers and the attributes, and does not compress the file.
without_docs(Apps, Base, Root) ->
    lists:append([app_without_docs(A, maps:get(vsn, maps:get(A, Base)), Root)
                  || A <- Apps]).

app_without_docs(App, Vsn, Root) ->
    Dir = atom_to_list(App) ++ "-" ++ Vsn,
    Files = lists:sort(filelib:wildcard(filename:join([Root, "lib", Dir, "ebin", "*.beam"]))),
    case Files =/= [] andalso has_docs(hd(Files)) of
        false -> [];
        true ->
            [begin
                 {ok, Beam} = read_file(F),
                 {"lib/" ++ Dir ++ "/ebin/" ++ filename:basename(F), strip(Beam)}
             end || F <- Files]
    end.

strip(Beam) ->
    Keep = ["Atom", "AtU8", "Attr", "Code", "StrT", "ImpT", "ExpT", "FunT",
            "LitT", "Line", "Type", "Meta", "Recs"],
    {ok, {_, Chunks}} = beam_lib:chunks(Beam, Keep, [allow_missing_chunks]),
    {ok, Stripped} = beam_lib:build_module([C || {_, Data} = C <- Chunks, is_binary(Data)]),
    Stripped.

has_docs(File) ->
    {ok, Beam} = read_file(File),
    case beam_lib:chunks(Beam, ["Docs"], [allow_missing_chunks]) of
        {ok, {_, [{"Docs", Docs}]}} -> is_binary(Docs);
        _ -> false
    end.

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
       (".allow") -> false;
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

%% The output file: a new file next to it, then a rename. The rename
%% replaces a link at Output, and does not write through it.
write_output(Output, Data) ->
    New = filename:join(filename:dirname(Output),
                        "." ++ filename:basename(Output) ++ "." ++
                            binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8), lowercase))),
    case file:open(New, [write, exclusive, raw, binary]) of
        {ok, F} ->
            try
                ok = file:write(F, Data)
            after
                file:close(F)
            end;
        {error, Reason} ->
            throw({error, "~ts: ~ts", [New, file:format_error(Reason)]})
    end,
    _ = file:change_mode(New, 8#755),
    case file:rename(New, Output) of
        ok -> ok;
        {error, Reason2} ->
            _ = file:delete(New),
            throw({error, "~ts: ~ts", [Output, file:format_error(Reason2)]})
    end.

write_file(File, Data) ->
    case file:write_file(File, Data) of
        ok -> ok;
        {error, Reason} ->
            throw({error, "~ts: ~ts", [File, file:format_error(Reason)]})
    end.
