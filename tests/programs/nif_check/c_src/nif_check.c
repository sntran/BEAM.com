/*
 * The test NIF of the NIF libraries in WebAssembly (docs/NIFS.md). It
 * uses the common enif_* functions, so that a test can compare its
 * results with Erlang. build.sh makes priv/nif_check.wasm and the AOT
 * files from this file.
 */
#include <string.h>
#include "erl_nif.h"

static ERL_NIF_TERM atom_ok, atom_error, atom_true, atom_false;
static ErlNifResourceType *counter_type, *watcher_type, *bad_dtor_type;
static void watcher_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *mon);
static int dtors, bad_dtors;

typedef struct {
    long long value;
} counter;

static void counter_dtor(ErlNifEnv *env, void *obj)
{
    (void)env;
    (void)obj;
    dtors++;
}

/* A destructor of an other type (an i64 parameter): the bridge does not
 * call it. */
static void bad_dtor(long long x)
{
    (void)x;
    bad_dtors++;
}

/* A function of the module as the function of a NIF (or of a resource
 * type), whatever its type. */
#define AS_NIF(f) ((ERL_NIF_TERM (*)(ErlNifEnv *, int, const ERL_NIF_TERM[]))(void (*)(void))(f))

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
    static int loads;
    int n;
    /* The atoms stay valid between calls: a NIF compares them with ==. */
    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    atom_true = enif_make_atom(env, "true");
    atom_false = enif_make_atom(env, "false");
    counter_type = enif_open_resource_type(env, NULL, "counter", counter_dtor,
                                           ERL_NIF_RT_CREATE, NULL);
    {
        ErlNifResourceTypeInit init = { NULL, NULL, watcher_down, 3, NULL };
        watcher_type = enif_init_resource_type(env, "watcher", &init, ERL_NIF_RT_CREATE, NULL);
    }
    if (!watcher_type)
        return 1;
    bad_dtor_type = enif_open_resource_type(env, NULL, "bad_dtor",
                                            (ErlNifResourceDtor *)(void (*)(void))bad_dtor,
                                            ERL_NIF_RT_CREATE, NULL);
    if (!bad_dtor_type)
        return 1;
    if (!counter_type || !enif_get_int(env, info, &n))
        return 1;
    loads += n;
    *priv = &loads;
    return 0;
}

static ERL_NIF_TERM add(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifSInt64 a, b;
    if (!enif_get_int64(env, argv[0], &a) || !enif_get_int64(env, argv[1], &b))
        return enif_make_badarg(env);
    return enif_make_int64(env, a + b);
}

static ERL_NIF_TERM echo(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    return argv[0];
}

static ERL_NIF_TERM is_ok(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    return argv[0] == atom_ok ? atom_true : atom_false;
}

static ERL_NIF_TERM swap(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    const ERL_NIF_TERM *t;
    int n;
    if (!enif_get_tuple(env, argv[0], &n, &t) || n != 2)
        return enif_make_badarg(env);
    return enif_make_tuple2(env, t[1], t[0]);
}

static ERL_NIF_TERM reverse(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM list = argv[0], out = enif_make_list(env, 0), head;
    unsigned n;
    if (!enif_get_list_length(env, list, &n))
        return enif_make_badarg(env);
    while (enif_get_list_cell(env, list, &head, &list))
        out = enif_make_list_cell(env, head, out);
    return enif_make_tuple2(env, enif_make_uint(env, n), out);
}

/* The bytes go into the binary after the tuple is made. */
static ERL_NIF_TERM upcase(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary in;
    ERL_NIF_TERM bin, result;
    unsigned char *out;
    size_t i;
    if (!enif_inspect_binary(env, argv[0], &in))
        return enif_make_badarg(env);
    out = enif_make_new_binary(env, in.size, &bin);
    result = enif_make_tuple2(env, atom_ok, bin);
    for (i = 0; i < in.size; i++)
        out[i] = in.data[i] >= 'a' && in.data[i] <= 'z' ? in.data[i] - 32 : in.data[i];
    return result;
}

