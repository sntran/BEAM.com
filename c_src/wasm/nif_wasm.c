/*
 * NIF libraries in WebAssembly. When erlang:load_nif(PATH, Info) finds
 * no native library, ERTS calls nif_wasm_open(PATH) (see the patch
 * patches/otp/0003-wasm-nif.patch). This file loads PATH.ARCH.aot or
 * PATH.wasm in WAMR, and gives ERTS an ErlNifEntry with a native
 * function (a trampoline) for each NIF of the module.
 *
 * The C code of the NIF does not change. It is compiled for
 * wasm32-wasip1 with the headers of "beam.com --nif-include", and each
 * enif_* function is an import of the module "env" that this file gives.
 * See docs/NIFS.md for the contract of a module.
 *
 * The rules of this file:
 *
 * - A term in the module is a 32-bit handle (ERL_NIF_TERM is 32 bits
 *   in wasm32):
 *     h & 1 = 1   a small integer or [], in the bits of h (inline);
 *     h & 3 = 2   an atom, a pid or a port: an index into the table of
 *                 interned terms of the library. The same term always
 *                 has the same handle, so a NIF can keep an atom in a
 *                 static variable and compare it with ==;
 *     h & 3 = 0   any other term: an index into the table of terms of
 *                 its environment (slot << 22 | index + 1, shifted 2).
 * - An environment in the module is the number of its slot + 1. A NIF
 *   call, a callback and enif_alloc_env each open a slot.
 * - The module gets its binaries in its own linear memory: inspected
 *   binaries are copies. A binary of enif_make_new_binary is a real
 *   binary at once, and this file copies the bytes of the module into
 *   it when ERTS reads the bytes: at the end of the call, and before a
 *   send, a copy, a compare, a sub-binary or a map operation.
 * - A resource has a host object (hres_t) and memory in the module. The
 *   module sees the address of its memory.
 * - One call runs in a library at a time (a mutex). The same thread
 *   can enter again, for example for the destructor of a resource that
 *   a call releases. The module has no threads, so its mutexes and
 *   condition variables do nothing.
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "erl_nif.h"
#include "wasm_export.h"
#include "nif_wasm.h"

/* WAMR (core/iwasm/common/wasm_exec_env.h): the thread and its native
 * stack bound for the next call. One execution environment serves all
 * the threads that call a library, one at a time. */
void wasm_exec_env_set_thread_info(wasm_exec_env_t exec_env);

/* The WebAssembly runtime of --target wasm32: ERTS built with
 * Emscripten. The engine of the host runs the module there, not WAMR:
 * nif_wasm_host.c gives the functions of WAMR that this file calls. */
#ifdef __EMSCRIPTEN__
#define NIF_WASM_EDGE 1
#include <emscripten.h>
#include "nif_wasm_host.h"
#endif

#define MAX_FUNCS 256
#define MAX_SLOTS 256
#define IDX_BITS 22
#define IDX_MASK ((1u << IDX_BITS) - 1)
#define MAX_TSD 64
/* Scratch memory in the module for one call: the copies of inspected
 * binaries and the arrays of terms. Larger needs use malloc. */
#define ARENA_SIZE (256 * 1024)
/* The stack of WAMR (frames and operands), not the stack of C code in
 * the linear memory. */
#define WASM_STACK (256 * 1024)
/* The heap of WAMR in the linear memory, only for a module without an
 * allocator (no erl_nif_wasm_malloc and no malloc). */
#define APP_HEAP (16 * 1024 * 1024)
/* ref_bin of a binary of enif_alloc_binary: the module owns its data. */
#define OWNED_BINARY 0x6e69662bu
/* enif_alloc keeps the size of a block before it (for enif_realloc). */
#define ALLOC_HEADER 16

/* The tags of an immediate term of ERTS (erts/emulator/beam/erl_term.h,
 * 64-bit): the primary tag 3, and the small integer tag 0xF. */
#define IS_IMMEDIATE(t) (((t) & 0x3) == 0x3)
#define IS_SMALL(t) (((t) & 0xF) == 0xF)

typedef struct {
    unsigned char *host;
    uint32_t gptr, size;
} pending_t;

typedef struct {
    ErlNifEnv *env;
    int used, owned;            /* owned: from enif_alloc_env */
    ERL_NIF_TERM *terms;
    uint32_t n, cap;
    uint32_t *frees;            /* memory of the module to free with the slot */
    uint32_t nfree, capfree;
    pending_t *pend;            /* binaries of enif_make_new_binary */
    uint32_t npend, cappend;
} slot_t;

typedef struct {
    ErlNifResourceType *type;
    uint32_t dtor;              /* table index in the module, or 0 */
    uint32_t down;              /* the down callback, or 0 */
} rtype_t;

struct ctx;

typedef struct {
    struct ctx *c;
    uint32_t rtype;             /* index into ctx.rtypes */
    uint32_t gptr, size;
} hres_t;

typedef struct {
    uint32_t g;                 /* 0: empty, 1: removed */
    hres_t *h;
} res_slot_t;

/* A monitor of a resource. The module holds its index + 1. */
typedef struct {
    ErlNifMonitor m;
    hres_t *h;
    int used;
} mon_t;

/* An I/O queue of the module: its bytes are in memory of the module,
 * which the queue owns. */
typedef struct {
    uint32_t g, size, off;
} ioq_ent_t;

typedef struct {
    ioq_ent_t *e;
    uint32_t n, cap, total;
    uint32_t peek, peekcap;     /* the SysIOVec array of enif_ioq_peek */
} ioq_t;

typedef struct ctx {
    uint8_t *bytes;             /* WAMR keeps pointers into the bytes. */
    wasm_module_t module;
    wasm_module_inst_t inst;
    wasm_exec_env_t exec;
    ErlNifMutex *lock;
    uint32_t npend;             /* the binaries of enif_make_new_binary in all slots */
    const void *owner;          /* the thread in the library (thread_id()) */
    int depth;
    wasm_function_inst_t malloc_fn, free_fn;
    uint32_t arena, arena_used;
    uint32_t priv;              /* the priv_data of the module */
    uint32_t load_fn, unload_fn;
    uint32_t fn[MAX_FUNCS];
    ErlNifFunc funcs[MAX_FUNCS];
    ErlNifEntry entry;
    char **strings;             /* strings of the entry and of enif_schedule_nif */
    uint32_t nstrings, capstrings;
    slot_t slots[MAX_SLOTS];
    ERL_NIF_TERM *itab;         /* interned terms */
    uint32_t in, icap;
    uint32_t *ihash;            /* term -> index + 1 */
    uint32_t ihcap;
    rtype_t *rtypes;
    uint32_t nrt, caprt;
    res_slot_t *res;            /* guest pointer -> host object */
    uint32_t nres, capres;
    ErlNifMapIterator **iters;
    uint32_t niter, capiter;
    uint32_t tsd[MAX_TSD];
    uint32_t ntsd;
    uint32_t erts_version, otp_release;     /* strings of enif_system_info */
    mon_t *mons;
    uint32_t nmon, capmon;
    ioq_t **ioqs;
    uint32_t nioq, capioq;
} ctx;

/* The library that the last nif_wasm_open made, for its load callback:
 * ERTS calls the callback in the same thread, after the checks of the
 * entry. */
static __thread ctx *loading;
static __thread int thread_ready;
static ERL_NIF_TERM nil_term;
static int debug;

static int grow(void **p, uint32_t *cap, uint32_t need, size_t size)
{
    uint32_t n;
    void *q;
    if (need <= *cap)
        return 1;
    n = *cap ? *cap : 16;
    while (n < need)
        n *= 2;
    q = realloc(*p, (size_t)n * size);
    if (!q)
        return 0;
    *p = q;
    *cap = n;
    return 1;
}

/* The term [] (it is the same in all environments). */
static int nil_ready(void)
{
    ErlNifEnv *env;
    if (nil_term)
        return 1;
    if (!(env = enif_alloc_env()))
        return 0;
    nil_term = enif_make_list(env, 0);
    enif_free_env(env);
    return 1;
}

/* --- memory of the module --- */

/* The address of SIZE bytes at OFF of the module. In the WebAssembly
 * runtime of --target wasm32, it is a copy (a window, see
 * nif_wasm_host.c) that goes back at the next call into the module. */
static void *gaddr(ctx *c, uint32_t off, uint32_t size)
{
#ifdef NIF_WASM_EDGE
    return host_window(c->inst, off, size ? size : 1);
#else
    if (!wasm_runtime_validate_app_addr(c->inst, off, size ? size : 1))
        return NULL;
    return wasm_runtime_addr_app_to_native(c->inst, off);
#endif
}

static const char *gstr(ctx *c, uint32_t off)
{
#ifdef NIF_WASM_EDGE
    return off ? host_string(c->inst, off) : NULL;
#else
    if (!off || !wasm_runtime_validate_app_str_addr(c->inst, off))
        return NULL;
    return wasm_runtime_addr_app_to_native(c->inst, off);
#endif
}

static int put32(ctx *c, uint32_t off, uint32_t v)
{
    void *p = off ? gaddr(c, off, 4) : NULL;
    if (!p)
        return 0;
    memcpy(p, &v, 4);
    return 1;
}

static int get32(ctx *c, uint32_t off, uint32_t *v)
{
    void *p = off ? gaddr(c, off, 4) : NULL;
    if (!p)
        return 0;
    memcpy(v, p, 4);
    return 1;
}

static void call_ready(ctx *c)
{
    if (!thread_ready) {
        wasm_runtime_init_thread_env();
        thread_ready = 1;
    }
    wasm_exec_env_set_thread_info(c->exec);
}

/* malloc and free of the module. A call can move the linear memory (it
 * can grow), so get native addresses only after the allocations. */
static uint32_t gmalloc(ctx *c, uint32_t n)
{
    uint32_t a[1];
    if (c->malloc_fn) {
        a[0] = n ? n : 1;
        call_ready(c);
        if (!wasm_runtime_call_wasm(c->exec, c->malloc_fn, 1, a))
            return 0;
        return a[0];
    }
    return (uint32_t)wasm_runtime_module_malloc(c->inst, n ? n : 1, NULL);
}

static void gfree(ctx *c, uint32_t off)
{
    uint32_t a[1];
    if (!off)
        return;
    if (c->free_fn) {
        a[0] = off;
        call_ready(c);
        wasm_runtime_call_wasm(c->exec, c->free_fn, 1, a);
        return;
    }
    wasm_runtime_module_free(c->inst, off);
}

static uint32_t fail(ctx *c, const char *what)
{
    wasm_runtime_set_exception(c->inst, what);
    return 0;
}

/* --- environments --- */

static int slot_open(ctx *c, ErlNifEnv *env, int owned)
{
    int s;
    for (s = 0; s < MAX_SLOTS; s++) {
        slot_t *sl = &c->slots[s];
        if (!sl->used) {
            sl->used = 1;
            sl->owned = owned;
            sl->env = env;
            sl->n = sl->nfree = sl->npend = 0;
            return s;
        }
    }
    return -1;
}

/* Copy the bytes of the binaries of enif_make_new_binary into their
 * real binaries. The module can still write them: the entries stay. */
static void flush_slot(ctx *c, slot_t *sl)
{
    uint32_t i;
    for (i = 0; i < sl->npend; i++) {
        pending_t *p = &sl->pend[i];
        void *src = p->size ? gaddr(c, p->gptr, p->size) : NULL;
        if (src)
            memcpy(p->host, src, p->size);
    }
}

/* Most calls make no new binary: then there is no slot to look at. */
static void flush_all(ctx *c)
{
    uint32_t s, seen = 0;
    for (s = 0; s < MAX_SLOTS && seen < c->npend; s++)
        if (c->slots[s].used && c->slots[s].npend) {
            flush_slot(c, &c->slots[s]);
            seen += c->slots[s].npend;
        }
}

/* Empty the slot (its terms, its memory in the module), and keep it. */
static void slot_reset(ctx *c, slot_t *sl)
{
    uint32_t i;
    for (i = 0; i < sl->nfree; i++)
        gfree(c, sl->frees[i]);
    c->npend -= sl->npend;
    sl->n = sl->nfree = sl->npend = 0;
}

static void slot_close(ctx *c, int s)
{
    slot_reset(c, &c->slots[s]);
    c->slots[s].used = 0;
    c->slots[s].env = NULL;
}

/* The slot of the environment E of the module, or NULL. */
static slot_t *slot_of(ctx *c, uint32_t e)
{
    if (e == 0 || e > MAX_SLOTS || !c->slots[e - 1].used)
        return NULL;
    return &c->slots[e - 1];
}

/* Memory in the module that lives as long as the slot: the arena for
 * a call, else malloc. */
static uint32_t scratch(ctx *c, uint32_t e, uint32_t n)
{
    slot_t *sl = &c->slots[e - 1];
    uint32_t m = (n + 7) & ~7u, g;
    if (m == 0)
        m = 8;
    if (!sl->owned && c->arena && m <= ARENA_SIZE - c->arena_used) {
        g = c->arena + c->arena_used;
        c->arena_used += m;
        return g;
    }
    if (!grow((void **)&sl->frees, &sl->capfree, sl->nfree + 1, 4))
        return 0;
    g = gmalloc(c, m);
    if (g)
        sl->frees[sl->nfree++] = g;
    return g;
}

/* --- terms --- */

static uint32_t thash(ERL_NIF_TERM t)
{
    uint64_t x = (uint64_t)t;
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    return (uint32_t)x;
}

static uint32_t intern(ctx *c, ERL_NIF_TERM t)
{
    uint32_t i, mask;
    if (c->ihcap) {
        mask = c->ihcap - 1;
        for (i = thash(t) & mask; c->ihash[i]; i = (i + 1) & mask)
            if (c->itab[c->ihash[i] - 1] == t)
                return ((c->ihash[i] - 1) << 2) | 2;
    }
    if (c->in >= (1u << 29) || !grow((void **)&c->itab, &c->icap, c->in + 1, sizeof(ERL_NIF_TERM)))
        return 0;
    if (2 * (c->in + 1) > c->ihcap) {
        uint32_t ncap = c->ihcap ? 2 * c->ihcap : 64, j;
        uint32_t *nh = calloc(ncap, 4);
        if (!nh)
            return 0;
        for (j = 0; j < c->in; j++) {
            for (i = thash(c->itab[j]) & (ncap - 1); nh[i]; i = (i + 1) & (ncap - 1))
                ;
            nh[i] = j + 1;
        }
        free(c->ihash);
        c->ihash = nh;
        c->ihcap = ncap;
    }
    mask = c->ihcap - 1;
    for (i = thash(t) & mask; c->ihash[i]; i = (i + 1) & mask)
        ;
    c->itab[c->in] = t;
    c->ihash[i] = ++c->in;
    return ((c->in - 1) << 2) | 2;
}

/* The handle of the term T, made in the environment E. 0: no memory. */
static uint32_t handle(ctx *c, uint32_t e, ERL_NIF_TERM t)
{
    slot_t *sl;
    if (IS_SMALL(t) || t == nil_term) {
        int64_t v = (int64_t)t;
        if (v >= -(INT64_C(1) << 30) && v < (INT64_C(1) << 30))
            return ((uint32_t)v << 1) | 1;
    }
    if (IS_IMMEDIATE(t) && !IS_SMALL(t))
        return intern(c, t);
    sl = &c->slots[e - 1];
    if (sl->n >= IDX_MASK || !grow((void **)&sl->terms, &sl->cap, sl->n + 1, sizeof(ERL_NIF_TERM)))
        return 0;
    sl->terms[sl->n++] = t;
    return ((((uint32_t)(e - 1)) << IDX_BITS) | sl->n) << 2;
}

static int get_term(ctx *c, uint32_t h, ERL_NIF_TERM *t)
{
    uint32_t v, s, i;
    if (h & 1) {
        *t = (ERL_NIF_TERM)(int64_t)((int32_t)h >> 1);
        return IS_SMALL(*t) || *t == nil_term;
    }
    if ((h & 3) == 2) {
        if ((h >> 2) >= c->in)
            return 0;
        *t = c->itab[h >> 2];
        return 1;
    }
    v = h >> 2;
    s = v >> IDX_BITS;
    i = v & IDX_MASK;
    if (s >= MAX_SLOTS || !c->slots[s].used || i == 0 || i > c->slots[s].n)
        return 0;
    *t = c->slots[s].terms[i - 1];
    return 1;
}

/* Read N handles at OFF into OUT (terms). */
static int get_terms(ctx *c, uint32_t off, uint32_t n, ERL_NIF_TERM *out)
{
    uint32_t i, h;
    const uint8_t *p;
    if (n == 0)
        return 1;
    if (n > UINT32_MAX / 4 || !(p = gaddr(c, off, 4 * n)))
        return 0;
    for (i = 0; i < n; i++) {
        memcpy(&h, p + 4 * i, 4);
        if (!get_term(c, h, &out[i]))
            return 0;
    }
    return 1;
}

