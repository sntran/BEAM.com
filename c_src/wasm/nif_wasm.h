/*
 * NIF libraries in WebAssembly (nif_wasm.c): erlang:load_nif/2 loads
 * PATH.ARCH.aot or PATH.wasm through WAMR, when PATH has no native
 * library. See docs/NIFS.md.
 */
#ifndef NIF_WASM_H
#define NIF_WASM_H

#include <stddef.h>
#include "erl_nif.h"

/* Start the WAMR runtime one time, for the wasm NIF and for the NIF
 * libraries in WebAssembly. Gives 1 when the runtime is ready. */
int nif_wasm_runtime_init(void);

/* Load the NIF library of PATH (the path of load_nif/2, without an
 * extension): PATH.ARCH.aot, else PATH.wasm. Gives the entry of the
 * library. Gives NULL and an empty ERROR when neither file exists, and
 * NULL and a message in ERROR when a file does not load. */
ErlNifEntry *nif_wasm_open(const char *path, char *error, size_t size);

/* ERTS refused ENTRY, of the last nif_wasm_open() of this thread, before
 * its load callback (an upgrade, or a bad library): free the library. */
void nif_wasm_close(ErlNifEntry *entry);

#endif
