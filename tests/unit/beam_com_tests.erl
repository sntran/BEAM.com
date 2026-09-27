%% Unit tests for beam_com, the command line of beam.com.
-module(beam_com_tests).

-include_lib("eunit/include/eunit.hrl").

opts(Args) ->
    beam_com:build_options(Args, #{apps => []}).

build_options_test_() ->
    [?_assertEqual(#{input => "a.erl", apps => []}, opts(["a.erl"])),
     ?_assertEqual(#{input => "a.erl", output => "b.com", apps => []},
                   opts(["a.erl", "-o", "b.com"])),
     ?_assertEqual(#{input => "a.erl", output => "b.com", apps => []},
                   opts(["-o", "b.com", "a.erl"])),
     ?_assertEqual(#{input => "dir", apps => [crypto, ssl]},
                   opts(["-a", "crypto", "dir", "-a", "ssl"])),
     ?_assertEqual(#{input => "a.erl", target => "x86_64-unknown-linux-gnu", apps => []},
                   opts(["a.erl", "--target", "x86_64-unknown-linux-gnu"])),
     ?_assertEqual(#{input => "a.erl", target => "aarch64-unknown-linux-gnu", apps => []},
                   opts(["a.erl", "--target", "aarch64-linux"])),
     {"the last -o wins",
      ?_assertEqual(#{input => "a", output => "2", apps => []},
                    opts(["-o", "1", "a", "-o", "2"]))},
     {"the arguments of the program after --",
      ?_assertEqual(#{input => "a.erl", apps => [], args => ["x", "-o", "--"]},
                    opts(["a.erl", "--", "x", "-o", "--"]))},
     {"flags before and after the input",
      ?_assertEqual(#{input => "a.erl", output => "b.com", apps => [crypto], args => []},
                    opts(["-a", "crypto", "a.erl", "-o", "b.com", "--"]))}].

build_errors_test_() ->
    %% The tests run in a directory without a project: no input is an error.
    {error, "usage: " ++ _, ["beam.com"]} = Usage = (catch opts([])),
    [{"no input", ?_assertThrow(Usage, opts([]))},
     {"only options", ?_assertThrow(Usage, opts(["-o", "x.com"]))},
     {"two inputs",
      ?_assertThrow({error, "~ts: the arguments of the program come after \"--\" (see ~ts --help)",
                     ["b.erl", "beam.com"]},
                    opts(["a.erl", "b.erl"]))},
     {"-o without a value",
      ?_assertThrow({error, "option ~ts needs a value", ["-o"]}, opts(["a.erl", "-o"]))},
     {"-a without a value",
      ?_assertThrow({error, "option ~ts needs a value", ["-a"]}, opts(["a.erl", "-a"]))},
     {"--target without a value",
      ?_assertThrow({error, "option ~ts needs a value", ["--target"]},
                    opts(["a.erl", "--target"]))},
     {"--native is --target now",
      ?_assertThrow({error, "unknown option ~ts", ["--native"]},
                    opts(["a.erl", "--native", "x86_64-linux"]))},
     {"an unknown option",
      ?_assertThrow({error, "unknown option ~ts", ["-z"]}, opts(["a.erl", "-z"]))},
     {"--allow-* flags",
      ?_assertEqual(#{input => "a.erl", apps => [],
                      allow => #{read => ["/etc", "/srv"], write => all, net => true}},
                    opts(["--allow-read=/etc", "a.erl", "-W", "--allow-net",
                          "--allow-read=/srv,/etc"]))},
     {"-A and --allow-all",
      [?_assertEqual(#{input => "a", apps => [], allow => #{all => true}},
                     opts(["-A", "a"])),
       ?_assertEqual(#{input => "a", apps => [], allow => #{all => true, run => ["git"]}},
                     opts(["a", "--allow-all", "--allow-run=git"]))]},
     {"--allow-net with hosts",
      ?_assertThrow({error, "--allow-net takes no hosts: the sandbox cannot "
                     "filter the network by host", []},
                    opts(["a", "--allow-net=example.com"]))},
     {"flags of Deno that the sandbox cannot enforce",
      [?_assertThrow({error, "~ts is not supported: the sandbox cannot enforce it "
                      "(see beam.com --help)", [F]}, opts(["a", F]))
       || F <- ["--allow-env", "--allow-env=HOME", "--allow-sys", "--allow-ffi",
                "--deny-read=/etc"]]},
     {"an unknown --allow- flag",
      ?_assertThrow({error, "unknown option ~ts", ["--allow-bogus"]},
                    opts(["a", "--allow-bogus"]))},
     {"an empty list",
      ?_assertThrow({error, "~ts needs a list after \"=\"", ["--allow-read="]},
                    opts(["a", "--allow-read="]))},
     {"--pledge is --allow-* now",
      ?_assertThrow({error, "unknown option ~ts", ["--pledge"]},
                    opts(["a", "--pledge", "inet"]))},
     {"--main, --tool and --extract-priv",
      ?_assertEqual(#{input => "d", apps => [], main => m, tool => mix,
                      extract_priv => [a, b]},
                    opts(["d", "--main", "m", "--tool", "mix", "--extract-priv", "a",
                          "--extract-priv", "b"]))},
     {"--tool rebar", ?_assertMatch(#{tool := rebar}, opts(["d", "--tool", "rebar"]))},
     {"an unknown tool",
      ?_assertThrow({error, "--tool is rebar or mix, not ~ts", ["make"]},
                    opts(["d", "--tool", "make"]))},
     [{Option ++ " without a value",
       ?_assertThrow({error, "option ~ts needs a value", [Option]}, opts(["d", Option]))}
      || Option <- ["--main", "--tool", "--extract-priv"]],
     {"the commands before 0.2: a hint",
      [?_assertThrow({error, "there is no command ~ts: use \"~ts INPUT -o OUTPUT\"",
                      ["build", "beam.com"]}, opts(["build", "a.erl"])),
       ?_assertThrow({error, "there is no command ~ts: use \"~ts --help\"",
                      ["help", "beam.com"]}, beam_com:command(["help"])),
       ?_assertThrow({error, "there is no command ~ts: use \"~ts --version\"",
                      ["version", "beam.com"]}, beam_com:command(["version", "x"]))]},
     {"an old command with a directory of that name: still the hint",
      fun() ->
              Dir = filename:join(os:getenv("TMPDIR", "/tmp"), "beam_com_old_command"),
              _ = file:del_dir_r(Dir),
              ok = filelib:ensure_path(filename:join(Dir, "build")),
              {ok, Cwd} = file:get_cwd(),
              ok = file:set_cwd(Dir),
              try
                  ?assertThrow({error, "there is no command ~ts: use \"~ts INPUT -o OUTPUT\"",
                                ["build", "beam.com"]}, opts(["build", "a.erl"])),
                  ?assertMatch(#{input := "build"}, opts(["build"]))
              after
                  file:set_cwd(Cwd),
                  file:del_dir_r(Dir)
              end
      end},
     {"--target is only for -o",
      ?_assertThrow({error, "--target makes a file for another system: use it with -o", []},
                    beam_com:command(["a.erl", "--target", "x86_64-linux"]))}].

run_file_test_() ->
    A = beam_com:run_file("dir/app.erl", #{apps => []}),
    [?_assertEqual(".com", filename:extension(A)),
     ?_assertMatch("app-" ++ _, filename:basename(A)),
     ?_assertEqual("run", filename:basename(filename:dirname(A))),
     {"the same input and options: the same file",
      ?_assertEqual(A, beam_com:run_file("dir/app.erl", #{apps => []}))},
     {"other options (the sandbox): another file",
      ?_assertNotEqual(A, beam_com:run_file("dir/app.erl", #{apps => [], allow => #{net => true}}))},
     {"BEAM_COM_CACHE",
      fun() ->
              Old = os:getenv("BEAM_COM_CACHE"),
              os:putenv("BEAM_COM_CACHE", "/tmp/c"),
              try ?assertMatch("/tmp/c/run/app-" ++ _, beam_com:run_file("app.erl", #{}))
              after case Old of false -> os:unsetenv("BEAM_COM_CACHE"); _ -> os:putenv("BEAM_COM_CACHE", Old) end
              end
      end}].

is_project_test_() ->
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"), "beam_com_is_project"),
    Setup = fun() -> _ = file:del_dir_r(Dir), ok = file:make_dir(Dir) end,
    Cleanup = fun(_) -> file:del_dir_r(Dir) end,
    {setup, Setup, Cleanup,
     fun() ->
             ?assertNot(beam_com:is_project(Dir)),
             ok = file:write_file(filename:join(Dir, "mix.exs"), ""),
             ?assert(beam_com:is_project(Dir))
     end}.

%% The output of a command, and its result. A small I/O server collects
%% what the command writes.
output(Args) ->
    Collector = spawn_link(fun() -> collect([]) end),
    Old = group_leader(),
    group_leader(Collector, self()),
    Result = try beam_com:command(Args)
             after group_leader(Old, self())
             end,
    Collector ! {text, self()},
    receive {Collector, Text} -> {Result, Text} end.

collect(Acc) ->
    receive
        {io_request, From, Ref, Request} ->
            From ! {io_reply, Ref, ok},
            collect([Acc | request_text(Request)]);
        {text, From} ->
            From ! {self(), unicode:characters_to_list(Acc)}
    end.

request_text({put_chars, unicode, Chars}) -> Chars;
request_text({put_chars, unicode, M, F, A}) -> apply(M, F, A);
request_text({put_chars, latin1, Chars}) -> Chars;
request_text({put_chars, latin1, M, F, A}) -> apply(M, F, A);
request_text(_) -> [].

has(Text, Part) ->
    string:find(Text, Part) =/= nomatch.

commands_test_() ->
    [{"no command prints the help (not in a project)",
      fun() ->
              {ok, Text} = output([]),
              ?assert(has(Text, "usage: beam.com [FLAGS] [INPUT] [-- ARGUMENTS]")),
              ?assert(has(Text, "beam.com [FLAGS] INPUT -o OUTPUT")),
              ?assert(has(Text, "--help | --version")),
              ?assert(has(Text, "BEAM_COM_ALLOW")),
              ?assertNot(has(Text, "~n")),
              ?assertEqual({ok, Text}, output(["--help"])),
              ?assertEqual({ok, Text}, output(["-h"]))
      end},
     {"version shows the versions and the platform",
      fun() ->
              {ok, Text} = output(["--version"]),
              ERTS = erlang:system_info(version),
              ?assert(has(Text, "  ERTS        : " ++ ERTS ++ "\n")),
              ?assert(has(Text, "  Erlang/OTP  : " ++ erlang:system_info(otp_release))),
              ?assert(has(Text, "  Emulator    : ")),
              ?assert(has(Text, "  Architecture: " ++
                              erlang:system_info(system_architecture))),
              Stdlib = "stdlib-" ++ element(2, application:get_key(stdlib, vsn)),
              ?assert(has(Text, Stdlib)),
              ?assertEqual(1, length(string:split(Text, Stdlib, all)) - 1)
      end},
     {"the full OTP version from the .app file",
      fun() ->
              ok = application:set_env(beam_com, otp_version, "29.1.1"),
              try
                  {ok, Text} = output(["--version"]),
                  ?assert(has(Text, "  Erlang/OTP  : 29.1.1\n")),
                  {ok, Help} = output([]),
                  ?assert(has(Help, "Erlang/OTP 29.1.1 in one"))
              after
                  application:unset_env(beam_com, otp_version)
              end
      end},
     {"the linked NIFs of Elixir packages from the .app file",
      fun() ->
              {ok, Without} = output(["--version"]),
              ?assertNot(has(Without, "Linked NIFs")),
              ok = application:set_env(beam_com, nifs, [{exqlite, "0.41.0"},
                                                        {bcrypt_elixir, "3.3.2"}]),
              try
                  {ok, Text} = output(["--version"]),
                  ?assert(has(Text, "  Linked NIFs : exqlite-0.41.0 bcrypt_elixir-3.3.2\n"))
              after
                  application:set_env(beam_com, nifs, [])
              end
      end},
     {"--version with arguments",
      ?_assertThrow({error, "usage: ~ts --version", ["beam.com"]},
                    beam_com:command(["--version", "x"]))},
     {"the name of the file",
      [?_assertEqual("beam.com", beam_com:name()),
       ?_assertEqual("beam-emu.com", beam_com:name("/opt/bin/beam-emu.com")),
       ?_assertEqual("beam.com", beam_com:name("C:/tools/beam.exe")),
       ?_assertEqual("tool.com", beam_com:name("C:\\tools\\tool.exe")),
       ?_assertEqual("beam.com", beam_com:name("beam"))]}].
