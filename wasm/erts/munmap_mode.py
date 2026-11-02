"""A comparison, not for main: the unmap of erl_mmap.c for Emscripten
(wasm/erts/otp.patch) with a mode from the environment of the VM:
BEAM_WASM_MUNMAP=keep keeps the block, poison fills it with 0xA5 and
keeps it, check also scans the poisoned blocks at the exit and prints each
write into them, and another value frees it (the fix)."""
import sys

p = sys.argv[1]
s = open(p).read()
CHECK = r"""
/* A comparison, not for main: the blocks of BEAM_WASM_MUNMAP=check, and
 * their scan at the exit of the VM. */
#include <stdio.h>
#define ERTS_WASM_CHECK_MAX 16384
static struct { unsigned char *p; size_t n; } erts_wasm_check[ERTS_WASM_CHECK_MAX];
static int erts_wasm_check_count;
static unsigned long erts_wasm_mmaps;

/* An export of the module: run.mjs calls it at the exit of the VM (the
 * worker build has no EXIT_RUNTIME, so atexit() does not run). */
__attribute__((used, export_name("erts_wasm_check_all"))) void
erts_wasm_check_all(void)
{
    int i, written = 0;

    for (i = 0; i < erts_wasm_check_count; i++) {
        unsigned char *b = erts_wasm_check[i].p;
        size_t n = erts_wasm_check[i].n, j, first = n, last = 0, dirty = 0, k;

        for (j = 0; j < n; j++) {
            if (b[j] != 0xA5) {
                if (first == n)
                    first = j;
                last = j;
                dirty++;
            }
        }
        if (dirty == 0)
            continue;
        if (written++ < 40) {
            fprintf(stderr, "munmap_check: block %d of %d at %p, size %lu: %lu bytes written, offsets %lu to %lu:",
                    i, erts_wasm_check_count, (void *) b, (unsigned long) n,
                    (unsigned long) dirty, (unsigned long) first, (unsigned long) last);
            for (k = first; k < first + 32 && k < n; k++)
                fprintf(stderr, " %02x", b[k]);
            fprintf(stderr, "\n");
        }
    }
    fprintf(stderr, "munmap_check: %d blocks, %d written, %lu mmaps\n",
            erts_wasm_check_count, written, erts_wasm_mmaps);
}
"""

pairs = [
    ("static ErtsWasmMapping *erts_wasm_mappings;\n",
     "static ErtsWasmMapping *erts_wasm_mappings;\n" + CHECK),
    ("    ErtsWasmMapping *m = malloc(sizeof(ErtsWasmMapping));\n",
     "    ErtsWasmMapping *m = malloc(sizeof(ErtsWasmMapping));\n    erts_wasm_mmaps++;\n"),
    ("    void *ptr;\n} ErtsWasmMapping;", "    void *ptr;\n    size_t size;\n} ErtsWasmMapping;"),
    ("    m->ptr = ptr;\n", "    m->ptr = ptr;\n    m->size = (size_t) size;\n"),
    ("            *pp = m->next;\n            free(m->ptr);\n            free(m);\n            return;\n",
     "            static int mode = -1;\n"
     "            *pp = m->next;\n"
     "            if (mode < 0) {\n"
     "                const char *e = getenv(\"BEAM_WASM_MUNMAP\");\n"
     "                mode = !e ? 0 : e[0] == 'k' ? 1 : e[0] == 'p' ? 2 : e[0] == 'c' ? 3 : 0;\n"
     "                if (mode == 3)\n"
     "                    atexit(erts_wasm_check_all);\n"
     "            }\n"
     "            if (mode >= 2)\n"
     "                memset(m->ptr, 0xA5, m->size);\n"
     "            if (mode == 3 && erts_wasm_check_count < ERTS_WASM_CHECK_MAX) {\n"
     "                erts_wasm_check[erts_wasm_check_count].p = m->ptr;\n"
     "                erts_wasm_check[erts_wasm_check_count].n = m->size;\n"
     "                erts_wasm_check_count++;\n"
     "            }\n"
     "            if (mode == 0)\n"
     "                free(m->ptr);\n"
     "            free(m);\n"
     "            return;\n"),
]
for old, new in pairs:
    if s.count(old) != 1:
        sys.exit(f"munmap_mode.py: no single {old!r}")
    s = s.replace(old, new)
open(p, "w").write(s)
