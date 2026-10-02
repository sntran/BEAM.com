%% Crypto with fixed keys. The output must be the same in each runtime.
-module(diff_crypto).
-export([main/1]).

main(_Dir) ->
    try crypto:info_lib() of
        [_ | _] -> run()
    catch
        error:_ -> io:format("crypto: none~n")
    end.

run() ->
    Data = list_to_binary(lists:duplicate(1000, "the data ")),
    p(hash, [crypto:hash(H, Data) || H <- [md5, sha, sha256, sha512, sha3_256, blake2b]]),
    p(hmac, [crypto:mac(hmac, sha256, <<"key">>, Data)]),
    Key = binary:copy(<<7>>, 32), Iv = binary:copy(<<9>>, 12),
    {Ct, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, Key, Iv, Data, <<"aad">>, true),
    p(gcm, [erlang:md5(Ct), Tag,
            crypto:crypto_one_time_aead(aes_256_gcm, Key, Iv, Ct, <<"aad">>, Tag, false) =:= Data]),
    Cbc = crypto:crypto_one_time(aes_128_cbc, binary:copy(<<1>>, 16), binary:copy(<<2>>, 16),
                                 binary:part(Data, 0, 64), true),
    p(cbc, Cbc),
    p(pbkdf2, crypto:pbkdf2_hmac(sha256, <<"pass">>, <<"salt">>, 1000, 32)),
    {Pub, Priv} = crypto:generate_key(eddsa, ed25519, binary:copy(<<5>>, 32)),
    Sig = crypto:sign(eddsa, none, Data, [Priv, ed25519]),
    p(ed25519, [Pub, Sig, crypto:verify(eddsa, none, Data, Sig, [Pub, ed25519])]),
    p(random, byte_size(crypto:strong_rand_bytes(16))).

p(Label, Term) ->
    io:format("~s: ~w~n", [Label, Term]).
