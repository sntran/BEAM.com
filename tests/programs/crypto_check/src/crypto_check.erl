%% Uses the crypto NIF and prints the results, then stops the node.
%%
%% The known answers cover the assembly code of OpenSSL for each CPU
%% half (docs/INTERNALS.md, "Crypto and TLS"). Each input is above 1 MiB
%% and not a multiple of a block, so the code of many blocks and the
%% code of the last part both run. The expected values come from Python
%% (hashlib and pow), from OpenSSL 3.0 of Linux (CTR, CBC and ECDH), from
%% the C code of OpenSSL 4.0.3 with no assembly (GCM and
%% ChaCha20-Poly1305), and from FIPS-197 and RFC 8032.
-module(crypto_check).
-export([main/0, values/0]).

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
    Values = values(),
    report("the known answers of the hashes", Values, hashes()),
    report("the known answers of the ciphers", Values, ciphers()),
    report("the public keys", Values, public_keys()),
    io:format("crypto: os ~p~n", [os:type()]),
    init:stop().

%% The expected values.
hashes() ->
    [{md5, <<"102120dfdb8b423a98c69ef89d76f2c8">>},
     {sha, <<"33d8312effbfd3c74f2ce7fee69aa620ba71ce18">>},
     {sha224, <<"aa122a3a53084835cc5ff20d962783f7fc52607c675ed90be841c94d">>},
     {sha256, <<"5e46ca8454f624efef662babf78abdab93c98ee13e84d61915fe4146a8488ced">>},
     {sha384, <<"635d265d2b19befb9eeb9f87e3efb9bd305dbc36b15b363412b3d8e8"
              "24c19e6a7267ea5286ef5785b6b0dac2fccbf589">>},
     {sha512, <<"9e6c0e7dcf78669d611258cf7c0d8d29fceb7a0cbea515b60f34d29449626adf"
              "e075819ad7bb525da1a3af34030de84202207f165cba23e96f5c21c6e289deff">>},
     {sha3_256, <<"0b8de794cfb1631dd263022869711111ad6fa4db4281f8be0f7febf05a3c4f84">>},
     {sha3_512, <<"e4e508ae89e936b8e8c0c910d922cf6b28e23c83db7b942820587ca8682fddaf"
                "95e4c91ae02adfd442767cf743261063f0b570ed01dcd212db0d14b4f5e8aee7">>},
     {mod_pow, <<"94e7c24e19ecdf8b7878df6c61533e15d1ef49319ba1f910edf186e6db74470a">>}].

ciphers() ->
    [{aes_128_ecb, <<"69c4e0d86a7b0430d8cdb78070b4c55a">>},
     {aes_256_ctr, <<"c74e01ee5d445094944f4068f36e45efe0cabd201e1bdad60b4d5b3e8250e071">>},
     {aes_256_cbc, <<"b6f5e48218aecde8f0735e7759fbf3fc3837e9720f8e8c478e7e42634fe1e4bb">>},
     {aes_128_gcm, <<"c14a892f29f24861214cc12bfc15a519bcb56daafc6f2bee606175880436c43a">>},
     {aes_256_gcm, <<"88b8c7ad7c4c0dc55bbae22f098dcdae309f50160b4585bda39759556739f925">>},
     {chacha20_poly1305, <<"755e6c775fee6e55e19ad9aa16d1a579d582768a5a9b7b94d1fe4fd49013b067">>},
     {decrypt, true}].

public_keys() ->
    [{ed25519, <<"e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
               "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b">>},
     {ecdh_p256, <<"31b636aea0e231f4ffc94c81e9652b821c02202fde7f22cb74c27dd547ba79a3">>},
     {ecdh_p384, <<"96455d236990a84e1626bccfd2c5049b22b7b207254b014d"
                   "514cf36b88e5bb3bc71e5265b6374f1cc598281e66224b6c">>},
     {ecdh_p521, <<"00d9af062d761d879d62d48f95e61d2d76dfe28caf5b156ee61608311b73688f"
                   "1294c687295cbd10fa5f7561320ff63f4c6f329c574ff7bdd9c2e822a7bbf443d6ac">>},
     {rsa, true},
     {ecdsa, true},
     {ecdh, true},
     {x25519, true}].

report(What, Values, Expected) ->
    case [K || {K, V} <- Expected, maps:get(K, Values) =/= V] of
        [] -> io:format("crypto: ~s = ok~n", [What]);
        Bad -> io:format("crypto: ~s = FAIL ~p~n", [What, Bad])
    end.

