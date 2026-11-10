#!/usr/bin/env escript
%% git_sha1dc, the helper program of beam.com for the SHA-1 check of the
%% git client (beam_com_git, c_src/cosmo/beam_com_sha1dc.c):
%%
%%   beam.com escript tests/programs/git_sha1dc_check.escript [VECTORS [PROGRAM]]
%%
%% The default VECTORS is sha1dc_vectors.txt in the directory of this
%% script, and the default PROGRAM is /zip/bin/git_sha1dc. The check sends
%% the vectors and three good inputs to PROGRAM: each vector must have the
%% mark of an attack. Then beam_com_git:check/2 checks good objects with
%% its own program. The check of the code of beam.com is always on: the
%% option sha1dc none does not stop it. The last line is:
%%
%%   git_sha1dc_check: 4 vectors have the mark, the good objects pass
-mode(compile).

main([]) ->
    main([filename:join(filename:dirname(escript:script_name()), "sha1dc_vectors.txt")]);
main([File]) ->
    main([File, "/zip/bin/git_sha1dc"]);
main([File, Program]) ->
    {ok, Text} = file:read_file(File),
    Vectors = [{Name, binary:decode_hex(Hex)}
               || Line <- binary:split(Text, [<<"\n">>, <<"\r\n">>], [global, trim_all]),
                  binary:first(Line) =/= $#,
                  [Name, Hex] <- [binary:split(Line, <<" ">>)]],
    length(Vectors) =:= 4 orelse fail("~ts has ~b vectors, not 4", [File, length(Vectors)]),
    Port = open_port({spawn_executable, Program},
                     [{packet, 4}, binary, exit_status]),
    Good = [<<>>, <<"abc">>, binary:copy(<<"a">>, 1000000)],
    [Port ! {self(), {command, Data}} || {_, Data} <- Vectors],
    [Port ! {self(), {command, Data}} || Data <- Good],
    [case answer(Port) of
         <<1, Sum:20/binary>> ->
             Sum =/= crypto:hash(sha, Data) orelse fail("~ts: the digest is the SHA-1", [Name]);
         Other -> fail("~ts: the answer ~p has no mark", [Name, Other])
     end || {Name, Data} <- Vectors],
    [case answer(Port) of
         <<0, Sum:20/binary>> when Sum =:= Data0 -> ok;
         Other -> fail("a good input of ~b bytes: the answer ~p", [byte_size(Data), Other])
     end || Data <- Good, Data0 <- [crypto:hash(sha, Data)]],
    port_close(Port),
    ok = beam_com_git:check([{blob, D} || D <- Good] ++ [{commit, <<"c">>}], #{}),
    %% The code of beam.com has BEAM_COM_SHA1DC: the check always runs. With
    %% sha1dc none and a time limit of 0 ms, the check still starts the
    %% helper, which cannot answer in 0 ms.
    Options = proplists:get_value(options, beam_com_git:module_info(compile)),
    lists:member({d, 'BEAM_COM_SHA1DC'}, Options)
        orelse fail("beam_com_git has no BEAM_COM_SHA1DC: ~p", [Options]),
    try beam_com_git:check([{blob, <<"x">>}], #{sha1dc => none, sha1dc_timeout => 0}) of
        ok -> fail("the option sha1dc none stops the check", [])
    catch throw:{error, "git: the SHA-1 check gives no answer in ~b ms", [0]} -> ok
    end,
    io:format("git_sha1dc_check: ~b vectors have the mark, the good objects pass~n",
              [length(Vectors)]).

answer(Port) ->
    receive
        {Port, {data, Data}} -> Data;
        {Port, {exit_status, Status}} -> fail("git_sha1dc stopped with the status ~b", [Status])
    after 30000 -> fail("no answer of git_sha1dc", [])
    end.

fail(Format, Args) ->
    io:format(standard_error, "git_sha1dc_check: " ++ Format ++ "~n", Args),
    halt(1).
