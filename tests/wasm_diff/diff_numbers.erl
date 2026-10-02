%% Integers and floats. The output must be the same in each runtime.
-module(diff_numbers).
-export([main/1]).

main(_Dir) ->
    Big = 1 bsl 200 + 12345,
    p(bignum, [Big * Big, Big div 7, Big rem 7, -Big div 3, -Big rem 3,
               Big bsr 100, -Big bsr 100, Big band 16#FFFF, Big bxor (Big - 1)]),
    %% The boundary of a small integer is 2^27 or 2^59, by the word size.
    Edges = [1 bsl N + D || N <- [27, 28, 31, 32, 59, 60, 63, 64], D <- [-1, 0, 1]],
    p(edges, [{E, -E, E * E, E + E, E - (E + 1)} || E <- Edges]),
    p(bases, [integer_to_list(Big, B) || B <- [2, 16, 36]]),
    p(from_text, [list_to_integer("-123456789012345678901234567890"),
                  binary_to_integer(<<"zz">>, 36)]),
    p(pow, [pow(3, 100), pow(-7, 33)]),
    Floats = [0.1 + 0.2, 5.0e-324, 2.2250738585072014e-308,
              1 / 3, 2.0e22, 123456789.125, -0.0, 1.0e16, 9007199254740993.0],
    p(floats, Floats),
    p(float_text, [float_to_list(F) || F <- Floats, abs(F) < 1.0e300]),
    p(float_fmt, [{float_to_list(1 / 3, [{decimals, 10}]),
                   float_to_list(1 / 3, [{scientific, 12}]),
                   float_to_binary(123.5, [short]),
                   io_lib:format("~.3f ~e ~g", [2.675, 1.0e-10, 31415.9])}]),
    p(parse, [list_to_float("1.5e-7"), binary_to_float(<<"-2.5e300">>),
              list_to_float("0.30000000000000004")]),
    p(round, [{round(X), trunc(X), floor(X), ceil(X)} || X <- [2.5, -2.5, 3.5, -0.5, 1.0e20]]),
    p(sqrt, [math:sqrt(X) || X <- [2, 1.0e-300, 1.0e300, 0.5]]),
    p(math, [io_lib:format("~.10e", [F]) ||
                F <- [math:sin(1.0), math:cos(2.0), math:exp(10.0), math:log(3.0),
                      math:pow(2.0, 0.5), math:atan2(1.0, -1.0), math:log2(1000.0)]]),
    p(mixed, [1 == 1.0, 1 =:= 1.0, 1 < 1.0, Big > 1.0e60, Big < 1.0e61,
              float(Big), round(float(Big)) - Big]),
    p(errors, [catch_it(fun() -> 1 / o(0) end), catch_it(fun() -> math:log(o(-1)) end),
               catch_it(fun() -> list_to_float(o("1")) end),
               catch_it(fun() -> o(1.0e308) * 10 end)]).

pow(_, 0) -> 1;
pow(B, N) -> B * pow(B, N - 1).

%% The compiler cannot see the value, so it gives no warning.
o(X) -> binary_to_term(term_to_binary(X)).

catch_it(F) ->
    try F() catch C:R -> {C, R} end.

p(Label, Term) ->
    io:format("~s: ~w~n", [Label, Term]).