/* Write the handles of N terms into new memory of the slot. Gives the
 * address in the module, or 0. */
static uint32_t put_terms(ctx *c, uint32_t e, const ERL_NIF_TERM *ts, uint32_t n)
{
    /* Most calls have few arguments: no malloc for them. */
    uint32_t local[16], *hs = n <= 16 ? local : malloc((size_t)n * 4), g = 0, i;
    void *p;
    if (!hs)
        return 0;
    for (i = 0; i < n; i++)
        if (!(hs[i] = handle(c, e, ts[i])))
            goto done;
    g = scratch(c, e, 4 * n);
    if (g && n && (p = gaddr(c, g, 4 * n)))
        memcpy(p, hs, 4 * n);
done:
    if (hs != local)
        free(hs);
    return g;
}

/* --- locks and calls into the module --- */

/* The thread that calls. Not the address of a thread-local variable:
 * the green threads of the WebAssembly runtime share those. */
static const void *thread_id(void)
{
    return (const void *)enif_thread_self();
}

static void enter(ctx *c)
{
    const void *self = thread_id();
    /* Only this thread writes its own identity into owner. */
    if (c->owner == self) {
        c->depth++;
        return;
    }
    enif_mutex_lock(c->lock);
    c->owner = self;
    c->depth = 1;
}

static void leave(ctx *c)
{
    if (--c->depth > 0)
        return;
    c->arena_used = 0;
#ifdef NIF_WASM_EDGE
    host_release(c->inst);
#endif
    c->owner = NULL;
    enif_mutex_unlock(c->lock);
}

static int guest_call(ctx *c, uint32_t fidx, uint32_t argc, uint32_t *argv)
{
    call_ready(c);
    return wasm_runtime_call_indirect(c->exec, fidx, argc, argv);
}

/* The exception {wasm_trap, Message} for a trap of the module. */
static ERL_NIF_TERM trap(ctx *c, ErlNifEnv *env)
{
    const char *ex = wasm_runtime_get_exception(c->inst);
    ERL_NIF_TERM msg;
    size_t n;
    if (!ex)
        ex = "unknown";
    if (!strncmp(ex, "Exception: ", 11))
        ex += 11;
    n = strlen(ex);
    memcpy(enif_make_new_binary(env, n, &msg), ex, n);
    wasm_runtime_clear_exception(c->inst);
    return enif_raise_exception(env, enif_make_tuple2(env, enif_make_atom(env, "wasm_trap"), msg));
}

static ERL_NIF_TERM call_nif(ctx *c, uint32_t fidx, ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM r;
    uint32_t a[3], ga;
    int s;

    enter(c);
    s = slot_open(c, env, 0);
    if (s < 0) {
        leave(c);
        return enif_raise_exception(env, enif_make_tuple2(env, enif_make_atom(env, "wasm_trap"),
                                                          enif_make_atom(env, "too_many_environments")));
    }
    ga = put_terms(c, s + 1, argv, argc);
    a[0] = s + 1;
    a[1] = (uint32_t)argc;
    a[2] = ga;
    if (!ga)
        r = enif_raise_exception(env, enif_make_tuple2(env, enif_make_atom(env, "wasm_trap"),
                                                       enif_make_atom(env, "no_memory")));
    else if (!guest_call(c, fidx, 3, a))
        r = trap(c, env);
    else if (!get_term(c, a[0], &r))
        r = enif_raise_exception(env, enif_make_tuple2(env, enif_make_atom(env, "wasm_trap"),
                                                       enif_make_atom(env, "bad_term")));
    flush_all(c);
    slot_close(c, s);
    leave(c);
    return r;
}

/* The trampolines t000 to t377: the digits are the octal index of the
 * function (0##n is an octal literal). */
#define T1(n) static ERL_NIF_TERM t##n(ErlNifEnv *e, int argc, const ERL_NIF_TERM *v) \
    { ctx *c = enif_priv_data(e); return call_nif(c, c->fn[0##n], e, argc, v); }
#define T8(n) T1(n##0) T1(n##1) T1(n##2) T1(n##3) T1(n##4) T1(n##5) T1(n##6) T1(n##7)
#define T64(n) T8(n##0) T8(n##1) T8(n##2) T8(n##3) T8(n##4) T8(n##5) T8(n##6) T8(n##7)
T64(0) T64(1) T64(2) T64(3)
#define R1(n) t##n,
#define R8(n) R1(n##0) R1(n##1) R1(n##2) R1(n##3) R1(n##4) R1(n##5) R1(n##6) R1(n##7)
#define R64(n) R8(n##0) R8(n##1) R8(n##2) R8(n##3) R8(n##4) R8(n##5) R8(n##6) R8(n##7)
static ERL_NIF_TERM (*const tramp[MAX_FUNCS])(ErlNifEnv *, int, const ERL_NIF_TERM *) = {
    R64(0) R64(1) R64(2) R64(3)
};

/* enif_schedule_nif: the last argument is the table index of the
 * function in the module. */
static ERL_NIF_TERM sched_tramp(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ctx *c = enif_priv_data(env);
    unsigned fidx;
    if (argc < 1 || !enif_get_uint(env, argv[argc - 1], &fidx))
        return enif_make_badarg(env);
    return call_nif(c, fidx, env, argc - 1, argv);
}

/* --- resources --- */

static uint32_t rhash(uint32_t g)
{
    return (g >> 3) * 2654435761u;
}

static hres_t *res_get(ctx *c, uint32_t g)
{
    uint32_t i, mask;
    if (g < 2 || !c->capres)
        return NULL;
    mask = c->capres - 1;
    for (i = rhash(g) & mask; c->res[i].g; i = (i + 1) & mask)
        if (c->res[i].g == g)
            return c->res[i].h;
    return NULL;
}

static int res_put(ctx *c, uint32_t g, hres_t *h)
{
    uint32_t i, mask;
    if (4 * (c->nres + 1) > 3 * c->capres) {
        uint32_t ncap = c->capres ? 2 * c->capres : 64, j;
        res_slot_t *nr = calloc(ncap, sizeof(res_slot_t));
        if (!nr)
            return 0;
        for (j = 0; j < c->capres; j++)
            if (c->res[j].g > 1) {
                for (i = rhash(c->res[j].g) & (ncap - 1); nr[i].g; i = (i + 1) & (ncap - 1))
                    ;
                nr[i] = c->res[j];
            }
        free(c->res);
        c->res = nr;
        c->capres = ncap;
        c->nres = 0;
        for (j = 0; j < ncap; j++)
            if (nr[j].g > 1)
                c->nres++;
    }
    mask = c->capres - 1;
    for (i = rhash(g) & mask; c->res[i].g > 1; i = (i + 1) & mask)
        ;
    if (c->res[i].g == 0)
        c->nres++;
    c->res[i].g = g;
    c->res[i].h = h;
    return 1;
}

static void res_del(ctx *c, uint32_t g)
{
    uint32_t i, mask;
    if (!c->capres)
        return;
    mask = c->capres - 1;
    for (i = rhash(g) & mask; c->res[i].g; i = (i + 1) & mask)
        if (c->res[i].g == g) {
            c->res[i].g = 1;
            c->res[i].h = NULL;
            return;
        }
}

static void host_dtor(ErlNifEnv *env, void *obj)
{
    hres_t *h = obj;
    ctx *c = h->c;
    rtype_t *rt;
    int s;
    if (!c)
        return;
    enter(c);
    rt = &c->rtypes[h->rtype];
    if (rt->dtor) {
        uint32_t a[2];
        s = slot_open(c, env, 0);
        a[0] = s < 0 ? 0 : (uint32_t)s + 1;
        a[1] = h->gptr;
        if (!guest_call(c, rt->dtor, 2, a))
            wasm_runtime_clear_exception(c->inst);
        if (s >= 0) {
            flush_all(c);
            slot_close(c, s);
        }
    }
    for (s = 0; s < (int)c->nmon; s++)
        if (c->mons[s].used && c->mons[s].h == h)
            c->mons[s].used = 0;
    res_del(c, h->gptr);
    gfree(c, h->gptr);
    leave(c);
}

/* --- the imports: the enif_* functions for the module --- */

static ctx *ctx_of(wasm_exec_env_t x)
{
    ctx *c = wasm_runtime_get_user_data(x);
    if (!c)
        wasm_runtime_set_exception(wasm_runtime_get_module_inst(x), "enif_* outside of a NIF library");
    return c;
}

#define CTX ctx *c = ctx_of(x); if (!c) return 0
#define CTXV ctx *c = ctx_of(x); if (!c) return
#define ENV(var, e) ErlNifEnv *var; do { \
        slot_t *sl_ = slot_of(c, (e)); \
        if (!sl_) \
            return fail(c, "enif: bad environment"); \
        var = sl_->env; \
    } while (0)
#define TERM(var, h) ERL_NIF_TERM var; if (!get_term(c, (h), &var)) return fail(c, "enif: bad term")
#define RET(e, t) do { uint32_t h_ = handle(c, (e), (t)); \
    return h_ ? h_ : fail(c, "enif: no memory for terms"); } while (0)
#define OUT(off, e, t) do { uint32_t h_ = handle(c, (e), (t)); \
    if (!h_ || !put32(c, (off), h_)) return fail(c, "enif: bad pointer"); } while (0)

static uint32_t w_priv_data(wasm_exec_env_t x, uint32_t e)
{
    CTX;
    (void)e;
    return c->priv;
}

static uint32_t w_alloc(wasm_exec_env_t x, uint32_t n)
{
    uint32_t g;
    CTX;
    if (n > UINT32_MAX - ALLOC_HEADER)
        return 0;
    g = gmalloc(c, n + ALLOC_HEADER);
    if (!g || !put32(c, g, n))
        return 0;
    return g + ALLOC_HEADER;
}

static void w_free(wasm_exec_env_t x, uint32_t p)
{
    CTXV;
    if (p >= ALLOC_HEADER)
        gfree(c, p - ALLOC_HEADER);
}

static uint32_t w_realloc(wasm_exec_env_t x, uint32_t p, uint32_t n)
{
    uint32_t old, g;
    void *src, *dst;
    CTX;
    if (!p)
        return w_alloc(x, n);
    if (p < ALLOC_HEADER || !get32(c, p - ALLOC_HEADER, &old))
        return fail(c, "enif_realloc: bad pointer");
    if (!(g = w_alloc(x, n)))
        return 0;
    if ((old < n ? old : n) && (src = gaddr(c, p, old < n ? old : n)) && (dst = gaddr(c, g, old < n ? old : n)))
        memmove(dst, src, old < n ? old : n);
    gfree(c, p - ALLOC_HEADER);
    return g;
}

