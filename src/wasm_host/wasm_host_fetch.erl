%% HTTP of the program through fetch() of the host (specs/FetchPath.tla).
%% The host joins the socket of the program to a connection of the listener
%% of this server, in place of connect(). So the program sees an open
%% connection, and its code and its configuration do not change. worker.js
%% chooses the route:
%%
%% - Fetch first: plain HTTP (port 80) through fetch(), and HTTPS (port
%%   443) too when the trust store of the VM holds the CA of this server.
%%   BEAM_FETCH gives other hosts and ports.
%% - The fallback: on Cloudflare, connect() cannot reach a host behind
%%   Cloudflare. When connect() fails on port 443 or 80, worker.js checks
%%   the addresses of the name, and a host of Cloudflare comes here.
%%
%% The other connections (another port: a database, SMTP, Redis) use
%% connect() of the host.
%%
%% - TLS: the server ends the TLS of the program with a certificate for the
%%   name of its SNI, signed by a CA of this VM. The trust store of
%%   public_key:cacerts_get/0 holds that CA (Mint, Req, Finch, Swoosh and
%%   httpc with that store trust it). A program that gives its own CA file
%%   (castore, for example) gets an unknown CA. Without a store (no
%%   --cacerts), the store does not change, and HTTPS uses connect().
%% - The VM makes its CA at the start and again at the event "restored"
%%   of the host (reseed/0, in the pump): a VM of the global scope has zero
%%   random bytes until that event.
%% - Each request goes to the host ({"t":"fetch"}), and the host calls
%%   fetch() with the host of the connect, never with the Host header or
%%   the SNI. The response comes back as fetch_head, fetch_data and
%%   fetch_end (or fetch_error), and the server writes it with chunked
%%   transfer coding.
%% - An upgrade (WebSocket) does not go to fetch(): the server opens a
%%   tunnel, a connect() of the host to the host of the connect (never the
%%   fetch path), with TLS of its own and the trust store of the VM. On
%%   Cloudflare, a tunnel to a host of Cloudflare fails (502).
%% - HTTP/1.1 only (ALPN http/1.1): no HTTP/2. A request body is at most
%%   32 MiB.
%% - No retry: at the timeout of the host, the server closes the
%%   connection, and the program does not know if the request ran.
-module(wasm_host_fetch).
-behaviour(gen_server).

-export([start_link/0, reseed/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, handle_continue/2]).
-export([new_ca/0, leaf/2, store_with/2, serve/3, handshake_opts/1, client_opts/2]).

-include_lib("public_key/include/public_key.hrl").

-define(TABLE, ?MODULE).
-define(STORE, "/tmp/wasm_host_fetch.pem").
-define(MAX_BODY, 32 * 1024 * 1024).
-define(HEAD_TIMEOUT, 300000).
-define(IDLE_TIMEOUT, 300000).
-define(HANDSHAKE_TIMEOUT, 30000).
-define(CONNECT_TIMEOUT, 30000).
-define(CERT_DAYS, 7).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% A new CA and a new trust store, with the random bytes that the pump got
%% at the event "restored". The pump calls it, and takes the next event
%% after the reply.
reseed() ->
    case whereis(?MODULE) of
        undefined -> ok;
        _ -> gen_server:call(?MODULE, reseed, infinity)
    end.

