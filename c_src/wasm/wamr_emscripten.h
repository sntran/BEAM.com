/*
 * Forced-include header for the WAMR sources in the WebAssembly runtime
 * of --target wasm32 (Emscripten, step wamr_edge of scripts/steps.sh).
 *
 * - The libc of Emscripten declares the types of WASI, so the copy of
 *   WAMR (platform_wasi_types.h) is not used. WAMR has no WASI there:
 *   c_src/wasm/nif_wasm.c gives the part of WASI that a NIF uses.
 * - The target is a 32-bit little-endian CPU. WAMR calls each native
 *   function as a raw native there (nif_wasm.c), so its generic call
 *   (invokeNative) is never used.
 */
#include <wasi/api.h>
#define _PLATFORM_WASI_TYPES_H
#define BUILD_TARGET_X86_32 1
#define BUILD_TARGET "X86_32"
