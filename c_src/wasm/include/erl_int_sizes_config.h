/*
 * The C types of wasm32 (wasm32-wasip1) for the headers of ERTS:
 * "beam.com --nif-include" puts this file with erl_nif.h for a NIF
 * library in WebAssembly. See docs/NIFS.md.
 */
#ifndef __wasm32__
#error "These headers are for wasm32: compile with --target=wasm32-wasip1"
#endif

#define SIZEOF_CHAR 1
#define SIZEOF_SHORT 2
#define SIZEOF_INT 4
#define SIZEOF_LONG 4
#define SIZEOF_LONG_LONG 8
#define SIZEOF_VOID_P 4
