%% SSH over a WebSocket, for a shell on a runner of CI
%% (.github/workflows/remote-ssh.yml). Erlang :ssh is the server and the
%% client, so no system has to have OpenSSH. It runs with beam.com and
%% with the erl of a stock OTP:
%%
%%   beam.com -a ssh scripts/remote_ssh.erl -- MODE ARGS...
%%   erlc remote_ssh.erl && erl -noshell -run remote_ssh main MODE ARGS...
%%
%% The modes:
%%
%%   keygen FILE              write the key FILE and FILE.pub (OpenSSH)
%%   serve PUBFILE WORK       an SSH server on 127.0.0.1 and a WebSocket
%%                            bridge to it on 127.0.0.1:$REMOTE_SSH_PORT
%%                            (default 8022), for the keys of PUBFILE
%%   exec URL KEY FP CMD      run CMD on the server, print its output, and
%%                            exit with its exit status
%%   put URL KEY FP LOCAL REMOTE   copy a file to the server (SFTP)
%%   get URL KEY FP REMOTE LOCAL   copy a file from the server (SFTP)
%%   bridge URL PORT          a local port for OpenSSH:
%%                            ssh -p PORT runner@127.0.0.1
%%
%% URL is ws://HOST:PORT/ or wss://HOST/. FP is the SHA-256 fingerprint
%% of the host key that serve prints, for example SHA256:abc... A wss
%% connection uses HTTPS_PROXY when it is set, and the CA file of
%% SSL_CERT_FILE, else the certificates of the system.
%%
%% The server runs each command with bash -c ($REMOTE_SSH_SHELL, else
%% bash on the PATH) in WORK, with stdin from /dev/null, and stderr in
%% the output. It stops after $REMOTE_SSH_MINUTES minutes (default 60), or
%% when the file $REMOTE_SSH_STOP exists (commands get this variable).
-module(remote_ssh).
-behaviour(ssh_server_channel).

-export([main/1]).
%% ssh_server_key_api and ssh_client_key_api
-export([host_key/2, is_auth_key/3, is_host_key/4, is_host_key/5,
         add_host_key/3, add_host_key/4, user_key/2]).
%% ssh_server_channel
-export([init/1, handle_msg/2, handle_ssh_msg/2, terminate/2]).

-define(ED25519, {namedCurve, {1, 3, 101, 112}}).
-define(GUID, <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>).
-define(MAX_BRIDGES, 16).

main(Args) ->
    try run(Args) of
        Status -> halt(Status)
    catch
        throw:{usage, Text} ->
            io:format(standard_error, "remote_ssh: ~ts~n", [Text]),
            halt(2);
        throw:{error, Text} ->
            io:format(standard_error, "remote_ssh: ~ts~n", [Text]),
            halt(1)
    end.

run(["keygen", File]) ->
    keygen(File);
run(["serve", PubFile, Work]) ->
    serve(PubFile, Work);
run(["exec", Url, Key, Fp, Cmd]) ->
    exec(connect(Url, Key, Fp), Cmd);
run(["put", Url, Key, Fp, Local, Remote]) ->
    transfer(connect(Url, Key, Fp), put, Local, Remote);
run(["get", Url, Key, Fp, Remote, Local]) ->
    transfer(connect(Url, Key, Fp), get, Remote, Local);
run(["bridge", Url, Port]) ->
    bridge(Url, list_to_integer(Port));
run(_) ->
    throw({usage, "see the comment at the start of scripts/remote_ssh.erl"}).

%% Keys