#define IS(name) static uint32_t w_##name(wasm_exec_env_t x, uint32_t e, uint32_t h) \
    { CTX; ENV(env, e); TERM(t, h); return (uint32_t)enif_##name(env, t); }
IS(is_atom) IS(is_binary) IS(is_ref) IS(is_fun) IS(is_pid) IS(is_port) IS(is_list)
IS(is_tuple) IS(is_map) IS(is_number) IS(is_empty_list) IS(is_exception)

static uint32_t w_term_type(wasm_exec_env_t x, uint32_t e, uint32_t h)
{
    CTX;
    ENV(env, e);
    TERM(t, h);
    return (uint32_t)enif_term_type(env, t);
}

static uint32_t w_is_identical(wasm_exec_env_t x, uint32_t a, uint32_t b)
{
    CTX;
    TERM(ta, a);
    TERM(tb, b);
    flush_all(c);
    return (uint32_t)enif_is_identical(ta, tb);
}

static uint32_t w_compare(wasm_exec_env_t x, uint32_t a, uint32_t b)
{
    CTX;
    TERM(ta, a);
    TERM(tb, b);
    flush_all(c);
    return (uint32_t)enif_compare(ta, tb);
}

static uint64_t w_hash(wasm_exec_env_t x, uint32_t type, uint32_t h, uint64_t salt)
{
    CTX;
    TERM(t, h);
    flush_all(c);
    return enif_hash((ErlNifHash)type, t, salt);
}

/* --- binaries (ErlNifBinary of wasm32: size, data, ref_bin, spare[2]) --- */

static uint32_t copy_binary(ctx *c, uint32_t e, ErlNifBinary *b, uint32_t binp)
{
    uint32_t g, v[5];
    void *p;
    if (b->size > UINT32_MAX - 8)
        return 0;
    g = scratch(c, e, (uint32_t)b->size);
    if (!g)
        return fail(c, "enif: no memory in the module");
    if (b->size && (p = gaddr(c, g, (uint32_t)b->size)))
        memcpy(p, b->data, b->size);
    v[0] = (uint32_t)b->size;
    v[1] = g;
    v[2] = v[3] = v[4] = 0;
    if (!binp || !(p = gaddr(c, binp, 20)))
        return fail(c, "enif: bad pointer");
    memcpy(p, v, 20);
    return 1;
}

static uint32_t w_inspect_binary(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t binp)
{
    ErlNifBinary b;
    CTX;
    ENV(env, e);
    TERM(t, h);
    flush_all(c);
    if (!enif_inspect_binary(env, t, &b))
        return 0;
    return copy_binary(c, e, &b, binp);
}

static uint32_t w_inspect_iolist_as_binary(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t binp)
{
    ErlNifBinary b;
    CTX;
    ENV(env, e);
    TERM(t, h);
    flush_all(c);
    if (!enif_inspect_iolist_as_binary(env, t, &b))
        return 0;
    return copy_binary(c, e, &b, binp);
}

static uint32_t w_alloc_binary(wasm_exec_env_t x, uint32_t n, uint32_t binp)
{
    uint32_t g, v[5];
    void *p;
    CTX;
    if (!(g = gmalloc(c, n)))
        return 0;
    v[0] = n;
    v[1] = g;
    v[2] = OWNED_BINARY;
    v[3] = v[4] = 0;
    if (!binp || !(p = gaddr(c, binp, 20))) {
        gfree(c, g);
        return fail(c, "enif_alloc_binary: bad pointer");
    }
    memcpy(p, v, 20);
    return 1;
}

static uint32_t w_realloc_binary(wasm_exec_env_t x, uint32_t binp, uint32_t n)
{
    uint32_t v[5], g, m;
    void *p, *src, *dst;
    CTX;
    if (!binp || !(p = gaddr(c, binp, 20)))
        return fail(c, "enif_realloc_binary: bad pointer");
    memcpy(v, p, 20);
    if (v[2] != OWNED_BINARY)
        return 0;
    if (!(g = gmalloc(c, n)))
        return 0;
    m = v[0] < n ? v[0] : n;
    if (m && (src = gaddr(c, v[1], m)) && (dst = gaddr(c, g, m)))
        memcpy(dst, src, m);
    gfree(c, v[1]);
    v[0] = n;
    v[1] = g;
    if (!(p = gaddr(c, binp, 20)))
        return fail(c, "enif_realloc_binary: bad pointer");
    memcpy(p, v, 20);
    return 1;
}

static void w_release_binary(wasm_exec_env_t x, uint32_t binp)
{
    uint32_t v[5];
    void *p;
    CTXV;
    if (!binp || !(p = gaddr(c, binp, 20))) {
        fail(c, "enif_release_binary: bad pointer");
        return;
    }
    memcpy(v, p, 20);
    if (v[2] != OWNED_BINARY)
        return;
    v[2] = 0;
    memcpy(p, v, 20);
    gfree(c, v[1]);
}

static uint32_t w_make_binary(wasm_exec_env_t x, uint32_t e, uint32_t binp)
{
    uint32_t v[5];
    void *p, *src;
    unsigned char *dst;
    ERL_NIF_TERM t;
    CTX;
    ENV(env, e);
    if (!binp || !(p = gaddr(c, binp, 20)))
        return fail(c, "enif_make_binary: bad pointer");
    memcpy(v, p, 20);
    if (v[0] && !(src = gaddr(c, v[1], v[0])))
        return fail(c, "enif_make_binary: bad data");
    if (!(dst = enif_make_new_binary(env, v[0], &t)))
        return fail(c, "enif_make_binary: no memory");
    if (v[0])
        memcpy(dst, src, v[0]);
    if (v[2] == OWNED_BINARY) {
        v[2] = 0;
        memcpy(p, v, 20);
        gfree(c, v[1]);
    }
    RET(e, t);
}

static uint32_t w_make_new_binary(wasm_exec_env_t x, uint32_t e, uint32_t n, uint32_t termp)
{
    unsigned char *hp;
    ERL_NIF_TERM t;
    uint32_t g, h;
    slot_t *sl;
    CTX;
    ENV(env, e);
    sl = &c->slots[e - 1];
    if (!(g = scratch(c, e, n)))
        return 0;
    if (!grow((void **)&sl->pend, &sl->cappend, sl->npend + 1, sizeof(pending_t)))
        return 0;
    if (!(hp = enif_make_new_binary(env, n, &t)))
        return 0;
    sl->pend[sl->npend++] = (pending_t){ hp, g, n };
    c->npend++;
    if (!(h = handle(c, e, t)) || !put32(c, termp, h))
        return fail(c, "enif_make_new_binary: bad pointer");
    return g;
}

static uint32_t w_make_sub_binary(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t pos, uint32_t n)
{
    CTX;
    ENV(env, e);
    TERM(t, h);
    /* ERTS copies the bytes of a small sub-binary at once. */
    flush_all(c);
    RET(e, enif_make_sub_binary(env, t, pos, n));
}

static uint32_t w_term_to_binary(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t binp)
{
    ErlNifBinary b;
    uint32_t g, v[5];
    void *p;
    CTX;
    ENV(env, e);
    TERM(t, h);
    flush_all(c);
    if (!enif_term_to_binary(env, t, &b))
        return 0;
    if (b.size > UINT32_MAX - 8 || !(g = gmalloc(c, (uint32_t)b.size))) {
        enif_release_binary(&b);
        return 0;
    }
    if (b.size && (p = gaddr(c, g, (uint32_t)b.size)))
        memcpy(p, b.data, b.size);
    v[0] = (uint32_t)b.size;
    v[1] = g;
    v[2] = OWNED_BINARY;
    v[3] = v[4] = 0;
    enif_release_binary(&b);
    if (!binp || !(p = gaddr(c, binp, 20))) {
        gfree(c, g);
        return fail(c, "enif_term_to_binary: bad pointer");
    }
    memcpy(p, v, 20);
    return 1;
}

static uint32_t w_binary_to_term(wasm_exec_env_t x, uint32_t e, uint32_t data, uint32_t n,
                                 uint32_t termp, uint32_t opts)
{
    const unsigned char *src;
    ERL_NIF_TERM t;
    size_t r;
    CTX;
    ENV(env, e);
    if (!(src = gaddr(c, data, n)))
        return fail(c, "enif_binary_to_term: bad data");
    if (!(r = enif_binary_to_term(env, src, n, &t, opts)))
        return 0;
    OUT(termp, e, t);
    return (uint32_t)r;
}

/* --- numbers --- */

static uint32_t w_get_int(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t ip)
{
    int v;
    CTX;
    ENV(env, e);
    TERM(t, h);
    if (!enif_get_int(env, t, &v))
        return 0;
    return put32(c, ip, (uint32_t)v) ? 1 : fail(c, "enif_get_int: bad pointer");
}

static uint32_t w_get_uint(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t ip)
{
    unsigned v;
    CTX;
    ENV(env, e);
    TERM(t, h);
    if (!enif_get_uint(env, t, &v))
        return 0;
    return put32(c, ip, v) ? 1 : fail(c, "enif_get_uint: bad pointer");
}

/* long is 32 bits in wasm32. */
static uint32_t w_get_long(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t ip)
{
    ErlNifSInt64 v;
    CTX;
    ENV(env, e);
    TERM(t, h);
    if (!enif_get_int64(env, t, &v) || v < INT32_MIN || v > INT32_MAX)
        return 0;
    return put32(c, ip, (uint32_t)(int32_t)v) ? 1 : fail(c, "enif_get_long: bad pointer");
}

static uint32_t w_get_ulong(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t ip)
{
    ErlNifUInt64 v;
    CTX;
    ENV(env, e);
    TERM(t, h);
    if (!enif_get_uint64(env, t, &v) || v > UINT32_MAX)
        return 0;
    return put32(c, ip, (uint32_t)v) ? 1 : fail(c, "enif_get_ulong: bad pointer");
}

static uint32_t put64(ctx *c, uint32_t off, const void *v)
{
    void *p = off ? gaddr(c, off, 8) : NULL;
    if (!p)
        return fail(c, "enif: bad pointer");
    memcpy(p, v, 8);
    return 1;
}

static uint32_t w_get_int64(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t ip)
{
    ErlNifSInt64 v;
    CTX;
    ENV(env, e);
    TERM(t, h);
    return enif_get_int64(env, t, &v) ? put64(c, ip, &v) : 0;
}

static uint32_t w_get_uint64(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t ip)
{
    ErlNifUInt64 v;
    CTX;
    ENV(env, e);
    TERM(t, h);
    return enif_get_uint64(env, t, &v) ? put64(c, ip, &v) : 0;
}

static uint32_t w_get_double(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t dp)
{
    double v;
    CTX;
    ENV(env, e);
    TERM(t, h);
    return enif_get_double(env, t, &v) ? put64(c, dp, &v) : 0;
}

static uint32_t w_make_int(wasm_exec_env_t x, uint32_t e, uint32_t i)
{
    CTX;
    ENV(env, e);
    RET(e, enif_make_int(env, (int)i));
}

static uint32_t w_make_uint(wasm_exec_env_t x, uint32_t e, uint32_t i)
{
    CTX;
    ENV(env, e);
    RET(e, enif_make_uint(env, i));
}

static uint32_t w_make_long(wasm_exec_env_t x, uint32_t e, uint32_t i)
{
    CTX;
    ENV(env, e);
    RET(e, enif_make_int64(env, (int32_t)i));
}

static uint32_t w_make_ulong(wasm_exec_env_t x, uint32_t e, uint32_t i)
{
    CTX;
    ENV(env, e);
    RET(e, enif_make_uint64(env, i));
}

static uint32_t w_make_int64(wasm_exec_env_t x, uint32_t e, int64_t i)
{
    CTX;
    ENV(env, e);
    RET(e, enif_make_int64(env, i));
}

static uint32_t w_make_uint64(wasm_exec_env_t x, uint32_t e, uint64_t i)
{
    CTX;
    ENV(env, e);
    RET(e, enif_make_uint64(env, i));
}

static uint32_t w_make_double(wasm_exec_env_t x, uint32_t e, double d)
{
    ERL_NIF_TERM t;
    CTX;
    ENV(env, e);
    t = enif_make_double(env, d);
    RET(e, t);
}

/* --- atoms and strings --- */

static uint32_t w_make_atom(wasm_exec_env_t x, uint32_t e, uint32_t name)
{
    const char *s;
    CTX;
    ENV(env, e);
    if (!(s = gstr(c, name)))
        return fail(c, "enif_make_atom: bad name");
    RET(e, enif_make_atom(env, s));
}

static uint32_t w_make_atom_len(wasm_exec_env_t x, uint32_t e, uint32_t name, uint32_t len)
{
    const char *s;
    CTX;
    ENV(env, e);
    if (!(s = gaddr(c, name, len)))
        return fail(c, "enif_make_atom_len: bad name");
    RET(e, enif_make_atom_len(env, s, len));
}

static uint32_t w_make_existing_atom(wasm_exec_env_t x, uint32_t e, uint32_t name, uint32_t ap, uint32_t enc)
{
    const char *s;
    ERL_NIF_TERM t;
    CTX;
    ENV(env, e);
    if (!(s = gstr(c, name)))
        return fail(c, "enif_make_existing_atom: bad name");
    if (!enif_make_existing_atom(env, s, &t, (ErlNifCharEncoding)enc))
        return 0;
    OUT(ap, e, t);
    return 1;
}

static uint32_t w_make_existing_atom_len(wasm_exec_env_t x, uint32_t e, uint32_t name, uint32_t len,
                                         uint32_t ap, uint32_t enc)
{
    const char *s;
    ERL_NIF_TERM t;
    CTX;
    ENV(env, e);
    if (!(s = gaddr(c, name, len)))
        return fail(c, "enif_make_existing_atom_len: bad name");
    if (!enif_make_existing_atom_len(env, s, len, &t, (ErlNifCharEncoding)enc))
        return 0;
    OUT(ap, e, t);
    return 1;
}

static uint32_t w_make_new_atom(wasm_exec_env_t x, uint32_t e, uint32_t name, uint32_t ap, uint32_t enc)
{
    const char *s;
    ERL_NIF_TERM t;
    CTX;
    ENV(env, e);
    if (!(s = gstr(c, name)))
        return fail(c, "enif_make_new_atom: bad name");
    if (!enif_make_new_atom(env, s, &t, (ErlNifCharEncoding)enc))
        return 0;
    OUT(ap, e, t);
    return 1;
}

static uint32_t w_make_new_atom_len(wasm_exec_env_t x, uint32_t e, uint32_t name, uint32_t len,
                                    uint32_t ap, uint32_t enc)
{
    const char *s;
    ERL_NIF_TERM t;
    CTX;
    ENV(env, e);
    if (!(s = gaddr(c, name, len)))
        return fail(c, "enif_make_new_atom_len: bad name");
    if (!enif_make_new_atom_len(env, s, len, &t, (ErlNifCharEncoding)enc))
        return 0;
    OUT(ap, e, t);
    return 1;
}

static uint32_t w_get_atom(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t buf, uint32_t len, uint32_t enc)
{
    char *p;
    CTX;
    ENV(env, e);
    TERM(t, h);
    if (!(p = gaddr(c, buf, len)))
        return fail(c, "enif_get_atom: bad buffer");
    return (uint32_t)enif_get_atom(env, t, p, len, (ErlNifCharEncoding)enc);
}

static uint32_t w_get_atom_length(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t lp, uint32_t enc)
{
    unsigned n;
    CTX;
    ENV(env, e);
    TERM(t, h);
    if (!enif_get_atom_length(env, t, &n, (ErlNifCharEncoding)enc))
        return 0;
    return put32(c, lp, n) ? 1 : fail(c, "enif_get_atom_length: bad pointer");
}

static uint32_t w_make_string(wasm_exec_env_t x, uint32_t e, uint32_t str, uint32_t enc)
{
    const char *s;
    CTX;
    ENV(env, e);
    if (!(s = gstr(c, str)))
        return fail(c, "enif_make_string: bad string");
    RET(e, enif_make_string(env, s, (ErlNifCharEncoding)enc));
}

static uint32_t w_make_string_len(wasm_exec_env_t x, uint32_t e, uint32_t str, uint32_t len, uint32_t enc)
{
    const char *s;
    CTX;
    ENV(env, e);
    if (!(s = gaddr(c, str, len)))
        return fail(c, "enif_make_string_len: bad string");
    RET(e, enif_make_string_len(env, s, len, (ErlNifCharEncoding)enc));
}

static uint32_t w_get_string(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t buf, uint32_t len, uint32_t enc)
{
    char *p;
    CTX;
    ENV(env, e);
    TERM(t, h);
    if (!len || !(p = gaddr(c, buf, len)))
        return len ? fail(c, "enif_get_string: bad buffer") : 0;
    return (uint32_t)enif_get_string(env, t, p, len, (ErlNifCharEncoding)enc);
}

static uint32_t w_get_string_length(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t lp, uint32_t enc)
{
    unsigned n;
    CTX;
    ENV(env, e);
    TERM(t, h);
    if (!enif_get_string_length(env, t, &n, (ErlNifCharEncoding)enc))
        return 0;
    return put32(c, lp, n) ? 1 : fail(c, "enif_get_string_length: bad pointer");
}

/* --- tuples and lists (the ... of wasm32 is a pointer to the values) --- */

static uint32_t make_from(wasm_exec_env_t x, uint32_t e, uint32_t arr, uint32_t n, int tuple)
{
    ERL_NIF_TERM *ts, t;
    CTX;
    ENV(env, e);
    if (n > (1u << 24) || !(ts = malloc((n ? n : 1) * sizeof(ERL_NIF_TERM))))
        return fail(c, "enif: too many elements");
    if (!get_terms(c, arr, n, ts)) {
        free(ts);
        return fail(c, "enif: bad term");
    }
    t = tuple ? enif_make_tuple_from_array(env, ts, n) : enif_make_list_from_array(env, ts, n);
    free(ts);
    RET(e, t);
}

static uint32_t w_make_tuple(wasm_exec_env_t x, uint32_t e, uint32_t n, uint32_t va)
{
    return make_from(x, e, va, n, 1);
}

static uint32_t w_make_tuple_from_array(wasm_exec_env_t x, uint32_t e, uint32_t arr, uint32_t n)
{
    return make_from(x, e, arr, n, 1);
}

static uint32_t w_make_list(wasm_exec_env_t x, uint32_t e, uint32_t n, uint32_t va)
{
    return make_from(x, e, va, n, 0);
}

static uint32_t w_make_list_from_array(wasm_exec_env_t x, uint32_t e, uint32_t arr, uint32_t n)
{
    return make_from(x, e, arr, n, 0);
}

static uint32_t w_get_tuple(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t arityp, uint32_t arrayp)
{
    const ERL_NIF_TERM *arr;
    int arity;
    uint32_t g;
    CTX;
    ENV(env, e);
    TERM(t, h);
    if (!enif_get_tuple(env, t, &arity, &arr))
        return 0;
    if (!(g = put_terms(c, e, arr, (uint32_t)arity)))
        return fail(c, "enif_get_tuple: no memory");
    if (!put32(c, arityp, (uint32_t)arity) || !put32(c, arrayp, g))
        return fail(c, "enif_get_tuple: bad pointer");
    return 1;
}

static uint32_t w_make_list_cell(wasm_exec_env_t x, uint32_t e, uint32_t hh, uint32_t th)
{
    CTX;
    ENV(env, e);
    TERM(hd, hh);
    TERM(tl, th);
    RET(e, enif_make_list_cell(env, hd, tl));
}

static uint32_t w_get_list_cell(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t hp, uint32_t tp)
{
    ERL_NIF_TERM hd, tl;
    CTX;
    ENV(env, e);
    TERM(t, h);
    if (!enif_get_list_cell(env, t, &hd, &tl))
        return 0;
    OUT(hp, e, hd);
    OUT(tp, e, tl);
    return 1;
}

static uint32_t w_get_list_length(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t lp)
{
    unsigned n;
    CTX;
    ENV(env, e);
    TERM(t, h);
    if (!enif_get_list_length(env, t, &n))
        return 0;
    return put32(c, lp, n) ? 1 : fail(c, "enif_get_list_length: bad pointer");
}

static uint32_t w_make_reverse_list(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t lp)
{
    ERL_NIF_TERM r;
    CTX;
    ENV(env, e);
    TERM(t, h);
    if (!enif_make_reverse_list(env, t, &r))
        return 0;
    OUT(lp, e, r);
    return 1;
}

/* --- maps --- */

static uint32_t w_make_new_map(wasm_exec_env_t x, uint32_t e)
{
    CTX;
    ENV(env, e);
    RET(e, enif_make_new_map(env));
}

static uint32_t w_make_map_put(wasm_exec_env_t x, uint32_t e, uint32_t mh, uint32_t kh, uint32_t vh, uint32_t op)
{
    ERL_NIF_TERM r;
    CTX;
    ENV(env, e);
    TERM(m, mh);
    TERM(k, kh);
    TERM(v, vh);
    flush_all(c);
    if (!enif_make_map_put(env, m, k, v, &r))
        return 0;
    OUT(op, e, r);
    return 1;
}

static uint32_t w_make_map_update(wasm_exec_env_t x, uint32_t e, uint32_t mh, uint32_t kh, uint32_t vh, uint32_t op)
{
    ERL_NIF_TERM r;
    CTX;
    ENV(env, e);
    TERM(m, mh);
    TERM(k, kh);
    TERM(v, vh);
    flush_all(c);
    if (!enif_make_map_update(env, m, k, v, &r))
        return 0;
    OUT(op, e, r);
    return 1;
}

static uint32_t w_make_map_remove(wasm_exec_env_t x, uint32_t e, uint32_t mh, uint32_t kh, uint32_t op)
{
    ERL_NIF_TERM r;
    CTX;
    ENV(env, e);
    TERM(m, mh);
    TERM(k, kh);
    flush_all(c);
    if (!enif_make_map_remove(env, m, k, &r))
        return 0;
    OUT(op, e, r);
    return 1;
}

static uint32_t w_get_map_value(wasm_exec_env_t x, uint32_t e, uint32_t mh, uint32_t kh, uint32_t vp)
{
    ERL_NIF_TERM v;
    CTX;
    ENV(env, e);
    TERM(m, mh);
    TERM(k, kh);
    flush_all(c);
    if (!enif_get_map_value(env, m, k, &v))
        return 0;
    OUT(vp, e, v);
    return 1;
}

static uint32_t w_get_map_size(wasm_exec_env_t x, uint32_t e, uint32_t mh, uint32_t sp)
{
    size_t n;
    CTX;
    ENV(env, e);
    TERM(m, mh);
    if (!enif_get_map_size(env, m, &n))
        return 0;
    return put32(c, sp, (uint32_t)n) ? 1 : fail(c, "enif_get_map_size: bad pointer");
}

static uint32_t w_make_map_from_arrays(wasm_exec_env_t x, uint32_t e, uint32_t keys, uint32_t vals,
                                       uint32_t n, uint32_t op)
{
    ERL_NIF_TERM *ks, *vs, r;
    int ok;
    CTX;
    ENV(env, e);
    if (n > (1u << 24))
        return fail(c, "enif_make_map_from_arrays: too many elements");
    ks = malloc((n ? n : 1) * sizeof(ERL_NIF_TERM));
    vs = malloc((n ? n : 1) * sizeof(ERL_NIF_TERM));
    ok = ks && vs && get_terms(c, keys, n, ks) && get_terms(c, vals, n, vs);
    flush_all(c);
    if (ok)
        ok = enif_make_map_from_arrays(env, ks, vs, n, &r);
    free(ks);
    free(vs);
    if (!ok)
        return 0;
    OUT(op, e, r);
    return 1;
}

/* An iterator of the module holds an index into ctx.iters (in its first
 * word). The module never reads the other fields. */
static ErlNifMapIterator *iter_of(ctx *c, uint32_t ip, uint32_t *idx)
{
    uint32_t i;
    if (!get32(c, ip, &i) || i == 0 || i > c->niter || !c->iters[i - 1])
        return NULL;
    if (idx)
        *idx = i - 1;
    return c->iters[i - 1];
}

static uint32_t w_map_iterator_create(wasm_exec_env_t x, uint32_t e, uint32_t mh, uint32_t ip, uint32_t entry)
{
    ErlNifMapIterator *it;
    uint32_t i;
    CTX;
    ENV(env, e);
    TERM(m, mh);
    if (!(it = malloc(sizeof(*it))))
        return 0;
    if (!enif_map_iterator_create(env, m, it, (ErlNifMapIteratorEntry)entry)) {
        free(it);
        return 0;
    }
    for (i = 0; i < c->niter && c->iters[i]; i++)
        ;
    if (i == c->niter && !grow((void **)&c->iters, &c->capiter, ++c->niter, sizeof(void *))) {
        c->niter--;
        enif_map_iterator_destroy(env, it);
        free(it);
        return 0;
    }
    c->iters[i] = it;
    if (!put32(c, ip, i + 1)) {
        c->iters[i] = NULL;
        enif_map_iterator_destroy(env, it);
        free(it);
        return fail(c, "enif_map_iterator_create: bad pointer");
    }
    return 1;
}

static void w_map_iterator_destroy(wasm_exec_env_t x, uint32_t e, uint32_t ip)
{
    ErlNifMapIterator *it;
    slot_t *sl;
    uint32_t i;
    CTXV;
    if (!(sl = slot_of(c, e)) || !(it = iter_of(c, ip, &i))) {
        fail(c, "enif_map_iterator_destroy: bad iterator");
        return;
    }
    enif_map_iterator_destroy(sl->env, it);
    free(it);
    c->iters[i] = NULL;
}

#define ITER(name) static uint32_t w_map_iterator_##name(wasm_exec_env_t x, uint32_t e, uint32_t ip) \
    { ErlNifMapIterator *it; CTX; ENV(env, e); \
      if (!(it = iter_of(c, ip, NULL))) return fail(c, "enif_map_iterator: bad iterator"); \
      return (uint32_t)enif_map_iterator_##name(env, it); }
ITER(is_head) ITER(is_tail) ITER(next) ITER(prev)

static uint32_t w_map_iterator_get_pair(wasm_exec_env_t x, uint32_t e, uint32_t ip, uint32_t kp, uint32_t vp)
{
    ErlNifMapIterator *it;
    ERL_NIF_TERM k, v;
    CTX;
    ENV(env, e);
    if (!(it = iter_of(c, ip, NULL)))
        return fail(c, "enif_map_iterator_get_pair: bad iterator");
    if (!enif_map_iterator_get_pair(env, it, &k, &v))
        return 0;
    OUT(kp, e, k);
    OUT(vp, e, v);
    return 1;
}

/* --- other terms --- */

static uint32_t w_make_ref(wasm_exec_env_t x, uint32_t e)
{
    CTX;
    ENV(env, e);
    RET(e, enif_make_ref(env));
}

static uint32_t w_make_unique_integer(wasm_exec_env_t x, uint32_t e, uint32_t props)
{
    CTX;
    ENV(env, e);
    RET(e, enif_make_unique_integer(env, (ErlNifUniqueInteger)props));
}

static uint32_t w_make_copy(wasm_exec_env_t x, uint32_t e, uint32_t h)
{
    CTX;
    ENV(env, e);
    TERM(t, h);
    flush_all(c);
    RET(e, enif_make_copy(env, t));
}

static uint32_t w_cpu_time(wasm_exec_env_t x, uint32_t e)
{
    CTX;
    ENV(env, e);
    RET(e, enif_cpu_time(env));
}

static uint32_t w_now_time(wasm_exec_env_t x, uint32_t e)
{
    CTX;
    ENV(env, e);
    RET(e, enif_now_time(env));
}

/* --- environments and processes (ErlNifPid of wasm32: one handle) --- */

static uint32_t w_alloc_env(wasm_exec_env_t x)
{
    ErlNifEnv *env;
    int s;
    CTX;
    if (!(env = enif_alloc_env()))
        return 0;
    if ((s = slot_open(c, env, 1)) < 0) {
        enif_free_env(env);
        return 0;
    }
    return (uint32_t)s + 1;
}

static void w_free_env(wasm_exec_env_t x, uint32_t e)
{
    slot_t *sl;
    CTXV;
    if (!(sl = slot_of(c, e)) || !sl->owned) {
        fail(c, "enif_free_env: bad environment");
        return;
    }
    enif_free_env(sl->env);
    slot_close(c, (int)e - 1);
}

static void w_clear_env(wasm_exec_env_t x, uint32_t e)
{
    slot_t *sl;
    CTXV;
    if (!(sl = slot_of(c, e)) || !sl->owned) {
        fail(c, "enif_clear_env: bad environment");
        return;
    }
    enif_clear_env(sl->env);
    slot_reset(c, sl);
}

static int get_pid(ctx *c, uint32_t pidp, ErlNifPid *pid)
{
    uint32_t h;
    return get32(c, pidp, &h) && get_term(c, h, &pid->pid);
}

static uint32_t w_send(wasm_exec_env_t x, uint32_t e, uint32_t pidp, uint32_t me, uint32_t mh)
{
    ErlNifEnv *env = NULL, *menv = NULL;
    slot_t *msl = NULL;
    ErlNifPid pid;
    int r;
    CTX;
    TERM(m, mh);
    if (e) {
        slot_t *sl = slot_of(c, e);
        if (!sl)
            return fail(c, "enif_send: bad environment");
        env = sl->env;
    }
    if (me) {
        if (!(msl = slot_of(c, me)) || !msl->owned)
            return fail(c, "enif_send: bad message environment");
        menv = msl->env;
    }
    if (!get_pid(c, pidp, &pid))
        return fail(c, "enif_send: bad pid");
    flush_all(c);
    r = enif_send(env, &pid, menv, m);
    /* enif_send clears the message environment. */
    if (msl)
        slot_reset(c, msl);
    return (uint32_t)r;
}

static uint32_t w_self(wasm_exec_env_t x, uint32_t e, uint32_t pidp)
{
    ErlNifPid pid;
    CTX;
    ENV(env, e);
    if (!enif_self(env, &pid))
        return 0;
    OUT(pidp, e, pid.pid);
    return pidp;
}

static uint32_t w_get_local_pid(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t pidp)
{
    ErlNifPid pid;
    CTX;
    ENV(env, e);
    TERM(t, h);
    if (!enif_get_local_pid(env, t, &pid))
        return 0;
    OUT(pidp, e, pid.pid);
    return 1;
}

static uint32_t w_is_process_alive(wasm_exec_env_t x, uint32_t e, uint32_t pidp)
{
    ErlNifPid pid;
    CTX;
    ENV(env, e);
    if (!get_pid(c, pidp, &pid))
        return fail(c, "enif_is_process_alive: bad pid");
    return (uint32_t)enif_is_process_alive(env, &pid);
}

static uint32_t w_is_current_process_alive(wasm_exec_env_t x, uint32_t e)
{
    CTX;
    ENV(env, e);
    return (uint32_t)enif_is_current_process_alive(env);
}

static uint32_t w_whereis_pid(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t pidp)
{
    ErlNifPid pid;
    CTX;
    ENV(env, e);
    TERM(t, h);
    if (!enif_whereis_pid(env, t, &pid))
        return 0;
    OUT(pidp, e, pid.pid);
    return 1;
}

static void w_set_pid_undefined(wasm_exec_env_t x, uint32_t pidp)
{
    ErlNifPid pid;
    uint32_t h;
    CTXV;
    enif_set_pid_undefined(&pid);
    if (!(h = intern(c, pid.pid)) || !put32(c, pidp, h))
        fail(c, "enif_set_pid_undefined: bad pointer");
}

static uint32_t w_is_pid_undefined(wasm_exec_env_t x, uint32_t pidp)
{
    ErlNifPid pid;
    CTX;
    if (!get_pid(c, pidp, &pid))
        return fail(c, "enif_is_pid_undefined: bad pid");
    return (uint32_t)enif_is_pid_undefined(&pid);
}

/* --- resources (the module sees the address of its memory) --- */

/* ErlNifMonitor of wasm32: 16 bytes. The first word is the index + 1 of
 * the monitor in ctx.mons (0: no monitor). */
static int put_mon(ctx *c, uint32_t off, uint32_t id)
{
    uint32_t v[4] = { id, 0, 0, 0 };
    void *p = off ? gaddr(c, off, 16) : NULL;
    if (!p)
        return 0;
    memcpy(p, v, 16);
    return 1;
}

static mon_t *mon_of(ctx *c, uint32_t off)
{
    uint32_t id;
    if (!get32(c, off, &id) || id == 0 || id > c->nmon || !c->mons[id - 1].used)
        return NULL;
    return &c->mons[id - 1];
}

static void host_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *mon)
{
    hres_t *h = obj;
    ctx *c = h->c;
    rtype_t *rt;
    uint32_t id = 0, i, a[4], gp, gm, hp;
    int s;
    if (!c)
        return;
    enter(c);
    for (i = 0; i < c->nmon; i++)
        if (c->mons[i].used && c->mons[i].h == h && !enif_compare_monitors(&c->mons[i].m, mon)) {
            id = i + 1;
            break;
        }
    rt = &c->rtypes[h->rtype];
    if (rt->down && (s = slot_open(c, env, 0)) >= 0) {
        gp = scratch(c, s + 1, 4);
        gm = scratch(c, s + 1, 16);
        hp = handle(c, s + 1, pid->pid);
        if (gp && gm && hp && put32(c, gp, hp) && put_mon(c, gm, id)) {
            a[0] = s + 1;
            a[1] = h->gptr;
            a[2] = gp;
            a[3] = gm;
            if (!guest_call(c, rt->down, 4, a))
                wasm_runtime_clear_exception(c->inst);
        }
        flush_all(c);
        slot_close(c, s);
    }
    /* The monitor fired: it is gone. */
    if (id)
        c->mons[id - 1].used = 0;
    leave(c);
}

static uint32_t open_rtype(ctx *c, ErlNifEnv *env, const char *name, uint32_t dtor, uint32_t down,
                           uint32_t flags, uint32_t triedp)
{
    ErlNifResourceTypeInit init;
    ErlNifResourceFlags tried = 0;
    ErlNifResourceType *type;
    memset(&init, 0, sizeof(init));
    init.dtor = host_dtor;
    init.down = down ? host_down : NULL;
    if (!grow((void **)&c->rtypes, &c->caprt, c->nrt + 1, sizeof(rtype_t)))
        return 0;
    type = enif_open_resource_type_x(env, name, &init, (ErlNifResourceFlags)flags, &tried);
    if (triedp && !put32(c, triedp, (uint32_t)tried))
        return fail(c, "enif_open_resource_type: bad pointer");
    if (!type)
        return 0;
    c->rtypes[c->nrt].type = type;
    c->rtypes[c->nrt].dtor = dtor;
    c->rtypes[c->nrt].down = down;
    return ++c->nrt;
}

static uint32_t w_open_resource_type(wasm_exec_env_t x, uint32_t e, uint32_t mod, uint32_t name,
                                     uint32_t dtor, uint32_t flags, uint32_t triedp)
{
    const char *s;
    CTX;
    ENV(env, e);
    (void)mod;
    if (!(s = gstr(c, name)))
        return fail(c, "enif_open_resource_type: bad name");
    return open_rtype(c, env, s, dtor, 0, flags, triedp);
}

/* ErlNifResourceTypeInit of wasm32: dtor, stop, down, members, dyncall.
 * The destructor and the down callback are used (enif_select does not
 * run, so stop does not). enif_init_resource_type uses down only when
 * members says that it is there (3 or more). */
static uint32_t init_rtype(wasm_exec_env_t x, uint32_t e, uint32_t name, uint32_t initp,
                           uint32_t flags, uint32_t triedp, int with_members)
{
    const char *s;
    const uint8_t *p;
    uint32_t w[4];
    CTX;
    ENV(env, e);
    if (!(s = gstr(c, name)) || !(p = gaddr(c, initp, with_members ? 16 : 12)))
        return fail(c, "enif_open_resource_type_x: bad argument");
    memcpy(w, p, with_members ? 16 : 12);
    if (with_members && w[3] < 3)
        w[2] = 0;
    return open_rtype(c, env, s, w[0], w[2], flags, triedp);
}

static uint32_t w_open_resource_type_x(wasm_exec_env_t x, uint32_t e, uint32_t name, uint32_t initp,
                                       uint32_t flags, uint32_t triedp)
{
    return init_rtype(x, e, name, initp, flags, triedp, 0);
}

static uint32_t w_init_resource_type(wasm_exec_env_t x, uint32_t e, uint32_t name, uint32_t initp,
                                     uint32_t flags, uint32_t triedp)
{
    return init_rtype(x, e, name, initp, flags, triedp, 1);
}

static rtype_t *rtype_of(ctx *c, uint32_t type)
{
    return type == 0 || type > c->nrt ? NULL : &c->rtypes[type - 1];
}

static uint32_t w_alloc_resource(wasm_exec_env_t x, uint32_t type, uint32_t n)
{
    rtype_t *rt;
    hres_t *h;
    uint32_t g;
    CTX;
    if (!(rt = rtype_of(c, type)))
        return fail(c, "enif_alloc_resource: bad type");
    if (!(h = enif_alloc_resource(rt->type, sizeof(hres_t))))
        return 0;
    h->c = NULL;
    if (!(g = gmalloc(c, n)) || !res_put(c, g, h)) {
        gfree(c, g);
        enif_release_resource(h);
        return 0;
    }
    h->c = c;
    h->rtype = type - 1;
    h->gptr = g;
    h->size = n;
    return g;
}

static void w_release_resource(wasm_exec_env_t x, uint32_t obj)
{
    hres_t *h;
    CTXV;
    if (!(h = res_get(c, obj))) {
        fail(c, "enif_release_resource: bad resource");
        return;
    }
    enif_release_resource(h);
}

static void w_keep_resource(wasm_exec_env_t x, uint32_t obj)
{
    hres_t *h;
    CTXV;
    if (!(h = res_get(c, obj))) {
        fail(c, "enif_keep_resource: bad resource");
        return;
    }
    enif_keep_resource(h);
}

static uint32_t w_make_resource(wasm_exec_env_t x, uint32_t e, uint32_t obj)
{
    hres_t *h;
    CTX;
    ENV(env, e);
    if (!(h = res_get(c, obj)))
        return fail(c, "enif_make_resource: bad resource");
    RET(e, enif_make_resource(env, h));
}

static uint32_t w_get_resource(wasm_exec_env_t x, uint32_t e, uint32_t th, uint32_t type, uint32_t objp)
{
    rtype_t *rt;
    void *obj;
    CTX;
    ENV(env, e);
    TERM(t, th);
    if (!(rt = rtype_of(c, type)))
        return fail(c, "enif_get_resource: bad type");
    if (!enif_get_resource(env, t, rt->type, &obj) || !((hres_t *)obj)->c)
        return 0;
    return put32(c, objp, ((hres_t *)obj)->gptr) ? 1 : fail(c, "enif_get_resource: bad pointer");
}

static uint32_t w_sizeof_resource(wasm_exec_env_t x, uint32_t obj)
{
    hres_t *h;
    CTX;
    if (!(h = res_get(c, obj)))
        return fail(c, "enif_sizeof_resource: bad resource");
    return h->size;
}

/* --- exceptions and scheduling --- */

static uint32_t w_make_badarg(wasm_exec_env_t x, uint32_t e)
{
    CTX;
    ENV(env, e);
    RET(e, enif_make_badarg(env));
}

static uint32_t w_raise_exception(wasm_exec_env_t x, uint32_t e, uint32_t h)
{
    CTX;
    ENV(env, e);
    TERM(t, h);
    RET(e, enif_raise_exception(env, t));
}

static uint32_t w_has_pending_exception(wasm_exec_env_t x, uint32_t e, uint32_t rp)
{
    ERL_NIF_TERM r;
    CTX;
    ENV(env, e);
    if (!enif_has_pending_exception(env, &r))
        return 0;
    if (rp)
        OUT(rp, e, r);
    return 1;
}

static uint32_t w_consume_timeslice(wasm_exec_env_t x, uint32_t e, uint32_t percent)
{
    CTX;
    ENV(env, e);
    return (uint32_t)enif_consume_timeslice(env, (int)percent);
}

static const char *keep_string(ctx *c, const char *s)
{
    uint32_t i;
    for (i = 0; i < c->nstrings; i++)
        if (!strcmp(c->strings[i], s))
            return c->strings[i];
    if (!grow((void **)&c->strings, &c->capstrings, c->nstrings + 1, sizeof(char *)))
        return NULL;
    if (!(c->strings[c->nstrings] = strdup(s)))
        return NULL;
    return c->strings[c->nstrings++];
}

static uint32_t w_schedule_nif(wasm_exec_env_t x, uint32_t e, uint32_t name, uint32_t flags,
                               uint32_t fp, uint32_t argc, uint32_t argv)
{
    ERL_NIF_TERM ts[256], r;
    const char *s;
    CTX;
    ENV(env, e);
    if (argc > 254 || !(s = gstr(c, name)) || !(s = keep_string(c, s)))
        return fail(c, "enif_schedule_nif: bad argument");
    if (!get_terms(c, argv, argc, ts))
        return fail(c, "enif_schedule_nif: bad term");
    ts[argc] = enif_make_uint(env, fp);
    r = enif_schedule_nif(env, s, (int)flags, sched_tramp, (int)argc + 1, ts);
    RET(e, r);
}

static uint32_t w_thread_type(wasm_exec_env_t x)
{
    (void)x;
    return (uint32_t)enif_thread_type();
}

static int64_t w_monotonic_time(wasm_exec_env_t x, uint32_t unit)
{
    (void)x;
    return enif_monotonic_time((ErlNifTimeUnit)unit);
}

static int64_t w_time_offset(wasm_exec_env_t x, uint32_t unit)
{
    (void)x;
    return enif_time_offset((ErlNifTimeUnit)unit);
}

static int64_t w_convert_time_unit(wasm_exec_env_t x, int64_t v, uint32_t from, uint32_t to)
{
    (void)x;
    return enif_convert_time_unit(v, (ErlNifTimeUnit)from, (ErlNifTimeUnit)to);
}

/* --- threads: the module has none. Its locks do nothing (the calls of
 * a library run one at a time), and it cannot start a thread. --- */

static uint32_t w_lock_create(wasm_exec_env_t x, uint32_t name)
{
    (void)x;
    (void)name;
    return 1;
}

static void w_lock_op(wasm_exec_env_t x, uint32_t lock)
{
    (void)x;
    (void)lock;
}

static uint32_t w_lock_try(wasm_exec_env_t x, uint32_t lock)
{
    (void)x;
    (void)lock;
    return 0;
}

static void w_cond_wait(wasm_exec_env_t x, uint32_t cnd, uint32_t mtx)
{
    (void)x;
    (void)cnd;
    (void)mtx;
}

static uint32_t w_thread_create(wasm_exec_env_t x, uint32_t name, uint32_t tidp, uint32_t func,
                                uint32_t args, uint32_t opts)
{
    (void)x;
    (void)name;
    (void)tidp;
    (void)func;
    (void)args;
    (void)opts;
    return EAGAIN;
}

static uint32_t w_thread_self(wasm_exec_env_t x)
{
    (void)x;
    return 1;
}

static uint32_t w_equal_tids(wasm_exec_env_t x, uint32_t a, uint32_t b)
{
    (void)x;
    return a == b;
}

static uint32_t w_tsd_key_create(wasm_exec_env_t x, uint32_t name, uint32_t keyp)
{
    CTX;
    (void)name;
    if (c->ntsd >= MAX_TSD)
        return ENOMEM;
    c->tsd[c->ntsd] = 0;
    return put32(c, keyp, c->ntsd++) ? 0 : (fail(c, "enif_tsd_key_create: bad pointer"), EINVAL);
}

static void w_tsd_set(wasm_exec_env_t x, uint32_t key, uint32_t data)
{
    CTXV;
    if (key < c->ntsd)
        c->tsd[key] = data;
}

static uint32_t w_tsd_get(wasm_exec_env_t x, uint32_t key)
{
    CTX;
    return key < c->ntsd ? c->tsd[key] : 0;
}

static uint32_t w_getenv(wasm_exec_env_t x, uint32_t key, uint32_t value, uint32_t sizep)
{
    const char *k;
    uint32_t n;
    size_t sz;
    char *buf;
    void *p;
    int r;
    CTX;
    if (!(k = gstr(c, key)) || !get32(c, sizep, &n))
        return fail(c, "enif_getenv: bad argument");
    sz = n;
    if (!(buf = malloc(n ? n : 1)))
        return (uint32_t)-1;
    r = enif_getenv(k, buf, &sz);
    if (r == 0 && sz <= n && (p = gaddr(c, value, (uint32_t)sz + 1)))
        memcpy(p, buf, sz + 1);
    free(buf);
    put32(c, sizep, (uint32_t)sz);
    return (uint32_t)r;
}

/* --- ports (ErlNifPort of wasm32: one handle) --- */

static uint32_t w_get_local_port(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t portp)
{
    ErlNifPort port;
    CTX;
    ENV(env, e);
    TERM(t, h);
    if (!enif_get_local_port(env, t, &port))
        return 0;
    OUT(portp, e, port.port_id);
    return 1;
}

static int get_port(ctx *c, uint32_t portp, ErlNifPort *port)
{
    uint32_t h;
    return get32(c, portp, &h) && get_term(c, h, &port->port_id);
}

static uint32_t w_is_port_alive(wasm_exec_env_t x, uint32_t e, uint32_t portp)
{
    ErlNifPort port;
    CTX;
    ENV(env, e);
    if (!get_port(c, portp, &port))
        return fail(c, "enif_is_port_alive: bad port");
    return (uint32_t)enif_is_port_alive(env, &port);
}

static uint32_t w_whereis_port(wasm_exec_env_t x, uint32_t e, uint32_t h, uint32_t portp)
{
    ErlNifPort port;
    CTX;
    ENV(env, e);
    TERM(t, h);
    if (!enif_whereis_port(env, t, &port))
        return 0;
    OUT(portp, e, port.port_id);
    return 1;
}

static uint32_t w_port_command(wasm_exec_env_t x, uint32_t e, uint32_t portp, uint32_t me, uint32_t mh)
{
    ErlNifEnv *menv = NULL;
    slot_t *msl = NULL;
    ErlNifPort port;
    int r;
    CTX;
    ENV(env, e);
    TERM(m, mh);
    if (me) {
        if (!(msl = slot_of(c, me)) || !msl->owned)
            return fail(c, "enif_port_command: bad message environment");
        menv = msl->env;
    }
    if (!get_port(c, portp, &port))
        return fail(c, "enif_port_command: bad port");
    flush_all(c);
    r = enif_port_command(env, &port, menv, m);
    return (uint32_t)r;
}

/* --- what a module in WebAssembly cannot do --- */

/* No file descriptors of the host: a negative value, ERL_NIF_SELECT_FAILED. */
static uint32_t w_select(wasm_exec_env_t x, uint32_t e, uint32_t ev, uint32_t mode, uint32_t obj,
                         uint32_t pidp, uint32_t ref)
{
    (void)x;
    (void)e;
    (void)ev;
    (void)mode;
    (void)obj;
    (void)pidp;
    (void)ref;
    return (uint32_t)INT32_MIN | ERL_NIF_SELECT_FAILED | ERL_NIF_SELECT_NOTSUP;
}

/* No native libraries. */
static uint32_t w_dlopen(wasm_exec_env_t x, uint32_t lib, uint32_t handler, uint32_t arg)
{
    (void)x;
    (void)lib;
    (void)handler;
    (void)arg;
    return 0;
}

static uint32_t w_dlsym(wasm_exec_env_t x, uint32_t lib, uint32_t sym, uint32_t handler, uint32_t arg)
{
    (void)x;
    (void)lib;
    (void)sym;
    (void)handler;
    (void)arg;
    return 0;
}

/* The options (on halt, on unload of a thread) need native callbacks:
 * a failure. */
static uint32_t w_set_option(wasm_exec_env_t x, uint32_t e, uint32_t opt, uint32_t va)
{
    (void)x;
    (void)e;
    (void)opt;
    (void)va;
    return EINVAL;
}

/* A copy of the bytes: memory of the module can move. */
static uint32_t w_make_resource_binary(wasm_exec_env_t x, uint32_t e, uint32_t obj, uint32_t data, uint32_t n)
{
    unsigned char *dst;
    const void *src;
    ERL_NIF_TERM t;
    CTX;
    ENV(env, e);
    (void)obj;
    if (n && !(src = gaddr(c, data, n)))
        return fail(c, "enif_make_resource_binary: bad data");
    if (!(dst = enif_make_new_binary(env, n, &t)))
        return 0;
    if (n)
        memcpy(dst, src, n);
    RET(e, t);
}

/* ErlNifSysInfo of wasm32: 11 words (the two strings are pointers into
 * memory of the module, made one time). */
static void w_system_info(wasm_exec_env_t x, uint32_t sip, uint32_t n)
{
    ErlNifSysInfo si;
    uint32_t v[11], i;
    void *p;
    CTXV;
    enif_system_info(&si, sizeof(si));
    for (i = 0; i < 2; i++) {
        const char *s = i ? si.otp_release : si.erts_version;
        uint32_t *g = i ? &c->otp_release : &c->erts_version, len = (uint32_t)strlen(s) + 1;
        if (!*g && (*g = gmalloc(c, len)) && (p = gaddr(c, *g, len)))
            memcpy(p, s, len);
    }
    v[0] = (uint32_t)si.driver_major_version;
    v[1] = (uint32_t)si.driver_minor_version;
    v[2] = c->erts_version;
    v[3] = c->otp_release;
    v[4] = (uint32_t)si.thread_support;
    v[5] = (uint32_t)si.smp_support;
    v[6] = (uint32_t)si.async_threads;
    v[7] = (uint32_t)si.scheduler_threads;
    v[8] = (uint32_t)si.nif_major_version;
    v[9] = (uint32_t)si.nif_minor_version;
    v[10] = (uint32_t)si.dirty_scheduler_support;
    if (n > sizeof(v))
        n = sizeof(v);
    if (n && (p = gaddr(c, sip, n)))
        memcpy(p, v, n);
}

/* --- monitors (ErlNifMonitor of wasm32: an index into ctx.mons) --- */

static uint32_t w_monitor_process(wasm_exec_env_t x, uint32_t e, uint32_t obj, uint32_t pidp, uint32_t monp)
{
    ErlNifEnv *env = NULL;
    ErlNifMonitor m;
    ErlNifPid pid;
    hres_t *h;
    uint32_t i;
    int r;
    CTX;
    if (e) {
        slot_t *sl = slot_of(c, e);
        if (!sl)
            return fail(c, "enif_monitor_process: bad environment");
        env = sl->env;
    }
    if (!(h = res_get(c, obj)) || !get_pid(c, pidp, &pid))
        return fail(c, "enif_monitor_process: bad argument");
    if (monp) {
        for (i = 0; i < c->nmon && c->mons[i].used; i++)
            ;
        if (i == c->nmon && !grow((void **)&c->mons, &c->capmon, c->nmon + 1, sizeof(mon_t)))
            return fail(c, "enif_monitor_process: no memory");
        if ((r = enif_monitor_process(env, h, &pid, &m)) != 0)
            return (uint32_t)r;
        if (i == c->nmon)
            c->nmon++;
        c->mons[i].m = m;
        c->mons[i].h = h;
        c->mons[i].used = 1;
        if (!put_mon(c, monp, i + 1))
            return fail(c, "enif_monitor_process: bad pointer");
        return 0;
    }
    return (uint32_t)enif_monitor_process(env, h, &pid, NULL);
}

static uint32_t w_demonitor_process(wasm_exec_env_t x, uint32_t e, uint32_t obj, uint32_t monp)
{
    ErlNifEnv *env = NULL;
    hres_t *h;
    mon_t *m;
    int r;
    CTX;
    if (e) {
        slot_t *sl = slot_of(c, e);
        if (!sl)
            return fail(c, "enif_demonitor_process: bad environment");
        env = sl->env;
    }
    if (!(h = res_get(c, obj)))
        return fail(c, "enif_demonitor_process: bad resource");
    if (!(m = mon_of(c, monp)) || m->h != h)
        return 1;
    if ((r = enif_demonitor_process(env, h, &m->m)) == 0)
        m->used = 0;
    return (uint32_t)r;
}

static uint32_t w_compare_monitors(wasm_exec_env_t x, uint32_t ap, uint32_t bp)
{
    uint32_t ia = 0, ib = 0;
    mon_t *a, *b;
    CTX;
    a = mon_of(c, ap);
    b = mon_of(c, bp);
    if (a && b)
        return (uint32_t)enif_compare_monitors(&a->m, &b->m);
    get32(c, ap, &ia);
    get32(c, bp, &ib);
    return ia < ib ? (uint32_t)-1 : ia > ib;
}

static uint32_t w_make_monitor_term(wasm_exec_env_t x, uint32_t e, uint32_t monp)
{
    mon_t *m;
    CTX;
    ENV(env, e);
    if (!(m = mon_of(c, monp)))
        return fail(c, "enif_make_monitor_term: bad monitor");
    RET(e, enif_make_monitor_term(env, &m->m));
}

/* --- formatted output: the ... and the va_list of wasm32 are a pointer
 * to the values, each one at the alignment of its size --- */

typedef struct {
    char *p;
    size_t n, cap;
} out_t;

static int out_add(out_t *o, const char *s, size_t n)
{
    if (o->n + n + 1 > o->cap) {
        size_t cap = o->cap ? o->cap : 128;
        char *q;
        while (cap < o->n + n + 1)
            cap *= 2;
        if (!(q = realloc(o->p, cap)))
            return 0;
        o->p = q;
        o->cap = cap;
    }
    memcpy(o->p + o->n, s, n);
    o->n += n;
    o->p[o->n] = '\0';
    return 1;
}

static int va_get(ctx *c, uint32_t *va, uint32_t size, void *v)
{
    const void *p;
    *va = (*va + size - 1) & ~(size - 1);
    if (!(p = gaddr(c, *va, size)))
        return 0;
    memcpy(v, p, size);
    *va += size;
    return 1;
}

/* Format one value with SPEC (a format of C with one conversion). */
#define OUT_ONE(o, spec, value) do { \
        int n_ = snprintf(NULL, 0, spec, value); \
        char *t_ = n_ >= 0 ? malloc((size_t)n_ + 1) : NULL; \
        if (!t_) return -1; \
        snprintf(t_, (size_t)n_ + 1, spec, value); \
        if (!out_add(o, t_, (size_t)n_)) { free(t_); return -1; } \
        free(t_); \
    } while (0)

