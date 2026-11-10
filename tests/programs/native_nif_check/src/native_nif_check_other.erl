%% A module that loads the native NIF objects of native_nif_check
%% (docs/NIFS.md): the object of native_nif_check, which ERTS refuses
%% (bad_lib: the object is for native_nif_check), and the broken objects
%% of priv/.
-module(native_nif_check_other).
-export([load/1]).

load(Path) ->
    erlang:load_nif(Path, 0).
