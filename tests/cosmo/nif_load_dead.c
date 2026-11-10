/*
 * An object of tests/cosmo/nif_load_check.c with a dead function (no live
 * section names it) that calls a function and reads a variable that the
 * program does not have. The loader removes the dead sections, as
 * "ld --gc-sections" does, so the object loads. Compiled with
 * -ffunction-sections and -fdata-sections, as the code of Rust is, and
 * with one global name (dead_live), as scripts/rust_link.sh makes the
 * object of a NIF.
 */
extern int dead_missing_function(int);
extern int dead_missing_data;

int dead_function(int x)
{
    return dead_missing_function(x) + dead_missing_data;
}

const char dead_table[200000] = { 1, 2, 3 };

static int live_helper(int x)
{
    return x * 3;
}

int dead_live(int x)
{
    return live_helper(x) + 1;
}
