%% Unit tests for beam_com_script: the copy of a priv directory to real
%% files (extract/2).
-module(beam_com_script_tests).

-include_lib("eunit/include/eunit.hrl").

extract_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun({Dir, _Ebin}) ->
             [{"a copy of priv, with the modes", fun() -> copy(Dir) end}]
     end}.

%% A fake application xapp-1.2 in the code path, with priv/run.sh and
%% priv/sub/data.txt.
setup() ->
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; T -> T end,
    Dir = filename:join(Base, "beam_com_script_tests." ++
                            integer_to_list(erlang:unique_integer([positive]))),
    Lib = filename:join([Dir, "lib", "xapp-1.2"]),
    Ebin = filename:join(Lib, "ebin"),
    ok = filelib:ensure_path(Ebin),
    ok = file:write_file(filename:join(Ebin, "xapp.app"),
                         "{application, xapp, [{vsn, \"1.2\"}, {modules, []}]}.\n"),
    ok = filelib:ensure_path(filename:join([Lib, "priv", "sub"])),
    ok = file:write_file(filename:join([Lib, "priv", "run.sh"]), "#!/bin/sh\necho run\n"),
    ok = file:write_file(filename:join([Lib, "priv", "sub", "data.txt"]), "data"),
    true = code:add_pathz(Ebin),
    {Dir, Ebin}.

cleanup({Dir, Ebin}) ->
    [code:del_path(P) || P <- code:get_path(), lists:prefix(Dir, P)],
    _ = Ebin,
    %% The copies are read-only: make them writable to remove them.
    [file:change_mode(F, 8#755) || F <- filelib:wildcard(filename:join(Dir, "**"))],
    file:del_dir_r(Dir).

copy(Dir) ->
    Cache = filename:join(Dir, "cache"),
    ZipEbin = code:lib_dir(xapp) ++ "/ebin",
    ok = beam_com_script:extract({xapp, "1.2", "abc", ["run.sh"]}, Cache),
    Priv = filename:join([Cache, "priv", "abc", "xapp-1.2", "priv"]),
    ?assertEqual(Priv, code:priv_dir(xapp)),
    ?assertEqual({ok, <<"#!/bin/sh\necho run\n">>}, file:read_file(filename:join(Priv, "run.sh"))),
    ?assertEqual({ok, <<"data">>}, file:read_file(filename:join([Priv, "sub", "data.txt"]))),
    case os:type() of
        {win32, _} -> ok;
        _ ->
            ?assertEqual(8#555, mode(filename:join(Priv, "run.sh"))),
            ?assertEqual(8#444, mode(filename:join([Priv, "sub", "data.txt"])))
    end,
    %% The original ebin stays in the code path (for the code).
    ?assert(lists:member(ZipEbin, code:get_path())),
    %% No temporary directory is left.
    ?assertEqual([], filelib:wildcard(filename:join([Cache, "priv", "abc", "*.tmp.*"]))),
    %% A second start uses the copy: a change to the source is not seen.
    ok = file:write_file(filename:join([ZipEbin, "..", "priv", "run.sh"]), "changed"),
    ok = beam_com_script:extract({xapp, "1.2", "abc", ["run.sh"]}, Cache),
    ?assertEqual({ok, <<"#!/bin/sh\necho run\n">>}, file:read_file(filename:join(Priv, "run.sh"))).

mode(File) ->
    {ok, Info} = file:read_file_info(File),
    element(8, Info) band 8#777.
