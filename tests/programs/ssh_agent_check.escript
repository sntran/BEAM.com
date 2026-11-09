#!/usr/bin/env escript
%% The SSH agent of Windows OpenSSH through ssh_agent_bridge, the helper
%% program of beam.com for the git client (beam_com_git_ssh). It needs an
%% agent with the key of PUBFILE (ssh-add):
%%
%%   beam.com escript tests/programs/ssh_agent_check.escript AGENT PUBFILE [BRIDGE]
%%
%% AGENT is the named pipe, for example \\.\pipe\openssh-ssh-agent.
%% BRIDGE is /zip/bin/ssh_agent_bridge when it is not given. The check
%% gets the keys of the agent, and then a signature of the git client.
%% The last line is:
%%
%%   ssh_agent_check: N keys, the key signs
-mode(compile).

main([Agent, PubFile]) ->
    main([Agent, PubFile, "/zip/bin/ssh_agent_bridge"]);
main([Agent, PubFile, Bridge]) ->
    {ok, Text} = file:read_file(PubFile),
    [{Pub, _} | _] = ssh_file:decode(Text, auth_keys),
    Blob = ssh_file:encode(Pub, ssh2_pubkey),
    Port = open_port({spawn_executable, Bridge},
                     [{args, [Agent]}, {packet, 4}, binary, exit_status]),
    Port ! {self(), {command, <<11>>}},
    N = receive
            {Port, {data, <<12, Count:32, _/binary>> = Answer}} ->
                case binary:match(Answer, Blob) of
                    nomatch -> fail("the agent does not have the key of ~ts", [PubFile]);
                    _ -> Count
                end;
            {Port, Other} -> fail("the bridge gave ~p", [Other])
        after 10000 -> fail("no answer of the bridge", [])
        end,
    port_close(Port),
    Data = <<"signed by the agent">>,
    Sig = beam_com_git_ssh:sign(Blob, Data,
                                [{key_cb_private, [{agent, {bridge, Bridge, Agent}}]}]),
    public_key:verify(Data, none, Sig, Pub) orelse fail("the signature is not correct", []),
    io:format("ssh_agent_check: ~b keys, the key signs~n", [N]).

fail(Format, Args) ->
    io:format("ssh_agent_check: " ++ Format ++ "~n", Args),
    halt(1).
