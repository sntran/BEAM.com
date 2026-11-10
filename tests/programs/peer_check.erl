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
%% Then, on Windows only, a native port program that waits in large reads
%% (the free space of the write end of the pipe is then 0):
%%
%%   native reader true
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
    native_reader(),
    ok.

%% On Windows: findstr.exe, a native program that waits in reads of 4 KiB
%% or more, so the free space of the write end of its pipe is 0. It gets
%% 20000 lines, and gives them back in order. It writes the last lines
%% only at the end of its input, so the check waits for 10000 lines.
native_reader() ->
    case os:type() of
        {unix, windows} ->
            Exe = os:find_executable("findstr"),
            Port = open_port({spawn_executable, Exe},
                             [binary, {line, 100}, {args, ["/B", "line"]}]),
            %% The program waits in its read.
            timer:sleep(500),
            port_command(Port, [io_lib:format("line ~6..0b~n", [I])
                                || I <- lists:seq(1, 20000)]),
            Ok = native_lines(Port, 1),
            port_close(Port),
            io:format("native reader ~p~n", [Ok]);
        _ ->
            ok
    end.

native_lines(_Port, 10001) ->
    true;
native_lines(Port, I) ->
    Line = iolist_to_binary(io_lib:format("line ~6..0b", [I])),
    receive
        {Port, {data, {eol, Line}}} -> native_lines(Port, I + 1);
        {Port, {data, Other}} -> {line, I, Other}
    after 60000 ->
            {no_line_in_60_s, I}
    end.

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
