/*
 * BEAM.com: the loader of native NIF objects (beam_com_nif.c,
 * docs/NIFS.md, "Native NIF objects").
 */
#ifndef BEAM_COM_NIF_H
#define BEAM_COM_NIF_H

#include <stddef.h>
#include <stdint.h>

/* The address of the symbol NAME of the program, or NULL. */
typedef void *(*bcn_lookup_fn)(const char *name);

struct bcn_module;

/* Loads the relocatable ELF object BYTES (SIZE bytes) of the CPU of the
 * program, near the program, and runs its constructors. LOOKUP gives
 * each symbol that the object does not define. Gives the module, or
 * NULL and the reason in ERROR (ERRSIZE bytes). The function does not
 * keep BYTES. */
struct bcn_module *bcn_load(const uint8_t *bytes, size_t size, bcn_lookup_fn lookup,
                            char *error, size_t errsize);

/* The address of the global symbol NAME of the module, or NULL. */
void *bcn_symbol(struct bcn_module *m, const char *name);

/* The start and the end of the memory of the module (for the tests). */
void bcn_range(struct bcn_module *m, uintptr_t *lo, uintptr_t *hi);

/* The suffix of the object of this CPU: ".x86_64.o" or ".aarch64.o". */
const char *bcn_suffix(void);

/* The address of the symbol NAME of the program for a NIF object
 * (beam_com_nif_syms.c), or NULL. */
void *beam_com_nif_lookup(const char *name);

/* Puts the loader of native NIF objects in front of the loader of NIF
 * libraries in WebAssembly (erts_wasm_nif_open of
 * patches/otp/0003-wasm-nif.patch). main() of beam_com.c calls it. */
void beam_com_nif_hook(void);

#endif
