%% The module Rustler of Elixir, for the NIFs of Rust that are linked into
%% beam.com (see beam_com_rustler). It has only the macro __using__/1:
%% "use Rustler, otp_app: ..., crate: ..." loads the linked NIF, and
%% runs no cargo. The package rustler, when a project has it, comes
%% first in the code path, and its module is used.
-module('Elixir.Rustler').

-export(['__info__'/1, 'MACRO-__using__'/2]).

'__info__'(module) -> ?MODULE;
'__info__'(functions) -> [];
'__info__'(macros) -> [{'__using__', 1}];
'__info__'(attributes) -> [];
'__info__'(compile) -> [];
'__info__'(md5) -> undefined;
'__info__'(struct) -> nil;
'__info__'(exports_md5) -> undefined;
'__info__'(deprecated) -> [].

'MACRO-__using__'(_Caller, Opts) ->
    beam_com_rustler:using(Opts).
