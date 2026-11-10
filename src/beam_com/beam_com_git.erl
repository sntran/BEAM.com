%% A git client over HTTPS and SSH, with no git program: version 2 of the
%% git protocol (ls-refs and fetch of git-upload-pack), over smart HTTP
%% or as an SSH command (beam_com_git_ssh, which also speaks version 0). It gets one
%% commit and the files of its tree, as "git fetch --depth 1" and "git
%% checkout" do, for a git dep of Mix (beam_com_git_scm).
%%
%% The name of a git object is the SHA-1 of its type, its size and its
%% data. The client computes the name of each object of the pack, and it
%% writes only the objects that the wanted commit names: the commit, its
%% tree, the trees in it, and their files. Thus each byte that it writes
%% is the byte of the commit of mix.lock.
-module(beam_com_git).

-export([resolve/3, fetch/3, checkout/4, redact/1]).
%% For beam_com_git_ssh.
-export([pkt/1, refs/1, pack_response/1]).

-ifdef(TEST).
-export([pkts/1, advertisement/1, objects/1, objects/2, apply_delta/2, apply_delta/3, http_opts/0,
         tree/1, commit_tree/1, inflate/2, safe_name/1, url/1, same_key/1,
         dot_git/1]).
-endif.

%% The limits of a response: the list of refs, and the pack.
-define(MAX_REFS, 16 * 1024 * 1024).
-define(MAX_PACK, 512 * 1024 * 1024).
%% The limits of the objects of a pack: one object (also a delta and its
%% result), and the sum of all the objects and the results of the deltas.
-define(MAX_OBJECT, 256 * 1024 * 1024).
-define(MAX_TOTAL, 1024 * 1024 * 1024).
-define(SHA_RE, "^[0-9a-f]{40}$").
%% The time limits of a request over HTTPS: the complete request (a pack
%% of MAX_PACK at 150 KB/s), and the time with no data.
-define(HTTP_TIMEOUT, 3600 * 1000).
-define(HTTP_IDLE, 120 * 1000).
%% The client follows at most 5 redirects of info/refs, as curl and git.
-define(MAX_REDIRECTS, 5).
-define(INFO_REFS, "/info/refs?service=git-upload-pack").

%% The commit of Rev at the repository Url: Rev is a commit (40 hex
%% digits), {branch, B}, {tag, T}, {ref, R}, or head. Opts: http, the
%% function of the requests (beam_com_hex:http/6 with the options of
%% http/1; another one for the tests), and ssh, the settings of
%% beam_com_git_ssh for the tests.
resolve(Url, {ref, Ref}, Opts) when length(Ref) =:= 40 ->
    case is_sha(Ref) of
        true -> list_to_binary(Ref);
        false -> resolve_refs(Url, [Ref], Opts)
    end;
resolve(Url, {ref, Ref}, Opts) ->
    resolve_refs(Url, [Ref, "refs/heads/" ++ Ref, "refs/tags/" ++ Ref], Opts);
resolve(Url, {branch, Branch}, Opts) ->
    resolve_refs(Url, ["refs/heads/" ++ Branch], Opts);
resolve(Url, {tag, Tag}, Opts) ->
    resolve_refs(Url, ["refs/tags/" ++ Tag], Opts);
resolve(Url, head, Opts) ->
    resolve_refs(Url, ["HEAD"], Opts).

resolve_refs(Url, Names, Opts) ->
    Body = [pkt("command=ls-refs\n"), pkt("object-format=sha1\n"), <<"0001">>,
            pkt("peel\n"), pkt("symrefs\n")]
        ++ [pkt(["ref-prefix ", N, "\n"]) || N <- Names] ++ [<<"0000">>],
    Refs = case beam_com_git_ssh:is_ssh(Url) of
               true ->
                   beam_com_git_ssh:ls_refs(Url, Body, ?MAX_REFS, Opts);
               false ->
                   Base = capabilities(Url, Opts),
                   refs(pkts(upload_pack(Url, Base, Body, ?MAX_REFS, Opts)))
           end,
    case [Sha || N <- Names, {Name, Sha} <- Refs, Name =:= list_to_binary(N)] of
        [Sha | _] -> Sha;
        [] -> throw({error, "~ts: no ~ts", [redact(Url), hd(Names)]})
    end.

