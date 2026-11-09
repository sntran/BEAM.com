%% The peer module of OTP with the file of the program: the program starts
%% its own file in erl mode as a new node, and controls it. The control
%% channel is the standard I/O of the node, then a TCP connection. The
%% node has no name, so no distribution and no epmd.
%%
%%   beam.com tests/programs/peer_check.erl -o peer_check.com
%%   ./peer_check.com
%%
%% For each channel, one line:
%%
%%   peer CHANNEL: release R, sum 6, own code true, error boom, bytes 1000000, sent 1000000
%%
%% Then the exit status of a port program, the output of os:cmd/1 (a
%% shell: on Windows, the sh of Git for Windows in PATH), and the bytes
%% that a port program gets when it reads its input only after 1 s (the
%% pipe stays full for that time):
%%
%%   exit status 3
%%   cmd hello
%%   slow reader 200000
%%
%% On Windows, the spawn driver starts the port programs itself, with
%% posix_spawn() (docs/UPSTREAM.md, C16).
-module(peer_check).
-export([main/1]).

main(_) ->
    {ok, [[Exe]]} = init:get_argument(beam_com_exe),
    [check(Exe, Channel) || Channel <- [standard_io, tcp]],
    exit_status(Exe),
    io:format("cmd ~ts~n", [string:trim(os:cmd("echo hello"))]),
    slow_reader(200000),
    ok.

%% A port program that reads its input after 1 s, and counts N bytes.
slow_reader(N) ->
    %% dd with bs=1 reads exactly N bytes on each system (head -c is not
    %% on each BSD). ERTS puts "exec " before the command, so the list of
    %% commands goes to a new sh.
    Port = open_port({spawn, "sh -c 'sleep 1; dd bs=1 count=" ++ integer_to_list(N)
                      ++ " 2>/dev/null | wc -c'"},
                     [binary, exit_status, use_stdio]),
    port_command(Port, binary:copy(<<"z">>, N)),
    Count = slow_output(Port, <<>>),
    io:format("slow reader ~ts~n", [string:trim(Count)]).

slow_output(Port, Acc) ->
    receive
        {Port, {data, Data}} -> slow_output(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, _}} -> Acc
    after 60000 ->
            io:format("slow reader: no end in 60 s~n"),
            erlang:halt(1)
    end.

%% The own file in erl mode, which stops with the status 3.
exit_status(Exe) ->
    Port = open_port({spawn_executable, Exe},
                     [exit_status, {args, ["-noshell", "-eval", "erlang:halt(3)."]},
                      {env, [{"BEAM_COM_ERL", "1"}]}]),
    receive
        {Port, {exit_status, Status}} -> io:format("exit status ~b~n", [Status])
    after 60000 ->
            io:format("exit status: no status in 60 s~n"),
            erlang:halt(1)
    end.

check(Exe, Channel) ->
    %% A node with a TCP channel stays a child of this program (detached
    %% false): erl mode has no erlexec, which would detach it.
    Options = case Channel of
                  standard_io -> #{connection => standard_io};
                  tcp -> #{connection => 0, detached => false}
              end,
    {ok, Peer, _Node} = peer:start_link(Options#{exec => {Exe, []},
                                                 env => [{"BEAM_COM_ERL", "1"}],
                                                 wait_boot => 60000}),
    Release = peer:call(Peer, erlang, system_info, [otp_release]),
    Release = erlang:system_info(otp_release),
    Sum = peer:call(Peer, lists, sum, [[1, 2, 3]]),
    %% erl mode has the applications of the zip in the code path.
    Own = peer:call(Peer, code, which, [?MODULE]) =/= non_existing,
    %% An error in the node comes back as the same error.
    Error = try peer:call(Peer, erlang, error, [boom]) catch error:E -> E end,
    %% A large reply goes through the channel in many parts.
    Bytes = byte_size(peer:call(Peer, binary, copy, [<<"x">>, 1000000], 60000)),
    %% A large request goes to the node in many parts (on Windows, more
    %% than the 4 KiB of the buffer of a pipe).
    Sent = peer:call(Peer, erlang, byte_size, [binary:copy(<<"y">>, 1000000)], 60000),
    ok = peer:stop(Peer),
    io:format("peer ~s: release ~s, sum ~b, own code ~p, error ~p, bytes ~b, sent ~b~n",
              [Channel, Release, Sum, Own, Error, Bytes, Sent]).
