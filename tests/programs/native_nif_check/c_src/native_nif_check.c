/*
 * The test of the native NIF objects (docs/NIFS.md): a NIF that a C
 * compiler of the host builds as for a dynamic library, with no change.
 * build.sh compiles it with cosmocc and joins its objects with `ld -r`
 * into priv/native_nif_check.ARCH.o. load_nif/2 loads the object of the
 * CPU from the zip of the program (c_src/cosmo/beam_com_nif.c).
 */
#include <erl_nif.h>

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int util_calls;
const char *util_name(int i);
extern long (*const util_ops[3])(long, long);

static ErlNifResourceType *counter_type, *watch_type;
static int dtors;
static int loads;
static int constructed;
static char big_table[1 << 20];

__attribute__((constructor)) static void construct(void)
{
    constructed += 7;
}

struct priv {
    int load_calls;
};

struct counter {
    long value;
};

struct watch {
    ErlNifPid owner;
    ErlNifMonitor mon;
};

static void counter_dtor(ErlNifEnv *env, void *obj)
{
    (void)env;
    (void)obj;
    __atomic_fetch_add(&dtors, 1, __ATOMIC_SEQ_CST);
}

static void watch_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *mon)
{
    struct watch *w = obj;
    (void)mon;
    enif_send(env, &w->owner, NULL,
              enif_make_tuple2(env, enif_make_atom(env, "down"), enif_make_pid(env, pid)));
}

static int open_types(ErlNifEnv *env, ErlNifResourceFlags flags)
{
    /* members: the count of the callbacks that ERTS reads (dtor, stop, down). */
    ErlNifResourceTypeInit init = { NULL, NULL, watch_down, 3, NULL };
    counter_type = enif_open_resource_type(env, NULL, "counter", counter_dtor, flags, NULL);
    watch_type = enif_init_resource_type(env, "watch", &init, flags, NULL);
    return counter_type && watch_type ? 0 : 1;
}

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM info)
{
    struct priv *p = enif_alloc(sizeof(*p));
    (void)info;
    if (!p)
        return 1;
    p->load_calls = 1;
    *priv_data = p;
    loads++;
    return open_types(env, ERL_NIF_RT_CREATE);
}

static int upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data, ERL_NIF_TERM info)
{
    struct priv *p = *old_priv_data;
    (void)info;
    p->load_calls++;
    *priv_data = p;
    loads++;
    return open_types(env, ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER);
}

static ERL_NIF_TERM ok(ErlNifEnv *env, ERL_NIF_TERM t)
{
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), t);
}

static ERL_NIF_TERM add(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifSInt64 a, b;
    (void)argc;
    if (!enif_get_int64(env, argv[0], &a) || !enif_get_int64(env, argv[1], &b))
        return enif_make_badarg(env);
    return enif_make_int64(env, a + b);
}

static ERL_NIF_TERM echo(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifEnv *other = enif_alloc_env();
    ERL_NIF_TERM copy = enif_make_copy(other, argv[0]), back;
    (void)argc;
    back = enif_make_copy(env, copy);
    enif_free_env(other);
    return back;
}

static ERL_NIF_TERM upcase(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary in;
    unsigned char *out;
    ERL_NIF_TERM t;
    size_t i;
    (void)argc;
    if (!enif_inspect_binary(env, argv[0], &in))
        return enif_make_badarg(env);
    out = enif_make_new_binary(env, in.size, &t);
    for (i = 0; i < in.size; i++)
        out[i] = in.data[i] >= 'a' && in.data[i] <= 'z' ? in.data[i] - 32 : in.data[i];
    return ok(env, t);
}

static ERL_NIF_TERM iolist(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary bin, own;
    (void)argc;
    if (!enif_inspect_iolist_as_binary(env, argv[0], &bin) || !enif_alloc_binary(bin.size, &own))
        return enif_make_badarg(env);
    memcpy(own.data, bin.data, bin.size);
    if (!enif_realloc_binary(&own, bin.size + 1))
        return enif_make_badarg(env);
    own.data[bin.size] = '!';
    return enif_make_binary(env, &own);
}