%% The objects of the commit Sha (40 hex digits) at Url: #{Name => {Type,
%% Data}}, with only the commit and the objects of its tree.
fetch(Url, Sha, Opts) ->
    is_sha(binary_to_list(Sha)) orelse throw({error, "~ts: not a commit: ~ts", [redact(Url), Sha]}),
    Body = [pkt("command=fetch\n"), pkt("object-format=sha1\n"), <<"0001">>,
            pkt("no-progress\n"), pkt("ofs-delta\n"), pkt("deepen 1\n"),
            pkt(["want ", Sha, "\n"]), pkt("done\n"), <<"0000">>],
    Pack = case beam_com_git_ssh:is_ssh(Url) of
               true ->
                   beam_com_git_ssh:pack(Url, Sha, Body, Opts);
               false ->
                   Base = capabilities(Url, Opts),
                   pack_response(pkts(upload_pack(Url, Base, Body, ?MAX_PACK, Opts)))
           end,
    Objects = objects(Pack),
    reachable(Sha, Objects).

%% Write the files of the tree of the commit Sha in Dir, or of the
%% directory Sparse of the tree (at the same path, as a sparse checkout
%% of git). Then Dir/.git/HEAD has Sha, and Dir/.git/config the URL, as
%% git writes them.
checkout(Objects, Sha, Dir, Opts) ->
    Tree = commit_tree(object(Sha, commit, Objects)),
    Root = case maps:get(sparse, Opts, none) of
               none -> {[], Tree};
               Sparse -> subtree(Tree, Sparse, Objects)
           end,
    {Path, Sub} = Root,
    Top = filename:join([Dir | Path]),
    file_ok(Top, filelib:ensure_path(Top)),
    write_tree(Sub, Top, Objects, maps:get(submodules, Opts, false)),
    Git = filename:join(Dir, ".git"),
    make_dir(Git),
    make_dir(filename:join(Git, "objects")),
    make_dir(filename:join(Git, "refs")),
    write_new(filename:join(Git, "HEAD"), [Sha, "\n"]),
    write_new(filename:join(Git, "config"), ["[remote \"origin\"]\n\turl = ", maps:get(url, Opts), "\n"]),
    ok.

%%% The protocol.

%% A pkt-line: four hex digits of the length (with the four), then the
%% data.
pkt(Data) ->
    Bin = iolist_to_binary(Data),
    <<(list_to_binary(io_lib:format("~4.16.0b", [byte_size(Bin) + 4])))/binary, Bin/binary>>.

%% The pkt-lines of Bin: each data, flush (0000), delim (0001) or
%% response_end (0002).
pkts(<<>>) ->
    [];
pkts(<<"0000", Rest/binary>>) ->
    [flush | pkts(Rest)];
pkts(<<"0001", Rest/binary>>) ->
    [delim | pkts(Rest)];
pkts(<<"0002", Rest/binary>>) ->
    [response_end | pkts(Rest)];
pkts(<<Hex:4/binary, Rest/binary>>) ->
    Len = try binary_to_integer(Hex, 16)
          catch error:badarg -> throw({error, "git: a bad pkt-line: ~p", [Hex]})
          end,
    (Len >= 4 andalso byte_size(Rest) >= Len - 4)
        orelse throw({error, "git: a short pkt-line", []}),
    <<Data:(Len - 4)/binary, Next/binary>> = Rest,
    [Data | pkts(Next)];
pkts(_) ->
    throw({error, "git: a short pkt-line", []}).

%% The capabilities of the server: the server must speak version 2. The
%% result is the URL of the repository after the redirects of info/refs:
%% the requests after it go there, as with git.
capabilities(Url, Opts) ->
    capabilities(Url, url(Url), Opts, 0).

capabilities(Url, Base, Opts, N) ->
    Http = http(Opts),
    case Http(get, Base ++ ?INFO_REFS, headers(Url, Base), none, ?MAX_REFS) of
        {redirect, Location} when N < ?MAX_REDIRECTS ->
            capabilities(Url, redirect(Url, Base, Location), Opts, N + 1);
        {redirect, _} ->
            throw({error, "~ts: more than ~b redirects", [redact(Url), ?MAX_REDIRECTS]});
        Body ->
            advertisement(pkts(Body)) orelse
                throw({error, "~ts: the server does not speak version 2 of the git protocol; "
                       "install git", [redact(Url)]}),
            Base
    end.

