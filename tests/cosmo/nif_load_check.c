/*
 * The checks of the loader of native NIF objects
 * (c_src/cosmo/beam_com_nif.c), with no ERTS. tests/cosmo/nif_load_objs.sh
 * makes the test objects (nif_load_obj_a.c and nif_load_obj_b.c, joined
 * with `ld -r`, for x86_64 and aarch64) and nif_load_objs.h with their
 * bytes. The check loads the object of its CPU, calls its functions, and
 * checks the errors and broken objects. step_test of scripts/steps.sh
 * builds it, and tests/run.sh runs it on each system. The last line is
 * "nif_load_check: ok".
 */
#define BEAM_COM_NIF_TEST
#include "../../c_src/cosmo/beam_com_nif.c"
#include "nif_load_objs.h"

#include <fcntl.h>
#include <math.h>

static int failures;

#define CHECK(cond)                                                            \
    do {                                                                       \
        if (!(cond)) {                                                         \
            fprintf(stderr, "nif_load_check: line %d: %s\n", __LINE__, #cond); \
            failures++;                                                        \
        }                                                                      \
    } while (0)

/* The program gives these to the object. */
int host_value = 10;
int host_add(int a, int b) { return a + b; }

#define SYM(n) { #n, (void *)&n }
static const struct {
    const char *name;
    void *addr;
} host_syms[] = {
    SYM(host_add), SYM(host_value), SYM(snprintf), SYM(strlen), SYM(memcpy),
    SYM(memset), SYM(qsort), SYM(malloc), SYM(free), SYM(sqrt), SYM(pow),
    SYM(floor), SYM(__errno_location), SYM(EINVAL), SYM(O_CREAT), SYM(ERANGE),
};

/* The lookup gives no address for this name. */
static const char *missing_name;
static int lookups, quiet;

static void *lookup(const char *name)
{
    size_t i;
    lookups++;
    if (missing_name && !strcmp(name, missing_name))
        return NULL;
    for (i = 0; i < sizeof(host_syms) / sizeof(host_syms[0]); i++)
        if (!strcmp(host_syms[i].name, name))
            return host_syms[i].addr;
    if (!quiet && strcmp(name, "host_missing"))
        fprintf(stderr, "nif_load_check: the object asks for %s\n", name);
    return NULL;
}

struct dwarf_eh_bases {
    void *tbase, *dbase, *func;
};
const void *_Unwind_Find_FDE(const void *pc, struct dwarf_eh_bases *bases);

static int contains(const char *text, const char *part)
{
    if (strstr(text, part))
        return 1;
    fprintf(stderr, "nif_load_check: no \"%s\" in \"%s\"\n", part, text);
    return 0;
}

/* A load that must fail, with PART in its error. */
static void refused(const unsigned char *bytes, size_t size, const char *part)
{
    char err[512];
    struct bcn_module *m = bcn_load(bytes, size, lookup, err, sizeof(err));
    CHECK(m == NULL);
    if (m)
        free_module(m);
    else
        CHECK(contains(err, part));
}

/* The loader never crashes on a broken object: random changes in a copy
 * of the object with no constructors (so no broken code runs). */
static void broken_objects(const unsigned char *obj, size_t size)
{
    unsigned char *copy = malloc(size);
    unsigned seed = 12345, round, k, loaded = 0, rounds = 3000;
    char err[512];

    quiet = 1;
    for (round = 0; round < rounds; round++) {
        memcpy(copy, obj, size);
        for (k = 0; k < 1 + round % 8; k++) {
            seed = seed * 1103515245u + 12345u;
            copy[(seed >> 8) % size] ^= (unsigned char)(1u << ((seed >> 4) & 7));
        }
        {
            struct bcn_module *m = bcn_load(copy, size, lookup, err, sizeof(err));
            if (m) {
                loaded++;
                free_module(m);
            } else {
                CHECK(err[0] != '\0');
            }
        }
    }
    quiet = 0;
    free(copy);
    printf("nif_load_check: %u of %u broken objects loaded, none crashed\n", loaded, rounds);
}

int main(void)
{
#if defined(__x86_64__)
    const unsigned char *obj = obj_x86_64, *other = obj_aarch64, *objb = objb_x86_64;
    const unsigned char *tls = tls_x86_64;
    size_t objn = sizeof(obj_x86_64), othern = sizeof(obj_aarch64), objbn = sizeof(objb_x86_64);
    size_t tlsn = sizeof(tls_x86_64);
    uintptr_t limit = 0x80000000u;
#else
    const unsigned char *obj = obj_aarch64, *other = obj_x86_64, *objb = objb_aarch64;
    const unsigned char *tls = tls_aarch64;
    size_t objn = sizeof(obj_aarch64), othern = sizeof(obj_x86_64), objbn = sizeof(objb_aarch64);
    size_t tlsn = sizeof(tls_aarch64);
    uintptr_t limit = (uintptr_t)__executable_start + 0x100000000ull;
#endif
    char err[512], buf[64];
    struct bcn_module *m, *m2;
    uintptr_t lo, hi;
    int ei = 0, oc = 0, x;
    int (*a_constructors)(void), (*a_switch)(int), (*a_errno_values)(int *, int *);
    int (*a_format)(char *, size_t, int), (*a_sort)(void), (*a_call_table)(int, int);
    int (*a_host)(void), (*a_weak_is_null)(void), (*a_other_part)(void), (*a_bss)(void);
    int (*a_bump)(void), (*a_heap)(void), (*bump2)(void);
    double (*a_float)(double);
    int *a_global, *a_global2;
    struct dwarf_eh_bases bases;
    static const int switch_values[9] = { 10, 21, 32, 43, 54, 65, 76, 87, -1 };

    printf("nif_load_check: the program is at %p to %p\n", (void *)__executable_start, (void *)_end);
    m = bcn_load(obj, objn, lookup, err, sizeof(err));
    if (!m) {
        fprintf(stderr, "nif_load_check: the load failed: %s\n", err);
        return 1;
    }
    bcn_range(m, &lo, &hi);
    printf("nif_load_check: the module is at %p to %p\n", (void *)lo, (void *)hi);
    CHECK(lo >= (uintptr_t)_end);
    CHECK(hi <= limit);

#define GET(name) CHECK((*(void **)&name = bcn_symbol(m, #name)) != NULL)
    GET(a_constructors);
    GET(a_switch);
    GET(a_errno_values);
    GET(a_format);
    GET(a_sort);
    GET(a_call_table);
    GET(a_host);
    GET(a_weak_is_null);
    GET(a_other_part);
    GET(a_bss);
    GET(a_float);
    GET(a_bump);
    GET(a_heap);
    GET(a_global);
    if (failures)
        return 1;
    CHECK(bcn_symbol(m, "f_inc") == NULL); /* a local function */
    CHECK(bcn_symbol(m, "no_such_symbol") == NULL);

    CHECK(a_constructors());
    for (x = 0; x < 9; x++)
        CHECK(a_switch(x) == switch_values[x]);
    CHECK(a_switch(-3) == -1);
    errno = 0;
    CHECK(a_errno_values(&ei, &oc));
    CHECK(ei == EINVAL && oc == O_CREAT);
    CHECK(errno == ERANGE);
    CHECK(a_format(buf, sizeof(buf), 7) == 9 && !strcmp(buf, "n=7 len=6"));
    CHECK(a_sort());
    CHECK(a_call_table(0, 5) == 6 && a_call_table(1, 5) == 10 && a_call_table(2, 5) == -5);
    CHECK(a_call_table(3, 5) == 0);
    CHECK(a_host() == 111 && host_value == 11);
    CHECK(a_weak_is_null());
    CHECK(a_other_part() == 82 + 6 + 6000);
    CHECK(a_bss());
    CHECK(fabs(a_float(16.0) - (4 * 1.5 + 1024 + 2)) < 1e-9);
    CHECK(a_heap());
    CHECK(*a_global == 41);
    CHECK(a_bump() == 42 && *a_global == 42);
    /* The unwind tables of the module are in libunwind. */
    memset(&bases, 0, sizeof(bases));
    CHECK(_Unwind_Find_FDE((const char *)a_switch + 1, &bases) != NULL);
    /* nif_load_obj_b.c has its own CIE: each FDE goes to libunwind. */
    memset(&bases, 0, sizeof(bases));
    CHECK(_Unwind_Find_FDE((const char *)bcn_symbol(m, "b_twice") + 1, &bases) != NULL);

    /* A second load has its own data. */
    m2 = bcn_load(obj, objn, lookup, err, sizeof(err));
    CHECK(m2 != NULL);
    if (m2) {
        CHECK((*(void **)&a_global2 = bcn_symbol(m2, "a_global")) != NULL);
        CHECK((*(void **)&bump2 = bcn_symbol(m2, "a_bump")) != NULL);
        if (a_global2 && bump2) {
            CHECK(*a_global2 == 41);
            CHECK(bump2() == 42 && a_bump() == 43);
        }
    }

    /* The errors. */
    refused(obj, 40, "not an ELF object");
    refused(obj, 100, "bad section headers");
    refused((const unsigned char *)"\177ELFxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", 64,
            "not a 64-bit little-endian ELF object");
    refused(other, othern, "an object of a different CPU");
    refused(tls, tlsn, "thread-local data is not supported yet");
    missing_name = "host_add";
    refused(obj, objn, "the program has no symbol host_add");
    missing_name = NULL;
    {
        unsigned char *copy = malloc(objn);
        bcn_ehdr *eh = (bcn_ehdr *)copy;
        memcpy(copy, obj, objn);
        eh->e_type = 2;
        refused(copy, objn, "not a relocatable object");
        memcpy(copy, obj, objn);
        eh->e_shoff = (uint64_t)objn * 4;
        refused(copy, objn, "bad section headers");
        free(copy);
    }
    /* The checks of the unwind table. */
    {
        static const uint8_t cie[] = { 16, 0, 0, 0, 0, 0, 0, 0, 1, 'z', 'R', 0, 1, 0x78, 16, 1,
                                       0x1b, 0, 0, 0 };
        uint8_t t[64];
        CHECK(eh_frame_ok(cie, sizeof(cie)));
        memcpy(t, cie, sizeof(cie));
        memset(t + sizeof(cie), 0, 4);
        CHECK(eh_frame_ok(t, sizeof(cie) + 4)); /* with its end */
        t[0] = 200;
        CHECK(!eh_frame_ok(t, sizeof(cie) + 4)); /* a record out of the section */
        memcpy(t, cie, sizeof(cie));
        t[8] = 2;
        CHECK(!eh_frame_ok(t, sizeof(cie))); /* a version that libunwind does not read */
        memcpy(t, cie, sizeof(cie));
        memcpy(t + 20, (const uint8_t[]){ 12, 0, 0, 0, 99, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 16);
        CHECK(!eh_frame_ok(t, 36)); /* an FDE with no CIE */
        memcpy(t + 20, (const uint8_t[]){ 12, 0, 0, 0, 24, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 16);
        CHECK(eh_frame_ok(t, 36)); /* an FDE after its CIE */
    }
    lookups = 0;
    bcn_unwind = 0;
    broken_objects(objb, objbn);
    bcn_unwind = 1;

    if (failures) {
        printf("nif_load_check: %d failures\n", failures);
        return 1;
    }
    printf("nif_load_check: ok\n");
    return 0;
}
