%% A source of Mix (the callbacks of Mix.SCM) for the git deps of an
%% https or SSH URL, with the git client of beam.com (beam_com_git) and no
%% git program. The child of beam_com_mix puts it before Mix.SCM.Git when
%% PATH has no git, or when BEAM_COM_GIT is "client".
%%
%% It accepts the options of Mix.SCM.Git (git, github, ref, branch, tag,
%% sparse, subdir, depth), and its lock entries are the entries of
%% Mix.SCM.Git: {git, URL, COMMIT, OPTIONS}. Thus mix.lock is the same
%% with git and with no git. A git dep of another URL (for example
%% git://, or a path) goes to Mix.SCM.Git, which needs the git program.
-module(beam_com_git_scm).

-export(['fetchable?'/0, format/1, format_lock/1, accepts_options/2, 'checked_out?'/1,
         lock_status/1, 'equal?'/2, managers/1, checkout/1, update/1]).

-ifdef(TEST).
-export([lock_opts/1, lock_rev/2, rev_spec/1, checkout_info/1]).
-endif.

'fetchable?'() ->
    true.

%% The text and the options of Mix.SCM.Git, which are pure functions.
format(Opts) ->
    'Elixir.Mix.SCM.Git':format(Opts).

format_lock(Opts) ->
    'Elixir.Mix.SCM.Git':format_lock(Opts).

'equal?'(Opts1, Opts2) ->
    'Elixir.Mix.SCM.Git':'equal?'(Opts1, Opts2).

accepts_options(App, Opts) ->
    case 'Elixir.Mix.SCM.Git':accepts_options(App, Opts) of
        nil -> nil;
        Accepted ->
            Url = unicode:characters_to_list(proplists:get_value(git, Accepted)),
            case uri_string:parse(Url) of
                #{scheme := "https"} -> Accepted;
                _ ->
                    case beam_com_git_ssh:is_ssh(Url) of
                        true -> Accepted;
                        false -> nil
                    end
            end
    end.

managers(_Opts) ->
    [].

%% A checkout of beam_com_git (and of git) has .git/HEAD.
'checked_out?'(Opts) ->
    filelib:is_regular(filename:join([proplists:get_value(checkout, Opts), ".git", "HEAD"])).

lock_status(Opts) ->
    Lock = proplists:get_value(lock, Opts),
    case lock_rev(Lock, Opts) of
        nil when Lock =:= nil -> mismatch;
        nil -> outdated;
        Rev ->
            {git, Repo, _, _} = Lock,
            case checkout_info(proplists:get_value(checkout, Opts)) of
                {Repo, Rev} -> ok;
                _ -> mismatch
            end
    end.

checkout(Opts) ->
    Shell = 'Elixir.Mix':shell(),
    Shell:print_app(),
    Url = proplists:get_value(git, Opts),
    Dir = unicode:characters_to_list(proplists:get_value(checkout, Opts)),
    _ = file:del_dir_r(Dir),
    try
        Rev = case lock_rev(proplists:get_value(lock, Opts), Opts) of
                  nil -> beam_com_git:resolve(Url, rev_spec(Opts), #{});
                  Locked -> Locked
              end,
        Objects = beam_com_git:fetch(Url, Rev, #{}),
        ok = beam_com_git:checkout(Objects, Rev, Dir,
                                   #{url => Url,
                                     sparse => case proplists:get_value(sparse, Opts) of
                                                   undefined -> none;
                                                   Sparse -> unicode:characters_to_list(Sparse)
                                               end,
                                     submodules => proplists:get_value(submodules, Opts, false)
                                         =:= true}),
        ok = filelib:ensure_path(unicode:characters_to_list(proplists:get_value(dest, Opts))),
        {git, Url, Rev, lock_opts(Opts)}
    catch
        throw:{error, Format, Args} ->
            'Elixir.Mix':raise(unicode:characters_to_binary(
                                 io_lib:format("~ts (the git client of beam.com): " ++ Format,
                                               [proplists:get_value(dest, Opts) | Args])))
    end.

update(Opts) ->
    checkout(Opts).

%% The options of the lock entry, as Mix.SCM.Git keeps them.
lock_opts(Opts) ->
    [{K, V} || {K, V} <- Opts, lists:member(K, [branch, ref, tag, sparse, subdir, depth])]
        ++ [{submodules, true} || proplists:get_value(submodules, Opts, false) =:= true].

%% The commit of the lock when the lock is for these options.
lock_rev({git, Repo, Rev, LockOpts}, Opts) when is_binary(Rev) ->
    case Repo =:= proplists:get_value(git, Opts) andalso LockOpts =:= lock_opts(Opts) of
        true -> Rev;
        false -> nil
    end;
lock_rev(_Lock, _Opts) ->
    nil.

rev_spec(Opts) ->
    case [{K, unicode:characters_to_list(V)} || {K, V} <- Opts, lists:member(K, [branch, tag, ref])] of
        [Spec | _] -> Spec;
        [] -> head
    end.

%% The URL and the commit of a checkout: .git/config and .git/HEAD.
checkout_info(Dir) ->
    Git = filename:join(Dir, ".git"),
    case {file:read_file(filename:join(Git, "config")), file:read_file(filename:join(Git, "HEAD"))} of
        {{ok, Config}, {ok, Head}} ->
            case re:run(Config, "^\\s*url = (.*)$", [multiline, {capture, all_but_first, binary}]) of
                {match, [Url]} -> {string:trim(Url), string:trim(Head)};
                nomatch -> none
            end;
        _ ->
            none
    end.
