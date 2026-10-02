%% Read the zip of an executable, and write a new executable with other
%% zip entries.
%%
%% The zip of an Actually Portable Executable starts inside the file,
%% and its offsets count from the start of the file (not from the start
%% of the zip). The emulator also has its own entries (the symbol tables,
%% the time zones and `.cosmo`) inside its image, and they must stay
%% where they are.
%%
%% write/3 keeps the bytes of the executable up to the first entry that
%% it removes, moves the entries after that point that it keeps, adds the
%% new entries, and writes a new central directory. Zip64 is not
%% supported.
-module(beam_com_zip).

-export([entries/1, write/3]).

-define(LOCAL, 16#04034b50).
-define(CENTRAL, 16#02014b50).
-define(END, 16#06054b50).
-define(DESCRIPTOR, 16#08074b50).

-define(UNIX, 3).
-define(VERSION, 20).
-define(UTF8, 16#800).
-define(DEFLATED, 8).
-define(STORED, 0).
%% 1980-01-01 00:00, so that the same input gives the same file.
-define(DOS_DATE, 33).
-define(DOS_TIME, 0).

%% A central directory entry.
-record(entry, {name, offset, csize, usize, method, crc, flags,
                time, date, vmade, vneed, iattr, eattr, extra, comment}).

%% The names of the zip entries of Bin, in the order of the central
%% directory.
-spec entries(binary()) -> [string()].
entries(Bin) ->
    [binary_to_list(E#entry.name) || E <- central_directory(Bin)].

%% Make a new executable from Bin (an executable with a zip).
%%   Keep: fun((Name :: string()) -> boolean()), for the entries of Bin.
%%   New:  [{Name :: string(), Data :: binary()}]. A name that ends with
%%         "/" is a directory. A new entry replaces an entry of Bin with
%%         the same name.
-spec write(binary(), fun((string()) -> boolean()),
            [{string(), binary()}]) -> iodata().
write(Bin, Keep, New) ->
    NewNames = [unicode:characters_to_binary(N) || {N, _} <- New],
    Entries = lists:keysort(#entry.offset, central_directory(Bin)),
    IsKept = fun(#entry{name = Name}) ->
                     not lists:member(Name, NewNames)
                         andalso Keep(binary_to_list(Name))
             end,
    %% The bytes before the first removed entry stay as they are.
    PrefixEnd = case lists:dropwhile(IsKept, Entries) of
                    [First | _] -> First#entry.offset;
                    [] -> cd_offset(Bin)
                end,
    Kept = [E || E <- Entries, IsKept(E)],
    {InPlace, Moved} = lists:partition(
                         fun(E) -> E#entry.offset < PrefixEnd end, Kept),
    {MovedData, MovedEntries, Pos1} = move(Bin, Moved, PrefixEnd),
    {NewData, NewEntries, CdOffset} = add(New, Pos1),
    Central = [central(E) || E <- InPlace ++ MovedEntries ++ NewEntries],
    CdSize = iolist_size(Central),
    Count = length(Central),
    Count < 16#ffff orelse error(too_many_entries),
    CdOffset + CdSize < 16#ffffffff orelse error(zip64_not_supported),
    [binary:part(Bin, 0, PrefixEnd), MovedData, NewData, Central,
     <<?END:32/little, 0:16, 0:16, Count:16/little, Count:16/little,
       CdSize:32/little, CdOffset:32/little, 0:16>>].

%% Copy the local records (header, name, extra field, data and data
%% descriptor) of the entries, starting at offset Pos.
move(Bin, Entries, Pos) ->
    move(Bin, Entries, Pos, [], []).

move(_Bin, [], Pos, Data, Entries) ->
    {lists:reverse(Data), lists:reverse(Entries), Pos};
move(Bin, [E | Rest], Pos, Data, Entries) ->
    Offset = E#entry.offset,
    <<?LOCAL:32/little, _:22/binary, N:16/little, M:16/little>> =
        binary:part(Bin, Offset, 30),
    Size = 30 + N + M + E#entry.csize + descriptor_size(Bin, E, N, M),
    Record = binary:part(Bin, Offset, Size),
    move(Bin, Rest, Pos + Size, [Record | Data],
         [E#entry{offset = Pos} | Entries]).

%% Bit 3: the sizes and the CRC come after the data, with or without a
%% signature.
descriptor_size(Bin, #entry{flags = Flags, offset = Offset, csize = CSize},
                N, M) when Flags band 8 =/= 0 ->
    case binary:part(Bin, Offset + 30 + N + M + CSize, 4) of
        <<?DESCRIPTOR:32/little>> -> 16;
        _ -> 12
    end;
descriptor_size(_Bin, _E, _N, _M) ->
    0.

add(New, Pos) ->
    add(New, Pos, [], []).

add([], Pos, Data, Entries) ->
    {lists:reverse(Data), lists:reverse(Entries), Pos};
add([{Name0, Data0} | Rest], Pos, Data, Entries) ->
    Name = unicode:characters_to_binary(Name0),
    Content = iolist_to_binary(Data0),
    USize = byte_size(Content),
    Dir = binary:last(Name) =:= $/,
    {Method, Stored} = compress(Dir orelse stored(Name), Content),
    Flags = case is_ascii(Name) of
                true -> 0;
                false -> ?UTF8
            end,
    Mode = case Dir of
               true -> 8#40755;
               false -> 8#100644
           end,
    Crc = erlang:crc32(Content),
    CSize = byte_size(Stored),
    Local = [<<?LOCAL:32/little, ?VERSION:16/little, Flags:16/little,
               Method:16/little, ?DOS_TIME:16/little, ?DOS_DATE:16/little,
               Crc:32/little, CSize:32/little, USize:32/little,
               (byte_size(Name)):16/little, 0:16>>, Name, Stored],
    DosAttr = case Dir of
                  true -> 16#10;
                  false -> 0
              end,
    E = #entry{name = Name, offset = Pos, csize = CSize, usize = USize,
               method = Method, crc = Crc, flags = Flags,
               time = ?DOS_TIME, date = ?DOS_DATE,
               vmade = (?UNIX bsl 8) bor ?VERSION, vneed = ?VERSION,
               iattr = 0, eattr = (Mode bsl 16) bor DosAttr,
               extra = <<>>, comment = <<>>},
    add(Rest, Pos + iolist_size(Local), [Local | Data], [E | Entries]).

%% The code of kernel and stdlib is stored, not compressed: the boot
%% loads it, and a stored entry needs no inflating (see
%% scripts/steps.sh).
stored(<<"lib/kernel-", _/binary>> = Name) -> binary:match(Name, <<"/ebin/">>) =/= nomatch;
stored(<<"lib/stdlib-", _/binary>> = Name) -> binary:match(Name, <<"/ebin/">>) =/= nomatch;
stored(_) -> false.

compress(true, Content) ->
    {?STORED, Content};
compress(false, Content) ->
    Deflated = zlib:zip(Content),
    case byte_size(Deflated) < byte_size(Content) of
        true -> {?DEFLATED, Deflated};
        false -> {?STORED, Content}
    end.

is_ascii(Bin) ->
    lists:all(fun(C) -> C < 128 end, binary_to_list(Bin)).

central(#entry{} = E) ->
    [<<?CENTRAL:32/little, (E#entry.vmade):16/little,
       (E#entry.vneed):16/little, (E#entry.flags):16/little,
       (E#entry.method):16/little, (E#entry.time):16/little,
       (E#entry.date):16/little, (E#entry.crc):32/little,
       (E#entry.csize):32/little, (E#entry.usize):32/little,
       (byte_size(E#entry.name)):16/little,
       (byte_size(E#entry.extra)):16/little,
       (byte_size(E#entry.comment)):16/little, 0:16,
       (E#entry.iattr):16/little, (E#entry.eattr):32/little,
       (E#entry.offset):32/little>>,
     E#entry.name, E#entry.extra, E#entry.comment].

%% The end of central directory record is at the end of the file, before
%% a comment of at most 65535 bytes. The comment can have the bytes of a
%% record too, so a record counts only when its comment ends the file
%% and the central directory ends where the record starts.
end_record(Bin) ->
    Size = byte_size(Bin),
    Start = max(0, Size - 22 - 16#ffff),
    Tail = binary:part(Bin, Start, Size - Start),
    Matches = binary:matches(Tail, <<?END:32/little>>),
    find_end(Tail, Start, lists:reverse(Matches)).

find_end(_Tail, _Start, []) ->
    error(no_zip);
find_end(Tail, Start, [{Pos, _} | Rest]) ->
    case Tail of
        <<_:Pos/binary, ?END:32/little, _Disk:16, _CdDisk:16,
          _N:16/little, 16#ffff:16, _/binary>> ->
            error(zip64_not_supported);
        <<_:Pos/binary, ?END:32/little, _Disk:16, _CdDisk:16,
          _N:16/little, _Count:16/little, _CdSize:32/little,
          16#ffffffff:32, _/binary>> ->
            error(zip64_not_supported);
        <<_:Pos/binary, ?END:32/little, _Disk:16, _CdDisk:16,
          _N:16/little, Count:16/little, CdSize:32/little,
          CdOffset:32/little, CommentLen:16/little, Comment/binary>>
          when byte_size(Comment) =:= CommentLen,
               CdOffset + CdSize =:= Start + Pos ->
            {Count, CdSize, CdOffset};
        _ ->
            find_end(Tail, Start, Rest)
    end.

cd_offset(Bin) ->
    {_Count, _CdSize, CdOffset} = end_record(Bin),
    CdOffset.

central_directory(Bin) ->
    {Count, CdSize, CdOffset} = end_record(Bin),
    parse_central(binary:part(Bin, CdOffset, CdSize), Count, []).

parse_central(_Bin, 0, Acc) ->
    lists:reverse(Acc);
parse_central(<<?CENTRAL:32/little, VMade:16/little, VNeed:16/little,
                Flags:16/little, Method:16/little, Time:16/little,
                Date:16/little, Crc:32/little, CSize:32/little,
                USize:32/little, N:16/little, M:16/little, K:16/little,
                _Disk:16, IAttr:16/little, EAttr:32/little,
                Offset:32/little, Name:N/binary, Extra:M/binary,
                Comment:K/binary, Rest/binary>>, Count, Acc) ->
    E = #entry{name = Name, offset = Offset, csize = CSize, usize = USize,
               method = Method, crc = Crc, flags = Flags, time = Time,
               date = Date, vmade = VMade, vneed = VNeed, iattr = IAttr,
               eattr = EAttr, extra = Extra, comment = Comment},
    parse_central(Rest, Count - 1, [E | Acc]).