/* The format of enif_snprintf: the conversions of C, and %T for a term. */
static int format(ctx *c, const char *fmt, uint32_t va, out_t *o)
{
    const char *f = fmt;
    while (*f) {
        char spec[64], conv;
        const char *start;
        int len = 0, k = 0;
        if (*f != '%') {
            const char *q = strchr(f, '%');
            size_t n = q ? (size_t)(q - f) : strlen(f);
            if (!out_add(o, f, n))
                return -1;
            f += n;
            continue;
        }
        start = f++;
        spec[k++] = '%';
        while (*f && strchr("-+ #0", *f) && k < 40)
            spec[k++] = *f++;
        if (*f == '*') {
            int32_t w;
            if (!va_get(c, &va, 4, &w))
                return -1;
            k += snprintf(spec + k, sizeof(spec) - (size_t)k, "%d", (int)w);
            f++;
        }
        while (*f >= '0' && *f <= '9' && k < 50)
            spec[k++] = *f++;
        if (*f == '.') {
            spec[k++] = *f++;
            if (*f == '*') {
                int32_t pr;
                if (!va_get(c, &va, 4, &pr))
                    return -1;
                k += snprintf(spec + k, sizeof(spec) - (size_t)k, "%d", (int)pr);
                f++;
            }
            while (*f >= '0' && *f <= '9' && k < 58)
                spec[k++] = *f++;
        }
        /* The length: 8 bytes for ll and j, 16 for L, else 4 (long,
         * size_t and ptrdiff_t are 32 bits in wasm32). */
        while (*f && strchr("hlzjtL", *f)) {
            if (*f == 'L')
                len = 16;
            else if (*f == 'j' || (*f == 'l' && len == 4))
                len = 8;
            else if (*f == 'l')
                len = 4;
            f++;
        }
        if (!(conv = *f++))
            break;
        if (k > 60)
            return -1;
        switch (conv) {
        case '%':
            if (!out_add(o, "%", 1))
                return -1;
            break;
        case 'd':
        case 'i':
        case 'u':
        case 'o':
        case 'x':
        case 'X':
        case 'c':
            if (len == 8) {
                int64_t v;
                if (!va_get(c, &va, 8, &v))
                    return -1;
                spec[k] = 'l';
                spec[k + 1] = 'l';
                spec[k + 2] = conv;
                spec[k + 3] = '\0';
                OUT_ONE(o, spec, (long long)v);
            } else {
                int32_t v;
                if (!va_get(c, &va, 4, &v))
                    return -1;
                spec[k] = conv;
                spec[k + 1] = '\0';
                if (conv == 'd' || conv == 'i' || conv == 'c')
                    OUT_ONE(o, spec, (int)v);
                else
                    OUT_ONE(o, spec, (unsigned)v);
            }
            break;
        case 'f':
        case 'F':
        case 'e':
        case 'E':
        case 'g':
        case 'G':
        case 'a':
        case 'A':
            if (len == 16) {
                /* long double is 128 bits in wasm32: not supported. */
                uint8_t skip[16];
                if (!va_get(c, &va, 16, skip) || !out_add(o, "?", 1))
                    return -1;
            } else {
                double v;
                if (!va_get(c, &va, 8, &v))
                    return -1;
                spec[k] = conv;
                spec[k + 1] = '\0';
                OUT_ONE(o, spec, v);
            }
            break;
        case 's': {
            uint32_t g;
            const char *str;
            if (!va_get(c, &va, 4, &g))
                return -1;
            str = g ? gstr(c, g) : "(null)";
            spec[k] = 's';
            spec[k + 1] = '\0';
            OUT_ONE(o, spec, str ? str : "(bad string)");
            break;
        }
        case 'p': {
            uint32_t g;
            if (!va_get(c, &va, 4, &g))
                return -1;
            OUT_ONE(o, "0x%x", (unsigned)g);
            break;
        }
        case 'n': {
            /* No write through a pointer of the format. */
            uint32_t g;
            if (!va_get(c, &va, 4, &g))
                return -1;
            break;
        }
        case 'T': {
            uint32_t h;
            ERL_NIF_TERM t;
            int n;
            char *tmp;
            if (!va_get(c, &va, 4, &h) || !get_term(c, h, &t))
                return -1;
            flush_all(c);
            /* enif_snprintf of ERTS needs a buffer: try larger ones. */
            for (n = 256;; n *= 4) {
                int r;
                if (!(tmp = malloc((size_t)n)))
                    return -1;
                r = enif_snprintf(tmp, (size_t)n, "%T", t);
                if (r >= 0 && r < n - 1) {
                    n = r;
                    break;
                }
                free(tmp);
                if (n > (1 << 24))
                    return -1;
            }
            if (!out_add(o, tmp, (size_t)n)) {
                free(tmp);
                return -1;
            }
            free(tmp);
            break;
        }
        default:
            /* An unknown conversion: as written. */
            if (!out_add(o, start, (size_t)(f - start)))
                return -1;
        }
    }
    if (!o->p && !out_add(o, "", 0))
        return -1;
    return (int)o->n;
}