static ERL_NIF_TERM map_keys(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifMapIterator it;
    ERL_NIF_TERM k, v, list = enif_make_list(env, 0), put;
    size_t size;
    (void)argc;
    if (!enif_get_map_size(env, argv[0], &size) ||
        !enif_map_iterator_create(env, argv[0], &it, ERL_NIF_MAP_ITERATOR_FIRST))
        return enif_make_badarg(env);
    while (enif_map_iterator_get_pair(env, &it, &k, &v)) {
        list = enif_make_list_cell(env, k, list);
        enif_map_iterator_next(env, &it);
    }
    enif_map_iterator_destroy(env, &it);
    if (!enif_make_map_put(env, argv[0], enif_make_atom(env, "added"), enif_make_ulong(env, size), &put))
        return enif_make_badarg(env);
    return enif_make_tuple3(env, enif_make_ulong(env, size), list, put);
}

static ERL_NIF_TERM mul(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    double a, b;
    (void)argc;
    if (!enif_get_double(env, argv[0], &a) || !enif_get_double(env, argv[1], &b))
        return enif_make_badarg(env);
    return enif_make_double(env, a * b);
}

static ERL_NIF_TERM counter_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct counter *c = enif_alloc_resource(counter_type, sizeof(*c));
    ERL_NIF_TERM t;
    (void)argc;
    (void)argv;
    c->value = 0;
    t = enif_make_resource(env, c);
    enif_release_resource(c);
    return t;
}

static ERL_NIF_TERM counter_add(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct counter *c;
    long n;
    (void)argc;
    if (!enif_get_resource(env, argv[0], counter_type, (void **)&c) || !enif_get_long(env, argv[1], &n))
        return enif_make_badarg(env);
    return enif_make_long(env, __atomic_add_fetch(&c->value, n, __ATOMIC_SEQ_CST));
}

static ERL_NIF_TERM dtor_count(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    return enif_make_int(env, __atomic_load_n(&dtors, __ATOMIC_SEQ_CST));
}

static ERL_NIF_TERM watch(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct watch *w = enif_alloc_resource(watch_type, sizeof(*w));
    ErlNifPid pid;
    ERL_NIF_TERM t;
    int r;
    (void)argc;
    if (!enif_get_local_pid(env, argv[0], &pid)) {
        enif_release_resource(w);
        return enif_make_badarg(env);
    }
    enif_self(env, &w->owner);
    r = enif_monitor_process(env, w, &pid, &w->mon);
    t = enif_make_resource(env, w);
    enif_release_resource(w);
    return enif_make_tuple2(env, enif_make_int(env, r), t);
}

static ERL_NIF_TERM unwatch(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct watch *w;
    (void)argc;
    if (!enif_get_resource(env, argv[0], watch_type, (void **)&w))
        return enif_make_badarg(env);
    return enif_make_int(env, enif_demonitor_process(env, w, &w->mon));
}

static ERL_NIF_TERM send_self(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifPid self;
    ErlNifEnv *msg = enif_alloc_env();
    int r;
    (void)argc;
    enif_self(env, &self);
    r = enif_send(env, &self, msg, enif_make_tuple2(msg, enif_make_atom(msg, "sent"), enif_make_copy(msg, argv[0])));
    enif_free_env(msg);
    return r ? enif_make_atom(env, "ok") : enif_make_atom(env, "error");
}

static ERL_NIF_TERM raise_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    return enif_raise_exception(env, argv[0]);
}

/* A dirty NIF on a CPU scheduler, and one on an I/O scheduler. */
static ERL_NIF_TERM dirty_sum(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    long n, i, s = 0;
    (void)argc;
    if (!enif_get_long(env, argv[0], &n))
        return enif_make_badarg(env);
    for (i = 1; i <= n; i++)
        s += i;
    return enif_make_tuple2(env, enif_make_long(env, s),
                            enif_make_int(env, enif_thread_type() == ERL_NIF_THR_DIRTY_CPU_SCHEDULER));
}

static ERL_NIF_TERM dirty_io(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    return enif_make_tuple2(env, argv[0],
                            enif_make_int(env, enif_thread_type() == ERL_NIF_THR_DIRTY_IO_SCHEDULER));
}

