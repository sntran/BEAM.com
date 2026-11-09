%% The SSH transport of the git client (beam_com_git), with the ssh
%% application of OTP and no ssh program. It runs git-upload-pack on the
%% server as an SSH command, with version 2 of the git protocol
%% (GIT_PROTOCOL), else version 0.
%%
%% It finds the settings as ssh does:
%% - ~/.ssh/config: Host, Match all, Include, HostName, User, Port,
%%   IdentityFile, IdentitiesOnly, IdentityAgent, UserKnownHostsFile and
%%   HostKeyAlias. A host with ProxyJump or ProxyCommand needs the ssh
%%   program.
%% - The keys: the SSH agent (SSH_AUTH_SOCK, ssh_agent of OTP), and the
%%   key files (IdentityFile, else id_ed25519, id_ecdsa and id_rsa). A key
%%   file with a passphrase works through the agent only.
%% - The host key must be in known_hosts (also a hashed name). An unknown
%%   host is an error, with the fingerprint of its key; the client asks
%%   no question and writes no file.
%%
%% The module is also the key callback of the connection
%% (ssh_client_key_api): is_host_key/5, add_host_key/4, user_key/2 and
%% sign/3.
-module(beam_com_git_ssh).

-export([is_ssh/1, ls_refs/4, pack/4]).
-export([is_host_key/5, add_host_key/4, user_key/2, sign/3]).

-ifdef(TEST).
-export([parse_url/1, config/3, match_host/2, known/3, key_algs/1, rounds/1, quote/1,
         v0_refs/1, private_key/1, next_pkt/1]).
-endif.

-define(TIMEOUT, 120000).
-define(CONNECT_TIMEOUT, 30000).
-define(MAX_ROUNDS, 4).

%% True for an SSH URL of git: ssh://[user@]host[:port]/path, and the
%% form of scp, [user@]host:path.
is_ssh(Url) ->
    parse_url(Url) =/= none.

%% The refs of the repository: [{Name, Sha}]. Body is the request
%% ls-refs of version 2 (pkt-lines). A server of version 0 gives its refs
%% at the start.
ls_refs(Url, Body, Max, Opts) ->
    session(Url, Opts,
            fun(v2, S) ->
                    {Lines, S1} = request(S, Body, Max),
                    {beam_com_git:refs(Lines), S1};
               ({v0, Adv}, S) ->
                    {v0_refs(Adv), S}
            end).

%% The pack of the commit Sha, with depth 1. Body is the request fetch
%% of version 2.
pack(Url, Sha, Body, Opts) ->
    session(Url, Opts,
            fun(v2, S) ->
                    {Lines, S1} = request(S, Body, max_pack),
                    {beam_com_git:pack_response(Lines), S1};
               ({v0, Adv}, S) ->
                    v0_pack(Url, Sha, Adv, S)
            end).

%%% The URL.

%% {User | none, Host, Port | none, Path}, or none.
parse_url(Url0) ->
    Url = unicode:characters_to_list(Url0),
    case uri_string:parse(Url) of
        #{scheme := Scheme, host := Host, path := Path} = U
          when Host =/= "", (Scheme =:= "ssh" orelse Scheme =:= "git+ssh"
                             orelse Scheme =:= "ssh+git") ->
            {case U of
                 #{userinfo := User} -> uri_string:percent_decode(User);
                 _ -> none
             end,
             Host, maps:get(port, U, none),
             case Path of
                 "/~" ++ _ -> tl(Path);
                 _ -> uri_string:percent_decode(Path)
             end};
        #{scheme := _} ->
            scp_url(Url);
        _ ->
            scp_url(Url)
    end.

%% user@host:path: a ":" before the first "/", and no "://".
scp_url(Url) ->
    case string:find(Url, "://") of
        nomatch ->
            case string:split(Url, ":") of
                [Left, Path] when Path =/= "", Left =/= "" ->
                    case lists:member($/, Left) of
                        true -> none;
                        false ->
                            case string:split(Left, "@", trailing) of
                                [User, Host] when User =/= "", Host =/= "" ->
                                    {User, Host, none, Path};
                                [Host] -> {none, Host, none, Path};
                                _ -> none
                            end
                    end;
                _ -> none
            end;
        _ -> none
    end.

