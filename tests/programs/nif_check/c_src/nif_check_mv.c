/*
 * A function with four results for the test NIF four_results of
 * nif_check.c: build.sh compiles this file with the multi-value ABI, so
 * a struct of four terms is four i32 results. The bridge reads one result
 * of a NIF, so it must refuse this type: WAMR writes all the results into
 * the arguments of the call, past their end.
 */
#include "erl_nif.h"

typedef struct {
    ERL_NIF_TERM a, b, c, d;
} four_terms;

static four_terms four_results(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    four_terms r = { 1, 1, 1, 1 };
    (void)env;
    (void)argc;
    (void)argv;
    return r;
}

/* The function as a value, so that nif_check.c needs no declaration of
 * its type (an other ABI there). */
void (*const nif_check_four_results)(void) = (void (*)(void))four_results;
