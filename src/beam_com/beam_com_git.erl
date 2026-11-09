%% A git client over HTTPS, with no git program: the smart HTTP protocol
%% of git, version 2 (ls-refs and fetch of git-upload-pack). It gets one
%% commit and the files of its tree, as "git fetch --depth 1" and "git
%% checkout" do, for a git dep of Mix (beam_com_git_scm).
%%
%% The name of a git object is the SHA-1 of its type, its size and its
%% data. The client computes the name of each object of the pack, and it
%% writes only the objects that the wanted commit names: the commit, its
%% tree, the trees in it, and their files. Thus each byte that it writes
%% is the byte of the commit of mix.lock.
-module(beam_com_git).

-export([resolve/3, fetch/3, checkout/4]).

-ifdef(TEST).
-export([pkt/1, pkts/1, advertisement/1, refs/1, pack_response/1, objects/1, apply_delta/2,
         tree/1, commit_tree/1, zlib_end/2, safe_name/1, url/1]).
-endif.

%% The limits of a response: the list of refs, and the pack.
-define(MAX_REFS, 16 * 1024 * 1024).
-define(MAX_PACK, 512 * 1024 * 1024).
-define(SHA_RE, "^[0-9a-f]{40}$").

%% The commit of Rev at the repository Url: Rev is a commit (40 hex
%% digits), {branch, B}, {tag, T}, {ref, R}, or head. Opts: http, the
%% function of the requests (beam_com_hex:http/5; another one for the
%% tests).
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
    capabilities(Url, Opts),
    Body = [pkt("command=ls-refs\n"), pkt("object-format=sha1\n"), <<"0001">>,
            pkt("peel\n"), pkt("symrefs\n")]
        ++ [pkt(["ref-prefix ", N, "\n"]) || N <- Names] ++ [<<"0000">>],
    Refs = refs(pkts(upload_pack(Url, Body, ?MAX_REFS, Opts))),
    case [Sha || N <- Names, {Name, Sha} <- Refs, Name =:= list_to_binary(N)] of
        [Sha | _] -> Sha;
        [] -> throw({error, "~ts: no ~ts", [redact(Url), hd(Names)]})
    end.

%% The objects of the commit Sha (40 hex digits) at Url: #{Name => {Type,
%% Data}}, with only the commit and the objects of its tree.
fetch(Url, Sha, Opts) ->
    is_sha(binary_to_list(Sha)) orelse throw({error, "~ts: not a commit: ~ts", [redact(Url), Sha]}),
    capabilities(Url, Opts),
    Body = [pkt("command=fetch\n"), pkt("object-format=sha1\n"), <<"0001">>,
            pkt("no-progress\n"), pkt("ofs-delta\n"), pkt("deepen 1\n"),
            pkt(["want ", Sha, "\n"]), pkt("done\n"), <<"0000">>],
    Objects = objects(pack_response(pkts(upload_pack(Url, Body, ?MAX_PACK, Opts)))),
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
    ok = filelib:ensure_path(Dir),
    {Path, Sub} = Root,
    write_tree(Sub, filename:join([Dir | Path]), Objects, maps:get(submodules, Opts, false)),
    Git = filename:join(Dir, ".git"),
    ok = filelib:ensure_path(filename:join(Git, "objects")),
    ok = filelib:ensure_path(filename:join(Git, "refs")),
    ok = file:write_file(filename:join(Git, "HEAD"), [Sha, "\n"]),
    ok = file:write_file(filename:join(Git, "config"),
                         ["[remote \"origin\"]\n\turl = ", maps:get(url, Opts), "\n"]),
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

%% The capabilities of the server: the server must speak version 2.
capabilities(Url, Opts) ->
    Http = http(Opts),
    Body = Http(get, url(Url) ++ "/info/refs?service=git-upload-pack", headers(Url), none,
                ?MAX_REFS),
    advertisement(pkts(Body)) orelse
        throw({error, "~ts: the server does not speak version 2 of the git protocol; "
               "install git", [redact(Url)]}).

%% True when the advertisement has "version 2". A server of HTTP can put
%% "# service=git-upload-pack" and a flush first.
advertisement(Lines) ->
    lists:member(<<"version 2">>, [string:trim(L, trailing, "\n") || L <- Lines, is_binary(L)]).

upload_pack(Url, Body, Max, Opts) ->
    Http = http(Opts),
    Http(post, url(Url) ++ "/git-upload-pack",
         [{"accept", "application/x-git-upload-pack-result"} | headers(Url)],
         {"application/x-git-upload-pack-request", iolist_to_binary(Body)}, Max).

http(Opts) ->
    maps:get(http, Opts, fun beam_com_hex:http/5).

headers(Url) ->
    [{"git-protocol", "version=2"}]
        ++ case uri_string:parse(unicode:characters_to_list(Url)) of
               #{userinfo := User} ->
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
            throw({error, "~ts: only an https URL works with no git program", [redact(Url)]})
    end.

