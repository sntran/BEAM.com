/*
 * The wasm NIF: WebAssembly (and WASI preview 1) for Erlang, with the
 * WAMR interpreter.
 *
 * The Erlang API (src/wasm/wasm.erl) does not show WAMR types, so
 * that the runtime can change later.
 *
 * Modules and instances are resources. An instance is not thread safe:
 * a mutex serializes the calls into it. The calls run on dirty CPU
 * schedulers.
 */
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>

#include "erl_nif.h"
#include "wasm_export.h"

#define ERROR_BUF_SIZE 256
#define DEFAULT_STACK_SIZE (64 * 1024)
#define DEFAULT_HEAP_SIZE 0
#define MAX_VALUES 64

typedef struct {
    wasm_module_t module;
    uint8_t *buf;           /* WAMR keeps pointers into the buffer. */
    ErlNifMutex *lock;      /* For the WASI arguments of the module. */
} module_res;

typedef struct {
    module_res *module;     /* Kept alive while the instance lives. */
    wasm_module_inst_t inst;
    uint32_t stack_size;
    ErlNifMutex *lock;
} instance_res;

static ErlNifResourceType *module_type;
static ErlNifResourceType *instance_type;

static ERL_NIF_TERM am_ok, am_error, am_exit, am_trap, am_i32, am_i64,
    am_f32, am_f64, am_stack_size, am_heap_size, am_args, am_env, am_preopens,
    am_not_found, am_badarg, am_no_memory, am_out_of_bounds, am_nan,
    am_infinity, am_neg_infinity;

static void module_dtor(ErlNifEnv *env, void *obj)
{
    module_res *m = obj;
    (void)env;
    if (m->module)
        wasm_runtime_unload(m->module);
    if (m->buf)
        enif_free(m->buf);
    if (m->lock)
        enif_mutex_destroy(m->lock);
}

static void instance_dtor(ErlNifEnv *env, void *obj)
{
    instance_res *i = obj;
    (void)env;
    if (i->inst)
        wasm_runtime_deinstantiate(i->inst);
    if (i->lock)
        enif_mutex_destroy(i->lock);
    if (i->module)
        enif_release_resource(i->module);
}

static int on_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
    RuntimeInitArgs args;
    (void)priv;
    (void)info;

    module_type = enif_open_resource_type(env, NULL, "wasm_module",
                                          module_dtor, ERL_NIF_RT_CREATE,
                                          NULL);
    instance_type = enif_open_resource_type(env, NULL, "wasm_instance",
                                            instance_dtor, ERL_NIF_RT_CREATE,
                                            NULL);
    if (!module_type || !instance_type)
        return 1;

    memset(&args, 0, sizeof(args));
    args.mem_alloc_type = Alloc_With_System_Allocator;
    if (!wasm_runtime_full_init(&args))
        return 1;
    /* WAMR writes warnings (for example a missing import) to stdout. */
    wasm_runtime_set_log_level(WASM_LOG_LEVEL_ERROR);

    am_ok = enif_make_atom(env, "ok");
    am_error = enif_make_atom(env, "error");
    am_exit = enif_make_atom(env, "exit");
    am_trap = enif_make_atom(env, "trap");
    am_i32 = enif_make_atom(env, "i32");
    am_i64 = enif_make_atom(env, "i64");
    am_f32 = enif_make_atom(env, "f32");
    am_f64 = enif_make_atom(env, "f64");
    am_stack_size = enif_make_atom(env, "stack_size");
    am_heap_size = enif_make_atom(env, "heap_size");
    am_args = enif_make_atom(env, "args");
    am_env = enif_make_atom(env, "env");
    am_preopens = enif_make_atom(env, "preopens");
    am_not_found = enif_make_atom(env, "not_found");
    am_badarg = enif_make_atom(env, "badarg");
    am_no_memory = enif_make_atom(env, "no_memory");
    am_out_of_bounds = enif_make_atom(env, "out_of_bounds");
    am_nan = enif_make_atom(env, "nan");
    am_infinity = enif_make_atom(env, "infinity");
    am_neg_infinity = enif_make_atom(env, "-infinity");
    return 0;
}

static ERL_NIF_TERM error_string(ErlNifEnv *env, const char *msg)
{
    ERL_NIF_TERM bin;
    size_t n = strlen(msg);
    memcpy(enif_make_new_binary(env, n, &bin), msg, n);
    return enif_make_tuple2(env, am_error, bin);
}

/* WAMR needs its thread environment on each thread that runs code. */
static void ensure_thread_env(void)
{
    if (!wasm_runtime_thread_env_inited())
        wasm_runtime_init_thread_env();
}

