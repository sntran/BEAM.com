%% A behaviour of the application itself: beam.com build compiles it
%% before the modules that use it.
-module(toolbox_greeter).
-callback greet(Name :: string()) -> string().