static ERL_NIF_TERM concat(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary a, b, out;
    if (!enif_inspect_binary(env, argv[0], &a) || !enif_inspect_binary(env, argv[1], &b))
        return enif_make_badarg(env);
    if (!enif_alloc_binary(a.size, &out))
        return enif_make_badarg(env);
    memcpy(out.data, a.data, a.size);
    if (!enif_realloc_binary(&out, a.size + b.size))
        return enif_make_badarg(env);
    memcpy(out.data + a.size, b.data, b.size);
    return enif_make_binary(env, &out);
}

static ERL_NIF_TERM iolist(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary b;
    ERL_NIF_TERM t;
    if (!enif_inspect_iolist_as_binary(env, argv[0], &b))
        return enif_make_badarg(env);
    memcpy(enif_make_new_binary(env, b.size, &t), b.data, b.size);
    return enif_make_sub_binary(env, t, b.size > 1 ? 1 : 0, b.size > 1 ? b.size - 1 : b.size);
}

static ERL_NIF_TERM map_put(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM out;
    if (!enif_make_map_put(env, argv[0], argv[1], argv[2], &out))
        return enif_make_badarg(env);
    return out;
}

static ERL_NIF_TERM map_value(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM v;
    if (!enif_get_map_value(env, argv[0], argv[1], &v))
        return atom_error;
    return enif_make_tuple2(env, atom_ok, v);
}

/* The keys, from the last to the first, and the size. */
static ERL_NIF_TERM map_keys(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifMapIterator it;
    ERL_NIF_TERM k, v, keys = enif_make_list(env, 0);
    size_t size;
    if (!enif_get_map_size(env, argv[0], &size)
        || !enif_map_iterator_create(env, argv[0], &it, ERL_NIF_MAP_ITERATOR_FIRST))
        return enif_make_badarg(env);
    while (enif_map_iterator_get_pair(env, &it, &k, &v)) {
        keys = enif_make_list_cell(env, k, keys);
        enif_map_iterator_next(env, &it);
    }
    enif_map_iterator_destroy(env, &it);
    return enif_make_tuple2(env, enif_make_uint64(env, size), keys);
}

static ERL_NIF_TERM charlist(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char buf[256];
    ErlNifBinary b;
    if (enif_inspect_binary(env, argv[0], &b))
        return enif_make_string_len(env, (const char *)b.data, b.size, ERL_NIF_LATIN1);
    if (enif_get_string(env, argv[0], buf, sizeof(buf), ERL_NIF_LATIN1) > 0)
        return enif_make_atom(env, buf);
    return enif_make_badarg(env);
}

static ERL_NIF_TERM mul(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    double a, b;
    if (!enif_get_double(env, argv[0], &a) || !enif_get_double(env, argv[1], &b))
        return enif_make_badarg(env);
    return enif_make_double(env, a * b);
}

static ERL_NIF_TERM counter_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    counter *c = enif_alloc_resource(counter_type, sizeof(counter));
    ERL_NIF_TERM t;
    c->value = 0;
    t = enif_make_resource(env, c);
    enif_release_resource(c);
    return t;
}

static ERL_NIF_TERM counter_add(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    counter *c;
    ErlNifSInt64 n;
    if (!enif_get_resource(env, argv[0], counter_type, (void **)&c)
        || !enif_get_int64(env, argv[1], &n))
        return enif_make_badarg(env);
    c->value += n;
    return enif_make_int64(env, c->value);
}

static ERL_NIF_TERM dtor_count(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    return enif_make_int(env, dtors);
}

static ERL_NIF_TERM send_self(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifEnv *msg_env = enif_alloc_env();
    ErlNifPid self;
    ERL_NIF_TERM msg;
    int ok;
    if (!enif_self(env, &self))
        return enif_make_badarg(env);
    msg = enif_make_tuple2(msg_env, enif_make_atom(msg_env, "sent"), enif_make_copy(msg_env, argv[0]));
    ok = enif_send(env, &self, msg_env, msg);
    enif_free_env(msg_env);
    return ok ? atom_ok : atom_error;
}