static uint32_t w_snprintf(wasm_exec_env_t x, uint32_t buf, uint32_t size, uint32_t fmt, uint32_t va)
{
    out_t o = { NULL, 0, 0 };
    const char *f;
    char *p;
    int n;
    CTX;
    if (!(f = gstr(c, fmt)))
        return fail(c, "enif_snprintf: bad format");
    if ((n = format(c, f, va, &o)) < 0) {
        free(o.p);
        return fail(c, "enif_snprintf: bad argument");
    }
    if (size) {
        uint32_t m = (uint32_t)n < size - 1 ? (uint32_t)n : size - 1;
        if (!(p = gaddr(c, buf, m + 1))) {
            free(o.p);
            return fail(c, "enif_snprintf: bad buffer");
        }
        memcpy(p, o.p, m);
        p[m] = '\0';
    }
    free(o.p);
    return (uint32_t)n;
}

/* The FILE of the module is not a FILE of the VM: the text goes to the
 * standard error of the VM. */
static uint32_t w_fprintf(wasm_exec_env_t x, uint32_t file, uint32_t fmt, uint32_t va)
{
    out_t o = { NULL, 0, 0 };
    const char *f;
    int n;
    CTX;
    (void)file;
    if (!(f = gstr(c, fmt)))
        return fail(c, "enif_fprintf: bad format");
    if ((n = format(c, f, va, &o)) < 0) {
        free(o.p);
        return fail(c, "enif_fprintf: bad argument");
    }
    fwrite(o.p, 1, (size_t)n, stderr);
    free(o.p);
    return (uint32_t)n;
}

