%% An example application for "beam.com INPUT -o OUTPUT" with generated code:
%% calc_lexer.xrl (leex), calc_parser.yrl (yecc) and asn1/Greeting.asn1
%% (the ASN.1 compiler). a build (-o) makes the .erl files itself.
%%
%%   beam.com examples/calc -o calc.com
%%   ./calc.com
-module(calc).
-export([main/0, eval/1]).

-include("Greeting.hrl").

main() ->
    Expr = "1 + 2 * (3 - 1) - 8 / 4",
    io:format("calc: ~s = ~p~n", [Expr, eval(Expr)]),
    {ok, Ber} = 'Greeting':encode('Hello', #'Hello'{name = "BEAM", count = 3}),
    io:format("calc: asn1 ber ~s~n", [hex(Ber)]),
    {ok, #'Hello'{name = Name, count = Count}} = 'Greeting':decode('Hello', Ber),
    io:format("calc: asn1 decoded ~s ~p~n", [Name, Count]),
    init:stop().

%% Scan, parse and evaluate an expression.
eval(String) ->
    {ok, Tokens, _} = calc_lexer:string(String),
    {ok, Tree} = calc_parser:parse(Tokens),
    value(Tree).

value({Op, A, B}) ->
    case Op of
        '+' -> value(A) + value(B);
        '-' -> value(A) - value(B);
        '*' -> value(A) * value(B);
        '/' -> value(A) div value(B)
    end;
value(N) when is_integer(N) ->
    N.

hex(Bin) ->
    << <<(hex_digit(N))>> || <<N:4>> <= Bin >>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + N - 10.