static ERL_NIF_TERM self_pid(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifPid self;
    if (!enif_self(env, &self))
        return enif_make_badarg(env);
    return enif_make_pid(env, &self);
}

static ERL_NIF_TERM raise(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    return enif_raise_exception(env, argv[0]);
}

static ERL_NIF_TERM t2b(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary b;
    ERL_NIF_TERM t;
    if (!enif_term_to_binary(env, argv[0], &b))
        return enif_make_badarg(env);
    if (!enif_binary_to_term(env, b.data, b.size, &t, 0)) {
        enif_release_binary(&b);
        return enif_make_badarg(env);
    }
    return enif_make_tuple2(env, t, enif_make_binary(env, &b));
}

/* sum(N): 1 + 2 + ... + N, in steps of 1000 with enif_schedule_nif. */
static ERL_NIF_TERM sum_step(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifUInt64 n, i, acc;
    ERL_NIF_TERM next[3];
    int steps = 0;
    if (!enif_get_uint64(env, argv[0], &n) || !enif_get_uint64(env, argv[1], &i)
        || !enif_get_uint64(env, argv[2], &acc))
        return enif_make_badarg(env);
    for (; i <= n && steps < 1000; i++, steps++)
        acc += i;
    if (i > n)
        return enif_make_uint64(env, acc);
    next[0] = argv[0];
    next[1] = enif_make_uint64(env, i);
    next[2] = enif_make_uint64(env, acc);
    return enif_schedule_nif(env, "sum_step", 0, sum_step, 3, next);
}

static ERL_NIF_TERM sum(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM args[3] = { argv[0], enif_make_uint(env, 1), enif_make_uint(env, 0) };
    return sum_step(env, 3, args);
}

static ERL_NIF_TERM dirty_sum(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifUInt64 n, i, acc = 0;
    if (!enif_get_uint64(env, argv[0], &n))
        return enif_make_badarg(env);
    for (i = 1; i <= n; i++)
        acc += i;
    return enif_make_uint64(env, acc);
}

static ERL_NIF_TERM crash(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    __builtin_trap();
}

static ERL_NIF_TERM loads(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    return enif_make_int(env, *(int *)enif_priv_data(env));
}

static ERL_NIF_TERM compare(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    return enif_make_tuple3(env, enif_make_int(env, enif_compare(argv[0], argv[1])),
                            enif_is_identical(argv[0], argv[1]) ? atom_true : atom_false,
                            enif_make_uint64(env, enif_hash(ERL_NIF_PHASH2, argv[0], 0)));
}

static ERL_NIF_TERM types(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM t = argv[0];
    const char *name = enif_is_atom(env, t) ? "atom"
        : enif_is_binary(env, t) ? "binary"
        : enif_is_ref(env, t) ? "ref"
        : enif_is_fun(env, t) ? "fun"
        : enif_is_pid(env, t) ? "pid"
        : enif_is_map(env, t) ? "map"
        : enif_is_tuple(env, t) ? "tuple"
        : enif_is_empty_list(env, t) ? "nil"
        : enif_is_list(env, t) ? "list"
        : enif_is_number(env, t) ? "number"
        : "other";
    return enif_make_atom(env, name);
}

static ERL_NIF_TERM big(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM l[4];
    l[0] = enif_make_uint64(env, 18446744073709551615ULL);
    l[1] = enif_make_int64(env, -9223372036854775807LL - 1);
    l[2] = enif_make_long(env, -2147483647L - 1);
    l[3] = enif_make_ref(env);
    return enif_make_list_from_array(env, l, 4);
}

/* beam.com does not give enif_dynamic_resource_call: the call raises an
 * exception. */
static ERL_NIF_TERM unsupported(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    enif_dynamic_resource_call(env, atom_ok, atom_ok, atom_ok, NULL);
    return atom_ok;
}

