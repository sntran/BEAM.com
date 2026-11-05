/*
 * An object for priv/missing.ARCH.o of native_nif_check: it needs a
 * function that the program does not have, so load_nif/2 fails and its
 * error names the function.
 */
#include <erl_nif.h>

extern int no_such_function(int);

static ERL_NIF_TERM call(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    return enif_make_int(env, no_such_function(1));
}

static ErlNifFunc funcs[] = { { "load", 1, call, 0 } };

ERL_NIF_INIT(native_nif_check_other, funcs, NULL, NULL, NULL, NULL)