/* compile(Binary) -> {ok, Module} | {error, Message} */
static ERL_NIF_TERM nif_compile(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[])
{
    ErlNifBinary bin;
    module_res *m;
    char error[ERROR_BUF_SIZE];
    ERL_NIF_TERM term;
    (void)argc;

    if (!enif_inspect_binary(env, argv[0], &bin) || bin.size > UINT32_MAX)
        return enif_make_badarg(env);
    ensure_thread_env();

    m = enif_alloc_resource(module_type, sizeof(*m));
    memset(m, 0, sizeof(*m));
    m->buf = enif_alloc(bin.size ? bin.size : 1);
    m->lock = enif_mutex_create("wasm_module");
    if (!m->buf || !m->lock) {
        enif_release_resource(m);
        return enif_make_tuple2(env, am_error, am_no_memory);
    }
    memcpy(m->buf, bin.data, bin.size);
    m->module = wasm_runtime_load(m->buf, (uint32_t)bin.size, error,
                                  sizeof(error));
    if (!m->module) {
        enif_release_resource(m);
        return error_string(env, error);
    }
    term = enif_make_resource(env, m);
    enif_release_resource(m);
    return enif_make_tuple2(env, am_ok, term);
}

/* A list of iodata as NUL-terminated C strings. */
static char **string_list(ErlNifEnv *env, ERL_NIF_TERM list, unsigned *count)
{
    unsigned n, i = 0;
    ERL_NIF_TERM head;
    char **v;

    if (!enif_get_list_length(env, list, &n))
        return NULL;
    v = enif_alloc((n + 1) * sizeof(char *));
    if (!v)
        return NULL;
    memset(v, 0, (n + 1) * sizeof(char *));
    while (enif_get_list_cell(env, list, &head, &list)) {
        ErlNifBinary b;
        if (!enif_inspect_iolist_as_binary(env, head, &b))
            goto fail;
        v[i] = enif_alloc(b.size + 1);
        if (!v[i])
            goto fail;
        memcpy(v[i], b.data, b.size);
        v[i][b.size] = '\0';
        i++;
    }
    *count = n;
    return v;
fail:
    for (i = 0; i < n; i++)
        if (v[i])
            enif_free(v[i]);
    enif_free(v);
    return NULL;
}

static void free_list(char **v, unsigned n)
{
    unsigned i;
    if (!v)
        return;
    for (i = 0; i < n; i++)
        enif_free(v[i]);
    enif_free(v);
}

static int get_uint_opt(ErlNifEnv *env, ERL_NIF_TERM map, ERL_NIF_TERM key,
                        unsigned dflt, unsigned *out)
{
    ERL_NIF_TERM v;
    if (!enif_get_map_value(env, map, key, &v)) {
        *out = dflt;
        return 1;
    }
    return enif_get_uint(env, v, out);
}

static int get_list_opt(ErlNifEnv *env, ERL_NIF_TERM map, ERL_NIF_TERM key,
                        char ***out, unsigned *n)
{
    ERL_NIF_TERM v;
    *n = 0;
    if (!enif_get_map_value(env, map, key, &v))
        v = enif_make_list(env, 0);
    *out = string_list(env, v, n);
    return *out != NULL;
}

/*
 * instantiate(Module, Opts) -> {ok, Instance} | {error, Message}
 *   Opts: #{stack_size, heap_size, args => [iodata()],
 *           env => [iodata()] ("NAME=VALUE"),
 *           preopens => [iodata()] ("GUEST::HOST", preopened directories)}
 */
