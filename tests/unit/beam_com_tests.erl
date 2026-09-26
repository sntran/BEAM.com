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
     {"the last -o wins",
      ?_assertEqual(#{input => "a", output => "2", apps => []},
                    opts(["-o", "1", "a", "-o", "2"]))}].

build_errors_test_() ->
    Usage = {error, "usage: beam.com build INPUT [-o OUTPUT] [-a APP]...~n"
             "  INPUT   a .erl file with main/1, or an application directory~n"
             "  OUTPUT  the new executable (default: the name of INPUT.com)~n"
             "  APP     an OTP application to add (for calls that the~n"
             "          builder cannot see, such as apply/3)", []},
    [{"no input", ?_assertThrow(Usage, opts([]))},
     {"only options", ?_assertThrow(Usage, opts(["-o", "x.com"]))},
     {"two inputs", ?_assertThrow(Usage, opts(["a.erl", "b.erl"]))},
     {"-o without a value",
      ?_assertThrow({error, "option ~ts needs a value", ["-o"]}, opts(["a.erl", "-o"]))},
     {"-a without a value",
      ?_assertThrow({error, "option ~ts needs a value", ["-a"]}, opts(["a.erl", "-a"]))},
     {"an unknown option",
      ?_assertThrow({error, "unknown option ~ts", ["-z"]}, opts(["a.erl", "-z"]))},
     {"no command", ?_assertThrow(Usage, beam_com:command([]))},
     {"an unknown command", ?_assertThrow(Usage, beam_com:command(["run", "x"]))},
     {"build with no input", ?_assertThrow(Usage, beam_com:command(["build"]))}].
