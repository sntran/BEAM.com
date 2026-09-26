#!/usr/bin/env escript
%% Run the unit tests of the Erlang code of BEAM.com, with coverage.
%%
%%   escript tests/unit/run.escript OUTDIR
%%
%% It compiles the modules of apps/*/src with -DTEST under cover, runs
%% the EUnit tests in tests/unit, and prints the line coverage of each
%% module. The exit status is 1 when a test fails. Modules with NIFs
%% (wasm) are tested in beam.com itself (tests/programs). ELIXIR_LIB (the
%% lib directory of an Elixir build) adds Elixir for the Elixir tests.
-mode(compile).

main([OutDir]) ->
    Root = filename:dirname(filename:dirname(filename:dirname(
                                               filename:absname(escript:script_name())))),
    Ebin = filename:join(OutDir, "ebin"),
    ok = filelib:ensure_path(Ebin),
    Sources = filelib:wildcard(filename:join(Root, "apps/beam_com*/src/*.erl")),
    Tests = filelib:wildcard(filename:join(Root, "tests/unit/*_tests.erl")),
    Opts = [debug_info, {d, 'TEST'}, {outdir, Ebin}, report, return_errors],
    [compile_or_halt(F, Opts) || F <- Sources ++ Tests],
    true = code:add_patha(Ebin),
    case os:getenv("ELIXIR_LIB") of
        Lib when is_list(Lib), Lib =/= "" ->
            [code:add_pathz(D) || D <- filelib:wildcard(filename:join(Lib, "*/ebin"))];
        _ -> ok
    end,
    cover:start(),
    Modules = [list_to_atom(filename:basename(F, ".erl")) || F <- Sources],
    [{ok, _} = cover:compile_beam(filename:join(Ebin, atom_to_list(M) ++ ".beam"))
     || M <- Modules],
    TestModules = [list_to_atom(filename:basename(F, ".erl")) || F <- Tests],
    Result = eunit:test(TestModules, [verbose]),
    io:format("~nCoverage (lines):~n"),
    Totals = [coverage(M) || M <- Modules],
    {Cov, Lines} = lists:foldl(fun({C, L}, {C0, L0}) -> {C0 + C, L0 + L} end,
                               {0, 0}, Totals),
    io:format("  ~-24s ~5.1f% (~b/~b)~n", ["total", percent(Cov, Lines), Cov, Lines]),
    HtmlDir = filename:join(OutDir, "cover"),
    ok = filelib:ensure_path(HtmlDir),
    [cover:analyse_to_file(M, filename:join(HtmlDir, atom_to_list(M) ++ ".html"),
                           [html]) || M <- Modules],
    io:format("  HTML report: ~ts~n", [HtmlDir]),
    halt(case Result of ok -> 0; _ -> 1 end);
main(_) ->
    io:format("usage: run.escript OUTDIR~n"),
    halt(2).

compile_or_halt(File, Opts) ->
    case compile:file(File, Opts) of
        {ok, _} -> ok;
        {ok, _, _} -> ok;
        _ -> io:format("compilation failed: ~ts~n", [File]), halt(1)
    end.

coverage(Module) ->
    {ok, Lines} = cover:analyse(Module, coverage, line),
    %% A line can be listed more than once (one clause per line); count
    %% each line once, as covered when one of its entries is.
    ByLine = lists:foldl(fun({{_, 0}, _}, Acc) -> Acc;
                            ({{_, L}, {C, _}}, Acc) ->
                                 maps:update_with(L, fun(V) -> V orelse C > 0 end,
                                                  C > 0, Acc)
                         end, #{}, Lines),
    Covered = length([L || L := true <- ByLine]),
    Total = map_size(ByLine),
    io:format("  ~-24s ~5.1f% (~b/~b)~n", [Module, percent(Covered, Total),
                                           Covered, Total]),
    {Covered, Total}.

percent(_, 0) -> 100.0;
percent(C, T) -> 100 * C / T.
