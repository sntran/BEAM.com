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
                    opts(["-o", "1", "a", "-o", "2"]))}].

build_errors_test_() ->
    {error, "usage: " ++ _, []} = Usage = (catch beam_com:command(["build"])),
    [{"no input", ?_assertThrow(Usage, opts([]))},
     {"only options", ?_assertThrow(Usage, opts(["-o", "x.com"]))},
     {"two inputs", ?_assertThrow(Usage, opts(["a.erl", "b.erl"]))},
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
                      "(see beam.com help build)", [F]}, opts(["a", F]))
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
     {"build with no input", ?_assertThrow(Usage, beam_com:command(["build"]))}].

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
    UnknownRun = {error, "unknown command ~ts (see ~ts help)", ["run", "beam.com"]},
    [{"no command prints the help",
      fun() ->
              {ok, Text} = output([]),
              ?assert(has(Text, "usage: beam.com COMMAND")),
              ?assert(has(Text, "build INPUT")),
              ?assert(has(Text, "version")),
              ?assertEqual({ok, Text}, output(["help"])),
              ?assertEqual({ok, Text}, output(["--help"])),
              ?assertEqual({ok, Text}, output(["-h"]))
      end},
     {"the help of each command",
      fun() ->
              {ok, Build} = output(["help", "build"]),
              ?assert(has(Build, "usage: beam.com build INPUT [-o OUTPUT] [-a APP]... [--allow-read[=PATH,...]]\n")),
              ?assert(has(Build, "BEAM_COM_ALLOW (flags")),
              ?assertNot(has(Build, "~n")),
              {ok, Version} = output(["help", "version"]),
              ?assert(has(Version, "usage: beam.com version")),
              {ok, Help} = output(["help", "help"]),
              ?assert(has(Help, "usage: beam.com help"))
      end},
     {"version shows the versions and the platform",
      fun() ->
              {ok, Text} = output(["version"]),
              ?assertEqual({ok, Text}, output(["--version"])),
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
                  {ok, Text} = output(["version"]),
                  ?assert(has(Text, "  Erlang/OTP  : 29.1.1\n")),
                  {ok, Help} = output([]),
                  ?assert(has(Help, "Erlang/OTP 29.1.1 in one"))
              after
                  application:unset_env(beam_com, otp_version)
              end
      end},
     {"the linked NIFs of Elixir packages from the .app file",
      fun() ->
              {ok, Without} = output(["version"]),
              ?assertNot(has(Without, "Linked NIFs")),
              ok = application:set_env(beam_com, nifs, [{exqlite, "0.41.0"},
                                                        {bcrypt_elixir, "3.3.2"}]),
              try
                  {ok, Text} = output(["version"]),
                  ?assert(has(Text, "  Linked NIFs : exqlite-0.41.0 bcrypt_elixir-3.3.2\n"))
              after
                  application:set_env(beam_com, nifs, [])
              end
      end},
     {"an unknown command", ?_assertThrow(UnknownRun, beam_com:command(["run", "x"]))},
     {"version with arguments",
      ?_assertThrow({error, "usage: ~ts version", ["beam.com"]},
                    beam_com:command(["version", "x"]))},
     {"help of an unknown command",
      ?_assertThrow(UnknownRun, beam_com:command(["help", "run"]))},
     {"the name of the file",
      [?_assertEqual("beam.com", beam_com:name()),
       ?_assertEqual("beam-emu.com", beam_com:name("/opt/bin/beam-emu.com")),
       ?_assertEqual("beam.com", beam_com:name("C:/tools/beam.exe")),
       ?_assertEqual("tool.com", beam_com:name("C:\\tools\\tool.exe")),
       ?_assertEqual("beam.com", beam_com:name("beam"))]}].