redact(Url) ->
    case uri_string:parse(unicode:characters_to_list(Url)) of
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
%% the SHA-1 of the bytes before it.
objects(<<"PACK", Version:32, Count:32, _/binary>> = Pack)
  when Version =:= 2; Version =:= 3 ->
    Size = byte_size(Pack) - 20,
    Size >= 12 orelse throw({error, "git: a short pack", []}),
    <<Body:Size/binary, Sum:20/binary>> = Pack,
    crypto:hash(sha, Body) =:= Sum orelse throw({error, "git: the pack has a bad checksum", []}),
    resolve_deltas(read_objects(Body, 12, Count, []));
objects(_) ->
    throw({error, "git: not a pack", []}).

read_objects(_Pack, _Pos, 0, Acc) ->
    lists:reverse(Acc);
read_objects(Pack, Pos, N, Acc) ->
    {Type, Size, P1} = header(Pack, Pos),
    {Base, P2} = case Type of
                     6 -> {Ofs, P} = offset(Pack, P1), {{ofs, Pos - Ofs}, P};
                     7 -> <<_:P1/binary, Ref:20/binary, _/binary>> = Pack,
                          {{ref, binary:encode_hex(Ref, lowercase)}, P1 + 20};
                     _ -> {none, P1}
                 end,
    {Data, Used} = inflate(binary_part(Pack, P2, byte_size(Pack) - P2), Size),
    read_objects(Pack, P2 + Used, N - 1, [{Pos, Type, Base, Data} | Acc]).

