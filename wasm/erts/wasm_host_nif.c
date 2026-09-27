/*
 * wasm_host: messages between Erlang and the JavaScript host (see
 * jspi_lib.js, Module.beamHost). The host pushes events (an HTTP request,
 * a WebSocket frame) as binaries; Erlang takes them with recv/0 and
 * answers with send/1.
 *
 * recv/0 runs on a dirty I/O scheduler: its (green) thread suspends until
 * the host has an event, and the other threads, the normal schedulers
 * too, run meanwhile.
 */
#include <erl_nif.h>
#include <stddef.h>

int jspi_host_recv_size(void);
void jspi_host_take(void *buf);
void jspi_host_send(const void *buf, size_t size);

static ERL_NIF_TERM recv_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary bin;
    int size = jspi_host_recv_size();

    (void)argc; (void)argv;
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
    {"recv", 0, recv_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"send", 1, send_nif, 0},
};

ERL_NIF_INIT(wasm_host, funcs, NULL, NULL, NULL, NULL)
