%% The speed of the crypto NIF. Each item runs for about one second and
%% prints one line: "bench NAME VALUE UNIT".
%%
%%   erl -noshell -eval '{ok,M,B}=compile:file("crypto_bench.erl",[binary]),
%%       code:load_binary(M,"crypto_bench.erl",B), crypto_bench:main(), halt().'
-module(crypto_bench).
-export([main/0]).

-define(TIME, 1000).

main() ->
    {ok, _} = application:ensure_all_started(ssl),
    [{_, _, Lib}] = crypto:info_lib(),
    io:format("bench library ~s~n", [Lib]),
    MiB = crypto:strong_rand_bytes(1 bsl 20),
    KiB = binary:part(MiB, 0, 1024),
    Small = binary:part(MiB, 0, 64),
    [mbps(A, fun() -> crypto:hash(A, MiB) end) || A <- [md5, sha, sha256, sha512, sha3_256]],
    ops(hmac_sha256_64b, fun() -> crypto:mac(hmac, sha256, Small, Small) end),
    ops(pbkdf2_sha256_1000, fun() -> crypto:pbkdf2_hmac(sha256, Small, Small, 1000, 32) end),
    K32 = crypto:strong_rand_bytes(32),
    K16 = binary:part(K32, 0, 16),
    IV = crypto:strong_rand_bytes(12),
    [mbps(Name, fun() -> crypto:crypto_one_time_aead(C, K, IV, MiB, <<>>, true) end)
     || {Name, C, K} <- [{aes_128_gcm, aes_128_gcm, K16},
                         {aes_256_gcm, aes_256_gcm, K32},
                         {chacha20_poly1305, chacha20_poly1305, K32}]],
    mbps(aes_256_gcm_1k, 1024, fun() -> crypto:crypto_one_time_aead(aes_256_gcm, K32, IV, KiB, <<>>, true) end),
    {RsaPub, RsaPriv} = crypto:generate_key(rsa, {2048, 65537}),
    RsaSig = crypto:sign(rsa, sha256, Small, RsaPriv),
    ops(rsa2048_sign, fun() -> crypto:sign(rsa, sha256, Small, RsaPriv) end),
    ops(rsa2048_verify, fun() -> true = crypto:verify(rsa, sha256, Small, RsaSig, RsaPub) end),
    {EcPub, EcPriv} = crypto:generate_key(ecdh, secp256r1),
    EcSig = crypto:sign(ecdsa, sha256, Small, [EcPriv, secp256r1]),
    ops(p256_sign, fun() -> crypto:sign(ecdsa, sha256, Small, [EcPriv, secp256r1]) end),
    ops(p256_verify, fun() -> true = crypto:verify(ecdsa, sha256, Small, EcSig, [EcPub, secp256r1]) end),
    {EcPub2, _} = crypto:generate_key(ecdh, secp256r1),
    ops(p256_ecdh, fun() -> crypto:compute_key(ecdh, EcPub2, EcPriv, secp256r1) end),
    {XPub, _} = crypto:generate_key(eddh, x25519),
    {_, XPriv} = crypto:generate_key(eddh, x25519),
    ops(x25519, fun() -> crypto:compute_key(eddh, XPub, XPriv, x25519) end),
    {_, EdPriv} = crypto:generate_key(eddsa, ed25519),
    ops(ed25519_sign, fun() -> crypto:sign(eddsa, none, Small, [EdPriv, ed25519]) end),
    tls(tls13_handshake_p256, {namedCurve, secp256r1}),
    tls(tls13_handshake_rsa2048, {rsa, 2048, 65537}),
    ok.

mbps(Name, F) -> mbps(Name, 1 bsl 20, F).

mbps(Name, Bytes, F) ->
    {N, Ms} = loop(F),
    io:format("bench ~s ~.1f MB/s~n", [Name, N * Bytes / 1048576 / (Ms / 1000)]).

ops(Name, F) ->
    {N, Ms} = loop(F),
    io:format("bench ~s ~.1f op/s~n", [Name, N / (Ms / 1000)]).

%% Runs F until ?TIME ms pass, after one run to warm up.
loop(F) ->
    F(),
    T0 = erlang:monotonic_time(microsecond),
    loop(F, T0, 0).

loop(F, T0, N) ->
    F(),
    Us = erlang:monotonic_time(microsecond) - T0,
    case Us >= ?TIME * 1000 of
        true -> {N + 1, Us / 1000};
        false -> loop(F, T0, N + 1)
    end.

%% Full TLS 1.3 handshakes on the loopback: both sides run in this VM.
%% The server has a certificate chain of the key type Key.
tls(Name, Key) ->
    Cert = [{key, Key}, {digest, sha256}],
    try
        #{server_config := S, client_config := C} =
            public_key:pkix_test_data(#{server_chain => #{root => Cert, peer => Cert},
                                        client_chain => #{root => Cert, peer => Cert}}),
        {ok, L} = ssl:listen(0, [{versions, ['tlsv1.3']}, {reuseaddr, true}, {nodelay, true}, binary | S]),
        {ok, {_, Port}} = ssl:sockname(L),
        Self = self(),
        Acceptor = spawn_link(fun() -> accept(L, Self) end),
        %% The client has no certificate, as with most clients: it
        %% checks the chain of the server.
        Client = [O || O <- C, not lists:member(element(1, O), [cert, key, certs_keys])],
        Opts = [{versions, ['tlsv1.3']}, {verify, verify_peer}, {nodelay, true},
                {server_name_indication, disable}, binary | Client],
        F = fun() ->
                    {ok, Sock} = ssl:connect("127.0.0.1", Port, Opts, 10000),
                    receive {accepted, Acceptor} -> ok end,
                    ssl:close(Sock)
            end,
        ops(Name, F),
        unlink(Acceptor),
        exit(Acceptor, kill),
        ssl:close(L)
    catch
        Class:Reason -> io:format("bench ~s n/a ~p:~0p~n", [Name, Class, Reason])
    end.

accept(L, Owner) ->
    {ok, T} = ssl:transport_accept(L),
    {ok, S} = ssl:handshake(T, 10000),
    Owner ! {accepted, self()},
    ssl:close(S),
    accept(L, Owner).
