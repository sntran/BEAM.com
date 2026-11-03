%% A name server for the test of --allow-net=HOST,... in tests/run.sh
%% (BEAM_COM_DNS_UPSTREAM). It answers queries over UDP on 127.0.0.1, and
%% it has a TCP port on 127.0.0.1 that takes connections. It prints
%% "dns_fake: DNSPORT TCPPORT", then "dns_fake: asked NAME" for each
%% query. It stops after 120 s with no query.
%%
%% The names (A records):
%%
%%   big.test.example     40 records of 127.0.0.1 (more than 512 bytes)
%%   alias.test.example   CNAME target.elsewhere.example, A 127.0.0.1
%%   test.example and NAME.test.example
%%                        127.0.0.1
%%   another name         nxdomain
-module(dns_fake).
-export([main/1]).

main(_) ->
    {ok, U} = gen_udp:open(0, [binary, {ip, {127, 0, 0, 1}}, {active, false}]),
    {ok, L} = gen_tcp:listen(0, [binary, {ip, {127, 0, 0, 1}}, {active, false}]),
    {ok, D} = inet:port(U),
    {ok, T} = inet:port(L),
    spawn_link(fun() -> accept(L) end),
    io:format("dns_fake: ~b ~b~n", [D, T]),
    serve(U).

accept(L) ->
    {ok, S} = gen_tcp:accept(L),
    gen_tcp:close(S),
    accept(L).

serve(U) ->
    case gen_udp:recv(U, 0, 120000) of
        {ok, {IP, Port, Query}} ->
            case answer(Query) of
                none -> ok;
                Answer -> gen_udp:send(U, IP, Port, Answer)
            end,
            serve(U);
        {error, timeout} ->
            halt(0)
    end.

answer(<<Id:16, _:16, 1:16, _:6/binary, Rest/binary>>) ->
    {Labels, <<Type:16, 1:16, _/binary>>} = labels(Rest, []),
    Name = string:lowercase(lists:flatten(lists:join(".", Labels))),
    io:format("dns_fake: asked ~s~n", [Name]),
    Question = binary:part(Rest, 0, byte_size(Rest) - byte_size(skip(Rest)) + 4),
    {Rcode, Records} = records(Name, Type),
    <<Id:16, (16#8180 bor Rcode):16, 1:16, (length(Records)):16, 0:16, 0:16,
      Question/binary, (iolist_to_binary(Records))/binary>>;
answer(_) ->
    none.

labels(<<0, Rest/binary>>, Acc) ->
    {lists:reverse(Acc), Rest};
labels(<<N, Label:N/binary, Rest/binary>>, Acc) ->
    labels(Rest, [binary_to_list(Label) | Acc]).

skip(Bin) ->
    {_, Rest} = labels(Bin, []),
    Rest.

records("big.test.example", 1) ->
    {0, [rr(<<16#c0, 12>>, 1, <<127, 0, 0, 1>>) || _ <- lists:seq(1, 40)]};
records("alias.test.example", 1) ->
    Target = name("target.elsewhere.example"),
    {0, [rr(<<16#c0, 12>>, 5, Target), rr(Target, 1, <<127, 0, 0, 1>>)]};
records(Name, Type) ->
    case Name =:= "test.example" orelse lists:suffix(".test.example", Name) of
        true when Type =:= 1 -> {0, [rr(<<16#c0, 12>>, 1, <<127, 0, 0, 1>>)]};
        true -> {0, []};
        false -> {3, []}
    end.

rr(Owner, Type, Data) ->
    <<Owner/binary, Type:16, 1:16, 60:32, (byte_size(Data)):16, Data/binary>>.

name(Text) ->
    Labels = << <<(length(L)), (list_to_binary(L))/binary>> || L <- string:split(Text, ".", all) >>,
    <<Labels/binary, 0>>.