%% The key file holds the private key of ed25519 (32 bytes) in base64.
%% FILE.pub holds the public key in the format of authorized_keys.
keygen(File) ->
    {Pub, Priv} = crypto:generate_key(eddsa, ed25519),
    ok = file:write_file(File, [base64:encode(Priv), $\n]),
    ok = file:change_mode(File, 8#600),
    Line = ssh_file:encode([{public(Pub), [{comment, "remote_ssh"}]}],
                           openssh_key),
    ok = file:write_file(File ++ ".pub", Line),
    io:format("~ts~n", [ssh:hostkey_fingerprint(sha256, public(Pub))]),
    0.

read_key(File) ->
    case file:read_file(File) of
        {ok, Text} ->
            Priv = base64:decode(string:trim(Text)),
            {Pub, Priv} = crypto:generate_key(eddsa, ed25519, Priv),
            private(Pub, Priv);
        {error, Reason} ->
            throw({error, io_lib:format("cannot read ~ts: ~p", [File, Reason])})
    end.

new_key() ->
    {Pub, Priv} = crypto:generate_key(eddsa, ed25519),
    private(Pub, Priv).

private(Pub, Priv) ->
    {'ECPrivateKey', 1, Priv, ?ED25519, Pub, asn1_NOVALUE}.

public(Pub) when is_binary(Pub) ->
    {{'ECPoint', Pub}, ?ED25519};
public({'ECPrivateKey', _, _, _, Pub, _}) ->
    public(Pub).

%% ssh_server_key_api: the host key and the keys of the users.
host_key('ssh-ed25519', _Options) ->
    {ok, persistent_term:get({?MODULE, host_key})};
host_key(_, _Options) ->
    {error, not_supported}.

is_auth_key(Key, _User, _Options) ->
    lists:member(Key, persistent_term:get({?MODULE, auth_keys})).

%% ssh_client_key_api: the key of the user, and the check of the host key
%% against the fingerprint that the person gave.
user_key('ssh-ed25519', _Options) ->
    {ok, persistent_term:get({?MODULE, user_key})};
user_key(_, _Options) ->
    {error, not_supported}.

is_host_key(Key, _Host, _Port, _Algorithm, _Options) ->
    ssh:hostkey_fingerprint(sha256, Key) =:=
        persistent_term:get({?MODULE, fingerprint}).

is_host_key(Key, Host, Algorithm, Options) ->
    is_host_key(Key, Host, 22, Algorithm, Options).

add_host_key(_Host, _Port, _Key, _Options) ->
    ok.

add_host_key(_Host, _Key, _Options) ->
    ok.

%% Server

serve(PubFile, Work) ->
    Keys = case file:read_file(PubFile) of
               {ok, Text} -> [K || {K, _} <- ssh_file:decode(Text, auth_keys)];
               {error, Reason} ->
                   throw({error, io_lib:format("cannot read ~ts: ~p",
                                               [PubFile, Reason])})
           end,
    Keys =/= [] orelse throw({error, "no public key in " ++ PubFile}),
    ok = filelib:ensure_path(Work),
    {ok, _} = application:ensure_all_started(ssh),
    HostKey = new_key(),
    persistent_term:put({?MODULE, host_key}, HostKey),
    persistent_term:put({?MODULE, auth_keys}, Keys),
    Shell = shell(),
    Stop = filename:join(Work, ".stop"),
    _ = file:delete(Stop),
    {ok, Daemon} =
        ssh:daemon({127, 0, 0, 1}, 0,
                   [{key_cb, {?MODULE, []}},
                    {preferred_algorithms, [{public_key, ['ssh-ed25519']}]},
                    {auth_methods, "publickey"},
                    {ssh_cli, {?MODULE, [Shell, Work, Stop]}},
                    {subsystems, [ssh_sftpd:subsystem_spec([{cwd, Work}])]},
                    {max_sessions, ?MAX_BRIDGES}]),
    {ok, Info} = ssh:daemon_info(Daemon),
    SshPort = proplists:get_value(port, Info),
    WsPort = env_integer("REMOTE_SSH_PORT", 8022),
    {ok, Listen} = gen_tcp:listen(WsPort, [binary, {ip, {127, 0, 0, 1}},
                                           {active, false}, {reuseaddr, true},
                                           {packet, raw}]),
    io:format("remote_ssh: host key ~ts~n",
              [ssh:hostkey_fingerprint(sha256, public(HostKey))]),
    io:format("remote_ssh: WebSocket on 127.0.0.1:~b, SSH on 127.0.0.1:~b, "
              "work directory ~ts~n", [WsPort, SshPort, Work]),
    Self = self(),
    spawn_link(fun() -> accept(Listen, SshPort, Self) end),
    Minutes = env_integer("REMOTE_SSH_MINUTES", 60),
    wait_stop(Stop, erlang:monotonic_time(second) + Minutes * 60).

shell() ->
    case os:getenv("REMOTE_SSH_SHELL") of
        Path when is_list(Path), Path =/= "" -> Path;
        _ ->
            case os:find_executable("bash") of
                false -> throw({error, "no bash on the PATH"});
                Path -> Path
            end
    end.

env_integer(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> list_to_integer(Value)
    end.

wait_stop(Stop, End) ->
    case filelib:is_regular(Stop) of
        true ->
            io:format("remote_ssh: stop~n"),
            0;
        false ->
            case erlang:monotonic_time(second) >= End of
                true ->
                    io:format("remote_ssh: the time ended~n"),
                    0;
                false ->
                    receive after 2000 -> wait_stop(Stop, End) end
            end
    end.

%% The WebSocket bridge of the server: one process for each connection.
accept(Listen, SshPort, Owner) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    Pid = spawn(fun() -> server_bridge(SshPort) end),
    ok = gen_tcp:controlling_process(Socket, Pid),
    Pid ! {socket, Socket},
    accept(Listen, SshPort, Owner).

server_bridge(SshPort) ->
    Socket = receive {socket, S} -> S after 5000 -> exit(normal) end,
    case read_head(gen_tcp, Socket, <<>>) of
        {ok, Head, Rest} ->
            case header(Head, <<"sec-websocket-key">>) of
                undefined ->
                    gen_tcp:send(Socket, <<"HTTP/1.1 400 Bad Request\r\n"
                                           "content-length: 0\r\n\r\n">>),
                    gen_tcp:close(Socket);
                Key ->
                    Accept = base64:encode(crypto:hash(sha, <<Key/binary, ?GUID/binary>>)),
                    ok = gen_tcp:send(Socket,
                                      [<<"HTTP/1.1 101 Switching Protocols\r\n"
                                         "upgrade: websocket\r\n"
                                         "connection: Upgrade\r\n"
                                         "sec-websocket-accept: ">>,
                                       Accept, <<"\r\n\r\n">>]),
                    {ok, Ssh} = gen_tcp:connect({127, 0, 0, 1}, SshPort,
                                                [binary, {active, once},
                                                 {nodelay, true}]),
                    relay({gen_tcp, Socket}, {gen_tcp, Ssh}, false, Rest)
            end;
        {error, _} ->
            gen_tcp:close(Socket)
    end.

%% The exec channel of the server (ssh_server_channel).
-record(ch, {shell, work, stop, id, conn, port}).

init([Shell, Work, Stop]) ->
    {ok, #ch{shell = Shell, work = Work, stop = Stop}}.

handle_msg({ssh_channel_up, Id, Conn}, S) ->
    {ok, S#ch{id = Id, conn = Conn}};
handle_msg({Port, {data, Data}}, #ch{port = Port} = S) ->
    ssh_connection:send(S#ch.conn, S#ch.id, Data),
    {ok, S};
handle_msg({Port, {exit_status, Status}}, #ch{port = Port, conn = C, id = Id} = S) ->
    ssh_connection:exit_status(C, Id, Status),
    ssh_connection:send_eof(C, Id),
    {stop, Id, S#ch{port = undefined}};
handle_msg(_, S) ->
    {ok, S}.

handle_ssh_msg({ssh_cm, C, {exec, Id, WantReply, Cmd}}, #ch{port = undefined} = S) ->
    %% The log of a job of a public repository is public: no command text.
    io:format("remote_ssh: a command of ~b bytes~n", [iolist_size(Cmd)]),
    Port = open_port({spawn_executable, S#ch.shell},
                     [{args, ["-c", "exec </dev/null\n" ++ to_list(Cmd)]},
                      {cd, S#ch.work}, {env, [{"REMOTE_SSH_STOP", S#ch.stop}]},
                      binary, exit_status, stderr_to_stdout, use_stdio, hide]),
    ssh_connection:reply_request(C, WantReply, success, Id),
    {ok, S#ch{port = Port}};
handle_ssh_msg({ssh_cm, C, {shell, Id, WantReply}}, S) ->
    ssh_connection:reply_request(C, WantReply, failure, Id),
    ssh_connection:send(C, Id, 1, <<"remote_ssh: no shell, give a command\n">>),
    ssh_connection:exit_status(C, Id, 2),
    ssh_connection:send_eof(C, Id),
    {stop, Id, S};
handle_ssh_msg({ssh_cm, C, {Request, Id, WantReply, _}}, S)
  when Request =:= pty; Request =:= env ->
    ssh_connection:reply_request(C, WantReply, failure, Id),
    {ok, S};
handle_ssh_msg({ssh_cm, _, {eof, _}}, S) ->
    {ok, S};
handle_ssh_msg({ssh_cm, _, {signal, _, _}}, S) ->
    {ok, S};
handle_ssh_msg({ssh_cm, _, {closed, Id}}, S) ->
    {stop, Id, S};
handle_ssh_msg(_, S) ->
    {ok, S}.

terminate(_, #ch{port = Port}) when is_port(Port) ->
    try port_close(Port) catch error:badarg -> ok end,
    ok;
terminate(_, _) ->
    ok.

to_list(Cmd) when is_binary(Cmd) -> unicode:characters_to_list(Cmd);
to_list(Cmd) -> Cmd.

%% Client

%% A local port that relays to the WebSocket, then an SSH connection to it.
connect(Url, KeyFile, Fp) ->
    %% The SSH client logs each refused connection as a report; the error
    %% that main prints is enough.
    ok = logger:set_primary_config(level, error),
    {ok, _} = application:ensure_all_started(ssh),
    {ok, _} = application:ensure_all_started(ssl),
    persistent_term:put({?MODULE, user_key}, read_key(KeyFile)),
    persistent_term:put({?MODULE, fingerprint}, Fp),
    Port = listen_bridge(Url, 1),
    case ssh:connect({127, 0, 0, 1}, Port,
                     [{user, "runner"}, {key_cb, {?MODULE, []}},
                      {preferred_algorithms, [{public_key, ['ssh-ed25519']}]},
                      {auth_methods, "publickey"},
                      {user_interaction, false}, {silently_accept_hosts, false},
                      {connect_timeout, 60000}], 60000) of
        {ok, Conn} -> Conn;
        {error, Reason} ->
            throw({error, io_lib:format("SSH: ~p (check the URL, the key and "
                                        "the fingerprint)", [Reason])})
    end.

exec(Conn, Cmd) ->
    {ok, Ch} = ssh_connection:session_channel(Conn, infinity),
    success = ssh_connection:exec(Conn, Ch, Cmd, infinity),
    exec_loop(Conn, Ch, 255).

exec_loop(Conn, Ch, Status) ->
    receive
        {ssh_cm, Conn, {data, Ch, Type, Data}} ->
            ok = file:write(case Type of 0 -> standard_io; _ -> standard_error end, Data),
            ssh_connection:adjust_window(Conn, Ch, byte_size(Data)),
            exec_loop(Conn, Ch, Status);
        {ssh_cm, Conn, {exit_status, Ch, New}} ->
            exec_loop(Conn, Ch, New);
        {ssh_cm, Conn, {closed, Ch}} ->
            ssh:close(Conn),
            Status;
        {ssh_cm, Conn, _} ->
            exec_loop(Conn, Ch, Status)
    end.

%% put uses SFTP. get streams the file through an exec channel, because
%% ssh_sftp:read_file/3 waits for each block of 32 KB.
transfer(Conn, put, Local, Remote) ->
    {ok, Sftp} = ssh_sftp:start_channel(Conn, [{timeout, infinity}]),
    {ok, Data} = file:read_file(Local),
    Result = ssh_sftp:write_file(Sftp, Remote, Data, infinity),
    ssh:close(Conn),
    case Result of
        ok -> 0;
        {error, Reason} -> throw({error, io_lib:format("SFTP: ~p", [Reason])})
    end;
transfer(Conn, get, Remote, Local) ->
    {ok, File} = file:open(Local, [write, raw, binary]),
    {ok, Ch} = ssh_connection:session_channel(Conn, infinity),
    success = ssh_connection:exec(Conn, Ch, "cat -- " ++ quote(Remote), infinity),
    Status = get_loop(Conn, Ch, File, 255),
    ok = file:close(File),
    case Status of
        0 -> 0;
        _ ->
            _ = file:delete(Local),
            throw({error, io_lib:format("cat ~ts: exit ~b", [Remote, Status])})
    end.

get_loop(Conn, Ch, File, Status) ->
    receive
        {ssh_cm, Conn, {data, Ch, 0, Data}} ->
            ok = file:write(File, Data),
            ssh_connection:adjust_window(Conn, Ch, byte_size(Data)),
            get_loop(Conn, Ch, File, Status);
        {ssh_cm, Conn, {exit_status, Ch, New}} ->
            get_loop(Conn, Ch, File, New);
        {ssh_cm, Conn, {closed, Ch}} ->
            ssh:close(Conn),
            Status;
        {ssh_cm, Conn, _} ->
            get_loop(Conn, Ch, File, Status)
    end.

quote(Text) ->
    "'" ++ lists:flatten(string:replace(Text, "'", "'\\''", all)) ++ "'".

%% A port for OpenSSH. Each connection gets its own WebSocket.
bridge(Url, Port) ->
    {ok, _} = application:ensure_all_started(ssl),
    Port = listen_bridge(Url, Port, infinity),
    io:format("remote_ssh: ssh -p ~b runner@127.0.0.1~n", [Port]),
    receive after infinity -> 0 end.

listen_bridge(Url, Count) ->
    listen_bridge(Url, 0, Count).

listen_bridge(Url, Port, Count) ->
    Target = parse_url(Url),
    {ok, Listen} = gen_tcp:listen(Port, [binary, {ip, {127, 0, 0, 1}},
                                         {active, false}, {reuseaddr, true}]),
    {ok, Real} = inet:port(Listen),
    Pid = spawn(fun() -> client_accept(Listen, Target, Count) end),
    ok = gen_tcp:controlling_process(Listen, Pid),
    Real.

client_accept(_Listen, _Target, 0) ->
    ok;
client_accept(Listen, Target, Count) ->
    {ok, Local} = gen_tcp:accept(Listen),
    Pid = spawn(fun() -> client_bridge(Target) end),
    ok = gen_tcp:controlling_process(Local, Pid),
    Pid ! {socket, Local},
    client_accept(Listen, Target, case Count of infinity -> infinity; _ -> Count - 1 end).

client_bridge(Target) ->
    Local = receive {socket, S} -> S end,
    case ws_open(Target) of
        {ok, Ws, Rest} ->
            ok = inet:setopts(Local, [{active, once}, {nodelay, true}]),
            relay(Ws, {gen_tcp, Local}, true, Rest);
        {error, Reason} ->
            io:format(standard_error, "remote_ssh: WebSocket: ~p~n", [Reason]),
            gen_tcp:close(Local)
    end.

parse_url(Url) ->
    case uri_string:parse(Url) of
        #{scheme := "ws", host := Host} = U ->
            {ws, Host, maps:get(port, U, 80), path(U)};
        #{scheme := "wss", host := Host} = U ->
            {wss, Host, maps:get(port, U, 443), path(U)};
        _ ->
            throw({usage, "the URL must be ws://HOST:PORT/ or wss://HOST/"})
    end.

path(#{path := ""}) -> "/";
path(#{path := Path}) -> Path;
path(_) -> "/".

%% Open the WebSocket: TCP (through HTTPS_PROXY for wss), TLS, upgrade.
ws_open({Scheme, Host, Port, Path}) ->
    case transport(Scheme, Host, Port) of
        {ok, Ws} -> upgrade(Ws, Host, Path);
        Error -> Error
    end.

transport(ws, Host, Port) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}, {nodelay, true}], 30000) of
        {ok, S} -> {ok, {gen_tcp, S}};
        Error -> Error
    end;
transport(wss, Host, Port) ->
    case tcp_to(Host, Port, [binary, {active, false}, {nodelay, true}]) of
        {ok, S} ->
            case ssl:connect(S, tls_options(Host), 30000) of
                {ok, Tls} -> {ok, {ssl, Tls}};
                Error -> Error
            end;
        Error -> Error
    end.

upgrade({Mod, Sock} = Ws, Host, Path) ->
    Key = base64:encode(crypto:strong_rand_bytes(16)),
    ok = Mod:send(Sock, ["GET ", Path, " HTTP/1.1\r\nhost: ", Host,
                         "\r\nupgrade: websocket\r\nconnection: Upgrade"
                         "\r\nsec-websocket-version: 13"
                         "\r\nsec-websocket-key: ", Key, "\r\n\r\n"]),
    Want = base64:encode(crypto:hash(sha, <<Key/binary, ?GUID/binary>>)),
    case read_head(Mod, Sock, <<>>) of
        {ok, <<"HTTP/1.1 101", _/binary>> = Head, Rest} ->
            case header(Head, <<"sec-websocket-accept">>) of
                Want -> {ok, Ws, Rest};
                _ -> {error, bad_accept}
            end;
        {ok, Head, _} ->
            [Line | _] = binary:split(Head, <<"\r\n">>),
            {error, {http, Line}};
        Error -> Error
    end.

tcp_to(Host, Port, Opts) ->
    case proxy() of
        none -> gen_tcp:connect(Host, Port, Opts, 30000);
        {PHost, PPort} ->
            case gen_tcp:connect(PHost, PPort, Opts, 30000) of
                {ok, S} ->
                    Target = io_lib:format("~ts:~b", [Host, Port]),
                    ok = gen_tcp:send(S, ["CONNECT ", Target, " HTTP/1.1\r\nhost: ",
                                          Target, "\r\n\r\n"]),
                    case read_head(gen_tcp, S, <<>>) of
                        {ok, <<"HTTP/1.", _, " 200", _/binary>>, <<>>} -> {ok, S};
                        {ok, Head, _} ->
                            [Line | _] = binary:split(Head, <<"\r\n">>),
                            {error, {proxy, Line}};
                        Error -> Error
                    end;
                Error -> Error
            end
    end.

proxy() ->
    case [V || N <- ["HTTPS_PROXY", "https_proxy"],
               V <- [os:getenv(N)], is_list(V), V =/= ""] of
        [Url | _] ->
            #{host := Host} = U = uri_string:parse(Url),
            {Host, maps:get(port, U, 80)};
        [] -> none
    end.

tls_options(Host) ->
    Cas = case os:getenv("SSL_CERT_FILE") of
              File when is_list(File), File =/= "" -> [{cacertfile, File}];
              _ -> [{cacerts, public_key:cacerts_get()}]
          end,
    [{verify, verify_peer}, {server_name_indication, Host},
     {customize_hostname_check,
      [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]},
     {versions, ['tlsv1.3', 'tlsv1.2']} | Cas].

read_head(Mod, Sock, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Head, Rest] -> {ok, Head, Rest};
        [_] when byte_size(Acc) > 16384 -> {error, head_too_long};
        [_] ->
            case Mod:recv(Sock, 0, 30000) of
                {ok, Data} -> read_head(Mod, Sock, <<Acc/binary, Data/binary>>);
                Error -> Error
            end
    end.

header(Head, Name) ->
    Lines = tl(binary:split(Head, <<"\r\n">>, [global])),
    Found = [string:trim(V) || L <- Lines,
                               [K, V] <- [binary:split(L, <<":">>)],
                               string:lowercase(string:trim(K)) =:= Name],
    case Found of
        [Value | _] -> Value;
        [] -> undefined
    end.

%% Relay: the frames of the WebSocket on one side, the bytes of SSH on
%% the other. A client masks its frames, and a server does not.
relay({WMod, W} = Ws, {gen_tcp, T} = Tcp, Mask, Buffer) ->
    case frames(Buffer) of
        {Frames, Rest} ->
            Continue =
                lists:all(fun({2, Data}) -> gen_tcp:send(T, Data) =:= ok;
                             ({0, Data}) -> gen_tcp:send(T, Data) =:= ok;
                             ({9, Data}) -> WMod:send(W, frame(10, Data, Mask)) =:= ok;
                             ({8, _}) -> false;
                             (_) -> true
                          end, Frames),
            case Continue of
                false ->
                    close(Ws, Tcp, Mask);
                true ->
                    active(Ws),
                    relay_wait(Ws, Tcp, Mask, Rest)
            end;
        too_big ->
            close(Ws, Tcp, Mask)
    end.

relay_wait({WMod, W} = Ws, {gen_tcp, T} = Tcp, Mask, Rest) ->
    receive
        {tcp, T, Data} ->
            case WMod:send(W, frame(2, Data, Mask)) of
                ok ->
                    inet:setopts(T, [{active, once}]),
                    relay_wait(Ws, Tcp, Mask, Rest);
                _ -> close(Ws, Tcp, Mask)
            end;
        {Tag, W, Data} when Tag =:= tcp; Tag =:= ssl ->
            relay(Ws, Tcp, Mask, <<Rest/binary, Data/binary>>);
        {Closed, _} when Closed =:= tcp_closed; Closed =:= ssl_closed ->
            close(Ws, Tcp, Mask);
        {Error, _, _} when Error =:= tcp_error; Error =:= ssl_error ->
            close(Ws, Tcp, Mask)
    end.

active({gen_tcp, S}) -> inet:setopts(S, [{active, once}]);
active({ssl, S}) -> ssl:setopts(S, [{active, once}]).

close({WMod, W}, {gen_tcp, T}, Mask) ->
    _ = WMod:send(W, frame(8, <<>>, Mask)),
    _ = WMod:close(W),
    _ = gen_tcp:close(T),
    ok.

%% Decode the whole frames of a buffer: {[{Opcode, Payload}], Rest}.
frames(Buffer) ->
    frames(Buffer, []).

frames(<<_Fin:1, _:3, Op:4, M:1, Len:7, More/binary>> = All, Acc) ->
    case length(Len, More) of
        {Size, _} when Size > 16#1000000 -> too_big;
        {Size, After} ->
            KeyLen = M * 4,
            case After of
                <<Key:KeyLen/binary, Payload:Size/binary, Rest/binary>> ->
                    frames(Rest, [{Op, unmask(Key, Payload)} | Acc]);
                _ -> {lists:reverse(Acc), All}
            end;
        short -> {lists:reverse(Acc), All}
    end;
frames(Rest, Acc) ->
    {lists:reverse(Acc), Rest}.

length(126, <<Size:16, After/binary>>) -> {Size, After};
length(127, <<Size:64, After/binary>>) -> {Size, After};
length(Len, After) when Len < 126 -> {Len, After};
length(_, _) -> short.

unmask(<<>>, Payload) ->
    Payload;
unmask(Key, Payload) ->
    Size = byte_size(Payload),
    crypto:exor(Payload, binary:part(binary:copy(Key, Size div 4 + 1), 0, Size)).

frame(Op, Data, Mask) ->
    Payload = iolist_to_binary(Data),
    Size = byte_size(Payload),
    Len = if Size < 126 -> <<Size:7>>;
             Size < 65536 -> <<126:7, Size:16>>;
             true -> <<127:7, Size:64>>
          end,
    case Mask of
        false ->
            [<<1:1, 0:3, Op:4, 0:1, Len/bitstring>>, Payload];
        true ->
            Key = crypto:strong_rand_bytes(4),
            [<<1:1, 0:3, Op:4, 1:1, Len/bitstring>>, Key, unmask(Key, Payload)]
    end.
