%% The parser of calc (yecc).
Nonterminals expr.
Terminals int '+' '-' '*' '/' '(' ')'.
Rootsymbol expr.

Left 100 '+' '-'.
Left 200 '*' '/'.

expr -> expr '+' expr : {'+', '$1', '$3'}.
expr -> expr '-' expr : {'-', '$1', '$3'}.
expr -> expr '*' expr : {'*', '$1', '$3'}.
expr -> expr '/' expr : {'/', '$1', '$3'}.
expr -> '(' expr ')'  : '$2'.
expr -> int           : element(3, '$1').
