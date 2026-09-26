%% Unit tests for beam_com_zip, the zip writer for APE files.
%%
%% The oracle is independent code: the zip module of stdlib must read
%% each file that the writer makes (with the offsets from the start of
%% the file, as in an APE file), and the data must be the same.
-module(beam_com_zip_tests).

-include_lib("eunit/include/eunit.hrl").

-define(END, 16#06054b50).

%% A fake executable: some bytes, then an empty zip whose offsets count
%% from the start of the file.
exe(Prefix) ->
    Size = byte_size(Prefix),
    <<Prefix/binary, ?END:32/little, 0:16, 0:16, 0:16, 0:16, 0:32,
      Size:32/little, 0:16>>.

prefix() ->
    %% Not a multiple of 4, and with "PK" bytes in it.
    <<"MZqFpD='\n", (binary:copy(<<"PK\1\2 image ">>, 50))/binary, 7>>.

write(Bin, Keep, New) ->
    iolist_to_binary(beam_com_zip:write(Bin, Keep, New)).

all(_) -> true.

%% The files of Bin, read by stdlib (without the directory entries).
files(Bin) ->
    {ok, Files} = zip:unzip(Bin, [memory]),
    lists:sort([F || {Name, _} = F <- Files, lists:last(Name) =/= $/]).

names(Bin) ->
    lists:sort(beam_com_zip:entries(Bin)).

sample() ->
    [{"a.txt", <<"hello">>},
     {"dir/", <<>>},
     {"dir/b.bin", crypto_free_random(1000)},
     {"dir/c.txt", binary:copy(<<"compress me ">>, 200)}].

%% Random bytes that do not compress, the same on each run (and with no
%% crypto NIF).
crypto_free_random(N) ->
    {Bytes, _} = rand:bytes_s(N, rand:seed_s(exsss, {1, 2, 3})),
    Bytes.

new_entries_test() ->
    Out = write(exe(prefix()), fun all/1, sample()),
    ?assertEqual(prefix(), binary:part(Out, 0, byte_size(prefix()))),
    ?assertEqual(["a.txt", "dir/", "dir/b.bin", "dir/c.txt"], names(Out)),
    ?assertEqual([{"a.txt", <<"hello">>},
                  {"dir/b.bin", crypto_free_random(1000)},
                  {"dir/c.txt", binary:copy(<<"compress me ">>, 200)}],
                 files(Out)).

entries_order_test() ->
    Out = write(exe(prefix()), fun all/1, sample()),
    ?assertEqual(["a.txt", "dir/", "dir/b.bin", "dir/c.txt"],
                 beam_com_zip:entries(Out)).

deterministic_test() ->
    A = write(exe(prefix()), fun all/1, sample()),
    B = write(exe(prefix()), fun all/1, sample()),
    ?assertEqual(A, B).

stored_or_deflated_test() ->
    Random = crypto_free_random(1000),
    Text = binary:copy(<<"compress me ">>, 200),
    Out = write(exe(prefix()), fun all/1,
                [{"random", Random}, {"text", Text}]),
    Methods = maps:from_list([{N, M} || {N, M, _} <- central(Out)]),
    ?assertEqual(0, maps:get("random", Methods)),
    ?assertEqual(8, maps:get("text", Methods)),
    ?assert(byte_size(Out) < byte_size(exe(prefix())) + 1000 + 2400).

%% The code of kernel and stdlib is stored (the boot reads it without
%% inflating); other code is compressed.
kernel_stdlib_stored_test() ->
    Text = binary:copy(<<"compress me ">>, 200),
    Out = write(exe(prefix()), fun all/1,
                [{"lib/kernel-11.0/ebin/code.beam", Text},
                 {"lib/stdlib-8.1/ebin/lists.beam", Text},
                 {"lib/stdlib-8.1/include/x.hrl", Text},
                 {"lib/other-1.0/ebin/o.beam", Text}]),
    Methods = maps:from_list([{N, M} || {N, M, _} <- central(Out)]),
    ?assertEqual(0, maps:get("lib/kernel-11.0/ebin/code.beam", Methods)),
    ?assertEqual(0, maps:get("lib/stdlib-8.1/ebin/lists.beam", Methods)),
    ?assertEqual(8, maps:get("lib/stdlib-8.1/include/x.hrl", Methods)),
    ?assertEqual(8, maps:get("lib/other-1.0/ebin/o.beam", Methods)),
    ?assertEqual(Text, proplists:get_value("lib/kernel-11.0/ebin/code.beam", files(Out))).

directory_attributes_test() ->
    Out = write(exe(prefix()), fun all/1, [{"d/", <<>>}, {"f", <<"x">>}]),
    Attrs = maps:from_list([{N, A} || {N, _, A} <- central(Out)]),
    ?assertEqual(8#40755, maps:get("d/", Attrs) bsr 16),
    ?assertEqual(16#10, maps:get("d/", Attrs) band 16#10),
    ?assertEqual(8#100644, maps:get("f", Attrs) bsr 16).

utf8_name_test() ->
    Name = "lib/caf\x{e9}/\x{65e5}.txt",
    Out = write(exe(prefix()), fun all/1, [{Name, <<"x">>}, {"ascii", <<"y">>}]),
    Flags = maps:from_list([{N, F} || {N, F} <- flags(Out)]),
    ?assertEqual(16#800, maps:get(unicode:characters_to_binary(Name), Flags)
                     band 16#800),
    ?assertEqual(0, maps:get(<<"ascii">>, Flags) band 16#800).

empty_file_test() ->
    Out = write(exe(prefix()), fun all/1, [{"empty", <<>>}]),
    ?assertEqual([{"empty", <<>>}], files(Out)).

iodata_test() ->
    Out = write(exe(prefix()), fun all/1, [{"io", [<<"a">>, "b", [$c]]}]),
    ?assertEqual([{"io", <<"abc">>}], files(Out)).

keep_all_test() ->
    Base = write(exe(prefix()), fun all/1, sample()),
    Out = write(Base, fun all/1, []),
    ?assertEqual(files(Base), files(Out)),
    %% Nothing moves: the entries and the data before the central
    %% directory are the same bytes.
    CdOffset = cd_offset(Base),
    ?assertEqual(binary:part(Base, 0, CdOffset), binary:part(Out, 0, CdOffset)).

remove_test() ->
    Base = write(exe(prefix()), fun all/1, sample()),
    Out = write(Base, fun(N) -> N =/= "a.txt" end, []),
    ?assertEqual(["dir/", "dir/b.bin", "dir/c.txt"], names(Out)),
    ?assertEqual(tl(files(Base)), files(Out)),
    ?assert(byte_size(Out) < byte_size(Base)).

remove_all_test() ->
    Base = write(exe(prefix()), fun all/1, sample()),
    Out = write(Base, fun(_) -> false end, []),
    ?assertEqual([], beam_com_zip:entries(Out)),
    ?assertEqual(exe(prefix()), Out).

replace_test() ->
    Base = write(exe(prefix()), fun all/1, sample()),
    Out = write(Base, fun all/1, [{"dir/c.txt", <<"new">>}]),
    ?assertEqual(["a.txt", "dir/", "dir/b.bin", "dir/c.txt"], names(Out)),
    ?assertEqual(<<"new">>, proplists:get_value("dir/c.txt", files(Out))),
    ?assertEqual(<<"hello">>, proplists:get_value("a.txt", files(Out))).

%% The entries before the first removed entry stay at the same offsets
%% (the zip entries of the emulator image), and the ones after it move.
in_place_and_moved_test() ->
    Base = write(exe(prefix()), fun all/1,
                 [{"image1", <<"first">>}, {"image2", <<"second">>},
                  {"old", <<"remove me">>}, {"after", <<"moved">>}]),
    Out = write(Base, fun(N) -> N =/= "old" end, [{"new", <<"added">>}]),
    Offsets0 = maps:from_list(offsets(Base)),
    Offsets1 = maps:from_list(offsets(Out)),
    ?assertEqual(maps:get(<<"image1">>, Offsets0), maps:get(<<"image1">>, Offsets1)),
    ?assertEqual(maps:get(<<"image2">>, Offsets0), maps:get(<<"image2">>, Offsets1)),
    ?assertEqual(maps:get(<<"old">>, Offsets0), maps:get(<<"after">>, Offsets1)),
    ?assertEqual([{"after", <<"moved">>}, {"image1", <<"first">>},
                  {"image2", <<"second">>}, {"new", <<"added">>}],
                 files(Out)).

chain_test() ->
    %% A file made from a file made by the writer (beam.com build on a
    %% program made by beam.com build).
    A = write(exe(prefix()), fun all/1, sample()),
    B = write(A, fun(N) -> N =/= "dir/b.bin" end, [{"x", <<"1">>}]),
    C = write(B, fun(N) -> N =/= "a.txt" end, [{"y", <<"2">>}]),
    ?assertEqual([{"dir/c.txt", binary:copy(<<"compress me ">>, 200)},
                  {"x", <<"1">>}, {"y", <<"2">>}], files(C)).

%% A zip made by another tool (stdlib), after a prefix, with the
%% offsets made absolute: the writer keeps and moves its entries.
foreign_zip_test() ->
    {ok, {_, Zip}} = zip:create("z.zip", [{"one", <<"1">>}, {"two", <<"22">>}],
                                [memory]),
    Base = relocate(prefix(), Zip),
    ?assertEqual([{"one", <<"1">>}, {"two", <<"22">>}], files(Base)),
    Out = write(Base, fun(N) -> N =/= "one" end, [{"three", <<"333">>}]),
    ?assertEqual([{"three", <<"333">>}, {"two", <<"22">>}], files(Out)).

%% Entries with data descriptors (flag bit 3), with and without their
%% signature, are moved with the descriptor.
data_descriptor_test_() ->
    [{"with signature", fun() -> data_descriptor(true) end},
     {"without signature", fun() -> data_descriptor(false) end}].

data_descriptor(Signature) ->
    Base = descriptor_zip(prefix(), Signature,
                          [{"first", <<"remove">>}, {"second", <<"keep me">>},
                           {"third", <<"and me">>}]),
    ?assertEqual([{"first", <<"remove">>}, {"second", <<"keep me">>},
                  {"third", <<"and me">>}], files(Base)),
    Out = write(Base, fun(N) -> N =/= "first" end, [{"new", <<"n">>}]),
    ?assertEqual([{"new", <<"n">>}, {"second", <<"keep me">>},
                  {"third", <<"and me">>}], files(Out)).

comment_test() ->
    Exe = exe(prefix()),
    %% A zip comment: the end record is not the last 22 bytes.
    Size = byte_size(Exe),
    <<Head:(Size - 2)/binary, _:16>> = Exe,
    WithComment = <<Head/binary, 5:16/little, "hello">>,
    Out = write(WithComment, fun all/1, [{"a", <<"b">>}]),
    ?assertEqual([{"a", <<"b">>}], files(Out)).

comment_with_signature_test() ->
    %% A comment that has the bytes of an end record: the last record
    %% whose comment length matches is the real one.
    Exe = exe(prefix()),
    Size = byte_size(Exe),
    <<Head:(Size - 2)/binary, _:16>> = Exe,
    Fake = <<?END:32/little, 0:(18 * 8)>>,
    WithComment = <<Head/binary, (byte_size(Fake)):16/little, Fake/binary>>,
    Out = write(WithComment, fun all/1, [{"a", <<"b">>}]),
    ?assertEqual([{"a", <<"b">>}], files(Out)),
    ?assertEqual(prefix(), binary:part(Out, 0, byte_size(prefix()))).

bad_end_record_test() ->
    %% The central directory does not end at the record: not a zip.
    Bad = <<"exe", ?END:32/little, 0:16, 0:16, 0:16, 0:16, 0:32, 0:32, 0:16>>,
    ?assertError(no_zip, beam_com_zip:entries(Bad)).

zip64_offset_test() ->
    Zip64 = <<"exe", ?END:32/little, 0:16, 0:16, 1:16, 1:16,
              0:32, 16#ffffffff:32, 0:16>>,
    ?assertError(zip64_not_supported, beam_com_zip:entries(Zip64)).

no_zip_test() ->
    ?assertError(no_zip, beam_com_zip:entries(<<"just an executable">>)),
    ?assertError(no_zip, beam_com_zip:write(<<>>, fun all/1, [])).

zip64_test() ->
    Zip64 = <<"exe", ?END:32/little, 0:16, 0:16, 16#ffff:16, 16#ffff:16,
              0:32, 16#ffffffff:32, 0:16>>,
    ?assertError(zip64_not_supported, beam_com_zip:entries(Zip64)).

%% The real check of the APE layout: Info-ZIP unzip reads the file, when
%% it is installed.
unzip_test() ->
    case os:find_executable("unzip") of
        false ->
            ok;
        Unzip ->
            File = filename:join(tmp_dir(), "beam_com_zip_test.com"),
            Out = write(exe(prefix()), fun all/1, sample()),
            ok = file:write_file(File, Out),
            Result = os:cmd(Unzip ++ " -tq " ++ File),
            ok = file:delete(File),
            ?assertMatch("No errors detected" ++ _, Result)
    end.

%% Helpers that read the central directory without the writer.

central(Bin) ->
    [{binary_to_list(Name), Method, EAttr}
     || {Name, Method, EAttr, _Offset, _Flags} <- cd_entries(Bin)].

flags(Bin) ->
    [{Name, Flags} || {Name, _, _, _, Flags} <- cd_entries(Bin)].

offsets(Bin) ->
    [{Name, Offset} || {Name, _, _, Offset, _} <- cd_entries(Bin)].

cd_offset(Bin) ->
    Pos = byte_size(Bin) - 22,
    <<?END:32/little, _:12/binary, CdOffset:32/little, _:16>> =
        binary:part(Bin, Pos, 22),
    CdOffset.

cd_entries(Bin) ->
    Pos = byte_size(Bin) - 22,
    <<?END:32/little, _:6/binary, Count:16/little, CdSize:32/little,
      CdOffset:32/little, _:16>> = binary:part(Bin, Pos, 22),
    parse(binary:part(Bin, CdOffset, CdSize), Count).

parse(_, 0) ->
    [];
parse(<<16#02014b50:32/little, _:4/binary, Flags:16/little, Method:16/little,
        _:16/binary, N:16/little, M:16/little, K:16/little, _:4/binary,
        EAttr:32/little, Offset:32/little, Name:N/binary, _:M/binary,
        _:K/binary, Rest/binary>>, Count) ->
    [{Name, Method, EAttr, Offset, Flags} | parse(Rest, Count - 1)].

%% Put a zip (offsets from its start) after Prefix, with offsets from the
%% start of the result.
relocate(Prefix, Zip) ->
    P = byte_size(Prefix),
    Size = byte_size(Zip),
    <<?END:32/little, _:6/binary, Count:16/little, CdSize:32/little,
      CdOffset:32/little, CLen:16/little>> = binary:part(Zip, Size - 22, 22),
    0 = CLen,
    Cd = binary:part(Zip, CdOffset, CdSize),
    NewCd = shift(Cd, Count, P),
    <<Prefix/binary, (binary:part(Zip, 0, CdOffset))/binary, NewCd/binary,
      ?END:32/little, 0:16, 0:16, Count:16/little, Count:16/little,
      CdSize:32/little, (CdOffset + P):32/little, 0:16>>.

shift(_, 0, _) ->
    <<>>;
shift(<<Head:42/binary, Offset:32/little, Rest0/binary>>, Count, P) ->
    <<_:28/binary, N:16/little, M:16/little, K:16/little, _/binary>> = Head,
    <<Tail:(N + M + K)/binary, Rest/binary>> = Rest0,
    <<Head/binary, (Offset + P):32/little, Tail/binary,
      (shift(Rest, Count - 1, P))/binary>>.

%% A zip of stored entries with data descriptors (as a streaming writer
%% makes them), after Prefix.
descriptor_zip(Prefix, Signature, Files) ->
    {Locals, Cds, _} =
        lists:foldl(
          fun({Name, Data}, {L, C, Pos}) ->
                  Crc = erlang:crc32(Data),
                  Size = byte_size(Data),
                  N = length(Name),
                  Local = <<16#04034b50:32/little, 20:16/little, 8:16/little,
                            0:16, 0:16, 33:16/little, 0:32, 0:32, 0:32,
                            N:16/little, 0:16, (list_to_binary(Name))/binary,
                            Data/binary>>,
                  Desc = case Signature of
                             true -> <<16#08074b50:32/little, Crc:32/little,
                                       Size:32/little, Size:32/little>>;
                             false -> <<Crc:32/little, Size:32/little,
                                        Size:32/little>>
                         end,
                  Cd = <<16#02014b50:32/little, 20:16/little, 20:16/little,
                         8:16/little, 0:16, 0:16, 33:16/little, Crc:32/little,
                         Size:32/little, Size:32/little, N:16/little, 0:16,
                         0:16, 0:16, 0:16, 0:32, Pos:32/little,
                         (list_to_binary(Name))/binary>>,
                  Record = <<Local/binary, Desc/binary>>,
                  {<<L/binary, Record/binary>>, <<C/binary, Cd/binary>>,
                   Pos + byte_size(Record)}
          end, {<<>>, <<>>, byte_size(Prefix)}, Files),
    Count = length(Files),
    <<Prefix/binary, Locals/binary, Cds/binary, ?END:32/little, 0:16, 0:16,
      Count:16/little, Count:16/little, (byte_size(Cds)):32/little,
      (byte_size(Prefix) + byte_size(Locals)):32/little, 0:16>>.

tmp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir -> Dir
    end.
