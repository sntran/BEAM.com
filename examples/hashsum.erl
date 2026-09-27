%% A one-file program for "beam.com INPUT -o OUTPUT": prints the SHA-256 of each
%% argument, as sha256sum does for files.
%%
%%   beam.com hashsum.erl -o hashsum.com
%%   ./hashsum.com abc
%%
%% It calls crypto, so the builder adds the crypto application.
-module(hashsum).
-export([main/1]).

main([]) ->
    io:format(standard_error, "usage: hashsum TEXT...~n", []),
    halt(2);
main(Args) ->
    [io:format("~s  ~ts~n", [hex(crypto:hash(sha256, Arg)), Arg])
     || Arg <- Args],
    ok.

hex(Bin) ->
    [io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin].
