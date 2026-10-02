%% The external term format, the hash functions, the order of terms,
%% Unicode, regular expressions, and JSON.
-module(diff_terms).
-export([main/1]).

main(_Dir) ->
    Terms = [0, -1, 255, 256, 1 bsl 31, -(1 bsl 31), 1 bsl 64, -(1 bsl 100),
             1.5, -0.0, abc, 'ünï', <<>>, <<1, 2, 3>>, <<1:3>>, "text", [1 | 2],
             {}, {a, [b], #{}}, #{a => 1, <<"b">> => [2.0]}, [$ä, 16#1F600],
             maps:from_list([{N, N * N} || N <- lists:seq(1, 40)])],
    p(external, [term_to_binary(T) || T <- Terms]),
    p(external_v, [term_to_binary(T, [{minor_version, 1}, deterministic]) || T <- Terms]),
    p(round_trip, [binary_to_term(term_to_binary(T, [compressed])) =:= T || T <- Terms]),
    p(phash2, [erlang:phash2(T) || T <- Terms]),
    p(phash2_range, [erlang:phash2(T, 1000) || T <- Terms]),
    p(sort, lists:sort(Terms)),
    p(map_order, [maps:keys(maps:from_list([{N, x} || N <- lists:seq(1, 40)]))]),
    %% Erlang does not specify the order of the keys of a map with more
    %% than 32 keys. With atom keys, the order in wasm32 is not the order
    %% in a 64-bit runtime. The sorted keys and the deterministic encoding
    %% must be the same.
    Atoms = maps:from_list([{list_to_atom([C]), x} || C <- lists:seq($a, $z) ++ lists:seq($A, $Z)]),
    p(map_atoms, [lists:sort(maps:keys(Atoms)), term_to_binary(Atoms, [deterministic])]),
    Data = list_to_binary([integer_to_list(N) || N <- lists:seq(1, 2000)]),
    p(checksums, [erlang:crc32(Data), erlang:adler32(Data), erlang:md5(Data)]),
    p(zlib, [zlib:uncompress(zlib:compress(Data)) =:= Data,
             zlib:gunzip(zlib:gzip(Data)) =:= Data]),
    p(base64, [base64:encode(Data), base64:decode(base64:encode(<<0, 255, 128>>))]),
    p(bits, [<<X:13/little-signed>> || X <- [-4096, -1, 0, 1, 4095]] ++
            [<<F:32/float>> || F <- [1.5, -2.0e30]] ++
            [<<F:64/float-little>> || F <- [1.0e-300]]),
    <<A:7, B:17/signed, C/bits>> = <<"binary bits!">>,
    p(match, [A, B, C]),
    S = "Grüße, Καλημέρα, こんにちは, 😀",
    p(unicode, [unicode:characters_to_binary(S), unicode:characters_to_binary(S, unicode, utf16),
                unicode:characters_to_binary(S, unicode, {utf32, little})]),
    p(string, [string:uppercase(S), string:casefold("Straße"), string:length(S),
               unicode:characters_to_nfd_binary("é"), string:split("a,b,,c", ",", all)]),
    p(re, [re:run("abc123def456", "[0-9]+", [global, {capture, all, list}]),
           re:replace("Grüße", "ü", "ue", [unicode, {return, binary}]),
           re:split("a1b22c333", "[0-9]+", [{return, list}])]),
    p(json, [iolist_to_binary(json:encode(#{<<"a">> => [1, 2.5, null, true, <<"ü\n"/utf8>>]})),
             json:decode(<<"{\"x\":[1e3, -0.5, \"\\u00fc\", {}]}">>)]),
    p(format, [lists:flatten(io_lib:format("~p", [Terms]))]).

p(Label, Term) ->
    io:format("~s: ~w~n", [Label, Term]).
