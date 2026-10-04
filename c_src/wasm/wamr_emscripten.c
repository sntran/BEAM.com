/*
 * The memory functions of the WAMR platform in the WebAssembly runtime of
 * --target wasm32 (Emscripten, step wamr_edge of scripts/steps.sh), in
 * the place of posix_memmap.c and mremap.c of WAMR.
 *
 * WebAssembly has no virtual memory: the mmap() of Emscripten takes
 * memory from malloc(), and its munmap() cannot free a part of a
 * mapping. os_mmap() of WAMR maps more and frees the ends, so its
 * munmap() of the rest failed, and each growth of a linear memory kept
 * the old memory. Here a mapping is a block of malloc().
 */
#include "platform_api_vmcore.h"

#define ALIGN 4096

void *
os_mmap(void *hint, size_t size, int prot, int flags, os_file_handle file)
{
    void *p;
    (void)hint;
    (void)prot;
    (void)flags;
    (void)file;
    if (posix_memalign(&p, ALIGN, size ? size : 1))
        return NULL;
    memset(p, 0, size);
    return p;
}

void
os_munmap(void *addr, size_t size)
{
    (void)size;
    free(addr);
}

void *
os_mremap(void *old_addr, size_t old_size, size_t new_size)
{
    void *p = os_mmap(NULL, new_size, 0, 0, os_get_invalid_handle());
    if (!p)
        return NULL;
    if (old_addr) {
        memcpy(p, old_addr, old_size < new_size ? old_size : new_size);
        free(old_addr);
    }
    return p;
}

int
os_mprotect(void *addr, size_t size, int prot)
{
    (void)addr;
    (void)size;
    (void)prot;
    return 0;
}

void
os_dcache_flush(void)
{
}

void
os_icache_flush(void *start, size_t len)
{
    (void)start;
    (void)len;
}
