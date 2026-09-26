-module(toolbox_english).
-behaviour(toolbox_greeter).
-export([greet/1]).
greet(Name) -> "Hello, " ++ Name.
