/*
 * Forced-include header for the WAMR sources. cosmocc compiles each
 * file two times (x86_64 and aarch64), so the WAMR target must follow
 * the compiler, not the command line.
 */
#if defined(__x86_64__)
#define BUILD_TARGET_X86_64 1
#elif defined(__aarch64__)
#define BUILD_TARGET_AARCH64 1
#endif