static ERL_NIF_TERM nif_instantiate(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[])
{
    module_res *m;
    instance_res *i;
    unsigned stack_size, heap_size, nargs = 0, nenv = 0, ndirs = 0;
    char **args = NULL, **envs = NULL, **dirs = NULL;
    char error[ERROR_BUF_SIZE] = "";
    ERL_NIF_TERM result;
    (void)argc;

    if (!enif_get_resource(env, argv[0], module_type, (void **)&m)
        || !enif_is_map(env, argv[1])
        || !get_uint_opt(env, argv[1], am_stack_size, DEFAULT_STACK_SIZE,
                         &stack_size)
        || !get_uint_opt(env, argv[1], am_heap_size, DEFAULT_HEAP_SIZE,
                         &heap_size)
        || !get_list_opt(env, argv[1], am_args, &args, &nargs)
        || !get_list_opt(env, argv[1], am_env, &envs, &nenv)
        || !get_list_opt(env, argv[1], am_preopens, &dirs, &ndirs)) {
        free_list(args, nargs);
        free_list(envs, nenv);
        free_list(dirs, ndirs);
        return enif_make_badarg(env);
    }
    ensure_thread_env();

    i = enif_alloc_resource(instance_type, sizeof(*i));
    memset(i, 0, sizeof(*i));
    i->lock = enif_mutex_create("wasm_instance");

    /* The WASI arguments are set on the module, and copied into the
     * instance when it is made. */
    enif_mutex_lock(m->lock);
    wasm_runtime_set_wasi_args(m->module, NULL, 0, (const char **)dirs,
                               ndirs, (const char **)envs, nenv, args,
                               (int)nargs);
    i->inst = wasm_runtime_instantiate(m->module, stack_size, heap_size,
                                       error, sizeof(error));
    wasm_runtime_set_wasi_args(m->module, NULL, 0, NULL, 0, NULL, 0, NULL, 0);
    enif_mutex_unlock(m->lock);
    free_list(args, nargs);
    free_list(envs, nenv);
    free_list(dirs, ndirs);

    if (!i->inst) {
        enif_release_resource(i);
        return error_string(env, error);
    }
    i->stack_size = stack_size;
    if (!i->lock) {
        enif_release_resource(i);
        return enif_make_tuple2(env, am_error, am_no_memory);
    }
    enif_keep_resource(m);
    i->module = m;
    result = enif_make_resource(env, i);
    enif_release_resource(i);
    return enif_make_tuple2(env, am_ok, result);
}

static int get_value(ErlNifEnv *env, ERL_NIF_TERM term, wasm_valkind_t kind,
                     wasm_val_t *v)
{
    ErlNifSInt64 s;
    ErlNifUInt64 u;
    double d;

    v->kind = kind;
    switch (kind) {
    case WASM_I32:
        if (enif_get_int64(env, term, &s) && s >= INT32_MIN
            && s <= (ErlNifSInt64)UINT32_MAX) {
            v->of.i32 = (int32_t)(uint32_t)s;
            return 1;
        }
        return 0;
    case WASM_I64:
        if (enif_get_int64(env, term, &s)) {
            v->of.i64 = s;
            return 1;
        }
        if (enif_get_uint64(env, term, &u)) {
            v->of.i64 = (int64_t)u;
            return 1;
        }
        return 0;
    case WASM_F32:
    case WASM_F64:
        /* Erlang floats are finite: NaN and the infinities are atoms. */
        if (enif_get_double(env, term, &d))
            ;
        else if (enif_get_int64(env, term, &s))
            d = (double)s;
        else if (enif_is_identical(term, am_nan))
            d = NAN;
        else if (enif_is_identical(term, am_infinity))
            d = INFINITY;
        else if (enif_is_identical(term, am_neg_infinity))
            d = -INFINITY;
        else
            return 0;
        if (kind == WASM_F32)
            v->of.f32 = (float)d;
        else
            v->of.f64 = d;
        return 1;
    default:
        return 0;
    }
}

static ERL_NIF_TERM make_float(ErlNifEnv *env, double d)
{
    if (isnan(d))
        return am_nan;
    if (isinf(d))
        return d > 0 ? am_infinity : am_neg_infinity;
    return enif_make_double(env, d);
}

static ERL_NIF_TERM make_value(ErlNifEnv *env, const wasm_val_t *v)
{
    switch (v->kind) {
    case WASM_I32:
        return enif_make_int(env, v->of.i32);
    case WASM_I64:
        return enif_make_int64(env, v->of.i64);
    case WASM_F32:
        return make_float(env, (double)v->of.f32);
    case WASM_F64:
        return make_float(env, v->of.f64);
    default:
        return am_error;
    }
}

/*
 * The error of a call: {exit, Code} when the program called WASI
 * proc_exit, else {error, {trap, Message}}.
 */
static ERL_NIF_TERM call_error(ErlNifEnv *env, instance_res *i)
{
    const char *exc = wasm_runtime_get_exception(i->inst);
    ERL_NIF_TERM msg, result;
    size_t n;

    if (exc && strstr(exc, "wasi proc exit")) {
        result = enif_make_tuple2(
            env, am_exit,
            enif_make_uint(env, wasm_runtime_get_wasi_exit_code(i->inst)));
    } else {
        if (!exc)
            exc = "unknown error";
        n = strlen(exc);
        memcpy(enif_make_new_binary(env, n, &msg), exc, n);
        result = enif_make_tuple2(env, am_error,
                                  enif_make_tuple2(env, am_trap, msg));
    }
    wasm_runtime_clear_exception(i->inst);
    return result;
}

