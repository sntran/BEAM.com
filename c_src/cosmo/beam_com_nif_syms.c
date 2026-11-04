/*
 * BEAM.com: the table of the symbols of the program that a native NIF
 * object can use (beam_com_nif.c): each function enif_* of
 * erl_nif_api_funcs.h of this OTP, and the symbols of the libc of
 * beam_com_nif_libc.h.
 *
 * Each name is only an address here: extern char bcn_sym_NAME, with the
 * assembler name NAME. The declarations need no types, and they do not
 * conflict with the headers that the build of ERTS includes in each file.
 */
#include <stddef.h>

void *beam_com_nif_lookup(const char *name);

#define SIZEOF_LONG 8
/* The header ends with inline functions of the types of erl_nif.h, when
 * the compiler is GCC and the system is not Windows. _WIN32_ selects the
 * form with macros, which needs no types. */
#define _WIN32_
#define ERL_NIF_API_FUNC_DECL(RET, NAME, ARGS) extern char bcn_sym_##NAME __asm__(#NAME)
#include "erl_nif_api_funcs.h"
#undef ERL_NIF_API_FUNC_DECL

#define NIF_LIBC(NAME) extern char bcn_sym_##NAME __asm__(#NAME);
#define NIF_LIBC_IFUNC(NAME)
#include "beam_com_nif_libc.h"
#undef NIF_LIBC
#undef NIF_LIBC_IFUNC

/* The functions for the IFUNC symbols (beam_com_nif_libc.h): a call of
 * the symbol, never its address. */
static char *nif_strcpy(char *d, const char *s) { return __builtin_strcpy(d, s); }
static char *nif_strstr(const char *h, const char *n) { return __builtin_strstr(h, n); }

struct nif_sym {
    const char *name;
    const void *addr;
};

/* One member of one byte for each name: the size of the struct is the
 * count of the names. */
struct nif_names {
#define ERL_NIF_API_FUNC_DECL(RET, NAME, ARGS) char NAME##_
#include "erl_nif_api_funcs.h"
#undef ERL_NIF_API_FUNC_DECL
#define NIF_LIBC(NAME) char NAME##_;
#define NIF_LIBC_IFUNC(NAME) char NAME##_;
#include "beam_com_nif_libc.h"
#undef NIF_LIBC
#undef NIF_LIBC_IFUNC
};

static struct nif_sym table[sizeof(struct nif_names)];
static size_t count;

static int strcmp_(const char *a, const char *b)
{
    while (*a && *a == *b)
        a++, b++;
    return (unsigned char)*a - (unsigned char)*b;
}

static void add(const char *name, const void *addr)
{
    if (count < sizeof(table) / sizeof(table[0])) {
        table[count].name = name;
        table[count].addr = addr;
        count++;
    }
}

/* The table, sorted by name for the search (insertion sort: it runs one
 * time, on less than 1000 names). */
static void fill(void)
{
    size_t i, j;
#define ERL_NIF_API_FUNC_DECL(RET, NAME, ARGS) add(#NAME, &bcn_sym_##NAME)
#include "erl_nif_api_funcs.h"
#undef ERL_NIF_API_FUNC_DECL
#define NIF_LIBC(NAME) add(#NAME, &bcn_sym_##NAME);
#define NIF_LIBC_IFUNC(NAME) add(#NAME, (const void *)nif_##NAME);
#include "beam_com_nif_libc.h"
#undef NIF_LIBC
#undef NIF_LIBC_IFUNC
#undef _WIN32_
    for (i = 1; i < count; i++) {
        struct nif_sym s = table[i];
        for (j = i; j > 0 && strcmp_(table[j - 1].name, s.name) > 0; j--)
            table[j] = table[j - 1];
        table[j] = s;
    }
}

void *beam_com_nif_lookup(const char *name)
{
    static int filled;
    size_t lo = 0, hi;

    if (!filled) {
        fill();
        filled = 1;
    }
    hi = count;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        int c = strcmp_(table[mid].name, name);
        if (c == 0)
            return (void *)table[mid].addr;
        if (c < 0)
            lo = mid + 1;
        else
            hi = mid;
    }
    return NULL;
}