/* --- I/O queues and I/O vectors. SysIOVec of wasm32: base, length.
 * ErlNifIOVec of wasm32 (212 bytes): iovcnt, size, iov, ref_bins,
 * flags, small_iov[16], small_ref_bin[16]. --- */

#define IOVEC_SIZE 212

static ioq_t *ioq_of(ctx *c, uint32_t q)
{
    return q == 0 || q > c->nioq ? NULL : c->ioqs[q - 1];
}

static int ioq_add(ctx *c, ioq_t *q, uint32_t g, uint32_t size, uint32_t off)
{
    if (size <= off) {
        gfree(c, g);
        return 1;
    }
    if (!grow((void **)&q->e, &q->cap, q->n + 1, sizeof(ioq_ent_t)))
        return 0;
    q->e[q->n++] = (ioq_ent_t){ g, size, off };
    q->total += size - off;
    return 1;
}

static uint32_t w_ioq_create(wasm_exec_env_t x, uint32_t opts)
{
    ioq_t *q;
    uint32_t i;
    CTX;
    if (opts != ERL_NIF_IOQ_NORMAL || !(q = calloc(1, sizeof(ioq_t))))
        return 0;
    for (i = 0; i < c->nioq && c->ioqs[i]; i++)
        ;
    if (i == c->nioq && !grow((void **)&c->ioqs, &c->capioq, c->nioq + 1, sizeof(ioq_t *))) {
        free(q);
        return 0;
    }
    if (i == c->nioq)
        c->nioq++;
    c->ioqs[i] = q;
    return i + 1;
}

static void ioq_free(ctx *c, ioq_t *q)
{
    uint32_t i;
    for (i = 0; i < q->n; i++)
        gfree(c, q->e[i].g);
    gfree(c, q->peek);
    free(q->e);
    free(q);
}

static void w_ioq_destroy(wasm_exec_env_t x, uint32_t qh)
{
    ioq_t *q;
    CTXV;
    if (!(q = ioq_of(c, qh))) {
        fail(c, "enif_ioq_destroy: bad queue");
        return;
    }
    ioq_free(c, q);
    c->ioqs[qh - 1] = NULL;
}

/* The queue takes the binary: its own memory, or a copy of an inspected
 * binary. */
static uint32_t w_ioq_enq_binary(wasm_exec_env_t x, uint32_t qh, uint32_t binp, uint32_t skip)
{
    uint32_t v[5], g;
    void *p, *src, *dst;
    ioq_t *q;
    CTX;
    if (!(q = ioq_of(c, qh)) || !binp || !(p = gaddr(c, binp, 20)))
        return fail(c, "enif_ioq_enq_binary: bad argument");
    memcpy(v, p, 20);
    if (skip > v[0])
        return 0;
    if (v[2] == OWNED_BINARY) {
        g = v[1];
        v[2] = 0;
        memcpy(p, v, 20);
    } else {
        if (!(g = gmalloc(c, v[0])))
            return 0;
        if (v[0] && (src = gaddr(c, v[1], v[0])) && (dst = gaddr(c, g, v[0])))
            memcpy(dst, src, v[0]);
    }
    return ioq_add(c, q, g, v[0], skip);
}

static uint32_t w_ioq_enqv(wasm_exec_env_t x, uint32_t qh, uint32_t iovp, uint32_t skip)
{
    uint32_t hdr[3], i, g, at = 0;
    const uint8_t *iov;
    ioq_t *q;
    CTX;
    if (!(q = ioq_of(c, qh)) || !iovp || !get32(c, iovp, &hdr[0]) || !get32(c, iovp + 4, &hdr[1])
        || !get32(c, iovp + 8, &hdr[2]) || hdr[0] > (1u << 20))
        return fail(c, "enif_ioq_enqv: bad argument");
    if (skip > hdr[1])
        return 0;
    if (!(g = gmalloc(c, hdr[1])))
        return 0;
    for (i = 0; i < hdr[0]; i++) {
        uint32_t e[2];
        void *src, *dst;
        if (!(iov = gaddr(c, hdr[2] + 8 * i, 8)))
            break;
        memcpy(e, iov, 8);
        if (e[1] > hdr[1] - at)
            break;
        if (e[1] && (src = gaddr(c, e[0], e[1])) && (dst = gaddr(c, g + at, e[1])))
            memcpy(dst, src, e[1]);
        at += e[1];
    }
    if (at != hdr[1]) {
        gfree(c, g);
        return fail(c, "enif_ioq_enqv: bad vector");
    }
    return ioq_add(c, q, g, hdr[1], skip);
}

static uint32_t w_ioq_size(wasm_exec_env_t x, uint32_t qh)
{
    ioq_t *q;
    CTX;
    if (!(q = ioq_of(c, qh)))
        return fail(c, "enif_ioq_size: bad queue");
    return q->total;
}

static uint32_t w_ioq_deq(wasm_exec_env_t x, uint32_t qh, uint32_t count, uint32_t sizep)
{
    ioq_t *q;
    uint32_t i = 0;
    CTX;
    if (!(q = ioq_of(c, qh)))
        return fail(c, "enif_ioq_deq: bad queue");
    if (count > q->total)
        return 0;
    q->total -= count;
    while (count) {
        ioq_ent_t *e = &q->e[i];
        uint32_t left = e->size - e->off;
        if (count < left) {
            e->off += count;
            break;
        }
        count -= left;
        gfree(c, e->g);
        i++;
    }
    memmove(q->e, q->e + i, (q->n - i) * sizeof(ioq_ent_t));
    q->n -= i;
    if (sizep && !put32(c, sizep, q->total))
        return fail(c, "enif_ioq_deq: bad pointer");
    return 1;
}

/* The SysIOVec array stays valid until the next change of the queue. */
static uint32_t w_ioq_peek(wasm_exec_env_t x, uint32_t qh, uint32_t lenp)
{
    ioq_t *q;
    uint32_t i;
    uint8_t *p;
    CTX;
    if (!(q = ioq_of(c, qh)))
        return fail(c, "enif_ioq_peek: bad queue");
    if (q->n > q->peekcap) {
        gfree(c, q->peek);
        q->peekcap = 0;
        if (!(q->peek = gmalloc(c, 8 * q->n)))
            return 0;
        q->peekcap = q->n;
    }
    if (q->n && !(p = gaddr(c, q->peek, 8 * q->n)))
        return 0;
    for (i = 0; i < q->n; i++) {
        uint32_t e[2] = { q->e[i].g + q->e[i].off, q->e[i].size - q->e[i].off };
        memcpy(p + 8 * i, e, 8);
    }
    if (lenp && !put32(c, lenp, q->n))
        return fail(c, "enif_ioq_peek: bad pointer");
    return q->peek;
}

static uint32_t w_ioq_peek_head(wasm_exec_env_t x, uint32_t e, uint32_t qh, uint32_t sizep, uint32_t headp)
{
    unsigned char *dst;
    const void *src;
    ERL_NIF_TERM t;
    ioq_t *q;
    uint32_t n;
    CTX;
    ENV(env, e);
    if (!(q = ioq_of(c, qh)))
        return fail(c, "enif_ioq_peek_head: bad queue");
    if (!q->n)
        return 0;
    n = q->e[0].size - q->e[0].off;
    if (!(src = gaddr(c, q->e[0].g + q->e[0].off, n)) || !(dst = enif_make_new_binary(env, n, &t)))
        return 0;
    memcpy(dst, src, n);
    if (sizep && !put32(c, sizep, n))
        return fail(c, "enif_ioq_peek_head: bad pointer");
    OUT(headp, e, t);
    return 1;
}

/* The ErlNifIOVec, its SysIOVec array and a copy of the bytes, in one
 * block of memory of the module: memory of the slot with an
 * environment, else enif_free_iovec frees it. */
static uint32_t w_inspect_iovec(wasm_exec_env_t x, uint32_t e, uint32_t max, uint32_t h,
                                uint32_t tailp, uint32_t iovecp)
{
    ErlNifEnv *env = NULL;
    ErlNifIOVec *hv;
    ERL_NIF_TERM tail;
    uint32_t g, n, data, i, w[5];
    uint8_t *p;
    CTX;
    TERM(t, h);
    if (e) {
        slot_t *sl = slot_of(c, e);
        if (!sl)
            return fail(c, "enif_inspect_iovec: bad environment");
        env = sl->env;
    }
    flush_all(c);
    /* ERTS fills *iov when it points to a vector of the caller: none. */
    hv = NULL;
    if (!enif_inspect_iovec(env, max, t, &tail, &hv))
        return 0;
    /* With an environment, the vector of ERTS belongs to it. */
#define FREE_HV() do { if (!env) enif_free_iovec(hv); } while (0)
    if (hv->size > (1u << 30) || hv->iovcnt > (1 << 20)) {
        FREE_HV();
        return 0;
    }
    data = IOVEC_SIZE + 8 * (uint32_t)hv->iovcnt;
    n = data + (uint32_t)hv->size;
    g = e ? scratch(c, e, n) : gmalloc(c, n);
    if (!g || !(p = gaddr(c, g, n))) {
        FREE_HV();
        return 0;
    }
    memset(p, 0, IOVEC_SIZE);
    w[0] = (uint32_t)hv->iovcnt;
    w[1] = (uint32_t)hv->size;
    w[2] = g + IOVEC_SIZE;
    w[3] = 0;
    /* flags: the block belongs to enif_free_iovec (no environment). */
    w[4] = e ? 0 : OWNED_BINARY;
    memcpy(p, w, 20);
    for (i = 0; i < (uint32_t)hv->iovcnt; i++) {
        uint32_t v[2] = { g + data, (uint32_t)hv->iov[i].iov_len };
        memcpy(p + IOVEC_SIZE + 8 * i, v, 8);
        memcpy(p + data, hv->iov[i].iov_base, hv->iov[i].iov_len);
        data += v[1];
    }
    FREE_HV();
#undef FREE_HV
    if (e) {
        OUT(tailp, e, tail);
    } else {
        /* The tail is a part of the input term: it goes into the slot of
         * that term (a list has a handle of a slot). */
        uint32_t th = (h & 3) == 0 ? handle(c, ((h >> 2) >> IDX_BITS) + 1, tail) : h;
        if (!th || !put32(c, tailp, th))
            return fail(c, "enif_inspect_iovec: bad pointer");
    }
    if (!put32(c, iovecp, g))
        return fail(c, "enif_inspect_iovec: bad pointer");
    return 1;
}

static void w_free_iovec(wasm_exec_env_t x, uint32_t iovp)
{
    uint32_t flags;
    CTXV;
    if (iovp && get32(c, iovp + 16, &flags) && flags == OWNED_BINARY)
        gfree(c, iovp);
}

static uint32_t w_term_size(wasm_exec_env_t x, uint32_t h)
{
    CTX;
    TERM(t, h);
    return (uint32_t)enif_term_size(t);
}

/* The enif_* functions that the module imports: X(name, function,
 * signature). S_PARAMS_RESULT: i is i32, I is i64, F is f64, v is no
 * result. */
