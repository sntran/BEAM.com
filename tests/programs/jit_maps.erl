%% A one-file program for "beam.com INPUT -o OUTPUT" that shows how the JIT maps
%% the memory of its code: with dual mapping, the code has two views of
%% one shared memory object, one executable (r-x) and one writable
%% (rw-), and no page is writable and executable at the same time (W^X).
%%
%% It prints "wx pages: N" (the mappings that are writable and
%% executable) and "dual mapped: yes" or "no", from the memory map of the
%% process: /proc/self/maps (Linux, NetBSD), procstat -v (FreeBSD) or
%% vmmap (macOS). Elsewhere it prints "memory map: unknown".
-module(jit_maps).
-export([main/1]).

main(_) ->
    io:format("emulator: ~s~n", [erlang:system_info(emu_flavor)]),
    case maps() of
        unknown ->
            io:format("memory map: unknown~n");
        Maps ->
            Wx = [M || {Prot, _} = M <- Maps, wx(Prot)],
            Shared = [M || {Prot, shared} = M <- Maps, lists:member($x, Prot)],
            [io:format("wx: ~s~n", [P]) || {P, _} <- Wx],
            io:format("wx pages: ~b~n", [length(Wx)]),
            io:format("dual mapped: ~s~n", [yes_no(Shared =/= [])])
    end.

wx(Prot) -> lists:member($w, Prot) andalso lists:member($x, Prot).

yes_no(true) -> "yes";
yes_no(false) -> "no".

%% A list of {Protection, shared | private}.
maps() ->
    case file:open("/proc/self/maps", [read, raw, binary]) of
        {ok, F} ->
            Text = read_all(F, []),
            ok = file:close(F),
            [proc_line(L) || L <- string:lexemes(Text, "\n"), L =/= <<>>];
        {error, _} ->
            case os:type() of
                {unix, freebsd} -> procstat();
                {unix, darwin} -> vmmap();
                _ -> unknown
            end
    end.

%% "START-END PERMS OFFSET ...", with PERMS like "r-xs" or "rw-p".
proc_line(Line) ->
    [_, <<R, W, X, S>> | _] = string:lexemes(Line, " "),
    {[C || C <- [R, W, X], C =/= $-], case S of $s -> shared; _ -> private end}.

%% FreeBSD: "PID START END PRT RES PRES REF SHD FLAG TP PATH"; TP "sw"
%% or "df" for anonymous memory, "vn" for a file (a shared memory object
%% is "sw" with SHD 1 when it is mapped two times).
procstat() ->
    Out = os:cmd("procstat -v " ++ os:getpid()),
    [begin
         Cols = string:lexemes(L, " "),
         Prot = [C || C <- lists:nth(4, Cols), C =/= $-],
         {Prot, case lists:nth(8, Cols) of "0" -> private; _ -> shared end}
     end || L <- tl(string:lexemes(Out, "\n")), length(string:lexemes(L, " ")) >= 10].

%% macOS: the regions of vmmap, with "PRT/MAX" like "r-x/rwx" and
%% "SM=SHM" for shared memory.
vmmap() ->
    Out = os:cmd("vmmap -wide " ++ os:getpid() ++ " 2>/dev/null"),
    Re = "([r-][w-][x-])/[r-][w-][x-] +SM=([A-Z]+)",
    [{[C || C <- Prot, C =/= $-], case Sm of "SHM" -> shared; _ -> private end}
     || L <- string:lexemes(Out, "\n"),
        {match, [Prot, Sm]} <- [re:run(L, Re, [{capture, all_but_first, list}])]].

read_all(F, Acc) ->
    case file:read(F, 65536) of
        {ok, B} -> read_all(F, [Acc | B]);
        eof -> iolist_to_binary(Acc)
    end.
