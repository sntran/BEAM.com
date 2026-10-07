%% A one-file program for "beam.com INPUT -o app.com" that tests the limits
%% of the hosts of the npm package (tests/host/app_limits.sh). It is an HTTP
%% server on port 4000 (the port of the bridge of worker.js):
%%
%%   GET /halt    the VM stops with erlang:halt(3)
%%   GET /abort   the VM stops with erlang:halt(abort) (a trap in the runtime)
%%   GET /slow    no answer
%%   GET /spin    200 after a computation of about 100 million reductions,
%%                with no wait
%%   POST /upload       200 with the size of the body ("got N"): with
%%                      content-length or chunked, read in recv calls of any
%%                      size
%%   POST /upload-slow  the same, with a pause of 2 ms after each recv
%%   POST /upload-whole 200 with the size of the body: one recv of the
%%                      length of the body, as Bandit reads a body
%%   GET /download      200 with 64 MiB, in sends of 64 KB with no wait: a
%%                      client that reads slowly slows the sends (tcp_sent)
%%   GET PATH     200 with the start time of the VM, for example "vm 12345"
%%
%% A new VM has a new start time, so the text shows that the host started a
%% new VM after a stop.
-module(limits_check).
-export([main/1]).

main(_) ->
    {ok, L} = gen_tcp:listen(4000, [binary, {active, false}, {reuseaddr, true}]),
    accept(L).

accept(L) ->
    {ok, S} = gen_tcp:accept(L),
    Pid = spawn(fun() -> receive go -> serve(S) end end),
    ok = gen_tcp:controlling_process(S, Pid),
    Pid ! go,
    accept(L).

serve(S) ->
    {ok, Data} = gen_tcp:recv(S, 0),
    [_, Path | _] = binary:split(Data, <<" ">>, [global]),
    case Path of
        <<"/halt">> -> erlang:halt(3);
        <<"/abort">> -> erlang:halt(abort);
        <<"/slow">> -> receive after infinity -> ok end;
        <<"/spin">> -> reply(S, io_lib:format("spin ~p~n", [spin(100000000, 0)]));
        <<"/upload">> -> upload(S, Data, 0);
        <<"/upload-slow">> -> upload(S, Data, 2);
        <<"/upload-whole">> -> whole(S, Data);
        <<"/download">> -> download(S);
        _ -> reply(S, io_lib:format("vm ~p~n", [erlang:system_info(start_time)]))
    end.

spin(0, A) -> A;
spin(N, A) -> spin(N - 1, (A + N) rem 1000003).

%% The body of the request whose first bytes are Data, with a pause of Ms
%% milliseconds after each recv.
upload(S, Data, Ms) ->
    {Head, Rest} = head(S, Data),
    Size = case re:run(Head, "content-length: *([0-9]+)", [caseless, {capture, all_but_first, binary}]) of
        {match, [N]} -> sized(S, binary_to_integer(N) - byte_size(Rest), byte_size(Rest), Ms);
        nomatch -> chunked(S, Rest, 0, Ms)
    end,
    reply(S, io_lib:format("got ~p~n", [Size])).

head(S, Data) ->
    case binary:split(Data, <<"\r\n\r\n">>) of
        [Head, Rest] -> {Head, Rest};
        [_] -> head(S, more(S, Data, 0))
    end.

sized(_S, Left, Got, _Ms) when Left =< 0 -> Got;
sized(S, Left, Got, Ms) ->
    N = byte_size(more(S, <<>>, Ms)),
    sized(S, Left - N, Got + N, Ms).

chunked(S, Buf, Got, Ms) ->
    case binary:split(Buf, <<"\r\n">>) of
        [Line, Rest] ->
            case binary_to_integer(Line, 16) of
                0 -> Got;
                N -> skip(S, N + 2, Rest, Got + N, Ms)
            end;
        [_] -> chunked(S, more(S, Buf, Ms), Got, Ms)
    end.

%% Left bytes to skip (the data of a chunk and its CRLF), then the next
%% chunk. The app keeps no part of the data, so the memory of the VM shows
%% the buffers of the host and of wasm_tcp.
skip(S, Left, Buf, Got, Ms) when byte_size(Buf) >= Left ->
    <<_:Left/binary, Next/binary>> = Buf,
    chunked(S, Next, Got, Ms);
skip(S, Left, Buf, Got, Ms) ->
    skip(S, Left - byte_size(Buf), more(S, <<>>, Ms), Got, Ms).

%% The next bytes of the socket after Buf. With no Buf, the binary of recv
%% itself: a copy of each one makes garbage faster than the GC frees it.
more(S, Buf, Ms) ->
    {ok, B} = gen_tcp:recv(S, 0),
    timer:sleep(Ms),
    case Buf of
        <<>> -> B;
        _ -> <<Buf/binary, B/binary>>
    end.

%% The body in one recv of its length (content-length).
whole(S, Data) ->
    {Head, Rest} = head(S, Data),
    {match, [N]} = re:run(Head, "content-length: *([0-9]+)", [caseless, {capture, all_but_first, binary}]),
    Left = binary_to_integer(N) - byte_size(Rest),
    Size = case Left > 0 of
        true -> {ok, B} = gen_tcp:recv(S, Left), byte_size(Rest) + byte_size(B);
        false -> byte_size(Rest)
    end,
    reply(S, io_lib:format("got ~p~n", [Size])).

-define(DOWNLOAD_PARTS, 1024).

download(S) ->
    Part = binary:copy(<<"0123456789abcdef">>, 4096),
    ok = gen_tcp:send(S, ["HTTP/1.1 200 OK\r\ncontent-length: ",
                          integer_to_list(?DOWNLOAD_PARTS * byte_size(Part)),
                          "\r\nconnection: close\r\n\r\n"]),
    [ok = gen_tcp:send(S, Part) || _ <- lists:seq(1, ?DOWNLOAD_PARTS)],
    gen_tcp:close(S).

reply(S, Body) ->
    gen_tcp:send(S, ["HTTP/1.1 200 OK\r\ncontent-length: ", integer_to_list(iolist_size(Body)),
                     "\r\nconnection: close\r\n\r\n", Body]),
    gen_tcp:close(S).