header(Pack, Pos) ->
    <<_:Pos/binary, C, _/binary>> = Pack,
    size_bytes(Pack, Pos + 1, C band 16#80, C band 15, 4, (C bsr 4) band 7).

size_bytes(_Pack, Pos, 0, Size, _Shift, Type) ->
    {Type, Size, Pos};
size_bytes(Pack, Pos, _More, Size, Shift, Type) ->
    <<_:Pos/binary, C, _/binary>> = Pack,
    size_bytes(Pack, Pos + 1, C band 16#80, Size bor ((C band 16#7f) bsl Shift), Shift + 7, Type).

offset(Pack, Pos) ->
    <<_:Pos/binary, C, _/binary>> = Pack,
    offset(Pack, Pos + 1, C band 16#80, C band 16#7f).

offset(_Pack, Pos, 0, Ofs) ->
    {Ofs, Pos};
offset(Pack, Pos, _More, Ofs) ->
    <<_:Pos/binary, C, _/binary>> = Pack,
    offset(Pack, Pos + 1, C band 16#80, ((Ofs + 1) bsl 7) bor (C band 16#7f)).

%% The data of the zlib stream at the start of Bin (Size bytes), and the
%% number of bytes of the stream. zlib gives no count of the bytes that
%% it used, so zlib_end/2 finds the end.
inflate(Bin, Size) ->
    Z = zlib:open(),
    try
        ok = zlib:inflateInit(Z),
        Data = iolist_to_binary(inflate_all(Z, Bin)),
        byte_size(Data) =:= Size orelse throw({error, "git: an object has a bad size", []}),
        {Data, zlib_end(Bin, Data)}
    after
        zlib:close(Z)
    end.

inflate_all(Z, Bin) ->
    case zlib:safeInflate(Z, Bin) of
        {continue, Out} -> [Out | inflate_all(Z, [])];
        {finished, Out} -> Out;
        {need_dictionary, _, _} -> throw({error, "git: a zlib stream needs a dictionary", []})
    end.

%% The length of the zlib stream at the start of Bin with the data Data:
%% the stream ends with the Adler-32 of its data, so it ends after the
%% first copy of these four bytes where the bytes before it give Data.
%% The search stays in the bytes that a stream of Data can have.
zlib_end(Bin, Data) ->
    Limit = min(byte_size(Bin), byte_size(Data) + (byte_size(Data) div 16000 + 1) * 5 + 64),
    Window = binary_part(Bin, 0, Limit),
    Adler = <<(erlang:adler32(Data)):32>>,
    Ends = [P + 4 || {P, 4} <- binary:matches(Window, Adler)],
    case [E || E <- Ends, uncompress(binary_part(Bin, 0, E)) =:= Data] of
        [End | _] -> End;
        [] -> throw({error, "git: the end of a zlib stream is not found", []})
    end.

uncompress(Bin) ->
    try zlib:uncompress(Bin)
    catch error:_ -> error
    end.

%% The objects with their names, after the deltas, in one pass in the
%% order of the pack: the base of an offset delta comes before it. A
%% server sends the base of a ref delta first too (no thin pack).
resolve_deltas(Entries) ->
    {Named, _} =
        lists:foldl(
          fun({Pos, T, Base, Data}, {Named, Done}) ->
                  {Type, Full} =
                      case {T, Base} of
                          {_, none} when T >= 1, T =< 4 -> {type(T), Data};
                          {6, {ofs, BasePos}} -> delta(maps:find(BasePos, Done), Data);
                          {7, {ref, Name}} -> delta(maps:find(Name, Named), Data);
                          _ -> throw({error, "git: an object of an unknown type", []})
                      end,
                  {Named#{name(Type, Full) => {Type, Full}}, Done#{Pos => {Type, Full}}}
          end, {#{}, #{}}, Entries),
    Named.

delta({ok, {Type, Base}}, Delta) -> {Type, apply_delta(Base, Delta)};
delta(error, _Delta) -> throw({error, "git: a delta has no base", []}).

type(1) -> commit;
type(2) -> tree;
type(3) -> blob;
type(4) -> tag.

name(Type, Data) ->
    binary:encode_hex(crypto:hash(sha, [atom_to_list(Type), " ",
                                        integer_to_list(byte_size(Data)), 0, Data]),
                      lowercase).

%% The new data of a delta: the size of the base, the size of the result,
%% then copies from the base and new bytes.
apply_delta(Base, Delta) ->
    {BaseSize, D1} = varint(Delta),
    BaseSize =:= byte_size(Base) orelse throw({error, "git: a delta of another base", []}),
    {Size, D2} = varint(D1),
    Out = iolist_to_binary(delta_ops(Base, D2, [])),
    byte_size(Out) =:= Size orelse throw({error, "git: a delta has a bad size", []}),
    Out.

varint(Bin) -> varint(Bin, 0, 0).

varint(<<C, Rest/binary>>, Shift, Acc) when C band 16#80 =:= 0 ->
    {Acc bor (C bsl Shift), Rest};
varint(<<C, Rest/binary>>, Shift, Acc) ->
    varint(Rest, Shift + 7, Acc bor ((C band 16#7f) bsl Shift));
varint(<<>>, _, _) ->
    throw({error, "git: a short delta", []}).

delta_ops(_Base, <<>>, Acc) ->
    lists:reverse(Acc);
delta_ops(Base, <<1:1, Bits:7, Rest/binary>>, Acc) ->
    {Offset, R1} = delta_number(Bits band 16#0f, 4, Rest),
    {Size0, R2} = delta_number(Bits bsr 4, 3, R1),
    Size = case Size0 of 0 -> 16#10000; _ -> Size0 end,
    Offset + Size =< byte_size(Base) orelse throw({error, "git: a delta copies too much", []}),
    delta_ops(Base, R2, [binary_part(Base, Offset, Size) | Acc]);
delta_ops(Base, <<0:1, N:7, Rest/binary>>, Acc) when N > 0, byte_size(Rest) >= N ->
    <<New:N/binary, R1/binary>> = Rest,
    delta_ops(Base, R1, [New | Acc]);
delta_ops(_Base, _, _Acc) ->
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
tree(<<>>) ->
    [];
tree(Data) ->
    case binary:split(Data, <<0>>) of
        [Head, <<Raw:20/binary, Rest/binary>>] ->
            case binary:split(Head, <<" ">>) of
                [Mode, Name] -> [{Mode, safe_name(Name), binary:encode_hex(Raw, lowercase)} | tree(Rest)];
                _ -> throw({error, "git: a bad tree", []})
            end;
        _ ->
            throw({error, "git: a bad tree", []})
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
        orelse string:lowercase(Name) =:= <<".git">>,
    Bad andalso throw({error, "git: a tree entry with a bad name: ~tp", [Name]}),
    Name.

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

write_tree(Tree, Dir, Objects, Submodules) ->
    ok = filelib:ensure_path(Dir),
    lists:foreach(
      fun({Mode, Name, Sha}) ->
              Path = filename:join(Dir, Name),
              case kind(Mode) of
                  tree -> write_tree(Sha, Path, Objects, Submodules);
                  file -> ok = file:write_file(Path, object(Sha, blob, Objects));
                  exec ->
                      ok = file:write_file(Path, object(Sha, blob, Objects)),
                      ok = file:change_mode(Path, 8#755);
                  link -> write_link(Path, object(Sha, blob, Objects));
                  gitlink when Submodules ->
                      throw({error, "git: submodules need the git program", []});
                  gitlink -> ok
              end
      end, tree(object(Tree, tree, Objects))).

%% A symbolic link stays in the checkout: a relative target with no "..".
write_link(Path, Target) ->
    Parts = string:split(Target, "/", all),
    (Target =/= <<>> andalso binary:first(Target) =/= $/
     andalso not lists:member(<<"..">>, Parts) andalso binary:match(Target, <<0>>) =:= nomatch)
        orelse throw({error, "git: a link out of the checkout: ~ts", [Target]}),
    ok = file:make_symlink(Target, Path).

is_sha(Text) ->
    re:run(Text, ?SHA_RE, [{capture, none}]) =:= match.
