%% A module that loads the NIF library of nif_check (docs/NIFS.md): ERTS
%% refuses it (bad_lib: the library is for nif_check), after the loader
%% of beam.com loaded the module of the library. nif_check:run/0 checks
%% that the loader then frees it.
-module(nif_check_other).
-export([load/1]).

load(Path) ->
    erlang:load_nif(Path, 0).
