%% Assembles a program from a program and new files, as a server can
%% stream it (docs/NIFS.md, "A program assembled from parts"):
%%
%%   beam.com scripts/assemble.erl BASE OUT NAME=FILE...
%%
%% OUT is BASE up to its central directory, then a local entry for each
%% FILE (deflated, with the path NAME in the zip), then the central
%% directory of BASE with an entry for each FILE, and a new end record.
%% The bytes of BASE do not change, so the offsets of its entries and
%% its executable headers stay correct.
%%
%% The script first computes the length of OUT from the sizes alone, and
%% writes it ("assemble: OUT has N bytes"). Then it writes OUT from the
%% first byte to the last, with no seek, as a server sends a response
%% with a Content-Length. At the end, it checks the length of OUT.
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

main([Base, Out | Specs]) when Specs =/= [] ->
    try assemble(Base, Out, Specs)
    catch throw:{error, Format, Args} ->
        io:format(standard_error, "assemble: " ++ Format ++ "~n", Args),
        erlang:halt(1)
    end;
main(_) ->
    io:format(standard_error, "usage: assemble BASE OUT NAME=FILE...~n", []),
    erlang:halt(2).

assemble(Base, Out, Specs) ->
    B = read(Base),
    {CdOff, CdSize, Count, Comment} = eocd(B),
    Old = names(binary:part(B, CdOff, CdSize), Count, #{}),
    Files = [file(Spec, Old) || Spec <- Specs],
    case length(lists:usort([N || {N, _, _, _} <- Files])) =:= length(Files) of
        true -> ok;
        false -> fail("two files have the same NAME", [])
    end,
    New = Count + length(Files),
    New < 16#ffff orelse fail("~b entries: ZIP64 is not supported", [New]),
    %% The offset of each new local entry, after the bytes of BASE.
    {Locals, NewCdOff} =
        lists:mapfoldl(fun({Name, _, _, Data} = F, Off) ->
                               {{Off, F}, Off + 30 + byte_size(Name) + byte_size(Data)}
                       end, CdOff, Files),
    NewCdSize = CdSize + lists:sum([46 + byte_size(N) || {N, _, _, _} <- Files]),
    Length = NewCdOff + NewCdSize + 22 + byte_size(Comment),
    Length < 16#ffffffff orelse fail("~b bytes: ZIP64 is not supported", [Length]),
    io:format("assemble: ~ts has ~b bytes~n", [Out, Length]),
    {ok, Fd} = file:open(Out, [write, raw, binary]),
    ok = file:write(Fd, binary:part(B, 0, CdOff)),
    [ok = file:write(Fd, [local(F), Data]) || {_, {_, _, _, Data} = F} <- Locals],
    ok = file:write(Fd, binary:part(B, CdOff, CdSize)),
    [ok = file:write(Fd, central(Off, F)) || {Off, F} <- Locals],
    ok = file:write(Fd, <<?EOCD:32/little, 0:16, 0:16, New:16/little, New:16/little,
                          NewCdSize:32/little, NewCdOff:32/little,
                          (byte_size(Comment)):16/little, Comment/binary>>),
    ok = file:close(Fd),
    {ok, #file_info{size = Size, mode = Mode}} = file:read_file_info(Base),
    Size =:= byte_size(B) orelse fail("~ts changed", [Base]),
    ok = file:change_mode(Out, Mode band 8#777),
    case file:read_file_info(Out) of
        {ok, #file_info{size = Length}} ->
            io:format("assemble: wrote ~ts: ~b bytes, the length of the start; new files: ~b~n",
                      [Out, Length, length(Files)]);
        {ok, #file_info{size = Other}} ->
            fail("~ts has ~b bytes, not ~b", [Out, Other, Length])
    end.

read(Path) ->
    case file:read_file(Path) of
        {ok, B} -> B;
        {error, Reason} -> fail("~ts: ~ts", [Path, file:format_error(Reason)])
    end.

%% NAME=FILE: the name, the CRC-32 and the size of FILE, and its deflated
%% bytes.
file(Spec, Old) ->
    case string:split(Spec, "=") of
        [Name0, Path] when Name0 =/= "", Path =/= "" ->
            Name = unicode:characters_to_binary(Name0),
            maps:is_key(Name, Old) andalso fail("BASE already has ~ts", [Name]),
            Data = read(Path),
            {Name, erlang:crc32(Data), byte_size(Data), deflate(Data)};
        _ ->
            fail("~ts: not NAME=FILE", [Spec])
    end.

deflate(Data) ->
    Z = zlib:open(),
    ok = zlib:deflateInit(Z, default, deflated, -15, 8, default),
    D = iolist_to_binary(zlib:deflate(Z, Data, finish)),
    ok = zlib:deflateEnd(Z),
    zlib:close(Z),
    D.

local({Name, Crc, Size, Deflated}) ->
    <<?LOC:32/little, 20:16/little, ?FLAGS:16/little, 8:16/little,
      ?TIME:16/little, ?DATE:16/little, Crc:32/little,
      (byte_size(Deflated)):32/little, Size:32/little,
      (byte_size(Name)):16/little, 0:16, Name/binary>>.

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