#define NIF_NATIVES(X) \
    X(enif_priv_data, w_priv_data, S_i_i) \
    X(enif_alloc, w_alloc, S_i_i) \
    X(enif_free, w_free, S_i_v) \
    X(enif_realloc, w_realloc, S_ii_i) \
    X(enif_is_atom, w_is_atom, S_ii_i) \
    X(enif_is_binary, w_is_binary, S_ii_i) \
    X(enif_is_ref, w_is_ref, S_ii_i) \
    X(enif_is_fun, w_is_fun, S_ii_i) \
    X(enif_is_pid, w_is_pid, S_ii_i) \
    X(enif_is_port, w_is_port, S_ii_i) \
    X(enif_is_list, w_is_list, S_ii_i) \
    X(enif_is_tuple, w_is_tuple, S_ii_i) \
    X(enif_is_map, w_is_map, S_ii_i) \
    X(enif_is_number, w_is_number, S_ii_i) \
    X(enif_is_empty_list, w_is_empty_list, S_ii_i) \
    X(enif_is_exception, w_is_exception, S_ii_i) \
    X(enif_term_type, w_term_type, S_ii_i) \
    X(enif_is_identical, w_is_identical, S_ii_i) \
    X(enif_compare, w_compare, S_ii_i) \
    X(enif_hash, w_hash, S_iiI_I) \
    X(enif_inspect_binary, w_inspect_binary, S_iii_i) \
    X(enif_inspect_iolist_as_binary, w_inspect_iolist_as_binary, S_iii_i) \
    X(enif_alloc_binary, w_alloc_binary, S_ii_i) \
    X(enif_realloc_binary, w_realloc_binary, S_ii_i) \
    X(enif_release_binary, w_release_binary, S_i_v) \
    X(enif_make_binary, w_make_binary, S_ii_i) \
    X(enif_make_new_binary, w_make_new_binary, S_iii_i) \
    X(enif_make_sub_binary, w_make_sub_binary, S_iiii_i) \
    X(enif_term_to_binary, w_term_to_binary, S_iii_i) \
    X(enif_binary_to_term, w_binary_to_term, S_iiiii_i) \
    X(enif_get_int, w_get_int, S_iii_i) \
    X(enif_get_uint, w_get_uint, S_iii_i) \
    X(enif_get_long, w_get_long, S_iii_i) \
    X(enif_get_ulong, w_get_ulong, S_iii_i) \
    X(enif_get_int64, w_get_int64, S_iii_i) \
    X(enif_get_uint64, w_get_uint64, S_iii_i) \
    X(enif_get_double, w_get_double, S_iii_i) \
    X(enif_make_int, w_make_int, S_ii_i) \
    X(enif_make_uint, w_make_uint, S_ii_i) \
    X(enif_make_long, w_make_long, S_ii_i) \
    X(enif_make_ulong, w_make_ulong, S_ii_i) \
    X(enif_make_int64, w_make_int64, S_iI_i) \
    X(enif_make_uint64, w_make_uint64, S_iI_i) \
    X(enif_make_double, w_make_double, S_iF_i) \
    X(enif_make_atom, w_make_atom, S_ii_i) \
    X(enif_make_atom_len, w_make_atom_len, S_iii_i) \
    X(enif_make_existing_atom, w_make_existing_atom, S_iiii_i) \
    X(enif_make_existing_atom_len, w_make_existing_atom_len, S_iiiii_i) \
    X(enif_make_new_atom, w_make_new_atom, S_iiii_i) \
    X(enif_make_new_atom_len, w_make_new_atom_len, S_iiiii_i) \
    X(enif_get_atom, w_get_atom, S_iiiii_i) \
    X(enif_get_atom_length, w_get_atom_length, S_iiii_i) \
    X(enif_make_string, w_make_string, S_iii_i) \
    X(enif_make_string_len, w_make_string_len, S_iiii_i) \
    X(enif_get_string, w_get_string, S_iiiii_i) \
    X(enif_get_string_length, w_get_string_length, S_iiii_i) \
    X(enif_make_tuple, w_make_tuple, S_iii_i) \
    X(enif_make_tuple_from_array, w_make_tuple_from_array, S_iii_i) \
    X(enif_get_tuple, w_get_tuple, S_iiii_i) \
    X(enif_make_list, w_make_list, S_iii_i) \
    X(enif_make_list_cell, w_make_list_cell, S_iii_i) \
    X(enif_make_list_from_array, w_make_list_from_array, S_iii_i) \
    X(enif_get_list_cell, w_get_list_cell, S_iiii_i) \
    X(enif_get_list_length, w_get_list_length, S_iii_i) \
    X(enif_make_reverse_list, w_make_reverse_list, S_iii_i) \
    X(enif_make_new_map, w_make_new_map, S_i_i) \
    X(enif_make_map_put, w_make_map_put, S_iiiii_i) \
    X(enif_make_map_update, w_make_map_update, S_iiiii_i) \
    X(enif_make_map_remove, w_make_map_remove, S_iiii_i) \
    X(enif_get_map_value, w_get_map_value, S_iiii_i) \
    X(enif_get_map_size, w_get_map_size, S_iii_i) \
    X(enif_make_map_from_arrays, w_make_map_from_arrays, S_iiiii_i) \
    X(enif_map_iterator_create, w_map_iterator_create, S_iiii_i) \
    X(enif_map_iterator_destroy, w_map_iterator_destroy, S_ii_v) \
    X(enif_map_iterator_is_head, w_map_iterator_is_head, S_ii_i) \
    X(enif_map_iterator_is_tail, w_map_iterator_is_tail, S_ii_i) \
    X(enif_map_iterator_next, w_map_iterator_next, S_ii_i) \
    X(enif_map_iterator_prev, w_map_iterator_prev, S_ii_i) \
    X(enif_map_iterator_get_pair, w_map_iterator_get_pair, S_iiii_i) \
    X(enif_make_ref, w_make_ref, S_i_i) \
    X(enif_make_unique_integer, w_make_unique_integer, S_ii_i) \
    X(enif_make_copy, w_make_copy, S_ii_i) \
    X(enif_cpu_time, w_cpu_time, S_i_i) \
    X(enif_now_time, w_now_time, S_i_i) \
    X(enif_alloc_env, w_alloc_env, S__i) \
    X(enif_free_env, w_free_env, S_i_v) \
    X(enif_clear_env, w_clear_env, S_i_v) \
    X(enif_send, w_send, S_iiii_i) \
    X(enif_self, w_self, S_ii_i) \
    X(enif_get_local_pid, w_get_local_pid, S_iii_i) \
    X(enif_is_process_alive, w_is_process_alive, S_ii_i) \
    X(enif_is_current_process_alive, w_is_current_process_alive, S_i_i) \
    X(enif_whereis_pid, w_whereis_pid, S_iii_i) \
    X(enif_set_pid_undefined, w_set_pid_undefined, S_i_v) \
    X(enif_is_pid_undefined, w_is_pid_undefined, S_i_i) \
    X(enif_open_resource_type, w_open_resource_type, S_iiiiii_i) \
    X(enif_open_resource_type_x, w_open_resource_type_x, S_iiiii_i) \
    X(enif_init_resource_type, w_init_resource_type, S_iiiii_i) \
    X(enif_alloc_resource, w_alloc_resource, S_ii_i) \
    X(enif_release_resource, w_release_resource, S_i_v) \
    X(enif_keep_resource, w_keep_resource, S_i_v) \
    X(enif_make_resource, w_make_resource, S_ii_i) \
    X(enif_get_resource, w_get_resource, S_iiii_i) \
    X(enif_sizeof_resource, w_sizeof_resource, S_i_i) \
    X(enif_make_badarg, w_make_badarg, S_i_i) \
    X(enif_raise_exception, w_raise_exception, S_ii_i) \
    X(enif_has_pending_exception, w_has_pending_exception, S_ii_i) \
    X(enif_consume_timeslice, w_consume_timeslice, S_ii_i) \
    X(enif_schedule_nif, w_schedule_nif, S_iiiiii_i) \
    X(enif_thread_type, w_thread_type, S__i) \
    X(enif_monotonic_time, w_monotonic_time, S_i_I) \
    X(enif_time_offset, w_time_offset, S_i_I) \
    X(enif_convert_time_unit, w_convert_time_unit, S_Iii_I) \
    X(enif_mutex_create, w_lock_create, S_i_i) \
    X(enif_mutex_destroy, w_lock_op, S_i_v) \
    X(enif_mutex_lock, w_lock_op, S_i_v) \
    X(enif_mutex_unlock, w_lock_op, S_i_v) \
    X(enif_mutex_trylock, w_lock_try, S_i_i) \
    X(enif_cond_create, w_lock_create, S_i_i) \
    X(enif_cond_destroy, w_lock_op, S_i_v) \
    X(enif_cond_signal, w_lock_op, S_i_v) \
    X(enif_cond_broadcast, w_lock_op, S_i_v) \
    X(enif_cond_wait, w_cond_wait, S_ii_v) \
    X(enif_rwlock_create, w_lock_create, S_i_i) \
    X(enif_rwlock_destroy, w_lock_op, S_i_v) \
    X(enif_rwlock_rlock, w_lock_op, S_i_v) \
    X(enif_rwlock_runlock, w_lock_op, S_i_v) \
    X(enif_rwlock_rwlock, w_lock_op, S_i_v) \
    X(enif_rwlock_rwunlock, w_lock_op, S_i_v) \
    X(enif_rwlock_tryrlock, w_lock_try, S_i_i) \
    X(enif_rwlock_tryrwlock, w_lock_try, S_i_i) \
    X(enif_thread_create, w_thread_create, S_iiiii_i) \
    X(enif_thread_self, w_thread_self, S__i) \
    X(enif_equal_tids, w_equal_tids, S_ii_i) \
    X(enif_thread_opts_create, w_lock_create, S_i_i) \
    X(enif_thread_opts_destroy, w_lock_op, S_i_v) \
    X(enif_tsd_key_create, w_tsd_key_create, S_ii_i) \
    X(enif_tsd_key_destroy, w_lock_op, S_i_v) \
    X(enif_tsd_set, w_tsd_set, S_ii_v) \
    X(enif_tsd_get, w_tsd_get, S_i_i) \
    X(enif_getenv, w_getenv, S_iii_i) \
    X(enif_get_local_port, w_get_local_port, S_iii_i) \
    X(enif_is_port_alive, w_is_port_alive, S_ii_i) \
    X(enif_whereis_port, w_whereis_port, S_iii_i) \
    X(enif_port_command, w_port_command, S_iiii_i) \
    X(enif_select, w_select, S_iiiiii_i) \
    X(enif_dlopen, w_dlopen, S_iii_i) \
    X(enif_dlsym, w_dlsym, S_iiii_i) \
    X(enif_set_option, w_set_option, S_iii_i) \
    X(enif_make_resource_binary, w_make_resource_binary, S_iiii_i) \
    X(enif_system_info, w_system_info, S_ii_v) \
    X(enif_monitor_process, w_monitor_process, S_iiii_i) \
    X(enif_demonitor_process, w_demonitor_process, S_iii_i) \
    X(enif_compare_monitors, w_compare_monitors, S_ii_i) \
    X(enif_make_monitor_term, w_make_monitor_term, S_ii_i) \
    X(enif_snprintf, w_snprintf, S_iiii_i) \
    X(enif_vsnprintf, w_snprintf, S_iiii_i) \
    X(enif_fprintf, w_fprintf, S_iii_i) \
    X(enif_vfprintf, w_fprintf, S_iii_i) \
    X(enif_ioq_create, w_ioq_create, S_i_i) \
    X(enif_ioq_destroy, w_ioq_destroy, S_i_v) \
    X(enif_ioq_enq_binary, w_ioq_enq_binary, S_iii_i) \
    X(enif_ioq_enqv, w_ioq_enqv, S_iii_i) \
    X(enif_ioq_size, w_ioq_size, S_i_i) \
    X(enif_ioq_deq, w_ioq_deq, S_iii_i) \
    X(enif_ioq_peek, w_ioq_peek, S_ii_i) \
    X(enif_ioq_peek_head, w_ioq_peek_head, S_iiii_i) \
    X(enif_inspect_iovec, w_inspect_iovec, S_iiiii_i) \
    X(enif_free_iovec, w_free_iovec, S_i_v) \
    X(enif_term_size, w_term_size, S_i_i)

#define SIG_S__i "()i"
#define SIG_S_Iii_I "(Iii)I"
#define SIG_S_i_v "(i)"
#define SIG_S_i_I "(i)I"
#define SIG_S_i_i "(i)i"
#define SIG_S_iF_i "(iF)i"
#define SIG_S_iI_i "(iI)i"
#define SIG_S_ii_v "(ii)"
#define SIG_S_ii_i "(ii)i"
#define SIG_S_iiI_I "(iiI)I"
#define SIG_S_iii_i "(iii)i"
#define SIG_S_iiii_i "(iiii)i"
#define SIG_S_iiiii_i "(iiiii)i"
#define SIG_S_iiiiii_i "(iiiiii)i"

#define NATIVE_ENTRY(name, fn, sig) { #name, fn, SIG_##sig, NULL },
static NativeSymbol natives[] = { NIF_NATIVES(NATIVE_ENTRY) };

#ifdef NIF_WASM_EDGE
/* --- the WebAssembly runtime of --target wasm32 ---
 *
 * The engine of the host runs the module there (nif_wasm_host.c). The
 * module imports each function of NIF_NATIVES as the export
 * nifx_NAME of ERTS, which has the exact type of the import: a call
 * has no JavaScript between the module and ERTS, so ERTS can wait (and
 * suspend the thread) in it. host_enter() gives the execution
 * environment of the call, and host_leave() writes back the windows on
 * the memory of the module (and stops the module after a failure). */
#define P_i uint32_t
#define P_I uint64_t
#define P_F double
#define EXPORT_S__i(name, fn) \
    EMSCRIPTEN_KEEPALIVE uint32_t nifx_##name(void) \
    { wasm_exec_env_t x = host_enter(); uint32_t r = fn(x); host_leave(x); return r; }
#define EXPORT_S_i_v(name, fn) \
    EMSCRIPTEN_KEEPALIVE void nifx_##name(P_i a) \
    { wasm_exec_env_t x = host_enter(); fn(x, a); host_leave(x); }
#define EXPORT_S_i_i(name, fn) \
    EMSCRIPTEN_KEEPALIVE uint32_t nifx_##name(P_i a) \
    { wasm_exec_env_t x = host_enter(); uint32_t r = fn(x, a); host_leave(x); return r; }
#define EXPORT_S_i_I(name, fn) \
    EMSCRIPTEN_KEEPALIVE int64_t nifx_##name(P_i a) \
    { wasm_exec_env_t x = host_enter(); int64_t r = fn(x, a); host_leave(x); return r; }
#define EXPORT_S_ii_v(name, fn) \
    EMSCRIPTEN_KEEPALIVE void nifx_##name(P_i a, P_i b) \
    { wasm_exec_env_t x = host_enter(); fn(x, a, b); host_leave(x); }
#define EXPORT_S_ii_i(name, fn) \
    EMSCRIPTEN_KEEPALIVE uint32_t nifx_##name(P_i a, P_i b) \
    { wasm_exec_env_t x = host_enter(); uint32_t r = fn(x, a, b); host_leave(x); return r; }
#define EXPORT_S_iii_i(name, fn) \
    EMSCRIPTEN_KEEPALIVE uint32_t nifx_##name(P_i a, P_i b, P_i c) \
    { wasm_exec_env_t x = host_enter(); uint32_t r = fn(x, a, b, c); host_leave(x); return r; }
#define EXPORT_S_iiii_i(name, fn) \
    EMSCRIPTEN_KEEPALIVE uint32_t nifx_##name(P_i a, P_i b, P_i c, P_i d) \
    { wasm_exec_env_t x = host_enter(); uint32_t r = fn(x, a, b, c, d); host_leave(x); return r; }
#define EXPORT_S_iiiii_i(name, fn) \
    EMSCRIPTEN_KEEPALIVE uint32_t nifx_##name(P_i a, P_i b, P_i c, P_i d, P_i e) \
    { wasm_exec_env_t x = host_enter(); uint32_t r = fn(x, a, b, c, d, e); host_leave(x); return r; }
#define EXPORT_S_iiiiii_i(name, fn) \
    EMSCRIPTEN_KEEPALIVE uint32_t nifx_##name(P_i a, P_i b, P_i c, P_i d, P_i e, P_i f) \
    { wasm_exec_env_t x = host_enter(); uint32_t r = fn(x, a, b, c, d, e, f); host_leave(x); return r; }
#define EXPORT_S_iI_i(name, fn) \
    EMSCRIPTEN_KEEPALIVE uint32_t nifx_##name(P_i a, P_I b) \
    { wasm_exec_env_t x = host_enter(); uint32_t r = fn(x, a, b); host_leave(x); return r; }
#define EXPORT_S_iF_i(name, fn) \
    EMSCRIPTEN_KEEPALIVE uint32_t nifx_##name(P_i a, P_F b) \
    { wasm_exec_env_t x = host_enter(); uint32_t r = fn(x, a, b); host_leave(x); return r; }
#define EXPORT_S_iiI_I(name, fn) \
    EMSCRIPTEN_KEEPALIVE int64_t nifx_##name(P_i a, P_i b, P_I c) \
    { wasm_exec_env_t x = host_enter(); int64_t r = fn(x, a, b, c); host_leave(x); return r; }
#define EXPORT_S_Iii_I(name, fn) \
    EMSCRIPTEN_KEEPALIVE int64_t nifx_##name(P_I a, P_i b, P_i c) \
    { wasm_exec_env_t x = host_enter(); int64_t r = fn(x, a, b, c); host_leave(x); return r; }
#define NATIVE_EXPORT(name, fn, sig) EXPORT_##sig(name, fn)
NIF_NATIVES(NATIVE_EXPORT)
#endif

