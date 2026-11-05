%% Assembles a program from a program and new files, as a server can
%% stream it (docs/NIFS.md, "A program assembled from parts"):
%%
%%   beam.com scripts/assemble.erl -- BASE OUT SPEC...
%%   beam.com scripts/assemble.erl -- --parts BASE DIR KEY URL PKG:SPEC...
%%
%% A SPEC is NAME=FILE (the file FILE, with the path NAME in the zip), or
%% PREFIX/=FROM (each regular file of the directory FROM, with the path
%% PREFIX/PATH, in the sequence of the names).
%%
%% OUT is BASE up to its central directory, then a local entry for each
%% file (deflated), then the central directory of BASE with an entry for
%% each file, and a new end record. The bytes of BASE do not change, so
%% the offsets of its entries and its executable headers stay correct.
%%
%% The script first computes the length of OUT from the sizes alone, and
%% writes it ("assemble: OUT has N bytes"). Then it writes OUT from the
%% first byte to the last, with no seek, as a server sends a response
%% with a Content-Length. At the end, it checks the length of OUT.
%%
%% With --parts, the script cuts the same program into segments, in DIR.
%% A local entry has no offset, so the entries of a package are the same
%% bytes in each program. Only the central directory changes:
%%
%%   beam-p.KEY.head            BASE up to its central directory
%%   beam-p.KEY.PKG.part        the local entries of the files of PKG
%%   beam-p.KEY.SET.tail        the central directory and the end record
%%                              of the program with the packages of SET
%%   beam-p.plus.SET.txt        the list of the segments of SET, one URL
%%                              (URL, then the name of the file) on each
%%                              line
%%
%% SET is each set of the packages that is not empty: their names in the
%% sequence of sort, with a dot between them. The segments of the list of
%% SET, one after the other, are the bytes of OUT with the specs of the
%% packages of SET, in that sequence.
%%
%% Limits: no ZIP64 (fewer than 65,535 entries, and less than 4 GiB),
%% and no NAME that BASE already has.
-module(assemble).
-export([main/1]).

-include_lib("kernel/include/file.hrl").

