%% Unit tests for beam_com_make: the make of elixir_make for the packages
%% whose NIFs are linked into beam.com.
-module(beam_com_make_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NIFS, [{exqlite, "0.41.0"}, {bcrypt_elixir, "3.3.2"}]).

make_test_() ->
    {setup, fun tmp/0, fun rm/1,
     fun(Dir) ->
             Hex = filename:join(Dir, "exqlite"),
             write(Hex, "hex_metadata.config",
                   "{<<\"name\">>,<<\"exqlite\">>}.\n{<<\"version\">>,<<\"0.41.0\">>}.\n"),
             write(Hex, "mix.exs", "@version \"9.9.9\"\n"),
             Old = filename:join(Dir, "exqlite_old"),
             write(Old, "mix.exs", "defmodule M do\n  @version \"0.40.0\"\nend\n"),
             Git = filename:join(Dir, "bcrypt_elixir"),
             write(Git, "mix.exs", "[app: :bcrypt_elixir, version: \"3.3.2\"]\n"),
             None = filename:join(Dir, "none"),
             ok = filelib:ensure_path(None),
             Other = filename:join(Dir, "other"),
             ok = filelib:ensure_path(Other),
             Env = fun(Cwd, AppPath) ->
                           #{cwd => Cwd, app_path => AppPath, nifs => ?NIFS,
                             make => "/nowhere/make"}
                   end,
             Run = fun(Args, Cwd, AppPath) -> beam_com_make:run(Args, Env(Cwd, AppPath)) end,
             [{"the version of a package",
               [?_assertEqual("0.41.0", beam_com_make:dep_version(Hex)),
                ?_assertEqual("0.40.0", beam_com_make:dep_version(Old)),
                ?_assertEqual("3.3.2", beam_com_make:dep_version(Git)),
                ?_assertEqual(undefined, beam_com_make:dep_version(None))]},
              {"a linked NIF: nothing to do",
               [?_assertEqual(ok, Run(["all"], Hex, "/p/_build/dev/lib/exqlite")),
                ?_assertEqual(ok, Run(["clean"], Hex, "/p/_build/dev/lib/exqlite")),
                ?_assertEqual(ok, Run([], Git, "")),
                %% The version is not known: the NIF is used.
                ?_assertEqual(ok, Run(["all"], None, "/p/_build/dev/lib/exqlite"))]},
              {"a linked NIF of another version",
               ?_assertEqual("exqlite 0.40.0 has a NIF, and beam.com has the NIF of "
                             "exqlite 0.41.0 (which it always uses). Use exqlite 0.41.0 "
                             "(in the deps of mix.exs: {:exqlite, \"0.41.0\"})",
                             error_text(fun() ->
                                                Run(["all"], Old, "/p/_build/dev/lib/exqlite")
                                        end))},
              {"another package: the make of PATH, else an error",
               fun() ->
                       case os:find_executable("make") of
                           false ->
                               ?assertThrow({error, _, ["other" | _]},
                                            Run(["all"], Other, ""));
                           Make ->
                               ?assertEqual({make, Make, ["-f", "M", "all"]},
                                            Run(["-f", "M", "all"], Other, ""))
                       end,
                       Path = os:getenv("PATH"),
                       os:putenv("PATH", Dir),
                       try
                           ?assertEqual("other has C code (a NIF) that is not in "
                                        "beam.com, and there is no make in PATH. The "
                                        "NIFs in beam.com: exqlite 0.41.0, "
                                        "bcrypt_elixir 3.3.2",
                                        error_text(fun() -> Run(["all"], Other, "") end))
                       after
                           os:putenv("PATH", Path)
                       end
               end}]
     end}.

error_text(Fun) ->
    try Fun() of
        Result -> Result
    catch
        throw:{error, Format, Args} -> lists:flatten(io_lib:format(Format, Args))
    end.

tmp() ->
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; T -> T end,
    Dir = filename:join(Base, "beam_com_make_tests." ++
                            integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_path(Dir),
    Dir.

rm(Dir) ->
    file:del_dir_r(Dir).

write(Dir, Name, Content) ->
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(filename:join(Dir, Name), Content).
