/*
 * The test NIF of the NIF libraries in WebAssembly (docs/NIFS.md). It
 * uses the common enif_* functions, so that a test can compare its
 * results with Erlang. build.sh makes priv/nif_check.wasm and the AOT
 * files from this file.
 */
#include <string.h>
#include "erl_nif.h"

static ERL_NIF_TERM atom_ok, atom_error, atom_true, atom_false;
static ErlNifResourceType *counter_type;
static int dtors;

typedef struct {
    long long value;
} counter;

static void counter_dtor(ErlNifEnv *env, void *obj)
{
    (void)env;
    (void)obj;
    dtors++;
}

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

/* beam.com does not give enif_snprintf: the call raises an exception. */
static ERL_NIF_TERM unsupported(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char buf[16];
    enif_snprintf(buf, sizeof(buf), "%d", 1);
    return enif_make_atom(env, buf);
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
};

ERL_NIF_INIT(nif_check, funcs, load, NULL, NULL, NULL)
