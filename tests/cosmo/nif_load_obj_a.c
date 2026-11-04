/*
 * The first part of the test object of tests/cosmo/nif_load_check.c: code
 * of cosmocc with each kind of relocation that a NIF object has. `ld -r`
 * joins it with nif_load_obj_b.c, as the static library of a NIF.
 */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The program (the check) gives these. */
extern int host_add(int a, int b);
extern int host_value;
extern int host_missing(void) __attribute__((weak));

/* nif_load_obj_b.c gives these. */
extern int b_twice(int x);
extern const char *b_name(void);
extern int b_counter;

int a_global = 41;
static int a_table[8] = { 3, 1, 4, 1, 5, 9, 2, 6 };
static char a_buffer[1 << 20]; /* 1 MiB of .bss */
int a_common_like;             /* a zero global */
static int a_order[4];
static int a_order_n;

__attribute__((constructor(101))) static void a_first(void) { a_order[a_order_n++] = 1; }
__attribute__((constructor(102))) static void a_second(void) { a_order[a_order_n++] = 2; }
__attribute__((constructor)) static void a_last(void) { a_order[a_order_n++] = 3; }

/* The constructors ran in the order of their priorities. */
int a_constructors(void)
{
    return a_order_n == 3 && a_order[0] == 1 && a_order[1] == 2 && a_order[2] == 3;
}

/* A switch with a jump table (R_X86_64_32S on x86_64). */
int a_switch(int x)
{
    switch (x) {
    case 0: return 10;
    case 1: return 21;
    case 2: return 32;
    case 3: return 43;
    case 4: return 54;
    case 5: return 65;
    case 6: return 76;
    case 7: return 87;
    default: return -1;
    }
}

/* The values of Cosmopolitan that change with the system: data of the
 * program, read with PC-relative relocations. */
int a_errno_values(int *einval, int *ocreat)
{
    *einval = EINVAL;
    *ocreat = O_CREAT;
    errno = ERANGE;
    return errno == ERANGE;
}

/* Calls of the libc, and strings of .rodata. */
int a_format(char *out, size_t size, int n)
{
    snprintf(out, size, "n=%d len=%d", n, (int)strlen("abcdef"));
    return (int)strlen(out);
}

static int cmp_int(const void *x, const void *y)
{
    return *(const int *)x - *(const int *)y;
}

/* A function of the module that the libc calls back. */
int a_sort(void)
{
    int v[8], i;
    memcpy(v, a_table, sizeof(v));
    qsort(v, 8, sizeof(int), cmp_int);
    for (i = 1; i < 8; i++)
        if (v[i - 1] > v[i])
            return 0;
    return v[0] == 1 && v[7] == 9;
}

/* Functions of the module in a table of pointers (R_X86_64_64). */
static int f_inc(int x) { return x + 1; }
static int f_dbl(int x) { return x * 2; }
static int f_neg(int x) { return -x; }
static int (*const a_funcs[3])(int) = { f_inc, f_dbl, f_neg };

int a_call_table(int i, int x)
{
    return i >= 0 && i < 3 ? a_funcs[i](x) : 0;
}

/* Calls and data of the program. */
int a_host(void)
{
    host_value += 1;
    return host_add(host_value, 100);
}

/* A weak symbol that the program does not have: NULL. */
int a_weak_is_null(void)
{
    return host_missing == NULL;
}

/* Calls and data of the other part of the object. */
int a_other_part(void)
{
    b_counter++;
    return b_twice(a_global) + (int)strlen(b_name()) + b_counter * 1000;
}

/* .bss: zero, and writable. */
int a_bss(void)
{
    size_t i;
    for (i = 0; i < sizeof(a_buffer); i++)
        if (a_buffer[i])
            return 0;
    memset(a_buffer, 7, sizeof(a_buffer));
    return a_buffer[sizeof(a_buffer) - 1] == 7 && a_common_like == 0;
}

/* Floating point: constants of .rodata and libm. */
double a_float(double x)
{
    return sqrt(x) * 1.5 + pow(2.0, 10.0) + floor(2.75);
}

/* The data of one load is not the data of an other load. */
int a_bump(void)
{
    return ++a_global;
}

/* malloc() and free() of the program. */
int a_heap(void)
{
    char *p = malloc(4096);
    int ok;
    if (!p)
        return 0;
    memset(p, 'x', 4096);
    ok = p[4095] == 'x';
    free(p);
    return ok;
}
