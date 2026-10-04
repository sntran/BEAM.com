/*
 * NIF libraries in WebAssembly in the WebAssembly runtime of --target
 * wasm32 (ERTS built with Emscripten). The engine of the host (V8)
 * compiles and runs the module, not WAMR: this file gives the functions
 * of WAMR that c_src/wasm/nif_wasm.c calls, on the host functions of
 * nif_wasm_host.js. The code of the module runs at the speed of the
 * engine, and beam.wasm has no interpreter.
 *
 * The rules of this file:
 *
 * - The module has its own linear memory. nif_wasm.c reads and writes
 *   it through windows: a window is a copy of a range in the memory of
 *   ERTS. Before each call into the module, and at the end of each
 *   enif_* function, the windows go back into the memory of the module
 *   in the order that they were made (host_flush()). Their copies stay
 *   allocated until the end of the call into the library
 *   (host_release()), so an old address is never freed memory.
 * - A call into the module (host_call()) runs on its own JSPI stack
 *   (WebAssembly.promising in nif_wasm_host.js): a trap stops only that
 *   call. When the call does not wait, it ends before the host function
 *   returns. When it waits (ERTS suspends the thread in an enif_*
 *   function), this thread waits for its end with nif_host_wait().
 * - The module imports each enif_* function as an export of ERTS
 *   (nifx_* in nif_wasm.c), so nothing of JavaScript is between them.
 *   host_enter() finds the execution environment of the call in a key
 *   of the thread.
 * - A failure of an enif_* function (wasm_runtime_set_exception()) stops
 *   the module at the end of that function (host_leave()), as in WAMR.
 */
#include <emscripten.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nif_wasm_host.h"

/* nif_wasm_host.js */
int nif_host_compile(const uint8_t *bytes, uint32_t n, const char *file, int debug, char *error,
                     uint32_t size);
int nif_host_instantiate(int lib, char *error, uint32_t size);
void nif_host_free(int lib);
int nif_host_has_export(int lib, const char *name);
uint32_t nif_host_export(int lib, const char *name, int32_t *types);
uint32_t nif_host_element(int lib, uint32_t index, int32_t *types);
int nif_host_read(int lib, uint32_t off, void *dst, uint32_t n);
int nif_host_write(int lib, uint32_t off, const void *src, uint32_t n);
int32_t nif_host_strlen(int lib, uint32_t off);
int nif_host_call(void *call);
int nif_host_wait(int id);
void nif_host_throw(void);
/* jspi_pthread.c: the state of the thread around a wait of the host. */
void *jspi_save(uintptr_t *sp);
void jspi_restore(void *self, uintptr_t sp);

typedef struct win {
    uint32_t off, n;
    uint8_t *buf;
    struct win *next;
} win_t;

typedef struct func {
    uint32_t slot;              /* index into the table of ERTS */
    int32_t np, nr;             /* parameters and results, or -1 */
    char *name;
    struct func *next;
} func_t;

struct WASMModuleCommon {
    int lib;
};

struct WASMModuleInstanceCommon {
    int lib;
    int has_exception;
    char exception[256];
    win_t *live, *live_tail, *retired;
    func_t *funcs;
    func_t *malloc_fn, *free_fn;
};

struct WASMExecEnv {
    wasm_module_inst_t inst;
    void *user_data;
};

/* The call of nif_host_tramp(): nif_host_call() reads done. */
typedef struct {
    uint32_t slot;
    int32_t np, nr;
    uint32_t done;
    uint32_t result;
    uint32_t a[4];
    char error[256];
} hcall_t;

static const char *next_file = "";
static int debug;
static pthread_key_t exec_key;

void host_set_file(const char *file)
{
    next_file = file;
}

/* --- the runtime --- */

bool wasm_runtime_full_init(RuntimeInitArgs *args)
{
    (void)args;
    debug = getenv("BEAM_COM_NIF_DEBUG") != NULL;
    return pthread_key_create(&exec_key, NULL) == 0;
}

void wasm_runtime_set_log_level(log_level_t level)
{
    (void)level;
}

/* nif_wasm_host.js gives the module the exports nifx_* of ERTS. */
bool wasm_runtime_register_natives(const char *module, NativeSymbol *natives, uint32_t n)
{
    (void)module;
    (void)natives;
    (void)n;
    return true;
}

bool wasm_runtime_init_thread_env(void)
{
    return true;
}

void wasm_exec_env_set_thread_info(wasm_exec_env_t exec_env)
{
    (void)exec_env;
}

/* --- modules and instances --- */

wasm_module_t wasm_runtime_load(uint8_t *buf, uint32_t size, char *error, uint32_t error_size)
{
    struct WASMModuleCommon *m;
    int lib = nif_host_compile(buf, size, next_file, debug, error, error_size);
    if (!lib)
        return NULL;
    if (!(m = calloc(1, sizeof(*m)))) {
        nif_host_free(lib);
        snprintf(error, error_size, "no memory");
        return NULL;
    }
    m->lib = lib;
    return m;
}

void wasm_runtime_unload(wasm_module_t m)
{
    if (m) {
        nif_host_free(m->lib);
        free(m);
    }
}

