/*
 * An object with more thread-local data than the TLS area of the
 * modules (beam_com_nif.c): the load fails with an error.
 */
_Thread_local char t_big[40000];

int t_big_get(int i)
{
    return t_big[i];
}