/* call_function(Instance, Name, Args) -> {ok, [Result]} | {exit, Code} | {error, _} */
static ERL_NIF_TERM nif_call(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[])
{
    instance_res *i;
    ErlNifBinary name_bin;
    char name[256];
    wasm_function_inst_t func;
    wasm_valkind_t ptypes[MAX_VALUES], rtypes[MAX_VALUES];
    wasm_val_t params[MAX_VALUES], results[MAX_VALUES];
    uint32_t np, nr, k;
    unsigned nargs;
    wasm_exec_env_t exec_env;
    bool ok;
    ERL_NIF_TERM head, tail, out;
    (void)argc;

    if (!enif_get_resource(env, argv[0], instance_type, (void **)&i)
        || !enif_inspect_iolist_as_binary(env, argv[1], &name_bin)
        || name_bin.size >= sizeof(name)
        || !enif_get_list_length(env, argv[2], &nargs))
        return enif_make_badarg(env);
    memcpy(name, name_bin.data, name_bin.size);
    name[name_bin.size] = '\0';
    ensure_thread_env();

    enif_mutex_lock(i->lock);
    func = wasm_runtime_lookup_function(i->inst, name);
    if (!func) {
        enif_mutex_unlock(i->lock);
        return enif_make_tuple2(env, am_error, am_not_found);
    }
    np = wasm_func_get_param_count(func, i->inst);
    nr = wasm_func_get_result_count(func, i->inst);
    if (np > MAX_VALUES || nr > MAX_VALUES || np != nargs) {
        enif_mutex_unlock(i->lock);
        return enif_make_tuple2(env, am_error, am_badarg);
    }
    wasm_func_get_param_types(func, i->inst, ptypes);
    wasm_func_get_result_types(func, i->inst, rtypes);
    tail = argv[2];
    for (k = 0; k < np; k++) {
        enif_get_list_cell(env, tail, &head, &tail);
        if (!get_value(env, head, ptypes[k], &params[k])) {
            enif_mutex_unlock(i->lock);
            return enif_make_tuple2(env, am_error, am_badarg);
        }
    }
    for (k = 0; k < nr; k++)
        results[k].kind = rtypes[k];

    /* The execution environment keeps the native stack bounds of the
     * thread that makes it, and the dirty schedulers are many threads. */
    exec_env = wasm_runtime_create_exec_env(i->inst, i->stack_size);
    if (!exec_env) {
        enif_mutex_unlock(i->lock);
        return enif_make_tuple2(env, am_error, am_no_memory);
    }
    ok = wasm_runtime_call_wasm_a(exec_env, func, nr, results, np, params);
    wasm_runtime_destroy_exec_env(exec_env);
    if (!ok) {
        out = call_error(env, i);
        enif_mutex_unlock(i->lock);
        return out;
    }
    enif_mutex_unlock(i->lock);

    out = enif_make_list(env, 0);
    for (k = nr; k > 0; k--)
        out = enif_make_list_cell(env, make_value(env, &results[k - 1]), out);
    return enif_make_tuple2(env, am_ok, out);
}

/* The default memory: base and size. Call with the lock. */
static int memory(instance_res *i, uint8_t **base, uint64_t *size)
{
    wasm_memory_inst_t mem = wasm_runtime_get_default_memory(i->inst);
    if (!mem)
        return 0;
    *base = wasm_memory_get_base_address(mem);
    *size = wasm_memory_get_cur_page_count(mem)
        * (uint64_t)wasm_memory_get_bytes_per_page(mem);
    return *base != NULL;
}

/* memory_size(Instance) -> {ok, Bytes} | {error, not_found} */
static ERL_NIF_TERM nif_memory_size(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[])
{
    instance_res *i;
    uint8_t *base;
    uint64_t size;
    int found;
    (void)argc;

    if (!enif_get_resource(env, argv[0], instance_type, (void **)&i))
        return enif_make_badarg(env);
    enif_mutex_lock(i->lock);
    found = memory(i, &base, &size);
    enif_mutex_unlock(i->lock);
    if (!found)
        return enif_make_tuple2(env, am_error, am_not_found);
    return enif_make_tuple2(env, am_ok, enif_make_uint64(env, size));
}