int host_has_export(wasm_module_t m, const char *name)
{
    return nif_host_has_export(m->lib, name);
}

wasm_module_inst_t wasm_runtime_instantiate(const wasm_module_t m, uint32_t stack, uint32_t heap,
                                            char *error, uint32_t error_size)
{
    struct WASMModuleInstanceCommon *inst;
    (void)stack;
    (void)heap;
    if (!nif_host_instantiate(m->lib, error, error_size))
        return NULL;
    if (!(inst = calloc(1, sizeof(*inst)))) {
        snprintf(error, error_size, "no memory");
        return NULL;
    }
    inst->lib = m->lib;
    return inst;
}

static void free_windows(win_t *w)
{
    while (w) {
        win_t *next = w->next;
        free(w->buf);
        free(w);
        w = next;
    }
}

void wasm_runtime_deinstantiate(wasm_module_inst_t inst)
{
    func_t *f, *next;
    if (!inst)
        return;
    free_windows(inst->live);
    free_windows(inst->retired);
    for (f = inst->funcs; f; f = next) {
        next = f->next;
        free(f->name);
        free(f);
    }
    free(inst);
}

wasm_exec_env_t wasm_runtime_create_exec_env(wasm_module_inst_t inst, uint32_t stack)
{
    struct WASMExecEnv *x = calloc(1, sizeof(*x));
    (void)stack;
    if (x)
        x->inst = inst;
    return x;
}

void wasm_runtime_destroy_exec_env(wasm_exec_env_t x)
{
    free(x);
}

wasm_module_inst_t wasm_runtime_get_module_inst(wasm_exec_env_t x)
{
    return x ? x->inst : NULL;
}

void wasm_runtime_set_user_data(wasm_exec_env_t x, void *data)
{
    x->user_data = data;
}

void *wasm_runtime_get_user_data(wasm_exec_env_t x)
{
    return x ? x->user_data : NULL;
}

/* --- exceptions --- */

void wasm_runtime_set_exception(wasm_module_inst_t inst, const char *msg)
{
    if (!inst)
        return;
    if (!msg) {
        inst->has_exception = 0;
        return;
    }
    snprintf(inst->exception, sizeof(inst->exception), "Exception: %s", msg);
    inst->has_exception = 1;
}

const char *wasm_runtime_get_exception(wasm_module_inst_t inst)
{
    return inst && inst->has_exception ? inst->exception : NULL;
}

void wasm_runtime_clear_exception(wasm_module_inst_t inst)
{
    if (inst)
        inst->has_exception = 0;
}

/* --- the memory of the module --- */

/* Put the windows back into the memory of the module, in the order that
 * they were made (a later window wins). */
static void host_flush(wasm_module_inst_t inst)
{
    win_t *w;
    for (w = inst->live; w; w = w->next)
        nif_host_write(inst->lib, w->off, w->buf, w->n);
    if (inst->live) {
        inst->live_tail->next = inst->retired;
        inst->retired = inst->live;
        inst->live = inst->live_tail = NULL;
    }
}

void *host_window(wasm_module_inst_t inst, uint32_t off, uint32_t n)
{
    win_t *w;
    if ((uint64_t)off + n > UINT32_MAX) {
        wasm_runtime_set_exception(inst, "out of bounds memory access");
        return NULL;
    }
    /* A window on the same bytes goes back first, so this copy has its
     * changes. */
    for (w = inst->live; w; w = w->next)
        if (off < w->off + w->n && w->off < off + n)
            nif_host_write(inst->lib, w->off, w->buf, w->n);
    if (!(w = calloc(1, sizeof(*w))) || !(w->buf = malloc(n ? n : 1))) {
        free(w);
        wasm_runtime_set_exception(inst, "no memory");
        return NULL;
    }
    if (!nif_host_read(inst->lib, off, w->buf, n)) {
        free(w->buf);
        free(w);
        wasm_runtime_set_exception(inst, "out of bounds memory access");
        return NULL;
    }
    w->off = off;
    w->n = n;
    if (inst->live_tail)
        inst->live_tail->next = w;
    else
        inst->live = w;
    inst->live_tail = w;
    return w->buf;
}

const char *host_string(wasm_module_inst_t inst, uint32_t off)
{
    int32_t n = nif_host_strlen(inst->lib, off);
    if (n < 0) {
        wasm_runtime_set_exception(inst, "out of bounds memory access");
        return NULL;
    }
    return host_window(inst, off, (uint32_t)n + 1);
}

void host_release(wasm_module_inst_t inst)
{
    if (!inst)
        return;
    host_flush(inst);
    free_windows(inst->retired);
    inst->retired = NULL;
}

/* --- calls into the module --- */

