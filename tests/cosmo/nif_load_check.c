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
#include <pthread.h>

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

/* The functions of the TLS object (nif_load_tls.c, nif_load_tls_asm.S). */
struct tls_fns {
    int (*get)(void), (*ctor)(void), (*zsum)(int), (*ie)(void);
    int (*gd)(void), (*ld)(void), (*big)(void);
    void *(*addr)(void);
};

static int tls_fns_of(struct bcn_module *m, struct tls_fns *f)
{
    *(void **)&f->get = bcn_symbol(m, "t_get");
    *(void **)&f->ctor = bcn_symbol(m, "t_constructor_value");
    *(void **)&f->zsum = bcn_symbol(m, "t_zero_sum");
    *(void **)&f->ie = bcn_symbol(m, "t_ie_get");
    *(void **)&f->gd = bcn_symbol(m, "t_gd");
    *(void **)&f->ld = bcn_symbol(m, "t_ld");
    *(void **)&f->big = bcn_symbol(m, "t_big_end");
    *(void **)&f->addr = bcn_symbol(m, "t_address");
    return f->get && f->ctor && f->zsum && f->ie && f->gd && f->ld && f->big && f->addr;
}

/* The checks of a thread that did not use the module: each variable has
 * its initial value, then the thread changes its own copy. Gives the
 * number of the first check that failed, or 0. */
static int tls_fresh(const struct tls_fns *f)
{
    if (f->get() != 4) return 1;
    if (f->zsum(7) != 0) return 2;
    if (f->ie() != 43) return 3;
    if (f->gd() != 41) return 4;
    if (f->ld() != 42) return 5;
    if (f->big() != 0) return 6;
    if (f->get() != 5) return 7;
    if (f->zsum(9) != 7 * 100) return 8;
    if (f->ie() != 44 || f->gd() != 42 || f->ld() != 43) return 9;
    return 0;
}

/* A thread that waits until GO, then runs tls_fresh. */
struct tls_thread {
    pthread_t tid;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    int go;
    const struct tls_fns *f;
    int result;
    void *addr;
};

static void *tls_thread_main(void *arg)
{
    struct tls_thread *t = arg;
    pthread_mutex_lock(&t->mu);
    while (!t->go)
        pthread_cond_wait(&t->cv, &t->mu);
    pthread_mutex_unlock(&t->mu);
    if (t->f) {
        t->result = tls_fresh(t->f);
        t->addr = t->f->addr();
    }
    return NULL;
}

static void tls_thread_start(struct tls_thread *t)
{
    memset(t, 0, sizeof(*t));
    t->result = -1;
    pthread_mutex_init(&t->mu, NULL);
    pthread_cond_init(&t->cv, NULL);
    pthread_create(&t->tid, NULL, tls_thread_main, t);
}

static void tls_thread_run(struct tls_thread *t, const struct tls_fns *f)
{
    pthread_mutex_lock(&t->mu);
    t->f = f;
    t->go = 1;
    pthread_cond_signal(&t->cv);
    pthread_mutex_unlock(&t->mu);
    pthread_join(t->tid, NULL);
}

/* Thread-local data: a thread that started before the load, the thread
 * that loads (with a constructor), a thread that starts after the load,
 * and a second module of the same object. */
static void tls_checks(const unsigned char *tls, size_t tlsn, const unsigned char *big, size_t bign)
{
    struct tls_thread before, after;
    struct tls_fns f, f2;
    struct bcn_module *m, *m2;
    char err[512];

    tls_thread_start(&before);
    m = bcn_load(tls, tlsn, lookup, err, sizeof(err));
    if (!m) {
        fprintf(stderr, "nif_load_check: the load of the TLS object failed: %s\n", err);
        failures++;
        tls_thread_run(&before, NULL);
        return;
    }
    CHECK(tls_fns_of(m, &f));
    if (failures)
        return;
    /* The constructor ran in this thread: 3 + 1. */
    CHECK(f.ctor() == 4);
    CHECK(f.get() == 5);
    CHECK(f.zsum(1) == 0 && f.ie() == 43 && f.gd() == 41 && f.ld() == 42 && f.big() == 0);
    tls_thread_run(&before, &f);
    CHECK(before.result == 0);
    if (before.result)
        fprintf(stderr, "nif_load_check: the thread before the load: check %d\n", before.result);
    tls_thread_start(&after);
    tls_thread_run(&after, &f);
    CHECK(after.result == 0);
    if (after.result)
        fprintf(stderr, "nif_load_check: the thread after the load: check %d\n", after.result);
    CHECK(before.addr != f.addr() && after.addr != f.addr());
    /* The other threads did not change the data of this thread. */
    CHECK(f.get() == 6 && f.zsum(0) == 100 && f.ie() == 44 && f.gd() == 42 && f.ld() == 43);

    /* A second module of the object has its own data. */
    m2 = bcn_load(tls, tlsn, lookup, err, sizeof(err));
    CHECK(m2 != NULL);
    if (m2 && tls_fns_of(m2, &f2)) {
        CHECK(f2.ctor() == 4 && f2.get() == 5 && f2.gd() == 41);
        CHECK(f.get() == 7 && f.gd() == 43);
        CHECK(f2.addr() != f.addr());
        free_module(m2);
    }
    free_module(m);
    refused(big, bign, "larger than");
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
    const unsigned char *tls = tls_x86_64, *tlsbig = tlsbig_x86_64, *dead = dead_x86_64;
    size_t tlsbign = sizeof(tlsbig_x86_64), deadn = sizeof(dead_x86_64);
    size_t objn = sizeof(obj_x86_64), othern = sizeof(obj_aarch64), objbn = sizeof(objb_x86_64);
    size_t tlsn = sizeof(tls_x86_64);
    uintptr_t limit = 0x80000000u;
#else
    const unsigned char *obj = obj_aarch64, *other = obj_x86_64, *objb = objb_aarch64;
    const unsigned char *tls = tls_aarch64, *tlsbig = tlsbig_aarch64, *dead = dead_aarch64;
    size_t tlsbign = sizeof(tlsbig_aarch64), deadn = sizeof(dead_aarch64);
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
    tls_checks(tls, tlsn, tlsbig, tlsbign);
    /* The dead sections: the object loads with no dead_missing_* in the
     * program, and its dead code and constants do not go into memory. */
    m2 = bcn_load(dead, deadn, lookup, err, sizeof(err));
    CHECK(m2 != NULL);
    if (m2) {
        int (*live)(int);
        uintptr_t dlo, dhi;
        CHECK((*(void **)&live = bcn_symbol(m2, "dead_live")) != NULL);
        if (live)
            CHECK(live(4) == 13);
        bcn_range(m2, &dlo, &dhi);
        /* One page of constants (.eh_frame), one of data: no page of the
         * 200 KB of dead_table. */
        CHECK(m2->data_size <= 2 * BCN_PAGE);
        free_module(m2);
    } else {
        fprintf(stderr, "nif_load_check: the load of the object with dead sections failed: %s\n", err);
    }
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