/* A watcher: a resource that monitors a process. Its down callback sends
 * {down, Pid} to the owner. */
typedef struct {
    ErlNifPid owner;
    ErlNifMonitor mon;
} watcher;

static void watcher_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *mon)
{
    watcher *w = obj;
    ErlNifEnv *msg_env = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple2(msg_env, enif_make_atom(msg_env, "down"), enif_make_pid(msg_env, pid));
    enif_send(env, &w->owner, msg_env, msg);
    enif_free_env(msg_env);
    (void)mon;
}

static ERL_NIF_TERM watch(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    watcher *w;
    ErlNifPid pid;
    ERL_NIF_TERM t;
    int r;
    if (!enif_get_local_pid(env, argv[0], &pid))
        return enif_make_badarg(env);
    w = enif_alloc_resource(watcher_type, sizeof(watcher));
    enif_self(env, &w->owner);
    r = enif_monitor_process(env, w, &pid, &w->mon);
    t = enif_make_tuple2(env, enif_make_int(env, r), enif_make_resource(env, w));
    enif_release_resource(w);
    return t;
}

/* {demonitor result, monitor term, compare of the monitor with itself} */
static ERL_NIF_TERM unwatch(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    watcher *w;
    ErlNifMonitor copy;
    ERL_NIF_TERM term;
    if (!enif_get_resource(env, argv[0], watcher_type, (void **)&w))
        return enif_make_badarg(env);
    copy = w->mon;
    term = enif_make_monitor_term(env, &w->mon);
    return enif_make_tuple3(env, enif_make_int(env, enif_demonitor_process(env, w, &w->mon)), term,
                            enif_make_int(env, enif_compare_monitors(&copy, &w->mon)));
}

static ERL_NIF_TERM fmt(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char buf[256];
    int n = enif_snprintf(buf, sizeof(buf), "%d|%5.2f|%s|%x|%lld|%T|%c%%|%-4u|%.3s", 42, 3.14159, "str",
                          255, (long long)1 << 40, argv[0], 'z', 7u, "abcdef");
    char small[8];
    int m = enif_snprintf(small, sizeof(small), "%s", "0123456789");
    return enif_make_tuple3(env, enif_make_string(env, buf, ERL_NIF_LATIN1), enif_make_int(env, n - m),
                            enif_make_string(env, small, ERL_NIF_LATIN1));
}

/* An I/O queue: the binaries of the list (enq_binary), then the list as an
 * I/O vector (enqv), and 3 bytes off. Gives {size, the size of the peek,
 * the bytes of the peek, the head}. */
static ERL_NIF_TERM ioq(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifIOQueue *q = enif_ioq_create(ERL_NIF_IOQ_NORMAL);
    ERL_NIF_TERM list = argv[0], head, tail, all, first;
    ErlNifIOVec *iov;
    ErlNifBinary b;
    SysIOVec *v;
    size_t size, total = 0;
    int i, n;
    unsigned char *out;
    while (enif_get_list_cell(env, list, &head, &list)) {
        if (!enif_inspect_binary(env, head, &b) || !enif_ioq_enq_binary(q, &b, 0))
            return enif_make_badarg(env);
    }
    if (!enif_inspect_iovec(env, 1024, argv[0], &tail, &iov) || !enif_ioq_enqv(q, iov, 0))
        return enif_make_badarg(env);
    size = enif_ioq_size(q);
    if (!enif_ioq_deq(q, 3, &size))
        return enif_make_badarg(env);
    v = enif_ioq_peek(q, &n);
    for (i = 0; i < n; i++)
        total += v[i].iov_len;
    out = enif_make_new_binary(env, total, &all);
    for (i = 0, total = 0; i < n; i++) {
        memcpy(out + total, v[i].iov_base, v[i].iov_len);
        total += v[i].iov_len;
    }
    if (!enif_ioq_peek_head(env, q, &size, &first))
        return enif_make_badarg(env);
    size = enif_ioq_size(q);
    enif_ioq_destroy(q);
    return enif_make_tuple4(env, enif_make_uint64(env, size), enif_make_uint64(env, total), all, first);
}

