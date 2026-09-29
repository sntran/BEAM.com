%% The scanner of calc (leex).
Definitions.

D  = [0-9]
WS = [\s\t\n]

Rules.

{D}+     : {token, {int, TokenLine, list_to_integer(TokenChars)}}.
[-+*/()] : {token, {list_to_atom(TokenChars), TokenLine}}.
{WS}+    : skip_token.

Erlang code.
