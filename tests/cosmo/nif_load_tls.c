/*
 * The thread-local data of a test object of tests/cosmo/nif_load_check.c,
 * as cosmocc compiles it: local exec (t_value, t_zero) and initial exec
 * (t_ie of nif_load_tls_asm.S, an other file of the object). The models of
 * Rust (general and local dynamic, TLS descriptors) are in
 * nif_load_tls_asm.S.
 */
static _Thread_local int t_value = 3;
static _Thread_local char t_zero[100];
extern _Thread_local int t_ie;
static int t_constructed;

/* A constructor uses the data of the thread that loads. */
__attribute__((constructor)) static void t_init(void)
{
    t_constructed = ++t_value;
}

int t_get(void)
{
    return ++t_value;
}

int t_constructor_value(void)
{
    return t_constructed;
}

/* The sum of t_zero, then a write of each byte. */
int t_zero_sum(int fill)
{
    int i, sum = 0;
    for (i = 0; i < (int)sizeof(t_zero); i++) {
        sum += t_zero[i];
        t_zero[i] = (char)fill;
    }
    return sum;
}

int t_ie_get(void)
{
    return t_ie++;
}

void *t_address(void)
{
    return &t_value;
}