/* sub(Bin, Pos, Size): enif_make_sub_binary. The bridge refuses a term
 * that is not a bitstring, and a range out of its whole bytes. */
static ERL_NIF_TERM sub(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    unsigned pos, size;
    if (!enif_get_uint(env, argv[1], &pos) || !enif_get_uint(env, argv[2], &size))
        return enif_make_badarg(env);
    return enif_make_sub_binary(env, argv[0], pos, size);
}

/* bad(Case, Arg): calls that ERTS checks only with ASSERT. The bridge
 * stops each one with an exception {wasm_trap, Message}, but the valid
 * cases (valid_*). An environment of enif_alloc_env stays after a trap. */
static ERL_NIF_TERM bad(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char name[32];
    ErlNifEnv *o;
    ERL_NIF_TERM t, x, nil = enif_make_list(env, 0);
    ErlNifPid pid;
    ErlNifPort port;
    ErlNifMapIterator it;
    counter *c;
    if (!enif_get_atom(env, argv[0], name, sizeof(name), ERL_NIF_LATIN1))
        return enif_make_badarg(env);
    /* A term of an other environment in a new term, in a result, or in
     * a message of an other environment. */
    if (!strcmp(name, "env_tuple")) {
        o = enif_alloc_env();
        return enif_make_tuple1(env, enif_make_copy(o, argv[1]));
    }
    if (!strcmp(name, "env_list")) {
        o = enif_alloc_env();
        return enif_make_list_cell(env, enif_make_copy(o, argv[1]), nil);
    }
    if (!strcmp(name, "env_map")) {
        o = enif_alloc_env();
        t = enif_make_copy(o, argv[1]);
        if (!enif_make_map_put(env, enif_make_new_map(env), atom_ok, t, &x))
            return atom_error;
        return x;
    }
    if (!strcmp(name, "env_sub")) {
        o = enif_alloc_env();
        return enif_make_sub_binary(env, enif_make_copy(o, argv[1]), 0, 1);
    }
    if (!strcmp(name, "env_result")) {
        o = enif_alloc_env();
        return enif_make_copy(o, argv[1]);
    }
    if (!strcmp(name, "env_send")) {
        o = enif_alloc_env();
        enif_self(env, &pid);
        return enif_send(env, &pid, o, argv[1]) ? atom_ok : atom_error;
    }
    if (!strcmp(name, "valid_env")) {
        o = enif_alloc_env();
        t = enif_make_copy(env, enif_make_tuple1(o, enif_make_copy(o, argv[1])));
        enif_free_env(o);
        return t;
    }
    /* The result of an exception: in a new term it is the same result
     * (the call raises badarg); else it is no term. */
    if (!strcmp(name, "valid_exception"))
        return enif_make_tuple2(env, atom_ok, enif_make_badarg(env));
    if (!strcmp(name, "exception_type"))
        return enif_make_int(env, (int)enif_term_type(env, enif_make_badarg(env)));
    if (!strcmp(name, "exception_copy"))
        return enif_make_copy(env, enif_make_badarg(env));
    if (!strcmp(name, "exception_format")) {
        char buf[64];
        enif_snprintf(buf, sizeof(buf), "%T", enif_make_badarg(env));
        return enif_make_string(env, buf, ERL_NIF_LATIN1);
    }
    if (!strcmp(name, "exception_send")) {
        enif_self(env, &pid);
        return enif_send(env, &pid, NULL, enif_make_badarg(env)) ? atom_ok : atom_error;
    }
    /* An ErlNifPid or an ErlNifPort with an other term. */
    if (!strcmp(name, "pid")) {
        pid.pid = argv[1];
        return enif_send(env, &pid, NULL, atom_ok) ? atom_ok : atom_error;
    }
    if (!strcmp(name, "port")) {
        port.port_id = argv[1];
        return enif_is_port_alive(env, &port) ? atom_true : atom_false;
    }
    if (!strcmp(name, "monitor_pid")) {
        void *w = enif_alloc_resource(watcher_type, sizeof(watcher));
        pid.pid = argv[1];
        return enif_make_int(env, enif_monitor_process(env, w, &pid, NULL));
    }
    /* A resource with no reference: two releases, and a keep or a term
     * after the last release. A release of a resource of a term, which
     * the module does not keep. */
    if (!strcmp(name, "release_twice")) {
        c = enif_alloc_resource(counter_type, sizeof(counter));
        t = enif_make_resource(env, c);
        enif_release_resource(c);
        enif_release_resource(c);
        return t;
    }
    if (!strcmp(name, "keep_released")) {
        c = enif_alloc_resource(counter_type, sizeof(counter));
        enif_release_resource(c);
        enif_keep_resource(c);
        return atom_ok;
    }
    if (!strcmp(name, "term_released")) {
        c = enif_alloc_resource(counter_type, sizeof(counter));
        enif_release_resource(c);
        return enif_make_resource(env, c);
    }
    if (!strcmp(name, "release_of_term")) {
        if (!enif_get_resource(env, argv[1], counter_type, (void **)&c))
            return enif_make_badarg(env);
        enif_release_resource(c);
        return atom_ok;
    }
    if (!strcmp(name, "valid_keep")) {
        if (!enif_get_resource(env, argv[1], counter_type, (void **)&c))
            return enif_make_badarg(env);
        enif_keep_resource(c);
        t = enif_make_resource(env, c);
        enif_release_resource(c);
        return enif_make_tuple2(env, atom_ok, t);
    }
    /* The functions of a process, with an environment of no process. */
    if (!strcmp(name, "alive")) {
        o = enif_alloc_env();
        return enif_is_current_process_alive(o) ? atom_true : atom_false;
    }
    if (!strcmp(name, "timeslice")) {
        o = enif_alloc_env();
        return enif_consume_timeslice(o, 10) ? atom_true : atom_false;
    }
    if (!strcmp(name, "schedule")) {
        o = enif_alloc_env();
        return enif_schedule_nif(o, "sum_step", 0, sum_step, 0, NULL);
    }
    /* A map iterator after the end of the environment of its map. */
    if (!strcmp(name, "iter_clear")) {
        o = enif_alloc_env();
        if (!enif_map_iterator_create(o, enif_make_copy(o, argv[1]), &it, ERL_NIF_MAP_ITERATOR_FIRST))
            return enif_make_badarg(env);
        enif_clear_env(o);
        return enif_map_iterator_is_tail(env, &it) ? atom_true : atom_false;
    }
    if (!strcmp(name, "iter_free")) {
        o = enif_alloc_env();
        if (!enif_map_iterator_create(o, enif_make_copy(o, argv[1]), &it, ERL_NIF_MAP_ITERATOR_FIRST))
            return enif_make_badarg(env);
        enif_free_env(o);
        return enif_map_iterator_next(env, &it) ? atom_true : atom_false;
    }
    /* A scheduled function of an other type. */
    if (!strcmp(name, "schedule_type"))
        return enif_schedule_nif(env, "schedule_type", 0, AS_NIF(bad_dtor), 0, NULL);
    return enif_make_badarg(env);
}

