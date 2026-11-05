/*
 * The C types for the headers of ERTS: "beam.com --nif-include" puts this
 * file with erl_nif.h. See docs/NIFS.md. Two kinds of NIF use them:
 *   - a NIF library in WebAssembly, for wasm32 (wasm32-wasip1);
 *   - a native NIF object of cosmocc, for x86_64 and aarch64 (LP64).
 */
#if defined(__wasm32__)
#define SIZEOF_CHAR 1
#define SIZEOF_SHORT 2
#define SIZEOF_INT 4
#define SIZEOF_LONG 4
#define SIZEOF_LONG_LONG 8
#define SIZEOF_VOID_P 4
#elif defined(__LP64__) && (defined(__x86_64__) || defined(__aarch64__))
#define SIZEOF_CHAR 1
#define SIZEOF_SHORT 2
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_LONG_LONG 8
#define SIZEOF_VOID_P 8
#else
#error "These headers are for wasm32 (--target=wasm32-wasip1), or for cosmocc on x86_64 and aarch64"
#endif
