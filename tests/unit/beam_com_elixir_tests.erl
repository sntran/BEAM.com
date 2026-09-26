%% Unit tests for beam_com_elixir: one-file programs, mix.exs, and
%% config/config.exs. They need Elixir in the code path (ELIXIR_LIB, see
%% run.escript); without it they are skipped.
-module(beam_com_elixir_tests).

-include_lib("eunit/include/eunit.hrl").

elixir_test_() ->
    case beam_com_elixir:available() of
        false ->
            [];
        true ->
            {setup, fun tmp/0, fun rm/1,
             fun(Dir) ->
                     [{"a one-file program", {timeout, 120, fun() -> script(Dir) end}},
                      {"one-file errors", {timeout, 120, fun() -> script_errors(Dir) end}},
                      {"mix.exs", {timeout, 120, fun() -> mix_project(Dir) end}},
                      {"the deps of mix.exs", fun deps/0},
                      {"config/config.exs", {timeout, 60, fun() -> config(Dir) end}}]
             end}
    end.

script(Dir) ->
    F = write(Dir, "two.ex",
              "defmodule Two.Helper do\n  def up(s), do: String.upcase(s)\nend\n"
              "defmodule Two do\n  def main(args), do: Enum.map(args, &Two.Helper.up/1)\nend\n"),
    #{beams := Beams, main := Main} = silent(fun() -> beam_com_elixir:script(F) end),
    ?assertEqual('Elixir.Two', Main),
    ?assertEqual(['Elixir.Two', 'Elixir.Two.Helper'], lists:sort([M || {M, _} <- Beams])),
    [{module, M} = code:load_binary(M, atom_to_list(M) ++ ".beam", B) || {M, B} <- Beams],
    ?assertEqual([<<"A">>, <<"B">>], 'Elixir.Two':main([<<"a">>, <<"b">>])),
    [code:purge(M) andalso code:delete(M) || {M, _} <- Beams].

script_errors(Dir) ->
    NoMain = write(Dir, "nomain.exs", "defmodule NoMain do\n  def f, do: 1\nend\n"),
    ?assertThrow({error, "~ts: no module exports main/1", [NoMain]},
                 silent(fun() -> beam_com_elixir:script(NoMain) end)),
    Two = write(Dir, "mains.ex", "defmodule MainA do\n  def main(_), do: :a\nend\n"
                "defmodule MainB do\n  def main(_), do: :b\nend\n"),
    ?assertThrow({error, "~ts: more than one module exports main/1: ~ts", [Two, _]},
                 silent(fun() -> beam_com_elixir:script(Two) end)),
    Bad = write(Dir, "bad.ex", "defmodule Bad do\n  def main(_), do: undefined_thing()\nend\n"),
    ?assertThrow({error, "~ts: Elixir compilation failed", [Bad]},
                 silent(fun() -> beam_com_elixir:script(Bad) end)),
    ?assertThrow({error, "~ts: no such file", ["none.ex"]}, beam_com_elixir:script("none.ex")).

mix_project(Dir) ->
    D = filename:join(Dir, "proj"),
    write(D, "mix.exs",
          "defmodule Proj.MixProject do\n  use Mix.Project\n"
          "  def project, do: [app: :proj, version: \"2.1.0\", deps: deps(),\n"
          "                    elixirc_paths: [\"lib\", \"more\"],\n"
          "                    escript: [main_module: Proj.CLI],\n"
          "                    start_permanent: Mix.env() == :prod]\n"
          "  def application, do: [mod: {Proj.App, []}, extra_applications: [:logger]]\n"
          "  defp deps, do: [{:jason, \"~> 1.4\"}, {:ex_doc, \">= 0.0.0\", only: :dev}]\n"
          "end\n"),
    ?assert(beam_com_elixir:is_mix(D)),
    ?assertNot(beam_com_elixir:is_mix(Dir)),
    P = beam_com_elixir:mix_project(D),
    ?assertMatch(#{app := proj, version := "2.1.0", elixirc_paths := ["lib", "more"],
                   erlc_paths := ["src"], deps := [{jason, <<"jason">>, "~> 1.4"}],
                   runtime_deps := [jason], escript := [{main_module, 'Elixir.Proj.CLI'}]}, P),
    #{application := App} = P,
    ?assertEqual({'Elixir.Proj.App', []}, proplists:get_value(mod, App)),
    %% The module of mix.exs is not left loaded; a second read works.
    ?assertEqual(false, code:is_loaded('Elixir.Proj.MixProject')),
    ?assertMatch(#{app := proj}, beam_com_elixir:mix_project(D)),
    Bad = filename:join(Dir, "badproj"),
    write(Bad, "mix.exs", "defmodule Bad.MixProject do\n  def project, do: raise \"boom\"\nend\n"),
    ?assertThrow({error, "~ts: ~ts", [_, _]}, beam_com_elixir:mix_project(Bad)).

deps() ->
    D = fun(Deps) -> beam_com_elixir:mix_deps(Deps) end,
    ?assertEqual([{a, <<"a">>, "~> 1.0", true}], D([{a, <<"~> 1.0">>}])),
    ?assertEqual([{b, <<"b">>, any, true}], D([{b, []}])),
    ?assertEqual([{c, <<"c_pkg">>, "1.0.0", false}],
                 D([{c, <<"1.0.0">>, [{hex, c_pkg}, {runtime, false}]}])),
    ?assertEqual([], D([{t, <<"~> 1.0">>, [{only, test}]},
                        {o, <<"~> 1.0">>, [{optional, true}]},
                        {dt, <<"~> 1.0">>, [{only, [dev, test]}]}])),
    ?assertEqual([{p, <<"p">>, "~> 1.0", true}], D([{p, <<"~> 1.0">>, [{only, [dev, prod]}]}])),
    ?assertThrow({error, "the dependency ~p is not a Hex package (~p; only Hex "
                  "packages are supported)", [g, git]},
                 D([{g, [{git, <<"https://example.com/g.git">>}]}])),
    ?assertThrow({error, "the dependency ~p is not a Hex package (~p; only Hex "
                  "packages are supported)", [l, path]},
                 D([{l, [{path, <<"../l">>}]}])).

config(Dir) ->
    D = filename:join(Dir, "cfg"),
    ?assertEqual(none, beam_com_elixir:sys_config(D)),
    write(filename:join(D, "config"), "config.exs",
          "import Config\nconfig :cfg, greeting: \"hi\", n: 2\n"
          "if config_env() == :prod, do: config(:cfg, env: :prod)\n"),
    Text = beam_com_elixir:sys_config(D),
    {ok, Tokens, _} = erl_scan:string(lists:flatten(Text)),
    {ok, Terms} = erl_parse:parse_term(Tokens),
    ?assertEqual([{cfg, [{env, prod}, {greeting, <<"hi">>}, {n, 2}]}],
                 [{A, lists:sort(KV)} || {A, KV} <- Terms]).

%%% Helpers

tmp() ->
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; T -> T end,
    Dir = filename:join(Base, "beam_com_elixir_tests." ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_path(Dir),
    Dir.

rm(Dir) -> file:del_dir_r(Dir).

write(Dir, Name, Content) ->
    ok = filelib:ensure_path(Dir),
    File = filename:join(Dir, Name),
    ok = file:write_file(File, Content),
    File.

silent(F) ->
    {ok, Dev} = file:open("/dev/null", [write]),
    Old = group_leader(),
    group_leader(Dev, self()),
    try F() after group_leader(Old, self()), file:close(Dev) end.
