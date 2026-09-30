/*
 * The native call trampoline of WAMR for the CPU of the compiler (the
 * same selection as WAMR's invokeNative_osx_universal.s). WAMR's
 * invokeNative_general.c passes 32-bit words, and only works on 32-bit
 * targets.
 */
#if defined(__aarch64__)
#include "invokeNative_aarch64.s"
#else
#include "invokeNative_em64.s"
#endif
