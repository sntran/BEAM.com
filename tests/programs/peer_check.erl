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
%%   peer CHANNEL: release R, sum 6, own code true, error boom, bytes 1000000
%%
%% Then the exit status of a port program, and the output of os:cmd/1
%% (a shell: on Windows, the sh of Git for Windows in PATH):
%%
%%   exit status 3
%%   cmd hello
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
    ok.

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
    ok = peer:stop(Peer),
    io:format("peer ~s: release ~s, sum ~b, own code ~p, error ~p, bytes ~b~n",
              [Channel, Release, Sum, Own, Error, Bytes]).