/* A NIF that yields: enif_schedule_nif with the state in its arguments. */
static ERL_NIF_TERM yield_sum_step(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    long n, i, s, steps;
    ERL_NIF_TERM next[4];
    (void)argc;
    if (!enif_get_long(env, argv[0], &n) || !enif_get_long(env, argv[1], &i) ||
        !enif_get_long(env, argv[2], &s) || !enif_get_long(env, argv[3], &steps))
        return enif_make_badarg(env);
    steps++;
    for (; i <= n; i++) {
        s += i;
        if (i % 10000 == 0 && enif_consume_timeslice(env, 10)) {
            i++;
            break;
        }
        if (i % 50000 == 0) {
            i++;
            break;
        }
    }
    if (i > n)
        return enif_make_tuple2(env, enif_make_long(env, s), enif_make_int(env, steps > 1));
    next[0] = argv[0];
    next[1] = enif_make_long(env, i);
    next[2] = enif_make_long(env, s);
    next[3] = enif_make_long(env, steps);
    return enif_schedule_nif(env, "yield_sum", 0, yield_sum_step, 4, next);
}

static ERL_NIF_TERM yield_sum(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM a[4];
    (void)argc;
    a[0] = argv[0];
    a[1] = enif_make_long(env, 1);
    a[2] = enif_make_long(env, 0);
    a[3] = enif_make_long(env, 0);
    return enif_schedule_nif(env, "yield_sum", 0, yield_sum_step, 4, a);
}

/* A thread of enif_thread_create waits on a condition, then sends
 * messages to the caller from its own environment. */
struct job {
    ErlNifPid to;
    int count, go;
    ErlNifMutex *mutex;
    ErlNifCond *cond;
};

static void *thread_main(void *arg)
{
    struct job *j = arg;
    ErlNifEnv *env = enif_alloc_env();
    int i;
    enif_mutex_lock(j->mutex);
    while (!j->go)
        enif_cond_wait(j->cond, j->mutex);
    enif_mutex_unlock(j->mutex);
    for (i = 0; i < j->count; i++) {
        enif_send(NULL, &j->to, env, enif_make_tuple2(env, enif_make_atom(env, "thread"), enif_make_int(env, i)));
        enif_clear_env(env);
    }
    enif_free_env(env);
    return j;
}

static ERL_NIF_TERM thread_send(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct job j;
    ErlNifTid tid;
    void *res = NULL;
    (void)argc;
    if (!enif_get_int(env, argv[0], &j.count))
        return enif_make_badarg(env);
    enif_self(env, &j.to);
    j.go = 0;
    j.mutex = enif_mutex_create("native_nif_check");
    j.cond = enif_cond_create("native_nif_check");
    if (enif_thread_create("native_nif_check", &tid, thread_main, &j, NULL)) {
        enif_cond_destroy(j.cond);
        enif_mutex_destroy(j.mutex);
        return enif_make_badarg(env);
    }
    enif_mutex_lock(j.mutex);
    j.go = 1;
    enif_cond_broadcast(j.cond);
    enif_mutex_unlock(j.mutex);
    enif_thread_join(tid, &res);
    enif_cond_destroy(j.cond);
    enif_mutex_destroy(j.mutex);
    return enif_make_int(env, res == &j);
}

static int cmp_int(const void *a, const void *b)
{
    int x = *(const int *)a, y = *(const int *)b;
    return (x > y) - (x < y);
}