EMSCRIPTEN_KEEPALIVE void nif_host_tramp(hcall_t *h)
{
    typedef uint32_t U;
    void *f = (void *)(uintptr_t)h->slot;
    U *a = h->a;
    switch (h->np * 2 + (h->nr > 0)) {
    case 0: ((void (*)(void))f)(); break;
    case 1: h->result = ((U (*)(void))f)(); break;
    case 2: ((void (*)(U))f)(a[0]); break;
    case 3: h->result = ((U (*)(U))f)(a[0]); break;
    case 4: ((void (*)(U, U))f)(a[0], a[1]); break;
    case 5: h->result = ((U (*)(U, U))f)(a[0], a[1]); break;
    case 6: ((void (*)(U, U, U))f)(a[0], a[1], a[2]); break;
    case 7: h->result = ((U (*)(U, U, U))f)(a[0], a[1], a[2]); break;
    case 8: ((void (*)(U, U, U, U))f)(a[0], a[1], a[2], a[3]); break;
    case 9: h->result = ((U (*)(U, U, U, U))f)(a[0], a[1], a[2], a[3]); break;
    }
    h->done = 1;
}

/* Call the function in the table slot SLOT with ARGC arguments of 32
 * bits. NP and NR: the type of the function (-1: not known). */
static bool host_call(wasm_exec_env_t x, uint32_t slot, int32_t np, int32_t nr, uint32_t argc,
                      uint32_t *argv)
{
    wasm_module_inst_t inst = x->inst;
    hcall_t h;
    void *prev, *self;
    uintptr_t sp;
    int id, ok = 1;

    if (!slot) {
        wasm_runtime_set_exception(inst, "uninitialized element");
        return false;
    }
    if (np < 0) {
        /* Not known (a table changed at run time): the callbacks of a NIF
         * library with 3 arguments (a NIF, load) have a result. */
        np = (int32_t)argc;
        nr = argc == 3;
    }
    if ((uint32_t)np != argc || np > 4 || nr > 1) {
        wasm_runtime_set_exception(inst, "indirect call type mismatch");
        return false;
    }
    memset(&h, 0, sizeof(h));
    h.slot = slot;
    h.np = np;
    h.nr = nr;
    if (argc)
        memcpy(h.a, argv, 4 * argc);
    host_flush(inst);
    prev = pthread_getspecific(exec_key);
    pthread_setspecific(exec_key, x);
    id = nif_host_call(&h);
    if (id) {
        self = jspi_save(&sp);
        ok = nif_host_wait(id);
        jspi_restore(self, sp);
    }
    pthread_setspecific(exec_key, prev);
    if (!ok || !h.done) {
        if (!inst->has_exception)
            wasm_runtime_set_exception(inst, h.error[0] ? h.error : "trap");
        return false;
    }
    if (inst->has_exception)
        return false;
    if (nr)
        argv[0] = h.result;
    return true;
}

static func_t *find_func(wasm_module_inst_t inst, const char *name)
{
    func_t *f;
    int32_t types[2];
    uint32_t slot;
    for (f = inst->funcs; f; f = f->next)
        if (!strcmp(f->name, name))
            return f;
    if (!(slot = nif_host_export(inst->lib, name, types)))
        return NULL;
    if (!(f = calloc(1, sizeof(*f))) || !(f->name = strdup(name))) {
        free(f);
        return NULL;
    }
    f->slot = slot;
    f->np = types[0];
    f->nr = types[1];
    f->next = inst->funcs;
    inst->funcs = f;
    return f;
}

wasm_function_inst_t wasm_runtime_lookup_function(const wasm_module_inst_t inst, const char *name)
{
    return find_func(inst, name);
}

bool wasm_runtime_call_wasm(wasm_exec_env_t x, wasm_function_inst_t function, uint32_t argc,
                            uint32_t argv[])
{
    func_t *f = function;
    return host_call(x, f->slot, f->np, f->nr, argc, argv);
}

bool wasm_runtime_call_indirect(wasm_exec_env_t x, uint32_t index, uint32_t argc, uint32_t argv[])
{
    int32_t types[2];
    uint32_t slot = nif_host_element(x->inst->lib, index, types);
    return host_call(x, slot, types[0], types[1], argc, argv);
}

/* A module without erl_nif_wasm_malloc: its malloc and free. */
uint64_t wasm_runtime_module_malloc(wasm_module_inst_t inst, uint64_t size, void **native)
{
    struct WASMExecEnv x = { inst, NULL };
    uint32_t a[1];
    (void)native;
    if (!inst->malloc_fn && !(inst->malloc_fn = find_func(inst, "malloc")))
        return 0;
    a[0] = (uint32_t)size;
    if (!host_call(&x, inst->malloc_fn->slot, inst->malloc_fn->np, inst->malloc_fn->nr, 1, a))
        return 0;
    return a[0];
}

void wasm_runtime_module_free(wasm_module_inst_t inst, uint64_t ptr)
{
    struct WASMExecEnv x = { inst, NULL };
    uint32_t a[1];
    if (!inst->free_fn && !(inst->free_fn = find_func(inst, "free")))
        return;
    a[0] = (uint32_t)ptr;
    host_call(&x, inst->free_fn->slot, inst->free_fn->np, inst->free_fn->nr, 1, a);
}

/* --- enif_* functions --- */

wasm_exec_env_t host_enter(void)
{
    return pthread_getspecific(exec_key);
}

void host_leave(wasm_exec_env_t x)
{
    if (!x)
        return;
    host_flush(x->inst);
    if (x->inst->has_exception)
        nif_host_throw();
}