%% The value of each check, as hex text or a boolean.
values() ->
    Data = << <<((I * 7 + 3) band 255)>> || I <- lists:seq(0, 1048576 + 16) >>,
    Data16 = binary:part(Data, 0, 1048576),
    K32 = crypto:hash(sha256, <<"beam.com key">>),
    K16 = binary:part(K32, 0, 16),
    <<IV12:12/binary, _/binary>> = IV16 = binary:part(crypto:hash(sha256, <<"beam.com iv">>), 0, 16),
    AAD = <<"beam.com aad">>,
    H = fun(B) -> hex(crypto:hash(sha256, B)) end,
    Aead = fun(C, K) ->
                   {E, T} = crypto:crypto_one_time_aead(C, K, IV12, Data, AAD, true),
                   {H(<<E/binary, T/binary>>), crypto:crypto_one_time_aead(C, K, IV12, E, AAD, T, false) =:= Data}
           end,
    {Gcm128, D1} = Aead(aes_128_gcm, K16),
    {Gcm256, D2} = Aead(aes_256_gcm, K32),
    {Chacha, D3} = Aead(chacha20_poly1305, K32),
    Ctr = crypto:crypto_one_time(aes_256_ctr, K32, IV16, Data, true),
    Cbc = crypto:crypto_one_time(aes_256_cbc, K32, IV16, Data16, true),
    D4 = crypto:crypto_one_time(aes_256_ctr, K32, IV16, Ctr, false) =:= Data andalso
        crypto:crypto_one_time(aes_256_cbc, K32, IV16, Cbc, false) =:= Data16,
    Ecb = crypto:crypto_one_time(aes_128_ecb, list_to_binary(lists:seq(0, 15)),
                                 binary:decode_hex(<<"00112233445566778899aabbccddeeff">>), true),
    Big = fun(S) -> binary:decode_unsigned(binary:copy(crypto:hash(sha512, S), 4)) end,
    M = Big(<<"m">>) bor 1 bor (1 bsl 2047),
    Pow = crypto:mod_pow(Big(<<"b">>), Big(<<"e">>), M),
    Ed = binary:decode_hex(<<"9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60">>),
    Msg = binary:part(Data, 0, 1000),
    maps:merge(
      maps:from_list([{A, hex(crypto:hash(A, Data))}
                      || A <- [md5, sha, sha224, sha256, sha384, sha512, sha3_256, sha3_512]]),
      #{mod_pow => H(pad(Pow, 256)),
        aes_128_ecb => hex(Ecb),
        aes_256_ctr => H(Ctr),
        aes_256_cbc => H(Cbc),
        aes_128_gcm => Gcm128,
        aes_256_gcm => Gcm256,
        chacha20_poly1305 => Chacha,
        decrypt => D1 andalso D2 andalso D3 andalso D4,
        ed25519 => hex(crypto:sign(eddsa, none, <<>>, [Ed, ed25519])),
        rsa => sign_verify(rsa, {rsa, 2048, 65537}, Msg),
        ecdsa => sign_verify(ecdsa, {ecdh, secp256r1}, Msg),
        ecdh_p256 => ecdh(secp256r1,
                          <<"21b42fd254445363f0dba47b5c4a7c7f0f5a93114aaf64325955c69ca760bd2d">>,
                          <<"04afff2375d81e613267d26aa2d547240b714c0df2d4d3a6e050e94ec1046a6c"
                            "d4661ab416b5c11c90dd5bbb825eaad6fbf9f01f4c0c794cbf0080d1c0fd1fe096">>),
        ecdh_p384 => ecdh(secp384r1,
                          <<"fc6aad13ad06f38f4245d566eb255821a75f3c0949845f09"
                            "ca833a61776a421a747e6d34e5d7ee39827c964d1398ce9b">>,
                          <<"04e0a08d7a7412b1b185634f50f80b8e27848bcfcbe42c84dc18cb895d44e5ee"
                            "b907d6f0b6979ff6e94f442a4044c4b60e85a9ff9b236cee1ae80ce69a2905ad"
                            "8e9bfa4738383997224ccd974eec4e86e049edcec63508675c57ef9c5c38490091">>),
        ecdh_p521 => ecdh(secp521r1,
                          <<"00b5586fc4db4f3dc6471734914b8361d154896c5bd7c8ac56f66d84ed226008"
                            "0f14b685ef5428ba24704ccb19a164cf41dfd9366d1bc2190a07cc6360495d43632a">>,
                          <<"04012be51fe9ffeeb1ad23ec7dd332c88926c05ae7547f15743ce575584dca4c"
                            "3592d5b2877aa3cb8e1e9bd3706aeddd7ae870d4cb127b8a40a233e5694ee32b"
                            "946f9b006753a0b9a334930f2cf72c0dae5890df77d3c12ca02d1d6d1718bb6a"
                            "e3026ecdfc4d24451b4e6aabded89cc5490cd8dba7162c5e38511eae5abb3738"
                            "c7eab399b6">>),
        ecdh => agree(ecdh, secp256r1),
        x25519 => agree(eddh, x25519)}).

%% A signature with a new key verifies, and a changed message does not.
sign_verify(Alg, KeyType, Msg) ->
    {Pub, Priv} = crypto:generate_key(element(1, KeyType), params(KeyType)),
    Key = case Alg of rsa -> Priv; ecdsa -> [Priv, secp256r1] end,
    PubKey = case Alg of rsa -> Pub; ecdsa -> [Pub, secp256r1] end,
    Sig = crypto:sign(Alg, sha256, Msg, Key),
    <<B, Rest/binary>> = Msg,
    crypto:verify(Alg, sha256, Msg, Sig, PubKey) andalso
        not crypto:verify(Alg, sha256, <<(B bxor 1), Rest/binary>>, Sig, PubKey).

params({rsa, Bits, E}) -> {Bits, E};
params({ecdh, Curve}) -> Curve.

%% The shared secret of a fixed private key and a fixed public key, as hex
%% text. The keys are hex text.
ecdh(Curve, Priv, Pub) ->
    hex(crypto:compute_key(ecdh, binary:decode_hex(Pub), binary:decode_hex(Priv), Curve)).

%% Two new keys give the same shared secret from each side.
agree(Type, Curve) ->
    {PubA, PrivA} = crypto:generate_key(Type, Curve),
    {PubB, PrivB} = crypto:generate_key(Type, Curve),
    crypto:compute_key(Type, PubB, PrivA, Curve) =:= crypto:compute_key(Type, PubA, PrivB, Curve).

pad(Bin, N) when byte_size(Bin) < N -> pad(<<0, Bin/binary>>, N);
pad(Bin, _) -> Bin.

hex(Bin) ->
    binary:encode_hex(Bin, lowercase).
