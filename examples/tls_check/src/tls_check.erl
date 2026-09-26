%% Checks port programs and TLS, prints the results, then stops the node:
%%
%%  0. Port programs: os:cmd/1 and the native resolver (not on Windows).
%%  1. A handshake between a server and a client in this node, with test
%%     certificates. This needs no network.
%%  2. An HTTPS request to a public host. The server certificate is
%%     verified with the certificates of the OS, when OTP can read them.
-module(tls_check).
-export([main/0]).

main() ->
    io:format("tls: ssl ~s, os ~p~n", [app_vsn(ssl), os:type()]),
    port_programs(),
    use_erlang_dns(),
    local_handshake(),
    remote_request(),
    init:stop().

%% --- 0. Port programs -----------------------------------------------------

%% os:cmd/1 and the native resolver (inet_gethost) are port programs.
%% BEAM.com has no port programs on Windows.
port_programs() ->
    case os:type() of
        {_, windows} ->
            io:format("ports: not supported on windows~n");
        _ ->
            "port-ok" ++ _ = os:cmd("echo port-ok"),
            {ok, _} = inet_gethost_native:gethostbyname("localhost"),
            io:format("ports: ok (os:cmd and inet_gethost)~n")
    end.

%% --- 1. Local handshake -------------------------------------------------

local_handshake() ->
    %% ECDSA P-256 keys with SHA-256 signatures (TLS 1.3 accepts these).
    Key = [{key, {namedCurve, secp256r1}}, {digest, sha256}],
    Chain = #{root => Key, peer => Key},
    #{server_config := ServerOpts, client_config := ClientOpts} =
        public_key:pkix_test_data(#{server_chain => Chain,
                                    client_chain => Chain}),
    {ok, Listen} = ssl:listen(0, [binary, {reuseaddr, true}, {active, false}
                                  | ServerOpts]),
    {ok, {_, Port}} = ssl:sockname(Listen),
    Parent = self(),
    spawn_link(fun() ->
                       {ok, T} = ssl:transport_accept(Listen),
                       {ok, S} = ssl:handshake(T),
                       {ok, <<"ping">>} = ssl:recv(S, 4),
                       ok = ssl:send(S, <<"pong">>),
                       Parent ! server_done
               end),
    {ok, C} = ssl:connect({127, 0, 0, 1}, Port,
                          [binary, {active, false}, {verify, verify_peer},
                           {server_name_indication, disable}
                           | ClientOpts], 10000),
    ok = ssl:send(C, <<"ping">>),
    {ok, <<"pong">>} = ssl:recv(C, 4),
    {ok, Info} = ssl:connection_information(C, [protocol]),
    receive server_done -> ok after 5000 -> exit(no_server) end,
    ssl:close(C),
    ssl:close(Listen),
    io:format("tls: local handshake ok (~p)~n",
              [proplists:get_value(protocol, Info)]).

%% --- 2. HTTPS request -----------------------------------------------------

remote_request() ->
    {ok, Host} = application:get_env(tls_check, host),
    {ok, Port} = application:get_env(tls_check, port),
    {Verify, Mode} = verify_options(),
    Opts = [{active, false}, {server_name_indication, Host} | Verify],
    case ssl:connect(Host, Port, Opts, 15000) of
        {ok, S} ->
            ok = ssl:send(S, ["HEAD / HTTP/1.1\r\nHost: ", Host,
                              "\r\nConnection: close\r\n\r\n"]),
            Status = case ssl:recv(S, 0, 15000) of
                         {ok, Data} -> hd(string:split(Data, "\r\n"));
                         Error -> io_lib:format("~p", [Error])
                     end,
            {ok, Info} = ssl:connection_information(S, [protocol]),
            ssl:close(S),
            io:format("tls: remote ~s ok (~p, verify ~s): ~s~n",
                      [Host, proplists:get_value(protocol, Info), Mode,
                       Status]);
        {error, Reason} ->
            io:format("tls: remote ~s failed (verify ~s): ~p~n",
                      [Host, Mode, Reason]),
            io:format("tls: dns lookup ~p, nameservers ~p~n",
                      [inet_db:res_option(lookup),
                       inet_db:res_option(nameservers)]),
            io:format("tls: inet_res:resolve ~p~n",
                      [inet_res:resolve(Host, in, a, [], 5000)])
    end.

%% Resolve names with the DNS client of Erlang. The native resolver
%% (inet_gethost) is a port program, and there are no port programs in
%% BEAM.com on Windows.
use_erlang_dns() ->
    inet_db:set_lookup([file, dns]),
    case inet_db:res_option(nameservers) of
        [] ->
            inet_db:add_ns({1, 1, 1, 1}),
            inet_db:add_ns({8, 8, 8, 8});
        _ ->
            ok
    end.

verify_options() ->
    try public_key:cacerts_get() of
        [_ | _] = CACerts ->
            {[{verify, verify_peer}, {cacerts, CACerts},
              {customize_hostname_check,
               [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
             io_lib:format("peer, ~p OS certificates", [length(CACerts)])};
        [] ->
            {[{verify, verify_none}], "none (no OS certificates)"}
    catch
        _:Reason ->
            {[{verify, verify_none}],
             io_lib:format("none (OS certificates: ~p)", [Reason])}
    end.

app_vsn(App) ->
    {ok, Vsn} = application:get_key(App, vsn),
    Vsn.
