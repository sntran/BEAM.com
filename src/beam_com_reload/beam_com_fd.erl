%% Send a file descriptor to another program over a Unix socket, and
%% receive one (SCM_RIGHTS), with the static NIF of
%% c_src/fd/beam_com_fd.c. The build of OTP has no socket NIF
%% (--disable-esock), and gen_tcp cannot send a descriptor.
%%
%% The use: a server gives its listening socket to the next version of
%% its program. The two programs then have one socket. The old program
%% stops its accept and closes its copy, and the new program accepts each
%% connection of the queue. No connection gets a reset, also on Linux
%% (examples/bluegreen).
%%
%%   %% The old program, with Unix: a gen_tcp socket of the family local.
%%   ok = beam_com_fd:send(Unix, Listen),
%%   %% The new program:
%%   {ok, Fd} = beam_com_fd:recv(Unix, 30000),
%%   {ok, Listen} = gen_tcp:listen(0, [{fd, Fd} | Options]),
%%
%% Unix must be connected, with {active, false}, and nothing else must
%% read it or write it during the call. A message has one byte and one
%% descriptor. Only on Linux, macOS and the BSDs, in a native beam.com:
%% elsewhere the result is {error, enotsup}. beam.com loads this module
%% in each program, with beam_com_reload (lib/beam_com_reload/ebin).
-module(beam_com_fd).

-export([send/2, recv/2]).
-on_load(init/0).

%% The static NIF has the name of this module. Without it (another
%% runtime), the module loads, and each call gives {error, enotsup}.
init() ->
    _ = erlang:load_nif("beam_com_fd", 0),
    ok.

%% Send the descriptor of Socket (a gen_tcp socket, for example a
%% listener, or a descriptor) over the Unix socket Unix. The receiver
%% gets its own copy: Socket stays open here.
-spec send(gen_tcp:socket(), gen_tcp:socket() | non_neg_integer()) ->
          ok | {error, term()}.
send(Unix, Socket) ->
    case {inet:getfd(Unix), fd(Socket)} of
        {{ok, U}, {ok, Fd}} -> call(fun() -> send_nif(U, Fd) end);
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

%% Receive one descriptor over the Unix socket Unix, in at most Timeout
%% ms. The descriptor has FD_CLOEXEC. The caller owns it: for example,
%% gen_tcp:listen(0, [{fd, Fd} | Options]) makes a listener of it. Give
%% port 0 and no ip or ifaddr option: with an address, inet binds the
%% descriptor again, and with another port, the call fails.
-spec recv(gen_tcp:socket(), timeout()) ->
          {ok, non_neg_integer()} | {error, timeout | closed | term()}.
recv(Unix, Timeout) when Timeout =:= infinity;
                         is_integer(Timeout), Timeout >= 0, Timeout =< 16#7fffffff ->
    Ms = case Timeout of infinity -> -1; _ -> Timeout end,
    case inet:getfd(Unix) of
        {ok, U} -> call(fun() -> recv_nif(U, Ms) end);
        {error, _} = Error -> Error
    end.

fd(Fd) when is_integer(Fd), Fd >= 0 -> {ok, Fd};
fd(Socket) -> inet:getfd(Socket).

call(Fun) ->
    try
        Fun()
    catch
        error:not_loaded -> {error, enotsup}
    end.

send_nif(_Sock, _Fd) -> erlang:nif_error(not_loaded).
recv_nif(_Sock, _Ms) -> erlang:nif_error(not_loaded).
