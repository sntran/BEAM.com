/*
 * An object with thread-local data, for tests/cosmo/nif_load_check.c: the
 * loader does not support it yet, and refuses it with a clear error.
 */
static _Thread_local int t_value = 3;

int t_get(void)
{
    return ++t_value;
}
