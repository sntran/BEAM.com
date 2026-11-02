"""A comparison, not for main: the unmap of erl_mmap.c for Emscripten
(wasm/erts/otp.patch) with a mode from the environment of the VM:
BEAM_WASM_MUNMAP=keep keeps the block, poison fills it with 0xA5 and
keeps it, and another value frees it (the fix)."""
import sys

p = sys.argv[1]
s = open(p).read()
pairs = [
    ("    void *ptr;\n} ErtsWasmMapping;", "    void *ptr;\n    size_t size;\n} ErtsWasmMapping;"),
    ("    m->ptr = ptr;\n", "    m->ptr = ptr;\n    m->size = (size_t) size;\n"),
    ("            *pp = m->next;\n            free(m->ptr);\n            free(m);\n            return;\n",
     "            static int mode = -1;\n"
     "            *pp = m->next;\n"
     "            if (mode < 0) {\n"
     "                const char *e = getenv(\"BEAM_WASM_MUNMAP\");\n"
     "                mode = !e ? 0 : e[0] == 'k' ? 1 : e[0] == 'p' ? 2 : 0;\n"
     "            }\n"
     "            if (mode == 2)\n"
     "                memset(m->ptr, 0xA5, m->size);\n"
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