%% The new URL of the repository: the location of a redirect of info/refs
%% with no INFO_REFS at its end. It must be https.
redirect(Url, Base, Location0) ->
    Location = uri_string:resolve(unicode:characters_to_list(Location0), Base ++ ?INFO_REFS),
    case {uri_string:parse(Location), string:find(Location, ?INFO_REFS, trailing)} of
        {#{scheme := "https", host := Host}, ?INFO_REFS} when Host =/= "" ->
            url(string:slice(Location, 0, length(Location) - length(?INFO_REFS)));
        _ ->
            throw({error, "~ts: a redirect to ~ts, which is not the info/refs of an https URL",
                   [redact(Url), redact(Location)]})
    end.

%% True when the advertisement has "version 2". A server of HTTP can put
%% "# service=git-upload-pack" and a flush first.
advertisement(Lines) ->
    lists:member(<<"version 2">>, [string:trim(L, trailing, "\n") || L <- Lines, is_binary(L)]).

upload_pack(Url, Base, Body, Max, Opts) ->
    Http = http(Opts),
    case Http(post, Base ++ "/git-upload-pack",
              [{"accept", "application/x-git-upload-pack-result"} | headers(Url, Base)],
              {"application/x-git-upload-pack-request", iolist_to_binary(Body)}, Max) of
        {redirect, _} ->
            throw({error, "~ts: a redirect of git-upload-pack; the server must redirect "
                   "info/refs", [redact(Url)]});
        Answer ->
            Answer
    end.

http(Opts) ->
    maps:get(http, Opts, fun(Method, Url, Headers, Body, Max) ->
                                 beam_com_hex:http(Method, Url, Headers, Body, Max, http_opts())
                         end).

%% The options of beam_com_hex:http/6 for git: a pack can need more time
%% than a request of Hex, and the client follows a redirect itself.
http_opts() ->
    #{timeout => ?HTTP_TIMEOUT, idle => ?HTTP_IDLE, redirect => false}.

%% The headers of a request to Base. The user and the password of Url go
%% only to the host of Url, also after a redirect.
headers(Url, Base) ->
    U = uri_string:parse(unicode:characters_to_list(Url)),
    B = uri_string:parse(Base),
    Same = maps:with([host, port], maps:remove(userinfo, U)) =:= maps:with([host, port], B),
    [{"git-protocol", "version=2"}]
        ++ case U of
               #{userinfo := User} when Same ->
                   [{"authorization",
                     "Basic " ++ base64:encode_to_string(uri_string:percent_decode(User))}];
               _ -> []
           end.

%% The URL of the repository with no user, no trailing "/", and the
%% scheme https only.
url(Url) ->
    case uri_string:parse(unicode:characters_to_list(Url)) of
        #{scheme := "https", host := Host} = U when Host =/= "" ->
            string:trim(uri_string:recompose(maps:remove(userinfo, U)), trailing, "/");
        _ ->
            throw({error, "~ts: only an https or SSH URL works with no git program", [redact(Url)]})
    end.

%% The URL for a message: with no password. The user of an https URL
%% can be a token, so it goes too. The user of an SSH URL stays.
redact(Url) ->
    case uri_string:parse(unicode:characters_to_list(Url)) of
        #{scheme := Scheme, userinfo := Info} = U
          when Scheme =:= "ssh"; Scheme =:= "git+ssh"; Scheme =:= "ssh+git" ->
            case string:split(Info, ":") of
                [_] -> Url;
                [User, _] -> uri_string:recompose(U#{userinfo := User ++ ":****"})
            end;
        #{userinfo := _} = U -> uri_string:recompose(U#{userinfo := "****:****"});
        _ -> Url
    end.

%% The refs of an answer of ls-refs: [{Name, Sha}], with the peeled
%% commit of an annotated tag.
refs(Lines) ->
    lists:append(
      [case binary:split(string:trim(L, trailing, "\n"), <<" ">>, [global]) of
           [<<"ERR">> | Message] ->
               throw({error, "git: ~ts", [iolist_to_binary(lists:join(<<" ">>, Message))]});
           [Sha, Name | Attrs] ->
               Peeled = [P || <<"peeled:", P/binary>> <- Attrs],
               [{Name, hd(Peeled ++ [Sha])}];
           _ -> []
       end || L <- Lines, is_binary(L)]).

%% The pack of an answer of fetch: the data of the side band 1 after the
%% section "packfile". Band 2 is progress, and band 3 an error.
pack_response(Lines) ->
    case lists:dropwhile(fun(L) -> L =/= <<"packfile\n">> end, Lines) of
        [_ | Bands] ->
            iolist_to_binary(
              [case B of
                   <<1, Data/binary>> -> Data;
                   <<2, _/binary>> -> [];
                   <<3, Message/binary>> -> throw({error, "git: ~ts", [Message]})
               end || B <- Bands, is_binary(B)]);
        [] ->
            case [M || <<"ERR ", M/binary>> <- Lines] of
                [M | _] -> throw({error, "git: ~ts", [M]});
                [] -> throw({error, "git: the answer has no pack", []})
            end
    end.

%%% The pack.

%% The objects of a pack: #{Name => {Type, Data}}. The pack ends with
%% the SHA-1 of the bytes before it. Limits: object, the largest size of
%% one object (also of a delta and its result), and total, the largest
%% sum of the sizes of all the objects and the results of the deltas.
objects(Pack) ->
    objects(Pack, #{object => ?MAX_OBJECT, total => ?MAX_TOTAL}).

objects(<<"PACK", Version:32, Count:32, _/binary>> = Pack, Limits)
  when Version =:= 2; Version =:= 3 ->
    Size = byte_size(Pack) - 20,
    Size >= 12 orelse throw({error, "git: a short pack", []}),
    <<Body:Size/binary, Sum:20/binary>> = Pack,
    crypto:hash(sha, Body) =:= Sum orelse throw({error, "git: the pack has a bad checksum", []}),
    {Entries, Left} = read_objects(Body, 12, Count, [], Limits, maps:get(total, Limits)),
    resolve_deltas(Entries, Limits, Left);
objects(_, _Limits) ->
    throw({error, "git: not a pack", []}).

read_objects(_Pack, _Pos, 0, Acc, _Limits, Left) ->
    {lists:reverse(Acc), Left};
read_objects(Pack, Pos, N, Acc, Limits, Left) ->
    {Type, Size, P1} = header(Pack, Pos),
    Left1 = take(Size, Limits, Left),
    {Base, P2} = case Type of
                     6 -> {Ofs, P} = offset(Pack, P1), {{ofs, Pos - Ofs}, P};
                     7 -> {{ref, binary:encode_hex(bytes(Pack, P1, 20), lowercase)}, P1 + 20};
                     _ -> {none, P1}
                 end,
    {Data, Used} = inflate(binary_part(Pack, P2, byte_size(Pack) - P2), Size),
    read_objects(Pack, P2 + Used, N - 1, [{Pos, Type, Base, Data} | Acc], Limits, Left1).

%% The rest of the total after an object of Size bytes.
take(Size, #{object := Max}, _Left) when Size > Max ->
    throw({error, "git: an object of ~b bytes is larger than the limit of ~b bytes", [Size, Max]});
take(Size, #{total := Total}, Left) when Size > Left ->
    throw({error, "git: the objects of the pack are larger than the limit of ~b bytes", [Total]});
take(Size, _Limits, Left) ->
    Left - Size.

%% N bytes of the pack at Pos.
bytes(Pack, Pos, N) when Pos + N =< byte_size(Pack) ->
    binary_part(Pack, Pos, N);
bytes(_Pack, _Pos, _N) ->
    throw({error, "git: a short pack", []}).

byte(Pack, Pos) ->
    <<C>> = bytes(Pack, Pos, 1),
    C.

header(Pack, Pos) ->
    C = byte(Pack, Pos),
    size_bytes(Pack, Pos + 1, C band 16#80, C band 15, 4, (C bsr 4) band 7).

size_bytes(_Pack, Pos, 0, Size, _Shift, Type) ->
    {Type, Size, Pos};
size_bytes(Pack, Pos, _More, Size, Shift, Type) ->
    C = byte(Pack, Pos),
    size_bytes(Pack, Pos + 1, C band 16#80, Size bor ((C band 16#7f) bsl Shift), Shift + 7, Type).

offset(Pack, Pos) ->
    C = byte(Pack, Pos),
    offset(Pack, Pos + 1, C band 16#80, C band 16#7f).

offset(_Pack, Pos, 0, Ofs) ->
    {Ofs, Pos};
offset(Pack, Pos, _More, Ofs) ->
    C = byte(Pack, Pos),
    offset(Pack, Pos + 1, C band 16#80, ((Ofs + 1) bsl 7) bor (C band 16#7f)).

%% The data of the zlib stream at the start of Bin (Size bytes), and the
%% number of bytes of the stream. The inflate stops when the data is
%% larger than Size.
%%
%% zlib gives no count of the bytes that it used, but it keeps the bytes
%% after the end of the stream, and the next inflate with them fails.
%% Thus a pass that gives the input in steps finds the step with the
%% end. The next pass gives the bytes before that step, then smaller
%% steps in it, and the last pass gives one byte in each step. Each pass
%% reads the stream one time, so the time is linear.
inflate(Bin, Size) ->
    Z = zlib:open(),
    try
        {Data, Step} = zpass(Z, Bin, 0, 4096, Size, keep),
        Step =/= open orelse throw({error, "git: a short pack", []}),
        byte_size(Data) =:= Size orelse throw({error, "git: an object has a bad size", []}),
        {Data, zfast(Z, Bin, Step, Data, Size)}
    after
        zlib:close(Z)
    end.

%% The stream ends with the Adler-32 of its data. The first copy of these
%% four bytes in the step of the end is usually the end: one pass checks
%% it. Else the smaller steps find the end.
zfast(_Z, Bin, done, _Data, _Size) ->
    byte_size(Bin);
zfast(Z, Bin, From, Data, Size) ->
    Start = max(0, From - 4),
    Scope = {Start, min(From + 4096, byte_size(Bin)) - Start},
    case binary:match(Bin, <<(erlang:adler32(Data)):32>>, [{scope, Scope}]) of
        {P, 4} ->
            case zpass(Z, binary_part(Bin, 0, P + 4), P + 4, 1, Size, count) of
                {_, done} -> P + 4;
                _ -> zend(Z, Bin, From, [32, 1], Size)
            end;
        nomatch ->
            zend(Z, Bin, From, [32, 1], Size)
    end.

zend(_Z, Bin, done, _Steps, _Size) ->
    byte_size(Bin);
zend(Z, Bin, From, [Step | Steps], Size) ->
    {_, Next} = zpass(Z, Bin, From, Step, Size, count),
    is_integer(Next) orelse throw({error, "git: a bad zlib stream", []}),
    zend(Z, Bin, Next, Steps, Size);
zend(Z, Bin, End, [], Size) ->
    %% The stream ends at End, or the byte at End is bad.
    case zpass(Z, binary_part(Bin, 0, End), End, 1, Size, count) of
        {_, done} -> End;
        _ -> throw({error, "git: a bad zlib stream", []})
    end.

%% One pass: the bytes before From in one step, then steps of Step bytes.
%% {Data, Pos}: the inflate failed in the step at Pos (Data: the data
%% before the failure). {Data, done}: the stream ends at the end of Bin.
%% {Data, open}: the stream does not end in Bin.
zpass(Z, Bin, From, Step, Size, Keep) ->
    %% error: an inflate after the end of the stream fails.
    ok = zlib:inflateInit(Z, 15, error),
    St = case zdrain(Z, binary_part(Bin, 0, From), {0, [], Size, Keep}) of
             {ok, St0} -> St0;
             {error, _} -> throw({error, "git: a bad zlib stream", []})
         end,
    zsteps(Z, Bin, From, Step, St).

zsteps(Z, Bin, Pos, _Step, {_, Acc, _, _}) when Pos >= byte_size(Bin) ->
    {iolist_to_binary(lists:reverse(Acc)), case zfinish(Z) of ok -> done; error -> open end};
zsteps(Z, Bin, Pos, Step, St) ->
    N = min(Step, byte_size(Bin) - Pos),
    case zdrain(Z, binary_part(Bin, Pos, N), St) of
        {ok, St1} -> zsteps(Z, Bin, Pos + N, Step, St1);
        {error, {_, Acc, _, _}} -> _ = zfinish(Z), {iolist_to_binary(lists:reverse(Acc)), Pos}
    end.

%% The end of the inflate: ok when the stream ended with no input after
%% it, else error. Then the next pass can start.
zfinish(Z) ->
    try zlib:inflateEnd(Z)
    catch error:data_error -> error
    end.

%% Inflate the input, and all the data of it.
zdrain(Z, Input, St) ->
    try zlib:safeInflate(Z, Input) of
        {continue, Out} -> zdrain(Z, [], zadd(Out, St));
        {finished, Out} -> {ok, zadd(Out, St)};
        {need_dictionary, _, _} -> throw({error, "git: a zlib stream needs a dictionary", []})
    catch error:data_error ->
            {error, St}
    end.

zadd(Out, {Got, Acc, Size, Keep}) ->
    Got1 = Got + iolist_size(Out),
    Got1 =< Size orelse throw({error, "git: an object is larger than the size in its header", []}),
    {Got1, case Keep of keep -> [Out | Acc]; count -> Acc end, Size, Keep}.

%% The objects with their names, after the deltas, in one pass in the
%% order of the pack: the base of an offset delta comes before it. A
%% server sends the base of a ref delta first too (no thin pack).
resolve_deltas(Entries, Limits, Left0) ->
    {Named, _, _} =
        lists:foldl(
          fun({Pos, T, Base, Data}, {Named, Done, Left}) ->
                  {Type, Full} =
                      case {T, Base} of
                          {_, none} when T >= 1, T =< 4 -> {type(T), Data};
                          {6, {ofs, BasePos}} ->
                              delta(maps:find(BasePos, Done), Data, Limits, Left);
                          {7, {ref, Name}} -> delta(maps:find(Name, Named), Data, Limits, Left);
                          _ -> throw({error, "git: an object of an unknown type", []})
                      end,
                  Left1 = case Base of none -> Left; _ -> take(byte_size(Full), Limits, Left) end,
                  {Named#{name(Type, Full) => {Type, Full}}, Done#{Pos => {Type, Full}}, Left1}
          end, {#{}, #{}, Left0}, Entries),
    Named.

delta({ok, {Type, Base}}, Delta, Limits, Left) ->
    {Type, apply_delta(Base, Delta, min(maps:get(object, Limits), Left))};
delta(error, _Delta, _Limits, _Left) ->
    throw({error, "git: a delta has no base", []}).

type(1) -> commit;
type(2) -> tree;
type(3) -> blob;
type(4) -> tag.

name(Type, Data) ->
    binary:encode_hex(crypto:hash(sha, [atom_to_list(Type), " ",
                                        integer_to_list(byte_size(Data)), 0, Data]),
                      lowercase).

%% The new data of a delta: the size of the base, the size of the result,
%% then copies from the base and new bytes. The result has at most Max
%% bytes, and the copies stop at the size of the result.
apply_delta(Base, Delta) ->
    apply_delta(Base, Delta, ?MAX_OBJECT).

apply_delta(Base, Delta, Max) ->
    {BaseSize, D1} = varint(Delta),
    BaseSize =:= byte_size(Base) orelse throw({error, "git: a delta of another base", []}),
    {Size, D2} = varint(D1),
    Size =< Max orelse
        throw({error, "git: the result of a delta has ~b bytes, more than the limit of ~b bytes",
               [Size, Max]}),
    iolist_to_binary(delta_ops(Base, D2, Size, [])).

varint(Bin) -> varint(Bin, 0, 0).

varint(<<C, Rest/binary>>, Shift, Acc) when C band 16#80 =:= 0 ->
    {Acc bor (C bsl Shift), Rest};
varint(<<C, Rest/binary>>, Shift, Acc) ->
    varint(Rest, Shift + 7, Acc bor ((C band 16#7f) bsl Shift));
varint(<<>>, _, _) ->
    throw({error, "git: a short delta", []}).

%% Left: the bytes of the result that are not made yet.
delta_ops(_Base, <<>>, 0, Acc) ->
    lists:reverse(Acc);
delta_ops(_Base, <<>>, _Left, _Acc) ->
    throw({error, "git: a delta has a bad size", []});
delta_ops(Base, <<1:1, Bits:7, Rest/binary>>, Left, Acc) ->
    {Offset, R1} = delta_number(Bits band 16#0f, 4, Rest),
    {Size0, R2} = delta_number(Bits bsr 4, 3, R1),
    Size = case Size0 of 0 -> 16#10000; _ -> Size0 end,
    Offset + Size =< byte_size(Base) orelse throw({error, "git: a delta copies too much", []}),
    Size =< Left orelse throw({error, "git: a delta has a bad size", []}),
    delta_ops(Base, R2, Left - Size, [binary_part(Base, Offset, Size) | Acc]);
delta_ops(Base, <<0:1, N:7, Rest/binary>>, Left, Acc) when N > 0, byte_size(Rest) >= N ->
    N =< Left orelse throw({error, "git: a delta has a bad size", []}),
    <<New:N/binary, R1/binary>> = Rest,
    delta_ops(Base, R1, Left - N, [New | Acc]);
delta_ops(_Base, _, _Left, _Acc) ->
    throw({error, "git: a bad delta", []}).

%% The bytes of a copy: one byte for each bit of Mask (low bit first).
delta_number(Mask, Bytes, Bin) ->
    lists:foldl(fun(I, {N, B}) ->
                        case Mask band (1 bsl I) of
                            0 -> {N, B};
                            _ ->
                                case B of
                                    <<V, R/binary>> -> {N bor (V bsl (8 * I)), R};
                                    _ -> throw({error, "git: a short delta", []})
                                end
                        end
                end, {0, Bin}, lists:seq(0, Bytes - 1)).

%%% The commit and its tree.

%% The objects that the commit Sha names: the commit, its tree, and each
%% tree and file in it.
reachable(Sha, Objects) ->
    Commit = object(Sha, commit, Objects),
    Tree = commit_tree(Commit),
    tree_objects(Tree, Objects, #{Sha => {commit, Commit}}).

tree_objects(Name, Objects, Acc) ->
    Data = object(Name, tree, Objects),
    lists:foldl(fun({Mode, _Entry, Sha}, A) ->
                        case kind(Mode) of
                            tree -> tree_objects(Sha, Objects, A);
                            gitlink -> A;
                            _ -> A#{Sha => {blob, object(Sha, blob, Objects)}}
                        end
                end, Acc#{Name => {tree, Data}}, tree(Data)).

object(Name, Type, Objects) ->
    case Objects of
        #{Name := {Type, Data}} -> Data;
        #{Name := {Other, _}} -> throw({error, "git: ~ts is a ~p, not a ~p", [Name, Other, Type]});
        _ -> throw({error, "git: the pack has no ~p ~ts", [Type, Name]})
    end.

%% The tree of a commit: its first line "tree NAME".
commit_tree(<<"tree ", Name:40/binary, "\n", _/binary>>) ->
    Name;
commit_tree(_) ->
    throw({error, "git: a commit with no tree", []}).

%% The entries of a tree: [{Mode, Name, Sha}], with the mode as text
%% ("100644", "40000").
%% Two entries with one name, also for a file system that ignores the
%% case, make an error: the second entry could write through the first.
tree(Data) ->
    Entries = entries(Data),
    Keys = [same_key(N) || {_, N, _} <- Entries],
    case Keys -- lists:usort(Keys) of
        [] -> Entries;
        [Key | _] ->
            throw({error, "git: a tree with two entries of the same name: ~tp",
                   [hd([N || {_, N, _} <- Entries, same_key(N) =:= Key])]})
    end.

entries(<<>>) ->
    [];
entries(Data) ->
    case binary:split(Data, <<0>>) of
        [Head, <<Raw:20/binary, Rest/binary>>] ->
            case binary:split(Head, <<" ">>) of
                [Mode, Name] ->
                    [{Mode, safe_name(Name), binary:encode_hex(Raw, lowercase)} | entries(Rest)];
                _ -> throw({error, "git: a bad tree", []})
            end;
        _ ->
            throw({error, "git: a bad tree", []})
    end.

%% The name as a file system that ignores the case can see it: in lower
%% case (case folding), in the form NFC, and with no "." or " " at the
%% end (Windows removes them).
same_key(Name) ->
    string:trim(fold(Name), trailing, ". ").

%% The name in lower case. A name that is not UTF-8 gets only the ASCII
%% letters in lower case (string:casefold/1 fails for it).
fold(Name) ->
    case unicode:characters_to_nfc_binary(Name) of
        B when is_binary(B) -> unicode:characters_to_nfc_binary(string:casefold(B));
        _ -> << <<(case C of _ when C >= $A, C =< $Z -> C + 32; _ -> C end)>> || <<C>> <= Name >>
    end.

kind(<<"40000">>) -> tree;
kind(<<"040000">>) -> tree;
kind(<<"100644">>) -> file;
kind(<<"100664">>) -> file;
kind(<<"100755">>) -> exec;
kind(<<"120000">>) -> link;
kind(<<"160000">>) -> gitlink;
kind(Mode) -> throw({error, "git: a tree entry of the mode ~ts", [Mode]}).

%% A name of a tree entry that stays in its directory: not empty, no
%% "/", no NUL, not "." or "..", and not .git (git also refuses it).
safe_name(Name) ->
    Bad = Name =:= <<>> orelse Name =:= <<".">> orelse Name =:= <<"..">>
        orelse binary:match(Name, [<<"/">>, <<"\\">>, <<0>>]) =/= nomatch
        orelse dot_git(Name),
    Bad andalso throw({error, "git: a tree entry with a bad name: ~tp", [Name]}),
    Name.

%% True for a name that a file system can read as .git.
dot_git(Name) ->
    fold(Name) =:= <<".git">>.

%% The tree of the directory Sparse ("a/b") of the tree Root: {Path, Tree}.
subtree(Root, Sparse, Objects) ->
    Parts = [P || P <- string:split(Sparse, "/", all), P =/= "", P =/= "."],
    lists:foldl(fun(Part, {Path, Tree}) ->
                        Name = list_to_binary(Part),
                        case [S || {M, N, S} <- tree(object(Tree, tree, Objects)),
                                   N =:= Name, kind(M) =:= tree] of
                            [Sub] -> {Path ++ [Part], Sub};
                            [] -> throw({error, "git: the tree has no directory ~ts", [Sparse]})
                        end
                end, {[], Root}, Parts).

%% Each entry is new: a directory, a file or a link that is already
%% there is an error, so a write never follows a link of the checkout.
write_tree(Tree, Dir, Objects, Submodules) ->
    lists:foreach(
      fun({Mode, Name, Sha}) ->
              Path = filename:join(Dir, Name),
              case kind(Mode) of
                  tree ->
                      make_dir(Path),
                      write_tree(Sha, Path, Objects, Submodules);
                  file -> write_new(Path, object(Sha, blob, Objects));
                  exec ->
                      write_new(Path, object(Sha, blob, Objects)),
                      file_ok(Path, file:change_mode(Path, 8#755));
                  link -> write_link(Path, object(Sha, blob, Objects));
                  gitlink when Submodules ->
                      throw({error, "git: submodules need the git program", []});
                  gitlink -> ok
              end
      end, tree(object(Tree, tree, Objects))).

%% A symbolic link stays in the checkout: a relative target with no ".."
%% and no part .git. A "\" or a ":" (a drive of Windows, as "C:") is an
%% error too, also on another system.
write_link(Path, Target) ->
    Parts = string:split(Target, "/", all),
    (Target =/= <<>> andalso binary:first(Target) =/= $/
     andalso not lists:member(<<"..">>, Parts)
     andalso binary:match(Target, [<<0>>, <<"\\">>, <<":">>]) =:= nomatch
     andalso not lists:any(fun dot_git/1, Parts))
        orelse throw({error, "git: a link out of the checkout: ~ts", [Target]}),
    file_ok(Path, file:make_symlink(Target, Path)).

%% A new file, with the exclusive mode: it follows no link.
write_new(Path, Data) ->
    {ok, F} = file_ok(Path, file:open(Path, [write, exclusive, raw, binary])),
    try file_ok(Path, file:write(F, Data))
    after file:close(F)
    end.

make_dir(Path) ->
    file_ok(Path, file:make_dir(Path)).

file_ok(_Path, ok) -> ok;
file_ok(_Path, {ok, _} = R) -> R;
file_ok(Path, {error, eexist}) ->
    throw({error, "git: ~ts is in the checkout already", [Path]});
file_ok(Path, {error, Reason}) ->
    throw({error, "git: ~ts: ~ts", [Path, file:format_error(Reason)]}).

is_sha(Text) ->
    re:run(Text, ?SHA_RE, [{capture, none}]) =:= match.
