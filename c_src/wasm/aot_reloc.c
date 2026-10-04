/*
 * The relocations of WAMR for AOT code of the CPU of the compiler.
 * cosmocc compiles each file two times (x86_64 and aarch64), so the
 * file follows the compiler, not the command line.
 */
#if defined(__x86_64__)
#include "arch/aot_reloc_x86_64.c"
#elif defined(__aarch64__)
#include "arch/aot_reloc_aarch64.c"
#else
#error "No AOT relocations for this CPU"
#endif
