/*
 * BEAM.com: the table of the symbols of the program that a native NIF
 * object can use (beam_com_nif.c): each function enif_* of
 * erl_nif_api_funcs.h of this OTP, the symbols of the libc of
 * beam_com_nif_libc.h, and libc++abi (beam_com_nif_cxx.h).
 *
 * Each name is only an address here: extern char bcn_sym_NAME, with the
 * assembler name NAME. The declarations need no types, and they do not
 * conflict with the headers that the build of ERTS includes in each file.
 *
 * With BEAM_COM_NIF_NAMES (tests/cosmo/nif_needs.c), the table holds the
 * names only: each address is the text of its name, so the file needs no
 * symbol of the program.
 */
#include <stddef.h>

void *beam_com_nif_lookup(const char *name);

#define SIZEOF_LONG 8
/* The header ends with inline functions of the types of erl_nif.h, when
 * the compiler is GCC and the system is not Windows. _WIN32_ selects the
 * form with macros, which needs no types. */
#define _WIN32_
#if defined(BEAM_COM_NIF_NAMES)
#define BCN_ADDR(NAME) #NAME
#define BCN_IFUNC_ADDR(NAME) #NAME
#define NIF_LIBC_IFUNC(NAME)
#define NIF_LIBC(NAME)
#else
#define BCN_ADDR(NAME) &bcn_sym_##NAME
#define ERL_NIF_API_FUNC_DECL(RET, NAME, ARGS) extern char bcn_sym_##NAME __asm__(#NAME)
#include "erl_nif_api_funcs.h"
#undef ERL_NIF_API_FUNC_DECL

/* An IFUNC symbol of x86_64 (beam_com_nif_libc.h): the table holds a
 * jump to it, never its address. aarch64 has no IFUNC symbols. */
#if defined(__x86_64__)
#define BCN_IFUNC_ADDR(NAME) bcn_ifunc_##NAME
#define NIF_LIBC_IFUNC(NAME)                                                                       \
    extern char bcn_ifunc_##NAME[] __asm__("bcn_ifunc_" #NAME);                                    \
    __asm__(".text\n.balign 16\nbcn_ifunc_" #NAME ":\n\tjmp " #NAME "\n");
#else
#define BCN_IFUNC_ADDR(NAME) &bcn_sym_##NAME
#define NIF_LIBC_IFUNC(NAME) extern char bcn_sym_##NAME __asm__(#NAME);
#endif
#define NIF_LIBC(NAME) extern char bcn_sym_##NAME __asm__(#NAME);
#endif
#include "beam_com_nif_libc.h"
#undef NIF_LIBC
#undef NIF_LIBC_IFUNC

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

/* The table, sorted by name for the search (a Shell sort: it runs one
 * time, at the start, on about 2000 names). */
static void fill(void)
{
    size_t i, j, gap;
#define ERL_NIF_API_FUNC_DECL(RET, NAME, ARGS) add(#NAME, BCN_ADDR(NAME))
#include "erl_nif_api_funcs.h"
#undef ERL_NIF_API_FUNC_DECL
#define NIF_LIBC(NAME) add(#NAME, BCN_ADDR(NAME));
#define NIF_LIBC_IFUNC(NAME) add(#NAME, BCN_IFUNC_ADDR(NAME));
#include "beam_com_nif_libc.h"
#undef NIF_LIBC
#undef NIF_LIBC_IFUNC
#undef _WIN32_
    for (gap = 1; gap < count / 3; gap = gap * 3 + 1)
        ;
    for (; gap > 0; gap /= 3)
        for (i = gap; i < count; i++) {
            struct nif_sym s = table[i];
            for (j = i; j >= gap && strcmp_(table[j - gap].name, s.name) > 0; j -= gap)
                table[j] = table[j - gap];
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
