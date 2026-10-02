%% The base path of a web app: the path of the site where the app is, for
%% example /REPO/app on GitHub Pages. The service worker of the page
%% (priv/wasm_host/page/sw.js) gives the VM the path without the prefix, as
%% a proxy does. So the app must make its links with the prefix: set/0 puts
%% BEAM_BASE_PATH in url: [path: ...] of each Phoenix endpoint, with no
%% change in the code of the app.
%%
%% The boot script calls set/0 after the config providers (runtime.exs), so
%% that runtime.exs does not replace the path, and before the applications
%% of the program start (beam_com_wasm:with_host/2).
-module(wasm_host_base).

-export([set/0, url_path/2]).

-ifdef(TEST).
-export([set/1, endpoint/1]).
-endif.

%% With no BEAM_BASE_PATH (or an empty one), no change.
set() ->
    set(os:getenv("BEAM_BASE_PATH", "")).

set("") ->
    ok;
set(Path) ->
    _ = [case url_path(proplists:get_value(url, Config, []), Path) of
             {ok, Url} ->
                 application:set_env(App, Mod, lists:keystore(url, 1, Config, {url, Url}),
                                     [{persistent, true}]);
             {error, Reason} ->
                 erlang:error(Reason)
         end
         || {App, _, _} <- application:loaded_applications(),
            {Mod, Config} <- application:get_all_env(App),
            is_list(Config), endpoint(Mod)],
    ok.

%% The url keyword list of an endpoint with the path Path. The other keys
%% stay. Path starts with "/", and has no query, no fragment, no "//" and
%% no "/" at the end (but "/" itself).
url_path(Url, Path) when is_list(Url) ->
    case is_path(Path) of
        true -> {ok, lists:keystore(path, 1, Url, {path, unicode:characters_to_binary(Path)})};
        false -> {error, {bad_base_path, Path}}
    end;
url_path(_Url, Path) ->
    url_path([], Path).

is_path("/") ->
    true;
is_path([$/ | _] = Path) ->
    io_lib:printable_unicode_list(Path)
        andalso lists:last(Path) =/= $/
        andalso string:find(Path, "//") =:= nomatch
        andalso uri_string:parse(Path) =:= #{path => Path};
is_path(_) ->
    false.

%% An Elixir module with the behaviour Phoenix.Endpoint. The code path of
%% the boot has the module, so it loads here.
endpoint(Mod) when is_atom(Mod) ->
    lists:prefix("Elixir.", atom_to_list(Mod))
        andalso code:ensure_loaded(Mod) =:= {module, Mod}
        andalso lists:member('Elixir.Phoenix.Endpoint',
                             proplists:get_value(behaviour, Mod:module_info(attributes), []));
endpoint(_) ->
    false.
