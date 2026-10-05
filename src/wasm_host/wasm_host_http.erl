%% HTTP/1.1 for the fetch path (wasm_host_fetch): the head of a request of
%% the program, the framing of its body, and the response that the server
%% writes back with chunked transfer coding. These functions only parse
%% and build binaries.
-module(wasm_host_http).

-export([head/1, framing/1, dechunk/2, request_headers/1, response/4,
         chunk/1, last_chunk/0, keep_alive/2, body_allowed/2, continue/1]).

-define(MAX_HEAD, 65536).

-type headers() :: [{binary(), binary()}].

%% The head of a request in Buffer: {ok, Head, Rest} when it is complete,
%% more when it needs more bytes, or {error, Reason}. The names of the
%% headers are in lower case, in their order.
-spec head(binary()) ->
    {ok, #{method := binary(), path := binary(), version := {non_neg_integer(), non_neg_integer()},
           headers := headers()}, binary()} | more | {error, atom()}.
head(Buffer) ->
    case parse_head(Buffer) of
        Result when byte_size(Buffer) < ?MAX_HEAD -> Result;
        {ok, _, _} = Result -> Result;
        {error, bad_target} = Result -> Result;
        _ -> {error, too_large}
    end.

parse_head(Buffer) ->
    case erlang:decode_packet(http_bin, Buffer, [{packet_size, ?MAX_HEAD}]) of
        {ok, {http_request, Method, Target, Version}, Rest} ->
            case path(Target) of
                {ok, Path} -> fields(Rest, #{method => method(Method), path => Path, version => Version}, []);
                error -> {error, bad_target}
            end;
        {more, _} -> more;
        _ -> {error, bad_request}
    end.

fields(Buffer, Head, Acc) ->
    case erlang:decode_packet(httph_bin, Buffer, [{packet_size, ?MAX_HEAD}]) of
        {ok, {http_header, _, Name, _, Value}, Rest} ->
            fields(Rest, Head, [{name(Name), Value} | Acc]);
        {ok, http_eoh, Rest} -> {ok, Head#{headers => lists:reverse(Acc)}, Rest};
        {ok, _, _} -> {error, bad_request};
        {more, _} -> more;
        {error, _} -> {error, bad_request}
    end.

method(M) when is_atom(M) -> atom_to_binary(M);
method(M) -> M.

%% Only a path: the host gives the scheme and the host of the URL.
path({abs_path, P}) -> {ok, P};
path({absoluteURI, _, _, _, P}) -> {ok, P};
path(_) -> error.

name(N) when is_atom(N) -> string:lowercase(atom_to_binary(N));
name(N) -> string:lowercase(N).

%% The framing of the body: {length, N}, chunked, none, or {error, Reason}.
%% A request with both transfer-encoding and content-length, or with two
%% different lengths, is refused (the two framings can disagree).
-spec framing(headers()) -> {length, non_neg_integer()} | chunked | none | {error, atom()}.
framing(Headers) ->
    TE = [V || {<<"transfer-encoding">>, V} <- Headers],
    CL = lists:usort([string:trim(V) || {<<"content-length">>, V} <- Headers]),
    case {TE, CL} of
        {[], []} -> none;
        {[], [L]} ->
            case number(L, 10) of
                {ok, N} -> {length, N};
                error -> {error, bad_length}
            end;
        {[], _} -> {error, bad_length};
        {_, []} ->
            case [string:lowercase(string:trim(C)) || V <- TE, C <- binary:split(V, <<",">>, [global])] of
                [<<"chunked">>] -> chunked;
                _ -> {error, bad_encoding}
            end;
        _ -> {error, bad_length}
    end.

%% A chunked body, from the start: Acc is the data of the chunks that are
%% complete. {ok, Body, Rest} at the end of the trailers, {more, Acc, Buffer}
%% (Buffer: the bytes that are not a complete chunk yet), or {error, Reason}.
-spec dechunk(binary(), iodata()) -> {ok, binary(), binary()} | {more, iodata(), binary()} | {error, atom()}.
dechunk(Buffer, Acc) ->
    case binary:match(Buffer, <<"\r\n">>) of
        nomatch when byte_size(Buffer) > 1024 -> {error, bad_chunk};
        nomatch -> {more, Acc, Buffer};
        {Pos, 2} ->
            <<Line:Pos/binary, "\r\n", Rest/binary>> = Buffer,
            [Size | _] = binary:split(Line, <<";">>),
            case number(string:trim(Size), 16) of
                {ok, 0} -> trailers(Rest, Acc, Buffer);
                {ok, N} ->
                    case Rest of
                        <<Data:N/binary, "\r\n", Next/binary>> -> dechunk(Next, [Acc, Data]);
                        <<_:N/binary, _, _, _/binary>> -> {error, bad_chunk};
                        _ -> {more, Acc, Buffer}
                    end;
                _ -> {error, bad_chunk}
            end
    end.

%% A number of digits only (no sign, no space): {ok, N} or error.
number(B, Base) when byte_size(B) > 0, byte_size(B) =< 16 ->
    Digits = case Base of
                 10 -> "0123456789";
                 16 -> "0123456789abcdefABCDEF"
             end,
    case lists:all(fun(C) -> lists:member(C, Digits) end, binary_to_list(B)) of
        true -> {ok, binary_to_integer(B, Base)};
        false -> error
    end;
number(_, _) ->
    error.

%% The trailers after the last chunk: header lines up to an empty line. The
%% server drops them.
trailers(Rest, Acc, Buffer) ->
    case binary:match(Rest, <<"\r\n">>) of
        nomatch when byte_size(Rest) > ?MAX_HEAD -> {error, bad_chunk};
        nomatch -> {more, Acc, Buffer};
        {0, 2} -> {ok, iolist_to_binary(Acc), binary:part(Rest, 2, byte_size(Rest) - 2)};
        {Pos, 2} -> trailers(binary:part(Rest, Pos + 2, byte_size(Rest) - Pos - 2), Acc, Buffer)
    end.

%% The headers of a request that go to fetch(): not the headers of this
%% connection (hop-by-hop, and the ones that "connection" names), not the
%% framing, and not host and accept-encoding (fetch() sets them).
-spec request_headers(headers()) -> headers().
request_headers(Headers) ->
    Named = [string:lowercase(string:trim(N)) || {<<"connection">>, V} <- Headers,
                                                N <- binary:split(V, <<",">>, [global])],
    Drop = Named ++ [<<"host">>, <<"content-length">>, <<"transfer-encoding">>, <<"expect">>,
                     <<"accept-encoding">> | hop_by_hop()],
    [{K, V} || {K, V} <- Headers, not lists:member(K, Drop)].

hop_by_hop() ->
    [<<"connection">>, <<"keep-alive">>, <<"proxy-connection">>, <<"te">>, <<"trailer">>,
     <<"upgrade">>, <<"proxy-authenticate">>, <<"proxy-authorization">>].

%% The head of a response. fetch() gives the body decoded, but can keep
%% content-encoding and the length of the encoded body: the response drops
%% them and the framing of the host, and has chunked transfer coding (with
%% a body) and connection.
-spec response(100..999, binary(), headers(), #{chunked := boolean(), close := boolean()}) -> iodata().
response(Status, Reason, Headers, #{chunked := Chunked, close := Close}) ->
    Drop = [<<"content-encoding">>, <<"content-length">>, <<"transfer-encoding">> | hop_by_hop()],
    Kept = [[K, <<": ">>, V, <<"\r\n">>] || {K0, V} <- Headers, K <- [string:lowercase(K0)],
                                           not lists:member(K, Drop), safe(K), safe(V)],
    [<<"HTTP/1.1 ">>, integer_to_binary(Status), $\s, reason(Status, Reason), <<"\r\n">>,
     Kept,
     [<<"transfer-encoding: chunked\r\n">> || Chunked],
     case Close of true -> <<"connection: close\r\n">>; false -> <<"connection: keep-alive\r\n">> end,
     <<"\r\n">>].

%% A value of the host must not end the line or the head.
safe(B) -> binary:match(B, [<<"\r">>, <<"\n">>, <<0>>]) =:= nomatch.

reason(Status, <<>>) -> default_reason(Status);
reason(Status, R) ->
    case safe(R) of
        true -> R;
        false -> default_reason(Status)
    end.

default_reason(200) -> <<"OK">>;
default_reason(201) -> <<"Created">>;
default_reason(204) -> <<"No Content">>;
default_reason(301) -> <<"Moved Permanently">>;
default_reason(302) -> <<"Found">>;
default_reason(304) -> <<"Not Modified">>;
default_reason(400) -> <<"Bad Request">>;
default_reason(401) -> <<"Unauthorized">>;
default_reason(403) -> <<"Forbidden">>;
default_reason(404) -> <<"Not Found">>;
default_reason(413) -> <<"Content Too Large">>;
default_reason(431) -> <<"Request Header Fields Too Large">>;
default_reason(500) -> <<"Internal Server Error">>;
default_reason(501) -> <<"Not Implemented">>;
default_reason(502) -> <<"Bad Gateway">>;
default_reason(504) -> <<"Gateway Timeout">>;
default_reason(_) -> <<"Status">>.

-spec chunk(iodata()) -> iodata().
chunk(Data) ->
    case iolist_size(Data) of
        0 -> [];
        N -> [integer_to_binary(N, 16), <<"\r\n">>, Data, <<"\r\n">>]
    end.

last_chunk() -> <<"0\r\n\r\n">>.

%% The connection stays open after the response: HTTP/1.1 with no
%% "connection: close".
-spec keep_alive({non_neg_integer(), non_neg_integer()}, headers()) -> boolean().
keep_alive({1, 1}, Headers) ->
    not lists:any(fun({<<"connection">>, V}) ->
                          lists:member(<<"close">>, [string:lowercase(string:trim(T))
                                                     || T <- binary:split(V, <<",">>, [global])]);
                     (_) -> false
                  end, Headers);
keep_alive(_, _) -> false.

%% A response to HEAD, and a status 1xx, 204 or 304, has no body.
-spec body_allowed(binary(), 100..999) -> boolean().
body_allowed(<<"HEAD">>, _) -> false;
body_allowed(_, S) when S < 200; S =:= 204; S =:= 304 -> false;
body_allowed(_, _) -> true.

%% "expect: 100-continue": the client waits for "100 Continue" before the body.
-spec continue(headers()) -> boolean().
continue(Headers) ->
    lists:any(fun({<<"expect">>, V}) -> string:lowercase(string:trim(V)) =:= <<"100-continue">>;
                 (_) -> false
              end, Headers).