-define(EOCD, 16#06054b50).
-define(CEN, 16#02014b50).
-define(LOC, 16#04034b50).
%% UTF-8 names (bit 11), as the program builder writes them.
-define(FLAGS, 16#0800).
%% Made by Unix (3), version 2.0; regular file, mode 0644.
-define(MADE_BY, ((3 bsl 8) bor 20)).
-define(ATTR, (8#100644 bsl 16)).
%% 2026-01-01 00:00:00, in MS-DOS form: the same bytes for each run.
-define(TIME, 0).
-define(DATE, (((2026 - 1980) bsl 9) bor (1 bsl 5) bor 1)).

main(Args) ->
    try run(Args)
    catch throw:{error, Format, FArgs} ->
        io:format(standard_error, "assemble: " ++ Format ++ "~n", FArgs),
        erlang:halt(1)
    end.

run(["--parts", Base, Dir, Key, Url | Specs]) when Specs =/= [] ->
    parts(Base, Dir, Key, Url, Specs);
run([[C | _] = Base, Out | Specs]) when C =/= $-, Specs =/= [] ->
    assemble(Base, Out, Specs);
run(_) ->
    io:format(standard_error,
              "usage: assemble BASE OUT SPEC...~n"
              "       assemble --parts BASE DIR KEY URL PKG:SPEC...~n", []),
    erlang:halt(2).

assemble(Base, Out, Specs) ->
    Zip = base(Base),
    Files = files(Specs, Zip),
    unique(Files),
    Tail = tail(Zip, Files),
    Length = program_size(Zip, [Files], Tail),
    io:format("assemble: ~ts has ~b bytes~n", [Out, Length]),
    {ok, Fd} = file:open(Out, [write, raw, binary]),
    ok = file:write(Fd, head(Zip)),
    [ok = file:write(Fd, local(F)) || F <- Files],
    ok = file:write(Fd, Tail),
    ok = file:close(Fd),
    same(Base, Zip),
    {ok, #file_info{mode = Mode}} = file:read_file_info(Base),
    ok = file:change_mode(Out, Mode band 8#777),
    case file:read_file_info(Out) of
        {ok, #file_info{size = Length}} ->
            io:format("assemble: wrote ~ts: ~b bytes, the length of the start; new files: ~b~n",
                      [Out, Length, length(Files)]);
        {ok, #file_info{size = Other}} ->
            fail("~ts has ~b bytes, not ~b", [Out, Other, Length])
    end.

parts(Base, Dir, Key, Url, Specs) ->
    re:run(Key, "^[0-9a-f]{7,40}$") =:= nomatch andalso
        fail("~ts: the KEY is 7 to 40 characters 0-9 and a-f", [Key]),
    re:run(Url, "^[ -~]{0,200}$") =:= nomatch andalso
        fail("the URL has characters that are not printable", []),
    Zip = base(Base),
    %% The specs of each package, in the sequence of the arguments.
    Groups = lists:foldl(
               fun(Spec, Acc) ->
                       case string:split(Spec, ":") of
                           [Pkg, S] when S =/= "" ->
                               re:run(Pkg, "^[a-z0-9_]{1,32}$") =:= nomatch andalso
                                   fail("~ts: a PKG is 1 to 32 characters a-z, 0-9 and _", [Pkg]),
                               maps:update_with(Pkg, fun(L) -> L ++ [S] end, [S], Acc);
                           _ ->
                               fail("~ts: not PKG:SPEC", [Spec])
                       end
               end, #{}, Specs),
    Pkgs = [{Pkg, files(S, Zip)} || {Pkg, S} <- lists:sort(maps:to_list(Groups))],
    unique(lists:append([F || {_, F} <- Pkgs])),
    ok = filelib:ensure_path(Dir),
    Head = "beam-p." ++ Key ++ ".head",
    write(Dir, Head, head(Zip)),
    [write(Dir, part(Key, Pkg), [local(F) || F <- Files]) || {Pkg, Files} <- Pkgs],
    lists:foreach(
      fun(Set) ->
              Name = string:join([P || {P, _} <- Set], "."),
              Files = [Fs || {_, Fs} <- Set],
              Tail = tail(Zip, lists:append(Files)),
              Length = program_size(Zip, Files, Tail),
              TailName = "beam-p." ++ Key ++ "." ++ Name ++ ".tail",
              write(Dir, TailName, Tail),
              List = [Head | [part(Key, P) || {P, _} <- Set]] ++ [TailName],
              write(Dir, "beam-p.plus." ++ Name ++ ".txt", [[Url, N, $\n] || N <- List]),
              io:format("assemble: the program of ~ts has ~b bytes~n", [Name, Length])
      end, subsets(Pkgs)),
    same(Base, Zip).

part(Key, Pkg) ->
    "beam-p." ++ Key ++ "." ++ Pkg ++ ".part".

%% Each subset of L that is not empty, with the sequence of L.
subsets([]) ->
    [];
subsets([X | Rest]) ->
    Others = subsets(Rest),
    [[X]] ++ [[X | S] || S <- Others] ++ Others.

write(Dir, Name, Data) ->
    Path = filename:join(Dir, Name),
    ok = file:write_file(Path, Data),
    io:format("assemble: wrote ~ts: ~b bytes~n", [Name, filelib:file_size(Path)]).

%% BASE: its bytes, and the facts of its central directory.
base(Base) ->
    B = read(Base),
    {CdOff, CdSize, Count, Comment} = eocd(B),
    Old = names(binary:part(B, CdOff, CdSize), Count, #{}),
    #{bytes => B, cd_off => CdOff, cd_size => CdSize, count => Count,
      comment => Comment, names => Old}.

%% BASE did not change while the script read it.
same(Base, #{bytes := B}) ->
    {ok, #file_info{size = Size}} = file:read_file_info(Base),
    Size =:= byte_size(B) orelse fail("~ts changed", [Base]).

head(#{bytes := B, cd_off := CdOff}) ->
    binary:part(B, 0, CdOff).

unique(Files) ->
    Names = [N || {N, _, _, _} <- Files],
    case Names -- lists:usort(Names) of
        [] -> ok;
        [Name | _] -> fail("two files have the name ~ts", [Name])
    end.

%% The length of the program with the files of each list of FILES.
program_size(#{cd_off := CdOff}, Files, Tail) ->
    Length = CdOff + lists:sum([local_size(F) || F <- lists:append(Files)]) + iolist_size(Tail),
    Length < 16#ffffffff orelse fail("~b bytes: ZIP64 is not supported", [Length]),
    Length.

local_size({Name, _, _, Data}) ->
    30 + byte_size(Name) + byte_size(Data).

%% The central directory of BASE, an entry for each of FILES, and the end
%% record. The local entries of FILES come after the bytes of BASE, in
%% this sequence.
tail(#{bytes := B, cd_off := CdOff, cd_size := CdSize, count := Count, comment := Comment},
     Files) ->
    New = Count + length(Files),
    New < 16#ffff orelse fail("~b entries: ZIP64 is not supported", [New]),
    {Central, NewCdOff} =
        lists:mapfoldl(fun(F, Off) -> {central(Off, F), Off + local_size(F)} end, CdOff, Files),
    NewCdSize = CdSize + iolist_size(Central),
    [binary:part(B, CdOff, CdSize), Central,
     <<?EOCD:32/little, 0:16, 0:16, New:16/little, New:16/little,
       NewCdSize:32/little, NewCdOff:32/little,
       (byte_size(Comment)):16/little, Comment/binary>>].

read(Path) ->
    case file:read_file(Path) of
        {ok, B} -> B;
        {error, Reason} -> fail("~ts: ~ts", [Path, file:format_error(Reason)])
    end.

%% The files of the specs: for each file, its name in the zip, its
%% CRC-32, its size, and its deflated bytes.
files(Specs, #{names := Old}) ->
    lists:append([spec(Spec, Old) || Spec <- Specs]).

spec(Spec, Old) ->
    case string:split(Spec, "=") of
        [Name, From] when Name =/= "", From =/= "" ->
            case lists:last(Name) of
                $/ ->
                    filelib:is_dir(From) orelse fail("~ts: no directory", [From]),
                    Paths = lists:sort([P || P <- filelib:wildcard("**", From),
                                             filelib:is_regular(filename:join(From, P))]),
                    Paths =:= [] andalso fail("~ts: no file", [From]),
                    [file(Name ++ P, filename:join(From, P), Old) || P <- Paths];
                _ ->
                    [file(Name, From, Old)]
            end;
        _ ->
            fail("~ts: not NAME=FILE or PREFIX/=DIR", [Spec])
    end.

file(Name0, Path, Old) ->
    Name = unicode:characters_to_binary(Name0),
    maps:is_key(Name, Old) andalso fail("BASE already has ~ts", [Name]),
    Data = read(Path),
    {Name, erlang:crc32(Data), byte_size(Data), deflate(Data)}.

deflate(Data) ->
    Z = zlib:open(),
    ok = zlib:deflateInit(Z, default, deflated, -15, 8, default),
    D = iolist_to_binary(zlib:deflate(Z, Data, finish)),
    ok = zlib:deflateEnd(Z),
    zlib:close(Z),
    D.

local({Name, Crc, Size, Deflated}) ->
    [<<?LOC:32/little, 20:16/little, ?FLAGS:16/little, 8:16/little,
      ?TIME:16/little, ?DATE:16/little, Crc:32/little,
      (byte_size(Deflated)):32/little, Size:32/little,
      (byte_size(Name)):16/little, 0:16, Name/binary>>, Deflated].

central(Off, {Name, Crc, Size, Deflated}) ->
    <<?CEN:32/little, ?MADE_BY:16/little, 20:16/little, ?FLAGS:16/little,
      8:16/little, ?TIME:16/little, ?DATE:16/little, Crc:32/little,
      (byte_size(Deflated)):32/little, Size:32/little,
      (byte_size(Name)):16/little, 0:16, 0:16, 0:16, 0:16,
      ?ATTR:32/little, Off:32/little, Name/binary>>.

%% The end record of BASE: the last one whose comment ends the file.
eocd(B) ->
    %% The record is in the last 22 bytes and its comment (65,535 bytes or
    %% fewer).
    Tail = min(byte_size(B), 22 + 16#ffff),
    Start = byte_size(B) - Tail,
    Found = binary:matches(binary:part(B, Start, Tail), <<?EOCD:32/little>>),
    eocd(B, lists:reverse([Start + Pos || {Pos, _} <- Found])).

eocd(_, []) ->
    fail("BASE has no zip", []);
eocd(B, [Pos | Rest]) ->
    case B of
        <<_:Pos/binary, ?EOCD:32/little, 0:16, 0:16, N:16/little, N:16/little,
          CdSize:32/little, CdOff:32/little, CLen:16/little, Comment:CLen/binary>>
          when CdOff + CdSize =< Pos ->
            (N =:= 16#ffff orelse CdOff =:= 16#ffffffff) andalso
                fail("BASE has a ZIP64 directory", []),
            {CdOff, CdSize, N, Comment};
        _ ->
            eocd(B, Rest)
    end.

%% The names of the central directory.
names(<<>>, 0, Acc) ->
    Acc;
names(<<?CEN:32/little, _:24/binary, NLen:16/little, XLen:16/little, CLen:16/little,
        _:12/binary, Name:NLen/binary, _:XLen/binary, _:CLen/binary, Rest/binary>>, N, Acc)
  when N > 0 ->
    names(Rest, N - 1, Acc#{Name => true});
names(_, _, _) ->
    fail("BASE has a central directory that does not read", []).

fail(Format, Args) ->
    throw({error, Format, Args}).
