%% The entry of the program (rebar.config: escript_emu_args). It gets
%% the command line arguments, as an escript.
%%
%%   greet NAME   uses the behaviour of the application
%%   priv         runs priv/hello.sh with sh: priv is a real directory
%%   peer         starts the program again as erl (erl mode), and reads
%%                its answer
-module(toolbox_cli).
-export([main/1]).

main(["greet", Name]) ->
    io:format("toolbox: ~s~n", [toolbox_english:greet(Name)]);
main(["priv"]) ->
    Script = filename:join(code:priv_dir(toolbox), "hello.sh"),
    io:format("toolbox: priv in /zip: ~p~n", [lists:prefix("/zip", Script)]),
    io:format("toolbox: ~s", [os:cmd(Script ++ " from-priv")]);
main(["peer"]) ->
    {ok, [[Exe]]} = init:get_argument(beam_com_exe),
    Port = open_port({spawn_executable, Exe},
                     [{env, [{"BEAM_COM_ERL", "1"}]}, {args, ["-noinput", "-eval",
                       "io:format(\"peer: ~p ~p~n\", [code:which(toolbox_english) =/= non_existing,"
                       " erlang:system_info(emu_flavor)]), halt()."]},
                      exit_status, stderr_to_stdout, binary]),
    io:format("toolbox: ~s", [collect(Port, <<>>)]);
main(Args) ->
    io:format("toolbox: usage: greet NAME | priv | peer (got ~p)~n", [Args]),
    erlang:halt(2).

collect(Port, Acc) ->
    receive
        {Port, {data, D}} -> collect(Port, <<Acc/binary, D/binary>>);
        {Port, {exit_status, _}} -> Acc
    end.