/* iter_keep(Map) keeps an iterator of its argument, and iter_use() uses
 * it: the map of the call is gone. */
static ErlNifMapIterator kept;

static ERL_NIF_TERM iter_keep(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    if (!enif_map_iterator_create(env, argv[0], &kept, ERL_NIF_MAP_ITERATOR_FIRST))
        return enif_make_badarg(env);
    return atom_ok;
}

static ERL_NIF_TERM iter_use(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM k, v;
    if (!enif_map_iterator_get_pair(env, &kept, &k, &v))
        return atom_error;
    return enif_make_tuple2(env, k, v);
}

/* NIFs of other types: four results (c_src/nif_check_mv.c), four
 * parameters, an i64. A call of four results writes past the arguments
 * of the call. */
extern void (*const nif_check_four_results)(void);

static ERL_NIF_TERM four_params(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[], int extra)
{
    return atom_ok;
}

static long long i64_nif(long long x)
{
    return x;
}

/* A resource of the type with a destructor of an other type. */
static ERL_NIF_TERM bad_dtor_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    void *r = enif_alloc_resource(bad_dtor_type, 8);
    ERL_NIF_TERM t = enif_make_resource(env, r);
    enif_release_resource(r);
    return t;
}

static ERL_NIF_TERM bad_dtor_count(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    return enif_make_int(env, bad_dtors);
}