/* read_binary(Instance, Offset, Length) -> {ok, Binary} | {error, _} */
static ERL_NIF_TERM nif_read_binary(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[])
{
    instance_res *i;
    ErlNifUInt64 offset, len;
    uint8_t *base;
    uint64_t size;
    ERL_NIF_TERM bin;
    (void)argc;

    if (!enif_get_resource(env, argv[0], instance_type, (void **)&i)
        || !enif_get_uint64(env, argv[1], &offset)
        || !enif_get_uint64(env, argv[2], &len))
        return enif_make_badarg(env);
    enif_mutex_lock(i->lock);
    if (!memory(i, &base, &size)) {
        enif_mutex_unlock(i->lock);
        return enif_make_tuple2(env, am_error, am_not_found);
    }
    if (offset > size || len > size - offset) {
        enif_mutex_unlock(i->lock);
        return enif_make_tuple2(env, am_error, am_out_of_bounds);
    }
    memcpy(enif_make_new_binary(env, len, &bin), base + offset, len);
    enif_mutex_unlock(i->lock);
    return enif_make_tuple2(env, am_ok, bin);
}

/* write_binary(Instance, Offset, Data) -> ok | {error, _} */
static ERL_NIF_TERM nif_write_binary(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[])
{
    instance_res *i;
    ErlNifUInt64 offset;
    ErlNifBinary data;
    uint8_t *base;
    uint64_t size;
    (void)argc;

    if (!enif_get_resource(env, argv[0], instance_type, (void **)&i)
        || !enif_get_uint64(env, argv[1], &offset)
        || !enif_inspect_iolist_as_binary(env, argv[2], &data))
        return enif_make_badarg(env);
    enif_mutex_lock(i->lock);
    if (!memory(i, &base, &size)) {
        enif_mutex_unlock(i->lock);
        return enif_make_tuple2(env, am_error, am_not_found);
    }
    if (offset > size || data.size > size - offset) {
        enif_mutex_unlock(i->lock);
        return enif_make_tuple2(env, am_error, am_out_of_bounds);
    }
    memcpy(base + offset, data.data, data.size);
    enif_mutex_unlock(i->lock);
    return am_ok;
}

/* memory_grow(Instance, Pages) -> {ok, PreviousPages} | {error, _}, as
 * WebAssembly.Memory.grow() and the memory.grow instruction. */
static ERL_NIF_TERM nif_memory_grow(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[])
{
    instance_res *i;
    ErlNifUInt64 pages;
    wasm_memory_inst_t mem;
    uint64_t before;
    bool ok;
    (void)argc;

    if (!enif_get_resource(env, argv[0], instance_type, (void **)&i)
        || !enif_get_uint64(env, argv[1], &pages))
        return enif_make_badarg(env);
    enif_mutex_lock(i->lock);
    mem = wasm_runtime_get_default_memory(i->inst);
    if (!mem) {
        enif_mutex_unlock(i->lock);
        return enif_make_tuple2(env, am_error, am_not_found);
    }
    before = wasm_memory_get_cur_page_count(mem);
    ok = pages == 0 || wasm_runtime_enlarge_memory(i->inst, pages);
    enif_mutex_unlock(i->lock);
    if (!ok)
        return enif_make_tuple2(env, am_error, am_out_of_bounds);
    return enif_make_tuple2(env, am_ok, enif_make_uint64(env, before));
}

/* function_exists(Instance, Name) -> boolean() */
static ERL_NIF_TERM nif_function_exists(ErlNifEnv *env, int argc,
                                        const ERL_NIF_TERM argv[])
{
    instance_res *i;
    ErlNifBinary name_bin;
    char name[256];
    int found;
    (void)argc;

    if (!enif_get_resource(env, argv[0], instance_type, (void **)&i)
        || !enif_inspect_iolist_as_binary(env, argv[1], &name_bin))
        return enif_make_badarg(env);
    if (name_bin.size >= sizeof(name))
        return enif_make_atom(env, "false");
    memcpy(name, name_bin.data, name_bin.size);
    name[name_bin.size] = '\0';
    enif_mutex_lock(i->lock);
    found = wasm_runtime_lookup_function(i->inst, name) != NULL;
    enif_mutex_unlock(i->lock);
    return enif_make_atom(env, found ? "true" : "false");
}

static ErlNifFunc nif_funcs[] = {
    {"compile_nif", 1, nif_compile, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"instantiate_nif", 2, nif_instantiate, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"call_function_nif", 3, nif_call, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"function_exists_nif", 2, nif_function_exists, 0},
    {"memory_size", 1, nif_memory_size, 0},
    {"memory_grow", 2, nif_memory_grow, 0},
    {"read_binary", 3, nif_read_binary, 0},
    {"write_binary", 3, nif_write_binary, 0},
};

ERL_NIF_INIT(wasm, nif_funcs, on_load, NULL, NULL, NULL)
