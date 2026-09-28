/*
 * wasm_host: messages between Erlang and the JavaScript host (see
 * jspi_lib.js, Module.beamHost). The host pushes events (a TCP connection,
 * data) as binaries; Erlang takes them with take/0 and answers with send/1.
 *
 * For each event, the host also writes a byte into a pipe: select/0 asks
 * ERTS for a message when the pipe has data (enif_select), as for a socket.
 * So no thread waits in a NIF, and all threads can return to the host for
 * a snapshot of the memory (erts_wasm_hibernate).
 */
#include <erl_nif.h>
#include <emscripten/emscripten.h>
#include <fcntl.h>
#include <stddef.h>
#include <unistd.h>

int jspi_host_next_size(void);
void jspi_host_take(void *buf);
void jspi_host_send(const void *buf, size_t size);
void jspi_host_set_fd(int fd);

static int fds[2] = {-1, -1};
static ErlNifResourceType *res_type;
static void *res;

static void stop(ErlNifEnv *env, void *obj, ErlNifEvent e, int is_direct_call)
{
    (void)env; (void)obj; (void)e; (void)is_direct_call;
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
    ErlNifResourceTypeInit init = {NULL, stop, NULL, 0, NULL, NULL};

    (void)priv; (void)info;
    res_type = enif_init_resource_type(env, "wasm_host", &init, ERL_NIF_RT_CREATE, NULL);
    if (!res_type || pipe(fds))
        return 1;
    fcntl(fds[0], F_SETFL, O_NONBLOCK);
    fcntl(fds[1], F_SETFL, O_NONBLOCK);
    res = enif_alloc_resource(res_type, 1);
    jspi_host_set_fd(fds[1]);
    return 0;
}

/* After the restore of a snapshot: the host gets the pipe again. */
EMSCRIPTEN_KEEPALIVE void wasm_host_restore(void)
{
    if (fds[1] >= 0)
        jspi_host_set_fd(fds[1]);
}

/* A message {select, _, undefined, ready_input} when the host has events. */
static ERL_NIF_TERM select_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc; (void)argv;
    if (enif_select(env, fds[0], ERL_NIF_SELECT_READ, res, NULL, enif_make_atom(env, "undefined")) < 0)
        return enif_make_badarg(env);
    return enif_make_atom(env, "ok");
}

/* The next event (a binary), or empty. */
static ERL_NIF_TERM take_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary bin;
    char buf[256];
    int size;

    (void)argc; (void)argv;
    while (read(fds[0], buf, sizeof(buf)) > 0)
        ;
    if ((size = jspi_host_next_size()) < 0)
        return enif_make_atom(env, "empty");
    if (!enif_alloc_binary(size, &bin))
        return enif_raise_exception(env, enif_make_atom(env, "enomem"));
    jspi_host_take(bin.data);
    return enif_make_binary(env, &bin);
}

static ERL_NIF_TERM send_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary bin;

    (void)argc;
    if (!enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    jspi_host_send(bin.data, bin.size);
    return enif_make_atom(env, "ok");
}

static ErlNifFunc funcs[] = {
    {"select", 0, select_nif, 0},
    {"take", 0, take_nif, 0},
    {"send", 1, send_nif, 0},
};

ERL_NIF_INIT(wasm_host, funcs, load, NULL, NULL, NULL)