/* enif_port_command(Port, Data) on a dirty scheduler. */
static ERL_NIF_TERM dirty_port_command(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifPort port;
    if (!enif_get_local_port(env, argv[0], &port))
        return enif_make_badarg(env);
    return enif_make_int(env, enif_port_command(env, &port, NULL, argv[1]));
}

static ErlNifFunc funcs[] = {
    { "add", 2, add, 0 },
    { "echo", 1, echo, 0 },
    { "is_ok", 1, is_ok, 0 },
    { "swap", 1, swap, 0 },
    { "reverse", 1, reverse, 0 },
    { "upcase", 1, upcase, 0 },
    { "concat", 2, concat, 0 },
    { "iolist", 1, iolist, 0 },
    { "map_put", 3, map_put, 0 },
    { "map_value", 2, map_value, 0 },
    { "map_keys", 1, map_keys, 0 },
    { "charlist", 1, charlist, 0 },
    { "mul", 2, mul, 0 },
    { "counter_new", 0, counter_new, 0 },
    { "counter_add", 2, counter_add, 0 },
    { "dtor_count", 0, dtor_count, 0 },
    { "send_self", 1, send_self, 0 },
    { "self_pid", 0, self_pid, 0 },
    { "raise", 1, raise, 0 },
    { "t2b", 1, t2b, 0 },
    { "sum", 1, sum, 0 },
    { "dirty_sum", 1, dirty_sum, ERL_NIF_DIRTY_JOB_CPU_BOUND },
    { "crash", 0, crash, 0 },
    { "loads", 0, loads, 0 },
    { "compare", 2, compare, 0 },
    { "types", 1, types, 0 },
    { "big", 0, big, 0 },
    { "unsupported", 0, unsupported, 0 },
    { "watch", 1, watch, 0 },
    { "unwatch", 1, unwatch, 0 },
    { "fmt", 1, fmt, 0 },
    { "ioq", 1, ioq, 0 },
    { "sub", 3, sub, 0 },
    { "bad", 2, bad, 0 },
    { "iter_keep", 1, iter_keep, 0 },
    { "iter_use", 0, iter_use, 0 },
    { "four_results", 0, NULL, 0 }, /* see set_four_results() */
    { "four_params", 0, AS_NIF(four_params), 0 },
    { "i64_nif", 0, AS_NIF(i64_nif), 0 },
    { "bad_dtor_new", 0, bad_dtor_new, 0 },
    { "bad_dtor_count", 0, bad_dtor_count, 0 },
    { "dirty_port_command", 2, dirty_port_command, ERL_NIF_DIRTY_JOB_CPU_BOUND },
};

/* The function of four_results is a value of nif_check_mv.c: the table
 * gets it before nif_init (a constructor runs in _initialize). */
__attribute__((constructor)) static void set_four_results(void)
{
    size_t i;
    for (i = 0; i < sizeof(funcs) / sizeof(funcs[0]); i++)
        if (!strcmp(funcs[i].name, "four_results"))
            funcs[i].fptr = AS_NIF(nif_check_four_results);
}

ERL_NIF_INIT(nif_check, funcs, load, NULL, NULL, NULL)
