%% Uses the crypto NIF and prints the results, then stops the node.
-module(crypto_check).
-export([main/0]).

main() ->
    [{Name, _, Version}] = crypto:info_lib(),
    io:format("crypto: library ~s~n", [Version]),
    io:format("crypto: name ~s~n", [Name]),
    Sha = hex(crypto:hash(sha256, <<"abc">>)),
    io:format("crypto: sha256(abc) = ~s~n", [Sha]),
    Hmac = hex(crypto:mac(hmac, sha256, <<"key">>, <<"data">>)),
    io:format("crypto: hmac-sha256 = ~s~n", [Hmac]),
    Rand = crypto:strong_rand_bytes(16),
    io:format("crypto: 16 random bytes = ~p bytes~n", [byte_size(Rand)]),
    Key = crypto:strong_rand_bytes(32),
    IV = crypto:strong_rand_bytes(12),
    {Cipher, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, Key, IV,
                                                <<"hello">>, <<>>, true),
    Plain = crypto:crypto_one_time_aead(aes_256_gcm, Key, IV,
                                        Cipher, <<>>, Tag, false),
    io:format("crypto: aes-256-gcm round trip = ~s~n", [Plain]),
    io:format("crypto: os ~p~n", [os:type()]),
    init:stop().

hex(Bin) ->
    binary:encode_hex(Bin, lowercase).