%% The command line of git-upload-pack: the path in single quotes, as
%% git quotes it.
quote(Path) ->
    "'" ++ lists:flatten([case C of $' -> "'\\''"; _ -> C end || C <- Path]) ++ "'".

%%% The settings.

%% The settings of Host in the text of ~/.ssh/config: #{Keyword => Value},
%% the first value of each keyword, and all the values of IdentityFile.
%% Read(Path) gives the text of an Include file, or error.
config(Text, Host, Read) ->
    {_, Acc} = config_lines(lines(Text), Host, Read, true, #{}, 0),
    Acc.

config_lines([], _Host, _Read, Applies, Acc, _Depth) ->
    {Applies, Acc};
config_lines([{Key, Args} | Rest], Host, Read, Applies, Acc, Depth) ->
    case Key of
        "host" ->
            config_lines(Rest, Host, Read, match_host(Host, Args), Acc, Depth);
        "match" ->
            config_lines(Rest, Host, Read, [string:lowercase(A) || A <- Args] =:= ["all"],
                         Acc, Depth);
        "include" when Applies, Depth < 8 ->
            Acc1 = lists:foldl(
                     fun(Text, A) ->
                             {_, A1} = config_lines(lines(Text), Host, Read, true, A, Depth + 1),
                             A1
                     end, Acc, Read(Args)),
            config_lines(Rest, Host, Read, Applies, Acc1, Depth);
        "identityfile" when Applies ->
            config_lines(Rest, Host, Read, Applies,
                         Acc#{"identityfile" => maps:get("identityfile", Acc, []) ++ [hd(Args)]},
                         Depth);
        _ when Applies, not is_map_key(Key, Acc) ->
            config_lines(Rest, Host, Read, Applies, Acc#{Key => Args}, Depth);
        _ ->
            config_lines(Rest, Host, Read, Applies, Acc, Depth)
    end.

%% The lines of a config file: [{Keyword, [Arg]}], with the keyword in
%% lower case, and "Keyword=Arg" also.
lines(Text) ->
    [L || Line <- string:split(unicode:characters_to_list(Text), "\n", all),
          L <- [line(string:trim(Line))], L =/= none].

line("") -> none;
line("#" ++ _) -> none;
line(Line) ->
    {Key, Rest} = lists:splitwith(fun(C) -> not lists:member(C, " \t=") end, Line),
    Args = words(string:trim(string:trim(string:trim(Rest, leading), leading, "="), leading)),
    case Args of
        [] -> none;
        _ -> {string:lowercase(Key), Args}
    end.

%% The words of the arguments; a word in double quotes can have spaces.
words("") -> [];
words([$" | Rest]) ->
    {Word, After} = lists:splitwith(fun(C) -> C =/= $" end, Rest),
    [Word | words(string:trim(drop_quote(After), leading))];
words(Text) ->
    {Word, After} = lists:splitwith(fun(C) -> C =/= $\s andalso C =/= $\t end, Text),
    [Word | words(string:trim(After, leading))].

drop_quote([$" | Rest]) -> Rest;
drop_quote(Rest) -> Rest.

%% True when Name matches a pattern of the list and no negated pattern
%% ("!pattern"). The patterns can be lists with commas.
match_host(Name, Patterns0) ->
    Patterns = lists:append([string:split(P, ",", all) || P <- Patterns0]),
    Lower = string:lowercase(Name),
    Neg = [P || "!" ++ P <- Patterns],
    Pos = [P || P <- Patterns, hd(P ++ " ") =/= $!],
    not lists:any(fun(P) -> wild(string:lowercase(P), Lower) end, Neg)
        andalso lists:any(fun(P) -> wild(string:lowercase(P), Lower) end, Pos).

wild([], []) -> true;
wild([$* | P], Name) -> wild(P, Name) orelse (Name =/= [] andalso wild([$* | P], tl(Name)));
wild([$? | P], [_ | Name]) -> wild(P, Name);
wild([C | P], [C | Name]) -> wild(P, Name);
wild(_, _) -> false.

%% The text of a setting with the tokens of ssh: ~ and %d (the home), %h
%% (the host), %r (the user), %u (the local user) and %%.
expand("~/" ++ Rest, T) -> expand("%d/" ++ Rest, T);
expand("~", T) -> expand("%d", T);
expand(Text, T) -> expand_tokens(Text, T).

expand_tokens([], _T) -> [];
expand_tokens([$%, $% | Rest], T) -> [$% | expand_tokens(Rest, T)];
expand_tokens([$%, C | Rest], T) when is_map_key(C, T) -> maps:get(C, T) ++ expand_tokens(Rest, T);
expand_tokens([C | Rest], T) -> [C | expand_tokens(Rest, T)].

%%% The known hosts.

%% The keys of Name ("host", or "[host]:port") in the text of
%% known_hosts: {Known, Revoked}, two lists of key blobs.
known(Text, Name, Acc) ->
    lists:foldl(
      fun(Line, {K, R}) ->
              case string:lexemes(Line, " \t\r") of
                  ["@revoked", Hosts, _Type, Key | _] ->
                      case known_match(Hosts, Name) of
                          true -> {K, R ++ blob(Key)};
                          false -> {K, R}
                      end;
                  ["@" ++ _ | _] -> {K, R};
                  [Hosts, _Type, Key | _] ->
                      case known_match(Hosts, Name) of
                          true -> {K ++ blob(Key), R};
                          false -> {K, R}
                      end;
                  _ -> {K, R}
              end
      end, Acc, [L || L <- string:split(unicode:characters_to_list(Text), "\n", all),
                      hd(string:trim(L) ++ "#") =/= $#]).

blob(Key) ->
    try [base64:decode(Key)]
    catch _:_ -> []
    end.

%% A hashed name (|1|SALT|HASH) is the HMAC-SHA1 of the name.
known_match("|1|" ++ Hashed, Name) ->
    case string:split(Hashed, "|") of
        [Salt, Hash] ->
            try crypto:mac(hmac, sha, base64:decode(Salt), Name) =:= base64:decode(Hash)
            catch _:_ -> false
            end;
        _ -> false
    end;
known_match(Hosts, Name) ->
    match_host(Name, [Hosts]).

%%% The keys.

%% The algorithms of a key blob (the format of SSH): the first is the
%% type of the key.
key_algs(<<Len:32, Type:Len/binary, Rest/binary>>) ->
    case Type of
        <<"ssh-ed25519">> -> ['ssh-ed25519'];
        <<"ssh-ed448">> -> ['ssh-ed448'];
        <<"ssh-rsa">> -> ['rsa-sha2-512', 'rsa-sha2-256', 'ssh-rsa'];
        <<"ecdsa-sha2-", _/binary>> when Rest =/= <<>> -> [binary_to_atom(Type)];
        _ -> []
    end;
key_algs(_) ->
    [].

%% The private key of the text of a key file: {ok, Key, Blob},
%% {passphrase, Blob} for a file of openssh-key-v1 with a passphrase
%% (Blob is its public key), or error.
private_key(Text) ->
    case encrypted_v1(Text) of
        {true, Blob} ->
            {passphrase, Blob};
        _ ->
            try ssh_file:decode_ssh_file(private, any, Text, ignore) of
                {ok, Keys} ->
                    case [K || {K, _} <- Keys, private_blob(K) =/= none] of
                        [Key | _] -> {ok, Key, private_blob(Key)};
                        [] -> error
                    end;
                _ -> error
            catch _:_ -> error
            end
    end.

%% The public key of a private key, in the format of SSH.
private_blob(Key) ->
    try ssh_file:encode(ssh_file:extract_public_key(Key), ssh2_pubkey)
    catch _:_ -> none
    end.

%% {true, PublicBlob} for a key of openssh-key-v1 with a cipher.
encrypted_v1(Text) ->
    Lines = [string:trim(L) || L <- string:split(Text, <<"\n">>, all)],
    case lists:dropwhile(fun(L) -> L =/= <<"-----BEGIN OPENSSH PRIVATE KEY-----">> end, Lines) of
        [_ | Rest] ->
            B64 = iolist_to_binary(lists:takewhile(
                                     fun(L) -> L =/= <<"-----END OPENSSH PRIVATE KEY-----">> end,
                                     Rest)),
            try base64:decode(B64) of
                <<"openssh-key-v1", 0, L1:32, Cipher:L1/binary, L2:32, _:L2/binary, L3:32,
                  _:L3/binary, _N:32, L4:32, Pub:L4/binary, _/binary>> ->
                    {Cipher =/= <<"none">>, Pub};
                _ -> false
            catch _:_ -> false
            end;
        _ -> false
    end.

%% The rounds of keys: [#{Alg => Key}]. The client of OTP asks for one
%% key of each algorithm, so each round has the next key of each type.
%% Key: {agent, Blob} or {file, PrivateKey}.
rounds(Keys) ->
    lists:foldl(fun({Key, Algs}, Rounds) -> add_round(Key, Algs, Rounds, []) end,
                [], [{K, algs(K, B)} || {K, B} <- Keys, algs(K, B) =/= []]).

%% An agent of OpenSSH signs with rsa-sha2-256 when the client asks for
%% each of the two RSA algorithms (ssh_agent asks for both).
algs({agent, _}, B) ->
    case key_algs(B) of
        ['rsa-sha2-512' | _] -> ['rsa-sha2-256'];
        Algs -> Algs
    end;
algs(_, B) ->
    key_algs(B).

add_round(Key, Algs, [], Done) ->
    lists:reverse(Done) ++ [maps:from_list([{A, Key} || A <- Algs])];
add_round(Key, Algs, [Round | Rest], Done) ->
    case lists:any(fun(A) -> is_map_key(A, Round) end, Algs) of
        true -> add_round(Key, Algs, Rest, [Round | Done]);
        false ->
            lists:reverse(Done) ++ [maps:merge(Round, maps:from_list([{A, Key} || A <- Algs]))
                                    | Rest]
    end.

%%% The key callback (ssh_client_key_api).

is_host_key(Key, _Peer, _Port, _Alg, Opts) ->
    P = proplists:get_value(key_cb_private, Opts),
    Blob = ssh_file:encode(Key, ssh2_pubkey),
    case {lists:member(Blob, proplists:get_value(revoked, P)),
          lists:member(Blob, proplists:get_value(known, P))} of
        {true, _} ->
            note(P, {revoked, ssh:hostkey_fingerprint(sha256, Key)}),
            {error, revoked};
        {false, true} ->
            true;
        {false, false} ->
            note(P, {unknown_host, ssh:hostkey_fingerprint(sha256, Key)}),
            false
    end.

%% The client writes no host key.
add_host_key(_Host, _Port, _Key, _Opts) ->
    {error, not_saved}.

user_key(Alg, Opts) ->
    P = proplists:get_value(key_cb_private, Opts),
    case maps:get(Alg, proplists:get_value(keys, P), none) of
        {agent, Blob} -> {ok, {ssh2_pubkey, Blob}};
        {file, Key} -> {ok, Key};
        none -> {error, enoent}
    end.

%% A signature of the agent, for a key of the agent.
sign(Blob, Data, Opts) ->
    P = proplists:get_value(key_cb_private, Opts),
    ssh_agent:sign(Blob, Data, [{key_cb_private, [{socket_path, proplists:get_value(agent, P)},
                                                  {timeout, ?TIMEOUT}]}]).

note(P, Note) ->
    proplists:get_value(owner, P) ! {?MODULE, proplists:get_value(ref, P), Note}.

%%% The connection.

%% The settings of the URL: #{user, host, port, path, name, keys,
%% agent, known, revoked, notes}.
settings(Url, Opts) ->
    {User0, Alias, Port0, Path} = case parse_url(Url) of
                                      none -> throw({error, "~ts: not an SSH URL", [Url]});
                                      Parsed -> Parsed
                                  end,
    [throw({error, "~ts: ~ts names a program, and beam.com cannot run it; install git",
           [Url, V]}) || V <- ["GIT_SSH_COMMAND", "GIT_SSH"], os:getenv(V, "") =/= ""],
    Dir = maps:get(dir, Opts, filename:join(home(), ".ssh")),
    Read = fun(F) -> case file:read_file(F) of {ok, B} -> B; _ -> <<>> end end,
    Include = fun(Args) ->
                      [Read(F) || A <- Args, F <- filelib:wildcard(include_path(A, Dir))]
              end,
    C = config(Read(filename:join(Dir, "config")), Alias, Include),
    [throw({error, "~ts: ~ts in ~ts needs the ssh program; install git",
            [Url, K, filename:join(Dir, "config")]})
     || K <- ["ProxyJump", "ProxyCommand"], is_map_key(string:lowercase(K), C),
        string:lowercase(hd(maps:get(string:lowercase(K), C))) =/= "none"],
    LocalUser = maps:get(local_user, Opts, os:getenv("USER", "git")),
    User = case User0 of
               none -> hd(maps:get("user", C, [LocalUser]));
               _ -> User0
           end,
    Tokens0 = #{$d => filename:dirname(Dir), $u => LocalUser, $r => User, $h => Alias},
    Host = expand(hd(maps:get("hostname", C, [Alias])), Tokens0),
    Tokens = Tokens0#{$h => Host},
    Port = case Port0 of
               none -> list_to_integer(hd(maps:get("port", C, ["22"])));
               _ -> Port0
           end,
    KeyName = hd(maps:get("hostkeyalias", C, [Host])),
    Name = case Port of 22 -> KeyName; _ -> "[" ++ KeyName ++ "]:" ++ integer_to_list(Port) end,
    KnownFiles = case maps:get("userknownhostsfile", C, none) of
                     none -> [filename:join(Dir, "known_hosts"), filename:join(Dir, "known_hosts2")];
                     Paths -> [expand(F, Tokens) || F <- Paths]
                 end ++ maps:get(global_known_hosts, Opts, ["/etc/ssh/ssh_known_hosts"]),
    {Known, Revoked} = lists:foldl(fun(F, Acc) -> known(Read(F), Name, Acc) end, {[], []},
                                   KnownFiles),
    IdentityFiles = case maps:get("identityfile", C, none) of
                        none -> [filename:join(Dir, F) || F <- ["id_ed25519", "id_ecdsa", "id_rsa"]];
                        Fs -> [expand(F, Tokens) || F <- Fs, string:lowercase(F) =/= "none"]
                    end,
    Only = string:lowercase(hd(maps:get("identitiesonly", C, ["no"]))) =:= "yes",
    Agent = case maps:get("identityagent", C, none) of
                none -> maps:get(agent, Opts, os:getenv("SSH_AUTH_SOCK", ""));
                ["none"] -> "";
                [A] when A =:= "SSH_AUTH_SOCK"; A =:= "$SSH_AUTH_SOCK" ->
                    maps:get(agent, Opts, os:getenv("SSH_AUTH_SOCK", ""));
                [A] -> expand(A, Tokens)
            end,
    {Files, Locked} = lists:foldl(
                        fun(F, {Ks, Ls}) ->
                                case file:read_file(F) of
                                    {ok, Text} ->
                                        case private_key(Text) of
                                            {ok, Key, Blob} -> {Ks ++ [{{file, Key}, Blob}], Ls};
                                            {passphrase, Blob} -> {Ks, Ls ++ [{F, Blob}]};
                                            error -> {Ks, Ls}
                                        end;
                                    _ -> {Ks, Ls}
                                end
                        end, {[], []}, IdentityFiles),
    AgentKeys = agent_keys(Agent),
    Wanted = [B || {_, B} <- Files] ++ [B || {_, B} <- Locked],
    Keys = [{{agent, B}, B} || B <- AgentKeys, lists:member(B, Wanted)]
        ++ [K || {_, B} = K <- Files, not lists:member(B, AgentKeys)]
        ++ [{{agent, B}, B} || not Only, B <- AgentKeys, not lists:member(B, Wanted)],
    #{user => User, host => Host, port => Port, path => Path, name => Name,
      keys => Keys, agent => Agent, known => Known, revoked => Revoked,
      locked => [F || {F, B} <- Locked, not lists:member(B, AgentKeys)],
      known_files => KnownFiles}.

include_path(Arg, Dir) ->
    case filename:pathtype(Arg) of
        absolute -> Arg;
        _ ->
            case Arg of
                "~/" ++ Rest -> filename:join(filename:dirname(Dir), Rest);
                _ -> filename:join(Dir, Arg)
            end
    end.

home() ->
    case os:getenv("HOME") of
        false -> case init:get_argument(home) of {ok, [[H]]} -> H; _ -> "." end;
        H -> H
    end.

%% The keys of the agent: [Blob]. No agent, or an agent that does not
%% answer, gives none.
agent_keys("") ->
    [];
agent_keys(Socket) ->
    try ssh_agent:send({ssh_agent_identities_request}, [{socket_path, Socket},
                                                        {timeout, 10000}]) of
        {ssh_agent_identities_response, Keys} ->
            [element(2, K) || K <- Keys];
        _ -> []
    catch _:_ -> []
    end.

%% Connect, run git-upload-pack, and give Fun the version of the server:
%% v2, or {v0, Advertisement}.
session(Url, Opts, Fun) ->
    S = settings(Url, maps:get(ssh, Opts, #{})),
    {ok, _} = application:ensure_all_started(ssh),
    Conn = connect(Url, S),
    try
        {ok, Ch} = ok(Url, ssh_connection:session_channel(Conn, ?TIMEOUT)),
        _ = ssh_connection:setenv(Conn, Ch, "GIT_PROTOCOL", "version=2", ?TIMEOUT),
        success = ok(Url, ssh_connection:exec(Conn, Ch, "git-upload-pack " ++ quote(maps:get(path, S)),
                                              ?TIMEOUT)),
        St = #{conn => Conn, ch => Ch, buf => <<>>, url => Url, eof => false},
        {Adv, St1} = read_flush(St, 16 * 1024 * 1024),
        Version = case lists:member(<<"version 2">>, [string:trim(L, trailing, "\n")
                                                      || L <- Adv, is_binary(L)]) of
                      true -> v2;
                      false -> {v0, Adv}
                  end,
        {Result, St2} = Fun(Version, St1),
        _ = send(St2, <<"0000">>),
        _ = ssh_connection:send_eof(Conn, Ch),
        Result
    after
        ssh:close(Conn)
    end.

ok(_Url, success) -> success;
ok(_Url, {ok, _} = R) -> R;
ok(Url, Error) -> throw({error, "~ts: the SSH server refused git-upload-pack: ~p", [Url, Error]}).

connect(Url, S) ->
    #{host := Host, port := Port, keys := Keys, known := Known} = S,
    Known =:= [] andalso
        throw({error, "~ts: ~ts is not in known_hosts (~ts). Add its key, for example with "
               "ssh-keyscan, and check the fingerprint", [Url, maps:get(name, S),
                                                         lists:join(", ", maps:get(known_files, S))]}),
    Rounds = case rounds(Keys) of [] -> [#{}]; R -> lists:sublist(R, ?MAX_ROUNDS) end,
    HostAlgs = lists:usort(lists:append([key_algs(B) || B <- Known])),
    connect(Url, S, Host, Port, HostAlgs, Rounds).

connect(Url, S, Host, Port, HostAlgs, [Round | Rest]) ->
    Ref = make_ref(),
    Supported = proplists:get_value(public_key, ssh:default_algorithms()),
    Private = [{owner, self()}, {ref, Ref}, {keys, Round}, {agent, maps:get(agent, S)},
               {known, maps:get(known, S)}, {revoked, maps:get(revoked, S)}],
    Result = ssh:connect(Host, Port,
                         [{user, maps:get(user, S)},
                          {key_cb, {?MODULE, Private}},
                          {auth_methods, "publickey"},
                          {silently_accept_hosts, false},
                          {save_accepted_host, false},
                          {user_interaction, false},
                          {quiet_mode, true},
                          {connect_timeout, ?CONNECT_TIMEOUT}]
                         ++ case [A || A <- HostAlgs, lists:member(A, Supported)] of
                                [] -> [];
                                First -> [{modify_algorithms, [{prepend, [{public_key, First}]}]}]
                            end,
                         ?CONNECT_TIMEOUT),
    receive
        {?MODULE, Ref, {unknown_host, Fp}} ->
            close(Result),
            throw({error, "~ts: the key of ~ts (~ts) is not in known_hosts. Check it, and add "
                   "it to ~ts", [Url, maps:get(name, S), Fp, hd(maps:get(known_files, S))]});
        {?MODULE, Ref, {revoked, Fp}} ->
            close(Result),
            throw({error, "~ts: the key of ~ts (~ts) is revoked in known_hosts",
                   [Url, maps:get(name, S), Fp]})
    after 0 ->
            case Result of
                {ok, Conn} -> Conn;
                {error, _} when Rest =/= [] -> connect(Url, S, Host, Port, HostAlgs, Rest);
                {error, Reason} -> throw(auth_error(Url, S, Reason))
            end
    end.

close({ok, Conn}) -> ssh:close(Conn);
close(_) -> ok.

auth_error(Url, S, Reason) ->
    Locked = case maps:get(locked, S) of
                 [] -> "";
                 Files -> io_lib:format(". These keys have a passphrase: add them to the SSH "
                                        "agent (ssh-add): ~ts", [lists:join(", ", Files)])
             end,
    {error, "~ts: no SSH connection as ~ts: ~ts~ts",
     [Url, maps:get(user, S), reason(Reason), Locked]}.

reason(R) when is_list(R) -> R;
reason(R) -> io_lib:format("~p", [R]).

%%% The pkt-lines of the channel.

send(#{conn := Conn, ch := Ch}, Data) ->
    ssh_connection:send(Conn, Ch, Data, ?TIMEOUT).

%% Send a request of version 2, and read its answer to the flush.
request(S, Body, Max) ->
    ok = send(S, iolist_to_binary(Body)),
    read_flush(S, max(Max)).

max(max_pack) -> 512 * 1024 * 1024;
max(N) -> N.

%% The pkt-lines up to a flush (the flush is the last item).
read_flush(S, Max) ->
    read_flush(S, Max, 0, []).

read_flush(#{buf := Buf} = S, Max, Size, Acc) ->
    case next_pkt(Buf) of
        {flush, Rest} -> {lists:reverse([flush | Acc]), S#{buf := Rest}};
        {Pkt, Rest} when is_atom(Pkt) -> read_flush(S#{buf := Rest}, Max, Size, [Pkt | Acc]);
        {Pkt, Rest} when Size + byte_size(Pkt) =< Max ->
            read_flush(S#{buf := Rest}, Max, Size + byte_size(Pkt), [Pkt | Acc]);
        more when byte_size(Buf) =< Max -> read_flush(recv(S), Max, Size, Acc);
        _ -> throw({error, "~ts: the answer of the server is too large", [maps:get(url, S)]})
    end.

%% The next pkt-line of Buf: {Pkt, Rest}, or more.
next_pkt(<<"0000", Rest/binary>>) -> {flush, Rest};
next_pkt(<<"0001", Rest/binary>>) -> {delim, Rest};
next_pkt(<<"0002", Rest/binary>>) -> {response_end, Rest};
next_pkt(<<Hex:4/binary, Rest/binary>>) ->
    Len = try binary_to_integer(Hex, 16)
          catch error:badarg -> throw({error, "git: a bad pkt-line: ~p", [Hex]})
          end,
    Len >= 4 orelse throw({error, "git: a bad pkt-line: ~p", [Hex]}),
    case Rest of
        <<Data:(Len - 4)/binary, Next/binary>> -> {Data, Next};
        _ -> more
    end;
next_pkt(_) -> more.

recv(#{conn := Conn, ch := Ch, buf := Buf, eof := false} = S) ->
    receive
        {ssh_cm, Conn, {data, Ch, 0, Data}} ->
            ssh_connection:adjust_window(Conn, Ch, byte_size(Data)),
            S#{buf := <<Buf/binary, Data/binary>>};
        {ssh_cm, Conn, {data, Ch, 1, Data}} ->
            ssh_connection:adjust_window(Conn, Ch, byte_size(Data)),
            recv(S#{err => <<(maps:get(err, S, <<>>))/binary, Data/binary>>});
        {ssh_cm, Conn, {exit_status, Ch, _}} -> recv(S);
        {ssh_cm, Conn, {eof, Ch}} -> S#{eof := true};
        {ssh_cm, Conn, {closed, Ch}} -> S#{eof := true}
    after ?TIMEOUT ->
            throw({error, "~ts: the SSH server sent nothing for ~b s", [maps:get(url, S),
                                                                       ?TIMEOUT div 1000]})
    end;
recv(S) ->
    Err = string:trim(maps:get(err, S, <<>>)),
    throw({error, "~ts: the SSH server closed the channel~ts",
           [maps:get(url, S), case Err of <<>> -> ""; _ -> [": ", Err] end]}).

%%% Version 0 of the protocol.

%% The refs of an advertisement of version 0: the first line has the
%% capabilities after a NUL, and NAME^{} is the commit of a tag.
v0_refs(Adv) ->
    Lines = [hd(binary:split(string:trim(L, trailing, "\n"), <<0>>)) || L <- Adv, is_binary(L)],
    case [M || <<"ERR ", M/binary>> <- Lines] of
        [M | _] -> throw({error, "git: ~ts", [M]});
        [] -> ok
    end,
    Pairs = [{Name, Sha} || L <- Lines, [Sha, Name] <- [binary:split(L, <<" ">>)]],
    Peeled = maps:from_list([{binary:part(N, 0, byte_size(N) - 3), Sha}
                             || {N, Sha} <- Pairs, binary:longest_common_suffix([N, <<"^{}">>]) =:= 3]),
    [{N, maps:get(N, Peeled, Sha)} || {N, Sha} <- Pairs,
                                      binary:longest_common_suffix([N, <<"^{}">>]) =/= 3].

v0_caps(Adv) ->
    case [L || L <- Adv, is_binary(L)] of
        [First | _] ->
            case binary:split(string:trim(First, trailing, "\n"), <<0>>) of
                [_, Caps] -> [hd(binary:split(C, <<"=">>)) || C <- binary:split(Caps, <<" ">>, [global])];
                _ -> []
            end;
        [] -> []
    end.

%% The pack of Sha from a server of version 0: want, deepen 1, then done.
v0_pack(Url, Sha, Adv, S) ->
    Caps = v0_caps(Adv),
    Band = case [B || B <- [<<"side-band-64k">>, <<"side-band">>], lists:member(B, Caps)] of
               [B | _] -> B;
               [] -> throw({error, "~ts: the server speaks version 0 of the git protocol with "
                            "no side band; install git", [Url]})
           end,
    lists:member(<<"shallow">>, Caps) orelse
        throw({error, "~ts: the server speaks version 0 of the git protocol with no shallow "
               "fetch; install git", [Url]}),
    Want = [C || C <- [Band, <<"ofs-delta">>, <<"shallow">>, <<"no-progress">>],
                 lists:member(C, Caps)],
    ok = send(S, iolist_to_binary(
                   [beam_com_git:pkt(["want ", Sha, " ", lists:join(" ", Want), "\n"]),
                    beam_com_git:pkt("deepen 1\n"), <<"0000">>])),
    {_Shallow, S1} = read_flush(S, 16 * 1024 * 1024),
    ok = send(S1, beam_com_git:pkt("done\n")),
    {Lines, S2} = read_flush(S1, max(max_pack)),
    Bands = lists:dropwhile(fun(L) -> L =:= <<"NAK\n">> orelse
                                          (is_binary(L) andalso binary:part(L, 0, min(4, byte_size(L))) =:= <<"ACK ">>)
                            end, Lines),
    case [M || <<"ERR ", M/binary>> <- Lines] of
        [M | _] -> throw({error, "git: ~ts", [M]});
        [] -> {beam_com_git:pack_response([<<"packfile\n">> | Bands]), S2#{eof := true}}
    end.