init([]) ->
    ?TABLE = ets:new(?TABLE, [named_table, public, {read_concurrency, true}]),
    ok = setup_ca(),
    {ok, #{}, {continue, listen}}.

%% The listener of the host for the connections of the fetch path. The host
%% keeps it apart from the listeners of the program: no WebSocket to
%% /.tcp/PORT reaches it. With the CA in the trust store, HTTPS comes here
%% first.
handle_continue(listen, S) ->
    Tls = original_store() =/= [],
    {ok, L} = wasm_tcp:listen(0, [binary, {active, false}, {wasm_fetch, true}, {wasm_fetch_tls, Tls}]),
    Acceptor = spawn_link(fun() -> accept(L) end),
    {noreply, S#{listener => L, acceptor => Acceptor}}.

handle_call(reseed, _From, S) ->
    {reply, setup_ca(), S}.

handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.

accept(L) ->
    case wasm_tcp:accept(L) of
        {ok, Sock} ->
            Pid = spawn(fun() -> receive go -> connection(Sock) end end),
            ok = wasm_tcp:controlling_process(Sock, Pid),
            Pid ! go,
            accept(L);
        {error, closed} ->
            ok
    end.

%% A connection of the fetch path: TLS when the first byte is a TLS record
%% (a handshake, 0x16), else plain HTTP.
connection(Sock) ->
    {ok, #{id := Conn, host := Host, port := Port}} = wasm_tcp:host_info(Sock),
    Call = fun(Tls) ->
                   fun(#{upgrade := Head}) -> tunnel(Host, Port, Tls, Head);
                      (Req) -> call_host(Req#{conn => Conn, tls => Tls})
                   end
           end,
    case gen_tcp:recv(Sock, 1, ?HANDSHAKE_TIMEOUT) of
        {ok, <<16#16>> = B} ->
            ok = gen_tcp:unrecv(Sock, B),
            {ok, _} = application:ensure_all_started(ssl),
            case ssl:handshake(Sock, handshake_opts(ets:lookup_element(?TABLE, ca, 2)),
                               ?HANDSHAKE_TIMEOUT) of
                {ok, Tls} -> serve({ssl, Tls}, Call(true), <<>>);
                {error, _} -> gen_tcp:close(Sock)
            end;
        {ok, B} ->
            serve({gen_tcp, Sock}, Call(false), B);
        {error, _} ->
            gen_tcp:close(Sock)
    end.

%% --- the CA ------------------------------------------------------------------

%% The CA, the leaf cache, and the trust store (when the VM has a store).
setup_ca() ->
    case code:ensure_loaded(public_key) of
        {module, _} ->
            CA = new_ca(),
            ets:delete_all_objects(?TABLE),
            true = ets:insert(?TABLE, {ca, CA}),
            case store_with(original_store(), CA) of
                none -> ok;
                Pem ->
                    ok = file:write_file(?STORE, Pem),
                    ok = public_key:cacerts_load(?STORE)
            end;
        _ ->
            ok
    end.

%% The trust store of the VM before the CA: the build put it there
%% (--cacerts). The tunnel checks the certificates of the hosts with it.
original_store() ->
    case persistent_term:get({?MODULE, store}, undefined) of
        undefined ->
            O = current_store(),
            persistent_term:put({?MODULE, store}, O),
            O;
        O -> O
    end.

current_store() ->
    try [Der || {cert, Der, _} <- public_key:cacerts_get()]
    catch _:_ -> []
    end.

%% The PEM of the trust store: the certificates of Orig and the CA. none
%% when the VM has no store: the store does not change.
-spec store_with([public_key:der_encoded()], map()) -> binary() | none.
store_with([], _CA) -> none;
store_with(Orig, #{cert := Der}) ->
    public_key:pem_encode([{'Certificate', D, not_encrypted} || D <- Orig ++ [Der]]).

-spec new_ca() -> #{cert := public_key:der_encoded(), key := term()}.
new_ca() ->
    public_key:pkix_test_root_cert("beam.com fetch", [{key, {namedCurve, secp256r1}}, {digest, sha256},
                                                      {validity, validity(365)}]).

%% A certificate for the name, signed by the CA (the cache of the ETS table
%% holds it for a day).
-spec leaf(map(), string()) -> #{cert := public_key:der_encoded(), key := term()}.
leaf(CA, Name) ->
    SAN = #'Extension'{extnID = ?'id-ce-subjectAltName', critical = false,
                       extnValue = [{dNSName, Name}]},
    Conf = public_key:pkix_test_data(#{root => CA, intermediates => [],
                                       peer => [{key, {namedCurve, secp256r1}}, {digest, sha256},
                                                {validity, validity(?CERT_DAYS)},
                                                {extensions, [SAN]}]}),
    #{cert => proplists:get_value(cert, Conf), key => proplists:get_value(key, Conf)}.

validity(Days) ->
    Today = calendar:date_to_gregorian_days(date()),
    {calendar:gregorian_days_to_date(Today - 1), calendar:gregorian_days_to_date(Today + Days)}.

cached_leaf(CA, Name) ->
    Now = erlang:monotonic_time(second),
    case ets:lookup(?TABLE, {leaf, Name}) of
        [{_, Leaf, Made}] when Now - Made < 86400 -> Leaf;
        _ ->
            Leaf = leaf(CA, Name),
            ets:insert(?TABLE, {{leaf, Name}, Leaf, Now}),
            Leaf
    end.

%% The options of the TLS server: the leaf of the SNI name, and a leaf for
%% an invalid name when the client sends no SNI (its host check fails).
-spec handshake_opts(map()) -> [ssl:tls_server_option()].
handshake_opts(CA) ->
    Leaf = fun(Name) -> case whereis(?MODULE) of
                            undefined -> leaf(CA, Name);
                            _ -> cached_leaf(CA, Name)
                        end
           end,
    [{certs_keys, [Leaf("fetch.invalid")]},
     {sni_fun, fun(Name) -> [{certs_keys, [Leaf(Name)]}] end},
     {alpn_preferred_protocols, [<<"http/1.1">>]},
     {versions, ['tlsv1.3', 'tlsv1.2']}].

%% --- HTTP ----------------------------------------------------------------------

%% The requests of one connection, one at a time. Call(Request) gives
%% {ok, Status, Reason, Headers, Next} or {error, Reason}, and Next() gives
%% {data, Bin, Next}, done or {error, Reason}. For an upgrade, the request
%% has the key upgrade, the bytes of its head. Then Call gives
%% {tunnel, Transport} (a connection to the host, which got the head) or
%% {error, Reason}, and the bytes of the two connections go both ways.
-spec serve({module(), term()}, fun((map()) -> term()), binary()) -> ok.
serve(T, Call, Buffer) ->
    case read_head(T, Buffer) of
        {ok, Head, Rest, Raw} ->
            request(T, Call, Head, Rest, Raw);
        {error, too_large} ->
            final(T, 431, <<"the head of the request is too large">>);
        {error, bad_request} ->
            final(T, 400, <<"bad request">>);
        {error, bad_target} ->
            final(T, 400, <<"the request target is not a path">>);
        closed ->
            close(T)
    end.

request(T, Call, #{method := Method, headers := Headers, version := Version} = Head, Rest, Raw) ->
    Upgrade = lists:keymember(<<"upgrade">>, 1, Headers),
    case wasm_host_http:framing(Headers) of
        _ when Upgrade ->
            upgrade(T, Call(#{upgrade => Raw}), Rest);
        {error, _} ->
            final(T, 400, <<"bad framing of the body">>);
        {length, N} when N > ?MAX_BODY ->
            final(T, 413, <<"the body is larger than 32 MiB">>);
        Framing ->
            wasm_host_http:continue(Headers) andalso Framing =/= none
                andalso send(T, <<"HTTP/1.1 100 Continue\r\n\r\n">>),
            case read_body(T, Framing, Rest) of
                {ok, Body, Next} ->
                    Close = not wasm_host_http:keep_alive(Version, Headers),
                    Req = #{method => Method, path => maps:get(path, Head),
                            headers => wasm_host_http:request_headers(Headers), body => Body},
                    case respond(T, Method, Call(Req), Close) of
                        ok when not Close -> serve(T, Call, Next);
                        _ -> close(T)
                    end;
                {error, too_large} ->
                    final(T, 413, <<"the body is larger than 32 MiB">>);
                {error, _} ->
                    close(T)
            end
    end.

respond(T, Method, {ok, Status, Reason, Headers, Next}, Close) ->
    Body = wasm_host_http:body_allowed(Method, Status),
    send(T, wasm_host_http:response(Status, Reason, Headers, #{chunked => Body, close => Close})),
    case Body of
        true -> stream(T, Next);
        false -> drain(Next)
    end;
respond(T, _Method, {error, Reason}, _Close) ->
    final(T, 502, iolist_to_binary(["beam.com: fetch() failed: ", text(Reason)])),
    closed.

%% An upgrade: the bytes after the head go to the host, and then the bytes
%% of the two connections go both ways, until one of them closes.
upgrade(T, {tunnel, Up}, Rest) ->
    case Rest =:= <<>> orelse send(Up, Rest) =:= ok of
        true -> relay(T, Up);
        false -> close(Up), close(T)
    end;
upgrade(T, {error, Reason}, _Rest) ->
    final(T, 502, iolist_to_binary(["beam.com: no tunnel: ", text(Reason)])).

relay(T, Up) ->
    Back = spawn_link(fun() -> pipe(Up, T) end),
    pipe(T, Up),
    unlink(Back),
    close(Up),
    close(T).

%% The bytes of From to To. At the end, both close: the other pipe ends.
pipe(From, To) ->
    case recv(From, infinity) of
        {ok, Data} ->
            case send(To, Data) of
                ok -> pipe(From, To);
                _ -> close(From), close(To)
            end;
        {error, _} ->
            close(From),
            close(To)
    end.

%% The body of the response, chunk by chunk. A failure after the head can
%% only close the connection: the program sees a body that ends early.
stream(T, Next) ->
    case Next() of
        {data, Data, Next1} ->
            case send(T, wasm_host_http:chunk(Data)) of
                ok -> stream(T, Next1);
                _ -> closed
            end;
        done ->
            send(T, wasm_host_http:last_chunk());
        {error, _} ->
            closed
    end.

drain(Next) ->
    case Next() of
        {data, _, Next1} -> drain(Next1);
        done -> ok;
        {error, _} -> closed
    end.

final(T, Status, Text) ->
    send(T, [wasm_host_http:response(Status, <<>>, [{<<"content-type">>, <<"text/plain">>}],
                                     #{chunked => true, close => true}),
             wasm_host_http:chunk(Text), wasm_host_http:last_chunk()]),
    close(T).

%% The head, the bytes after it, and the bytes of the head (for a tunnel).
read_head(T, Buffer) ->
    case wasm_host_http:head(Buffer) of
        more ->
            case recv(T) of
                {ok, Data} -> read_head(T, <<Buffer/binary, Data/binary>>);
                {error, _} -> closed
            end;
        {ok, Head, Rest} ->
            {ok, Head, Rest, binary:part(Buffer, 0, byte_size(Buffer) - byte_size(Rest))};
        Other ->
            Other
    end.

read_body(_T, none, Rest) ->
    {ok, <<>>, Rest};
read_body(_T, {length, N}, Rest) when byte_size(Rest) >= N ->
    <<Body:N/binary, Next/binary>> = Rest,
    {ok, Body, Next};
read_body(T, {length, N}, Rest) ->
    case recv(T) of
        {ok, Data} -> read_body(T, {length, N}, <<Rest/binary, Data/binary>>);
        Error -> Error
    end;
read_body(T, chunked, Rest) ->
    read_chunks(T, Rest, []).

read_chunks(T, Buffer, Acc) ->
    case wasm_host_http:dechunk(Buffer, Acc) of
        {ok, Body, Next} when byte_size(Body) =< ?MAX_BODY -> {ok, Body, Next};
        {ok, _, _} -> {error, too_large};
        {more, Acc1, Rest} ->
            case iolist_size(Acc1) + byte_size(Rest) > ?MAX_BODY + 65536 of
                true -> {error, too_large};
                false ->
                    case recv(T) of
                        {ok, Data} -> read_chunks(T, <<Rest/binary, Data/binary>>, Acc1);
                        Error -> Error
                    end
            end;
        {error, _} = Error -> Error
    end.

recv(T) -> recv(T, ?IDLE_TIMEOUT).
recv({M, S}, Timeout) -> M:recv(S, 0, Timeout).
send({M, S}, Data) -> M:send(S, Data).
close({M, S}) -> M:close(S), ok.

text(R) when is_binary(R) -> R;
text(R) -> io_lib:format("~0p", [R]).

%% --- the tunnel ----------------------------------------------------------------

%% The tunnel of an upgrade: connect() of the host to the host and the port
%% of the connect of the program, never through the fetch path. With TLS,
%% the server checks the certificate of the host with the trust store of
%% the build. The host gets the head of the request.
tunnel(Host, Port, Tls, Head) ->
    case wasm_tcp:connect(Host, Port, [binary, {active, false}, {wasm_direct, true}], ?CONNECT_TIMEOUT) of
        {ok, Sock} ->
            case secure(Sock, Host, Tls) of
                {ok, Up} ->
                    case send(Up, Head) of
                        ok -> {tunnel, Up};
                        {error, R} -> close(Up), {error, R}
                    end;
                {error, R} ->
                    gen_tcp:close(Sock),
                    {error, R}
            end;
        {error, R} ->
            {error, R}
    end.

secure(Sock, _Host, false) ->
    {ok, {gen_tcp, Sock}};
secure(Sock, Host, true) ->
    Name = binary_to_list(Host),
    case {original_store(), inet:parse_address(Name)} of
        {[], _} -> {error, <<"no trust store (--cacerts)">>};
        {_, {ok, _}} -> {error, <<"TLS to an IP address">>};
        {Store, _} ->
            case ssl:connect(Sock, client_opts(Store, Name), ?HANDSHAKE_TIMEOUT) of
                {ok, Tls} -> {ok, {ssl, Tls}};
                {error, R} -> {error, R}
            end
    end.

%% The options of the TLS client of a tunnel: the certificate of the name,
%% from a CA of the store.
-spec client_opts([public_key:der_encoded()], string()) -> [ssl:tls_client_option()].
client_opts(Store, Name) ->
    [{verify, verify_peer}, {cacerts, Store}, {server_name_indication, Name},
     {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]},
     {alpn_advertised_protocols, [<<"http/1.1">>]}, {versions, ['tlsv1.3', 'tlsv1.2']}].

%% --- the host ------------------------------------------------------------------

%% One request to the host, and its response as Next functions. The id
%% stays registered until the end of the response, in this process.
call_host(#{conn := Conn, tls := Tls, method := Method, path := Path, headers := Headers, body := Body}) ->
    Id = iolist_to_binary(["f", integer_to_binary(erlang:unique_integer([positive]))]),
    wasm_host_server:register(Id),
    wasm_host_server:send_host(#{t => fetch, id => Id, conn => Conn, tls => Tls, method => Method,
                                 path => Path, headers => [[K, V] || {K, V} <- Headers]}, Body),
    receive
        {wasm_host, <<"fetch_head">>, #{<<"id">> := Id} = M, _} ->
            {ok, maps:get(<<"status">>, M), maps:get(<<"reason">>, M, <<>>),
             [{K, V} || [K, V] <- maps:get(<<"headers">>, M, [])], fun() -> next(Id) end};
        {wasm_host, <<"fetch_error">>, #{<<"id">> := Id} = M, _} ->
            done(Id),
            {error, maps:get(<<"message">>, M, <<"error">>)}
    after ?HEAD_TIMEOUT ->
        cancel(Id),
        {error, <<"the host did not answer">>}
    end.

next(Id) ->
    receive
        {wasm_host, <<"fetch_data">>, #{<<"id">> := Id}, Data} -> {data, Data, fun() -> next(Id) end};
        {wasm_host, <<"fetch_end">>, #{<<"id">> := Id}, _} -> done(Id), done;
        {wasm_host, <<"fetch_error">>, #{<<"id">> := Id} = M, _} ->
            done(Id),
            {error, maps:get(<<"message">>, M, <<"error">>)}
    after ?IDLE_TIMEOUT ->
        cancel(Id),
        {error, <<"the host sent no data">>}
    end.

done(Id) -> wasm_host_server:unregister(Id).

%% The host stops the fetch() of the request (an AbortController).
cancel(Id) ->
    done(Id),
    wasm_host_server:send_host(#{t => fetch_cancel, id => Id}).
