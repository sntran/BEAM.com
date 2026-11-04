/*
 * The thread-local data of native_nif_check.c: the models of cosmocc
 * (local exec, initial exec), and the models of Rust in
 * native_nif_check_tls.S (general and local dynamic on x86_64, TLS
 * descriptors on aarch64).
 */
static _Thread_local int t_checked;
static _Thread_local int t_value = 5;
static _Thread_local char t_zeros[64];
extern _Thread_local int nc_t_ie;
int nc_t_gd(void);
int nc_t_ld(void);
int nc_t_big_end(void);

/* The first call in a thread: each variable has its initial value, then
 * the thread changes its own copy. Gives 0, or the number of the check
 * that failed. A later call in the same thread gives 0. */
int tls_check_thread(void)
{
    int i;
    if (t_checked)
        return 0;
    t_checked = 1;
    if (t_value != 5)
        return 1;
    for (i = 0; i < (int)sizeof(t_zeros); i++)
        if (t_zeros[i])
            return 2;
    if (nc_t_ie != 43)
        return 3;
    if (nc_t_gd() != 41)
        return 4;
    if (nc_t_ld() != 42)
        return 5;
    if (nc_t_big_end() != 0)
        return 6;
    t_value = 6;
    t_zeros[3] = 1;
    nc_t_ie = 44;
    if (nc_t_gd() != 42 || nc_t_ld() != 43 || t_value != 6)
        return 7;
    return 0;
}