static int register_natives(void)
{
    return wasm_runtime_register_natives("env", natives, sizeof(natives) / sizeof(natives[0]));
}

/* --- the library --- */

static void ctx_free(ctx *c)
{
    uint32_t i;
    int s;
    if (c->exec)
        wasm_runtime_destroy_exec_env(c->exec);
    if (c->inst)
        wasm_runtime_deinstantiate(c->inst);
    if (c->module)
        wasm_runtime_unload(c->module);
    free(c->bytes);
    for (i = 0; i < c->nstrings; i++)
        free(c->strings[i]);
    free(c->strings);
    for (s = 0; s < MAX_SLOTS; s++) {
        free(c->slots[s].terms);
        free(c->slots[s].frees);
        free(c->slots[s].pend);
    }
    free(c->itab);
    free(c->ihash);
    free(c->rtypes);
    free(c->res);
    for (i = 0; i < c->niter; i++)
        free(c->iters[i]);
    free(c->iters);
    free(c->mons);
    for (i = 0; i < c->nioq; i++)
        if (c->ioqs[i]) {
            free(c->ioqs[i]->e);
            free(c->ioqs[i]);
        }
    free(c->ioqs);
    if (c->lock)
        enif_mutex_destroy(c->lock);
    free(c);
}

static int nif_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
    ctx *c = loading;
    uint32_t a[3], pp, hi;
    int s, r = 1;
    loading = NULL;
    if (!c)
        return 1;
    *priv = c;
    if (!c->load_fn)
        return 0;
    enter(c);
    if ((s = slot_open(c, env, 0)) >= 0) {
        pp = scratch(c, s + 1, 4);
        hi = handle(c, s + 1, info);
        if (pp && hi && put32(c, pp, 0)) {
            a[0] = s + 1;
            a[1] = pp;
            a[2] = hi;
            if (guest_call(c, c->load_fn, 3, a))
                r = (int)a[0];
            else {
                fprintf(stderr, "%s: load: %s\n", c->entry.name, wasm_runtime_get_exception(c->inst));
                wasm_runtime_clear_exception(c->inst);
            }
            get32(c, pp, &c->priv);
        }
        flush_all(c);
        slot_close(c, s);
    }
    leave(c);
    if (r != 0) {
        /* ERTS forgets the library: nothing calls it again. */
        *priv = NULL;
        ctx_free(c);
    }
    return r;
}

static void nif_unload(ErlNifEnv *env, void *priv)
{
    ctx *c = priv;
    uint32_t a[2];
    int s;
    if (!c)
        return;
    if (c->unload_fn) {
        enter(c);
        s = slot_open(c, env, 0);
        a[0] = s < 0 ? 0 : (uint32_t)s + 1;
        a[1] = c->priv;
        if (!guest_call(c, c->unload_fn, 2, a))
            wasm_runtime_clear_exception(c->inst);
        if (s >= 0)
            slot_close(c, s);
        leave(c);
    }
    ctx_free(c);
}

int nif_wasm_runtime_init(void)
{
    static int ready;
    RuntimeInitArgs args;
    if (ready)
        return 1;
    memset(&args, 0, sizeof(args));
    args.mem_alloc_type = Alloc_With_System_Allocator;
    if (!wasm_runtime_full_init(&args))
        return 0;
    /* WAMR writes warnings (for example a missing import) to stdout. */
    wasm_runtime_set_log_level(WASM_LOG_LEVEL_ERROR);
    if (!register_natives())
        return 0;
    debug = getenv("BEAM_COM_NIF_DEBUG") != NULL;
    ready = 1;
    return 1;
}

/* Read the file PATH. Gives 1, 0 when it does not exist, or -1. */
static int read_file(const char *path, uint8_t **bytes, uint32_t *size)
{
    FILE *f = fopen(path, "rb");
    long n;
    if (!f)
        return errno == ENOENT || errno == ENOTDIR ? 0 : -1;
    if (fseek(f, 0, SEEK_END) || (n = ftell(f)) < 0 || n > INT32_MAX || fseek(f, 0, SEEK_SET)) {
        fclose(f);
        return -1;
    }
    *bytes = malloc(n ? (size_t)n : 1);
    if (!*bytes || fread(*bytes, 1, (size_t)n, f) != (size_t)n) {
        free(*bytes);
        *bytes = NULL;
        fclose(f);
        return -1;
    }
    fclose(f);
    *size = (uint32_t)n;
    return 1;
}

/* The AOT file of this CPU, or NULL when the AOT code cannot run. */
static const char *aot_suffix(void)
{
    const char *v = getenv("BEAM_COM_NIF_AOT");
    if (v && !strcmp(v, "0"))
        return NULL;
#if defined(__x86_64__)
    return ".x86_64.aot";
#elif defined(__aarch64__)
    /* On macOS on Apple silicon too: WAMR maps the AOT code with MAP_JIT
     * (patches/wamr/0001-cosmopolitan-aarch64-jit.patch). */
    return ".aarch64.aot";
#else
    return NULL;
#endif
}

static int module_exports(wasm_module_t m, const char *name)
{
#ifdef NIF_WASM_EDGE
    return host_has_export(m, name);
#else
    int32_t i, n = wasm_runtime_get_export_count(m);
    wasm_export_t ex;
    for (i = 0; i < n; i++) {
        wasm_runtime_get_export_type(m, i, &ex);
        if (ex.kind == WASM_IMPORT_EXPORT_KIND_FUNC && !strcmp(ex.name, name))
            return 1;
    }
    return 0;
#endif
}

/* Every import must be a function of WASI or an enif_* function. An
 * enif_* function that this file does not give stays unlinked: a call
 * to it traps with its name. (A library can import functions that it
 * never calls: rustler takes the address of each one.) In the
 * WebAssembly runtime of --target wasm32, nif_wasm_host.js checks the
 * imports. */
static int check_imports(wasm_module_t m, const char *file, char *error, size_t size)
{
#ifdef NIF_WASM_EDGE
    (void)m;
    (void)file;
    (void)size;
    error[0] = '\0';
    return 1;
#else
    int32_t i, n = wasm_runtime_get_import_count(m);
    wasm_import_t im;
    size_t used = 0;
    error[0] = '\0';
    for (i = 0; i < n; i++) {
        wasm_runtime_get_import_type(m, i, &im);
        if (im.kind == WASM_IMPORT_EXPORT_KIND_FUNC && im.linked
            && (!strcmp(im.module_name, "env") || !strcmp(im.module_name, "wasi_snapshot_preview1")))
            continue;
        if (im.kind == WASM_IMPORT_EXPORT_KIND_FUNC && !strcmp(im.module_name, "env")
            && !strncmp(im.name, "enif_", 5)) {
            if (debug)
                fprintf(stderr, "nif_wasm: %s: %s is not supported\n", file, im.name);
            continue;
        }
        if (used == 0)
            used = (size_t)snprintf(error, size, "unsupported imports:");
        if (used < size)
            used += (size_t)snprintf(error + used, size - used, " %s.%s", im.module_name, im.name);
    }
    return error[0] == '\0';
#endif
}

#ifndef NIF_WASM_EDGE
static const char *wasi_dirs[] = { "/", "." };
#endif

/* The module starts in the work directory of ERTS (at the load). */
static void set_cwd(ctx *c)
{
    wasm_function_inst_t f = wasm_runtime_lookup_function(c->inst, "erl_nif_wasm_chdir");
    char cwd[4096];
    uint32_t a[1], g, n;
    void *p;
    if (!f || !getcwd(cwd, sizeof(cwd)))
        return;
    n = (uint32_t)strlen(cwd) + 1;
    if (!(g = gmalloc(c, n)))
        return;
    if ((p = gaddr(c, g, n))) {
        memcpy(p, cwd, n);
        a[0] = g;
        call_ready(c);
        if (!wasm_runtime_call_wasm(c->exec, f, 1, a))
            wasm_runtime_clear_exception(c->inst);
    }
    gfree(c, g);
}

static ctx *instantiate(uint8_t *bytes, uint32_t n, const char *file, char *error, size_t size)
{
    ctx *c = calloc(1, sizeof(ctx));
    uint32_t heap;
    int has_chdir;
    if (!c) {
        snprintf(error, size, "no memory");
        free(bytes);
        return NULL;
    }
    c->bytes = bytes;
#ifdef NIF_WASM_EDGE
    host_set_file(file);
#endif
    if (!(c->module = wasm_runtime_load(bytes, n, error, (uint32_t)size)))
        goto failed;
    if (!check_imports(c->module, file, error, size))
        goto failed;
    /* The NIF can open files, as a native NIF can: WASI gets "/". The
     * sandbox of beam.com (docs/SANDBOX.md) limits the host calls of
     * WAMR too. wasi-libc starts in "/", so a relative path needs the
     * work directory: set_cwd() calls the chdir export of the headers
     * of beam.com. A module without it also gets ".", which then takes
     * all the paths (wasi-libc strips the "/" and the "."), so only its
     * relative paths work. */
#ifdef NIF_WASM_EDGE
    has_chdir = 0;
#else
    has_chdir = module_exports(c->module, "erl_nif_wasm_chdir");
    wasm_runtime_set_wasi_args(c->module, wasi_dirs, has_chdir ? 1 : 2, NULL, 0, NULL, 0, NULL, 0);
#endif
    heap = module_exports(c->module, "erl_nif_wasm_malloc")
        || (module_exports(c->module, "malloc") && module_exports(c->module, "free")) ? 0 : APP_HEAP;
#ifdef NIF_WASM_EDGE
    /* The host has no heap of WAMR for the module. */
    if (heap) {
        snprintf(error, size, "the module exports no malloc and free");
        goto failed;
    }
#endif
    if (!(c->inst = wasm_runtime_instantiate(c->module, WASM_STACK, heap, error, (uint32_t)size))) {
#ifdef NIF_WASM_EDGE
        goto failed;
#else
        /* A system can refuse to open a directory of WASI: then the
         * module runs with no files. */
        wasm_runtime_set_wasi_args(c->module, NULL, 0, NULL, 0, NULL, 0, NULL, 0);
        if (!(c->inst = wasm_runtime_instantiate(c->module, WASM_STACK, heap, error, (uint32_t)size)))
            goto failed;
        if (debug)
            fprintf(stderr, "nif_wasm: %s: no files (the directories of WASI did not open)\n", file);
        has_chdir = 0;
#endif
    }
    if (!(c->exec = wasm_runtime_create_exec_env(c->inst, WASM_STACK))) {
        snprintf(error, size, "no execution environment");
        goto failed;
    }
    wasm_runtime_set_user_data(c->exec, c);
    c->malloc_fn = wasm_runtime_lookup_function(c->inst, "erl_nif_wasm_malloc");
    c->free_fn = wasm_runtime_lookup_function(c->inst, "erl_nif_wasm_free");
    if (!c->malloc_fn || !c->free_fn)
        c->malloc_fn = c->free_fn = NULL;
    if (!(c->lock = enif_mutex_create("nif_wasm"))) {
        snprintf(error, size, "no mutex");
        goto failed;
    }
#ifdef NIF_WASM_EDGE
    /* WAMR calls _initialize of a reactor itself; the host does not. */
    {
        wasm_function_inst_t init = wasm_runtime_lookup_function(c->inst, "_initialize");
        if (init) {
            call_ready(c);
            if (!wasm_runtime_call_wasm(c->exec, init, 0, NULL)) {
                snprintf(error, size, "_initialize: %s", wasm_runtime_get_exception(c->inst));
                goto failed;
            }
        }
    }
#endif
    if (has_chdir)
        set_cwd(c);
    return c;
failed:
    ctx_free(c);
    return NULL;
}

static char *entry_string(ctx *c, uint32_t off)
{
    const char *s = gstr(c, off);
    return s ? (char *)keep_string(c, s) : NULL;
}

/* Read the ErlNifEntry of the module. ErlNifEntry of wasm32: major,
 * minor, name, num_of_funcs, funcs, load, reload, upgrade, unload,
 * vm_variant, options, sizeof_ErlNifResourceTypeInit, min_erts.
 * ErlNifFunc of wasm32: name, arity, fptr, flags. */
static int read_entry(ctx *c, char *error, size_t size)
{
    wasm_function_inst_t init = wasm_runtime_lookup_function(c->inst, "nif_init");
    uint32_t a[1] = { 0 }, ge[13], gf[4];
    const uint8_t *p;
    int i;
    if (!init) {
        snprintf(error, size, "no export nif_init");
        return 0;
    }
    call_ready(c);
    if (!wasm_runtime_call_wasm(c->exec, init, 0, a)) {
        snprintf(error, size, "nif_init: %s", wasm_runtime_get_exception(c->inst));
        return 0;
    }
    if (!(p = gaddr(c, a[0], sizeof(ge)))) {
        snprintf(error, size, "nif_init: bad entry");
        return 0;
    }
    memcpy(ge, p, sizeof(ge));
    if (ge[3] > MAX_FUNCS) {
        snprintf(error, size, "%u functions: at most %d", ge[3], MAX_FUNCS);
        return 0;
    }
    for (i = 0; i < (int)ge[3]; i++) {
        if (!(p = gaddr(c, ge[4] + 16 * (uint32_t)i, 16))) {
            snprintf(error, size, "nif_init: bad functions");
            return 0;
        }
        memcpy(gf, p, sizeof(gf));
        if (!(c->funcs[i].name = entry_string(c, gf[0]))) {
            snprintf(error, size, "nif_init: bad function name");
            return 0;
        }
        c->funcs[i].arity = gf[1];
        c->fn[i] = gf[2];
        c->funcs[i].fptr = tramp[i];
        c->funcs[i].flags = gf[3];
    }
    c->load_fn = ge[5];
    c->unload_fn = ge[8];
    c->entry.major = (int)ge[0];
    c->entry.minor = (int)ge[1];
    c->entry.name = entry_string(c, ge[2]);
    c->entry.num_of_funcs = (int)ge[3];
    c->entry.funcs = c->funcs;
    c->entry.load = nif_load;
    c->entry.reload = NULL;
    /* An upgrade (load_nif/2 of new code while the old code has the
     * library) is not supported. */
    c->entry.upgrade = NULL;
    c->entry.unload = nif_unload;
    c->entry.vm_variant = entry_string(c, ge[9]);
    c->entry.options = ge[10];
    c->entry.sizeof_ErlNifResourceTypeInit = sizeof(ErlNifResourceTypeInit);
    c->entry.min_erts = entry_string(c, ge[12]);
    if (!c->entry.name || !c->entry.vm_variant || !c->entry.min_erts) {
        snprintf(error, size, "nif_init: bad entry");
        return 0;
    }
    return 1;
}

ErlNifEntry *nif_wasm_open(const char *path, char *error, size_t size)
{
    const char *suffix = aot_suffix();
    char file[4096], aot_error[512];
    uint8_t *bytes = NULL;
    uint32_t n = 0;
    ctx *c = NULL;
    int r;

    error[0] = aot_error[0] = '\0';
    if (!nil_ready()) {
        snprintf(error, size, "no terms");
        return NULL;
    }
    if (suffix) {
        snprintf(file, sizeof(file), "%s%s", path, suffix);
        if ((r = read_file(file, &bytes, &n)) < 0)
            snprintf(aot_error, sizeof(aot_error), "%.300s: %s", file, strerror(errno));
        else if (r > 0) {
            if (!nif_wasm_runtime_init()) {
                free(bytes);
                snprintf(error, size, "no WebAssembly runtime");
                return NULL;
            }
            c = instantiate(bytes, n, file, aot_error, sizeof(aot_error));
        }
    }
    if (!c) {
        snprintf(file, sizeof(file), "%s.wasm", path);
        if ((r = read_file(file, &bytes, &n)) <= 0) {
            if (r < 0)
                snprintf(error, size, "%s: %s", file, strerror(errno));
            else if (aot_error[0])
                snprintf(error, size, "%s", aot_error);
            return NULL;
        }
        if (!nif_wasm_runtime_init()) {
            free(bytes);
            snprintf(error, size, "no WebAssembly runtime");
            return NULL;
        }
        if (!(c = instantiate(bytes, n, file, error, size)))
            return NULL;
    }
    if (debug)
        fprintf(stderr, "nif_wasm: %s%s%s\n", file, aot_error[0] ? ", AOT: " : "", aot_error);
    if (!read_entry(c, error, size)) {
        ctx_free(c);
        return NULL;
    }
    loading = c;
    return &c->entry;
}

#ifdef BEAM_COM_ERTS_HOOK
/* ERTS (patches/otp/0003-wasm-nif.patch) calls this hook in load_nif/2. */
extern ErlNifEntry *(*erts_wasm_nif_open)(const char *path, char *error, size_t size);

__attribute__((constructor)) static void nif_wasm_hook(void)
{
    erts_wasm_nif_open = nif_wasm_open;
}
#endif
