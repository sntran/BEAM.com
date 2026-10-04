/*
 * The functions of nif_wasm_host.c that c_src/wasm/nif_wasm.c calls in
 * the WebAssembly runtime of --target wasm32 (Emscripten).
 */
#ifndef NIF_WASM_HOST_H
#define NIF_WASM_HOST_H

#include <stdint.h>
#include "wasm_export.h"

/* The name of the file of the next wasm_runtime_load(). */
void host_set_file(const char *file);
/* A copy of N bytes at OFF of the memory of the module, or NULL. */
void *host_window(wasm_module_inst_t inst, uint32_t off, uint32_t n);
/* A copy of the string at OFF, or NULL. */
const char *host_string(wasm_module_inst_t inst, uint32_t off);
/* Free the windows: at the end of a call into the library. */
void host_release(wasm_module_inst_t inst);
int host_has_export(wasm_module_t module, const char *name);
/* The start and the end of an enif_* function that the module calls. */
wasm_exec_env_t host_enter(void);
void host_leave(wasm_exec_env_t exec_env);

#endif