/* The libc of the program: formats, numbers, sort, errno, math, memory. */
static ERL_NIF_TERM libc(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char buf[128], *end;
    int nums[6] = { 5, -2, 9, 0, 3, 3 }, i, n, erange;
    long long big;
    double d;
    ERL_NIF_TERM sorted[6];
    char *heap;
    (void)argc;
    (void)argv;
    n = snprintf(buf, sizeof(buf), "%d|%5.2f|%s|%x|%lld|%c", 42, 3.14159, "str", 255, 1LL << 40, 'z');
    d = strtod("2.5e3", &end);
    errno = 0;
    big = strtoll("99999999999999999999", NULL, 10);
    erange = errno == ERANGE && big == 9223372036854775807LL;
    qsort(nums, 6, sizeof(int), cmp_int);
    for (i = 0; i < 6; i++)
        sorted[i] = enif_make_int(env, nums[i]);
    heap = malloc(64 << 20);
    if (!heap)
        return enif_make_badarg(env);
    memset(heap, 0xab, 64 << 20);
    i = heap[(64 << 20) - 1] == (char)0xab;
    free(heap);
    return enif_make_tuple6(env, enif_make_string_len(env, buf, n, ERL_NIF_LATIN1), enif_make_double(env, d),
                            enif_make_int(env, erange), enif_make_list_from_array(env, sorted, 6),
                            enif_make_double(env, sqrt(2.0) * sqrt(2.0) + pow(2, 10) + floor(-1.5) + fabs(-0.25)),
                            enif_make_int(env, i && strlen(buf) == (size_t)n && !strcmp(end, "")));
}

/* A switch (a jump table), function pointers in an other object, a big
 * table in bss, and the constructor. */
static ERL_NIF_TERM code(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int op, r;
    long a = 0;
    (void)argc;
    if (!enif_get_int(env, argv[0], &op))
        return enif_make_badarg(env);
    switch (op) {
    case 0: r = 10; break;
    case 1: r = 21; break;
    case 2: r = 32; break;
    case 3: r = 43; break;
    case 4: r = 54; break;
    case 5: r = 65; break;
    case 6: r = 76; break;
    case 7: r = 87; break;
    default: r = -1;
    }
    big_table[sizeof(big_table) - 1] += 1;
    a = util_ops[0](40, 2) * 10000 + util_ops[1](10, 3) * 100 + util_ops[2](3, 3);
    return enif_make_tuple5(env, enif_make_int(env, r), enif_make_long(env, a),
                            enif_make_string(env, util_name(op % 5), ERL_NIF_LATIN1),
                            enif_make_int(env, big_table[sizeof(big_table) - 1]), enif_make_int(env, constructed));
}

static ERL_NIF_TERM info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    struct priv *p = enif_priv_data(env);
    char text[64];
    /* The monotonic time can be below 0: compare two reads. */
    ErlNifTime t0 = enif_monotonic_time(ERL_NIF_USEC), t1 = enif_monotonic_time(ERL_NIF_USEC);
    int n;
    (void)argc;
    n = enif_snprintf(text, sizeof(text), "%T", argv[0]);
    return enif_make_tuple5(env, enif_make_int(env, p->load_calls), enif_make_int(env, loads),
                            enif_make_string_len(env, text, n > 0 ? n : 0, ERL_NIF_LATIN1),
                            enif_make_int(env, t1 >= t0), enif_make_unique_integer(env, ERL_NIF_UNIQUE_POSITIVE));
}

static ERL_NIF_TERM big(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    return enif_make_list3(env, enif_make_uint64(env, 18446744073709551615ULL),
                           enif_make_int64(env, -9223372036854775807LL - 1), enif_make_ref(env));
}

static ErlNifFunc funcs[] = {
    { "add", 2, add, 0 },
    { "echo", 1, echo, 0 },
    { "upcase", 1, upcase, 0 },
    { "iolist", 1, iolist, 0 },
    { "map_keys", 1, map_keys, 0 },
    { "mul", 2, mul, 0 },
    { "counter_new", 0, counter_new, 0 },
    { "counter_add", 2, counter_add, 0 },
    { "dtor_count", 0, dtor_count, 0 },
    { "watch", 1, watch, 0 },
    { "unwatch", 1, unwatch, 0 },
    { "send_self", 1, send_self, 0 },
    { "raise", 1, raise_nif, 0 },
    { "dirty_sum", 1, dirty_sum, ERL_NIF_DIRTY_JOB_CPU_BOUND },
    { "dirty_io", 1, dirty_io, ERL_NIF_DIRTY_JOB_IO_BOUND },
    { "yield_sum", 1, yield_sum, 0 },
    { "thread_send", 1, thread_send, 0 },
    { "libc", 0, libc, 0 },
    { "code", 1, code, 0 },
    { "info", 1, info, 0 },
    { "big", 0, big, 0 },
};

ERL_NIF_INIT(native_nif_check, funcs, load, NULL, upgrade, NULL)
