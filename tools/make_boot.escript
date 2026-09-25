#!/usr/bin/env escript
%% Make the boot script of a release for BEAM.com.
%%
%% Usage: make_boot.escript RelFile Root
%%
%%   RelFile  Path of the .rel file, without the ".rel" extension.
%%   Root     The directory that becomes /zip. The applications must be
%%            in Root/lib/APP-VSN/ebin.
%%
%% The boot script goes next to the .rel file, as start.boot. Its code
%% paths start with $ROOT, so they point into /zip at run time.
main([RelFile, Root]) ->
    Dir = filename:dirname(RelFile),
    Opts = [{path, [filename:join([Root, "lib", "*", "ebin"])]},
            {outdir, Dir},
            {variables, [{"ROOT", Root}]},
            no_warn_sasl,
            silent],
    case systools:make_script(RelFile, Opts) of
        {ok, _Module, _Warnings} ->
            Name = filename:basename(RelFile),
            ok = file:rename(filename:join(Dir, Name ++ ".boot"),
                             filename:join(Dir, "start.boot"));
        Error ->
            io:format(standard_error, "make_boot: ~p~n", [Error]),
            halt(1)
    end;
main(_) ->
    io:format(standard_error, "usage: make_boot.escript RelFile Root~n", []),
    halt(2).
