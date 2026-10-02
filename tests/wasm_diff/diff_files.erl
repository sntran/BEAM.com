%% Files in the directory of the first argument. The program prints no
%% path and no time.
-module(diff_files).
-export([main/1]).

main([Dir]) ->
    D = filename:join(Dir, "files"),
    ok = file:make_dir(D),
    F = filename:join(D, "a.txt"),
    Lines = [integer_to_list(N) ++ " ü\n" || N <- lists:seq(1, 500)],
    ok = file:write_file(F, Lines),
    {ok, Bin} = file:read_file(F),
    p(read, [byte_size(Bin), erlang:md5(Bin)]),
    {ok, Io} = file:open(F, [read, binary]),
    First = [io:get_line(Io, "") || _ <- lists:seq(1, 3)],
    {ok, Pos} = file:position(Io, {eof, -7}),
    Tail = io:get_chars(Io, "", 3),
    ok = file:close(Io),
    p(lines, [First, Pos, Tail]),
    {ok, W} = file:open(F, [read, write, raw, binary]),
    ok = file:pwrite(W, 2, <<"XY">>),
    {ok, Got} = file:pread(W, 0, 6),
    ok = file:close(W),
    p(pwrite, Got),
    ok = file:write_file(filename:join(D, "b.bin"), <<0, 1, 2>>, [append]),
    ok = file:write_file(filename:join(D, "b.bin"), <<3>>, [append]),
    ok = file:make_dir(filename:join(D, "sub")),
    ok = file:rename(filename:join(D, "b.bin"), filename:join([D, "sub", "c.bin"])),
    {ok, Names} = file:list_dir(D),
    p(list, lists:sort(Names)),
    {ok, Info} = file:read_file_info(filename:join([D, "sub", "c.bin"])),
    p(info, [element(2, Info), element(3, Info)]),
    p(missing, [file:read_file(filename:join(D, "none")), file:del_dir(filename:join(D, "sub"))]),
    ok = file:delete(filename:join([D, "sub", "c.bin"])),
    ok = file:del_dir(filename:join(D, "sub")),
    p(wildcard, [filename:basename(N) || N <- filelib:wildcard(filename:join(D, "*"))]),
    p(names, [filename:join(["a", "../b", "c.erl"]), filename:rootname("x/y.tar.gz"),
              filename:extension("y.tar.gz"), filename:split("/a//b/c/"),
              filename:absname_join("/r", "s"), filename:basedir(user_cache, "app", #{os => linux})
              =/= ""]),
    {ok, Ram} = file:open(<<"ram text">>, [ram, read, binary]),
    p(ram, file:read(Ram, 3));
main(_) ->
    io:format("usage: diff_files DIR~n").

p(Label, Term) ->
    io:format("~s: ~w~n", [Label, Term]).
