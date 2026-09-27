%% A behaviour of the application itself: a build (-o) compiles it
%% before the modules that use it.
-module(toolbox_greeter).
-callback greet(Name :: string()) -> string().
