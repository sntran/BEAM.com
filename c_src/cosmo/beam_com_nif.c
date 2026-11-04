/*
 * BEAM.com: native NIF objects (docs/NIFS.md, "Native NIF objects").
 *
 * beam.com is one static file, with no dlopen(). A static NIF is linked
 * into the emulator, so each set of NIFs needs its own build. This file
 * loads a NIF from a relocatable ELF object of the CPU (PATH.x86_64.o or
 * PATH.aarch64.o, from `ld -r` of the static library of the NIF), as a
 * static linker does, when the program starts its load_nif/2:
 *
 *   - The object is code of Cosmopolitan, for the "small" code model of
 *     cosmocc: absolute 32-bit addresses on x86_64, and PC-relative
 *     references to the data of the program (EINVAL, O_CREAT: values of
 *     Cosmopolitan that change with the system). So the module goes near
 *     the program: below 2 GB on x86_64, and within 4 GB of the program
 *     on aarch64.
 *   - Each symbol that the object does not define comes from the table
 *     of the program (beam_com_nif_syms.c): the functions enif_* and the
 *     functions and the values of the libc that NIFs use. A call that a
 *     relocation cannot reach goes through a stub, and a GOT holds the
 *     addresses for the GOT relocations.
 *   - The code becomes read-only and executable after the relocations
 *     (MAP_JIT on macOS on Apple silicon, as the JIT does). The constants
 *     become read-only. The unwind tables go to libunwind, and the
 *     constructors (.init_array) run.
 *   - Thread-local data is not supported yet: an object with it gives an
 *     error.
 *
 * The functions of ERTS (the hook of erl_nif.c) are at the end of this
 * file. tests/cosmo/nif_load_check.c includes this file with
 * BEAM_COM_NIF_TEST, with no ERTS.
 */
#include "beam_com_nif.h"

#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <cosmo.h>

/* ELF64, little-endian: only what the loader reads. */
typedef struct {
    unsigned char e_ident[16];
    uint16_t e_type, e_machine;
    uint32_t e_version;
    uint64_t e_entry, e_phoff, e_shoff;
    uint32_t e_flags;
    uint16_t e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx;
} bcn_ehdr;

typedef struct {
    uint32_t sh_name, sh_type;
    uint64_t sh_flags, sh_addr, sh_offset, sh_size;
    uint32_t sh_link, sh_info;
    uint64_t sh_addralign, sh_entsize;
} bcn_shdr;

typedef struct {
    uint32_t st_name;
    unsigned char st_info, st_other;
    uint16_t st_shndx;
    uint64_t st_value, st_size;
} bcn_sym;

typedef struct {
    uint64_t r_offset, r_info;
    int64_t r_addend;
} bcn_rela;

#define BCN_ET_REL 1
#define BCN_EM_X86_64 62
#define BCN_EM_AARCH64 183

#define BCN_SHT_PROGBITS 1
#define BCN_SHT_SYMTAB 2
#define BCN_SHT_RELA 4
#define BCN_SHT_NOBITS 8
#define BCN_SHT_REL 9
#define BCN_SHT_INIT_ARRAY 14
#define BCN_SHT_FINI_ARRAY 15
#define BCN_SHT_PREINIT_ARRAY 16
#define BCN_SHT_SYMTAB_SHNDX 18

#define BCN_SHF_WRITE 0x1
#define BCN_SHF_ALLOC 0x2
#define BCN_SHF_EXECINSTR 0x4
#define BCN_SHF_TLS 0x400

#define BCN_SHN_UNDEF 0
#define BCN_SHN_LORESERVE 0xff00
#define BCN_SHN_ABS 0xfff1
#define BCN_SHN_COMMON 0xfff2
#define BCN_SHN_XINDEX 0xffff

#define BCN_STB_LOCAL 0
#define BCN_STB_GLOBAL 1
#define BCN_STB_WEAK 2
#define BCN_STT_TLS 6

/* The relocations of x86_64. */
#define R_X86_64_NONE 0
#define R_X86_64_64 1
#define R_X86_64_PC32 2
#define R_X86_64_PLT32 4
#define R_X86_64_GOTPCREL 9
#define R_X86_64_32 10
#define R_X86_64_32S 11
#define R_X86_64_GOTOFF64 25
#define R_X86_64_GOTPC32 26
#define R_X86_64_PC64 24
#define R_X86_64_GOTPC64 29
#define R_X86_64_SIZE32 32
#define R_X86_64_SIZE64 33
#define R_X86_64_GOTPCRELX 41
#define R_X86_64_REX_GOTPCRELX 42

/* The relocations of aarch64. */
#define R_AARCH64_NONE 0
#define R_AARCH64_ABS64 257
#define R_AARCH64_ABS32 258
#define R_AARCH64_ABS16 259
#define R_AARCH64_PREL64 260
#define R_AARCH64_PREL32 261
#define R_AARCH64_PREL16 262
#define R_AARCH64_MOVW_UABS_G0 263
#define R_AARCH64_MOVW_UABS_G0_NC 264
#define R_AARCH64_MOVW_UABS_G1 265
#define R_AARCH64_MOVW_UABS_G1_NC 266
#define R_AARCH64_MOVW_UABS_G2 267
#define R_AARCH64_MOVW_UABS_G2_NC 268
#define R_AARCH64_MOVW_UABS_G3 269
#define R_AARCH64_LD_PREL_LO19 273
#define R_AARCH64_ADR_PREL_LO21 274
#define R_AARCH64_ADR_PREL_PG_HI21 275
#define R_AARCH64_ADR_PREL_PG_HI21_NC 276
#define R_AARCH64_ADD_ABS_LO12_NC 277
#define R_AARCH64_LDST8_ABS_LO12_NC 278
#define R_AARCH64_TSTBR14 279
#define R_AARCH64_CONDBR19 280
#define R_AARCH64_JUMP26 282
#define R_AARCH64_CALL26 283
#define R_AARCH64_LDST16_ABS_LO12_NC 284
#define R_AARCH64_LDST32_ABS_LO12_NC 285
#define R_AARCH64_LDST64_ABS_LO12_NC 286
#define R_AARCH64_LDST128_ABS_LO12_NC 299
#define R_AARCH64_ADR_GOT_PAGE 311
#define R_AARCH64_LD64_GOT_LO12_NC 312

#if defined(__x86_64__)
#define BCN_MACHINE BCN_EM_X86_64
#define BCN_STUB_SIZE 16
#elif defined(__aarch64__)
#define BCN_MACHINE BCN_EM_AARCH64
#define BCN_STUB_SIZE 16
#elif defined(__COSMOPOLITAN__)
/* "cosmocc -E" and "cosmocc -MM" (the dependency files of ERTS) remove
 * the macros of the CPU: only the preprocessor reads this. */
#define BCN_MACHINE 0
#define BCN_STUB_SIZE 16
#else
#error "beam_com_nif.c: x86_64 or aarch64 only"
#endif

#define BCN_PAGE 65536 /* the largest page of the systems (Windows: 64 KiB granularity) */

/* The start and the end of the image of the program (the linker script
 * of Cosmopolitan). */
extern char __executable_start[], _end[];

/* macOS on Apple silicon: MAP_JIT memory is writable for this thread
 * between __jit_begin() and __jit_end() of Cosmopolitan. */
void __jit_begin(void);
void __jit_end(void);
/* libunwind of Cosmopolitan. */
void __unw_add_dynamic_fde(uintptr_t fde);
void __unw_remove_dynamic_fde(uintptr_t fde);

#ifdef BEAM_COM_NIF_TEST
/* The test of broken objects turns it off: libunwind reads the records
 * with no checks of their contents. */
static int bcn_unwind = 1;
#else
#define bcn_unwind 1
#endif

struct bcn_global {
    const char *name;
    uintptr_t addr;
};

struct bcn_module {
    uint8_t *code;       /* the code and the stubs (one mapping) */
    size_t code_size;
    uint8_t *data;       /* the constants, the GOT, and the data (one mapping) */
    size_t data_size;
    char *names;         /* the names of the globals */
    uintptr_t *fdes;     /* the FDE records in libunwind */
    size_t nfdes;
    struct bcn_global *globals;
    size_t nglobals;
};

/* The state of one load. */
typedef struct {
    const uint8_t *bytes;
    size_t size;
    const bcn_shdr *sh;
    unsigned nsec;
    const bcn_sym *syms;
    size_t nsyms;
    const char *strtab;
    size_t strsize;
    const uint32_t *xindex;  /* SHT_SYMTAB_SHNDX, or NULL */
    size_t nxindex;
    uintptr_t *secaddr;      /* the address of each allocated section, or 0 */
    uintptr_t *symaddr;      /* the address of each symbol, after resolve() */
    unsigned char *resolved; /* 1: symaddr is known; 2: the symbol is missing */
    uint32_t *got;           /* the GOT slot of each symbol, + 1, or 0 */
    uint32_t *stub;          /* the stub of each symbol, + 1, or 0 */
    size_t ngot, nstub;
    uintptr_t got_base, stub_base, common_base;
    uint64_t *common_off;    /* the offset of each COMMON symbol in common_base */
    uintptr_t dso_handle;
    bcn_lookup_fn lookup;
    char *error;
    size_t errsize;
    int jit;                 /* the code is MAP_JIT (macOS on Apple silicon) */
} bcn_load_t;

static int fail(bcn_load_t *l, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(l->error, l->errsize, fmt, ap);
    va_end(ap);
    return 0;
}

static uint64_t align_up(uint64_t v, uint64_t a)
{
    return a > 1 ? (v + a - 1) / a * a : v;
}

const char *bcn_suffix(void)
{
#if defined(__x86_64__)
    return ".x86_64.o";
#else
    return ".aarch64.o";
#endif
}

static const char *sym_name(bcn_load_t *l, const bcn_sym *s)
{
    return s->st_name < l->strsize ? l->strtab + s->st_name : "?";
}

/* The symbol has a name in the string table. */
static int sym_named(bcn_load_t *l, const bcn_sym *s)
{
    return s->st_name && s->st_name < l->strsize && l->strtab[s->st_name];
}

/* The section index of the symbol I. */
static uint32_t sym_shndx(bcn_load_t *l, size_t i)
{
    const bcn_sym *s = &l->syms[i];
    if (s->st_shndx == BCN_SHN_XINDEX && l->xindex && i < l->nxindex)
        return l->xindex[i];
    return s->st_shndx;
}

/* A section that goes into memory, and its group: 0 the code, 1 the
 * constants, 2 the data. -1: not in memory. */
static int sec_group(const bcn_shdr *s)
{
    if (!(s->sh_flags & BCN_SHF_ALLOC) || s->sh_size == 0)
        return -1;
    if (s->sh_flags & BCN_SHF_EXECINSTR)
        return 0;
    if (s->sh_flags & BCN_SHF_WRITE)
        return 2;
    return 1;
}

/* A string table in the file that ends with a zero byte. */
static int is_strtab(const bcn_shdr *s, const uint8_t *bytes)
{
    return s->sh_type == 3 /* SHT_STRTAB */ && s->sh_size && bytes[s->sh_offset + s->sh_size - 1] == '\0';
}

/* Checks the header and the sections of the object. */
static int check_object(bcn_load_t *l)
{
    const bcn_ehdr *eh = (const bcn_ehdr *)l->bytes;
    unsigned i;

    if (l->size < sizeof(*eh) || memcmp(eh->e_ident, "\177ELF", 4))
        return fail(l, "not an ELF object");
    if (eh->e_ident[4] != 2 || eh->e_ident[5] != 1)
        return fail(l, "not a 64-bit little-endian ELF object");
    if (eh->e_type != BCN_ET_REL)
        return fail(l, "not a relocatable object (ld -r)");
    if (eh->e_machine != BCN_MACHINE)
        return fail(l, "an object of a different CPU (machine %u)", eh->e_machine);
    if (eh->e_shentsize != sizeof(bcn_shdr) || eh->e_shnum == 0 || eh->e_shoff > l->size ||
        (uint64_t)eh->e_shnum * sizeof(bcn_shdr) > l->size - eh->e_shoff)
        return fail(l, "bad section headers");
    l->sh = (const bcn_shdr *)(l->bytes + eh->e_shoff);
    l->nsec = eh->e_shnum;
    /* First the bounds of each section, then the tables in them. */
    for (i = 0; i < l->nsec; i++) {
        const bcn_shdr *s = &l->sh[i];
        if (s->sh_type != BCN_SHT_NOBITS && s->sh_size &&
            (s->sh_offset > l->size || s->sh_size > l->size - s->sh_offset))
            return fail(l, "section %u is out of the file", i);
        if (s->sh_addralign > BCN_PAGE)
            return fail(l, "section %u has an alignment above 64 KiB", i);
        if (s->sh_size > ((uint64_t)1 << 30))
            return fail(l, "section %u is larger than 1 GiB", i);
        if ((s->sh_flags & BCN_SHF_ALLOC) && (s->sh_flags & BCN_SHF_TLS) && s->sh_size)
            return fail(l, "thread-local data is not supported yet");
        if (s->sh_type == BCN_SHT_REL)
            return fail(l, "REL relocations are not supported (only RELA)");
    }
    if (eh->e_shstrndx >= l->nsec || !is_strtab(&l->sh[eh->e_shstrndx], l->bytes))
        return fail(l, "bad section names");
    for (i = 0; i < l->nsec; i++) {
        const bcn_shdr *s = &l->sh[i];
        if (s->sh_type == BCN_SHT_SYMTAB) {
            if (l->syms)
                return fail(l, "more than one symbol table");
            if (s->sh_entsize != sizeof(bcn_sym) || s->sh_link >= l->nsec ||
                !is_strtab(&l->sh[s->sh_link], l->bytes))
                return fail(l, "bad symbol table");
            l->syms = (const bcn_sym *)(l->bytes + s->sh_offset);
            l->nsyms = s->sh_size / sizeof(bcn_sym);
            l->strtab = (const char *)(l->bytes + l->sh[s->sh_link].sh_offset);
            l->strsize = l->sh[s->sh_link].sh_size;
        }
        if (s->sh_type == BCN_SHT_SYMTAB_SHNDX) {
            l->xindex = (const uint32_t *)(l->bytes + s->sh_offset);
            l->nxindex = s->sh_size / 4;
        }
        if (s->sh_type == BCN_SHT_RELA) {
            if (s->sh_entsize != sizeof(bcn_rela) || s->sh_info >= l->nsec)
                return fail(l, "bad relocation section %u", i);
        }
    }
    if (!l->syms)
        return fail(l, "no symbol table");
    if (l->xindex && l->nxindex < l->nsyms)
        return fail(l, "bad extended section indexes");
    return 1;
}

static const char *sec_name(bcn_load_t *l, unsigned i)
{
    const bcn_ehdr *eh = (const bcn_ehdr *)l->bytes;
    const bcn_shdr *names;
    if (eh->e_shstrndx >= l->nsec)
        return "";
    names = &l->sh[eh->e_shstrndx];
    if (l->sh[i].sh_name >= names->sh_size)
        return "";
    return (const char *)(l->bytes + names->sh_offset + l->sh[i].sh_name);
}

static int is_got_reloc(uint32_t type)
{
#if defined(__x86_64__)
    return type == R_X86_64_GOTPCREL || type == R_X86_64_GOTPCRELX ||
           type == R_X86_64_REX_GOTPCRELX;
#else
    return type == R_AARCH64_ADR_GOT_PAGE || type == R_AARCH64_LD64_GOT_LO12_NC;
#endif
}

static int is_call_reloc(uint32_t type)
{
#if defined(__x86_64__)
    return type == R_X86_64_PLT32 || type == R_X86_64_PC32;
#else
    return type == R_AARCH64_CALL26 || type == R_AARCH64_JUMP26;
#endif
}

/* The slots of the GOT and the stubs that the relocations need, and the
 * place of each COMMON symbol. */
static int count_slots(bcn_load_t *l, uint64_t *common_size)
{
    unsigned i;
    size_t j;

    for (i = 0; i < l->nsec; i++) {
        const bcn_shdr *r = &l->sh[i];
        const bcn_rela *rel;
        size_t n;
        if (r->sh_type != BCN_SHT_RELA || sec_group(&l->sh[r->sh_info]) < 0)
            continue;
        rel = (const bcn_rela *)(l->bytes + r->sh_offset);
        n = r->sh_size / sizeof(bcn_rela);
        for (j = 0; j < n; j++) {
            uint32_t type = (uint32_t)rel[j].r_info;
            size_t s = (size_t)(rel[j].r_info >> 32);
            if (s >= l->nsyms)
                return fail(l, "a relocation names symbol %zu of %zu", s, l->nsyms);
            if (is_got_reloc(type) && !l->got[s])
                l->got[s] = (uint32_t)++l->ngot;
            /* A stub is a jump: only for a call from the code. */
            if (is_call_reloc(type) && (l->sh[r->sh_info].sh_flags & BCN_SHF_EXECINSTR) &&
                sym_shndx(l, s) == BCN_SHN_UNDEF && s != 0 && !l->stub[s])
                l->stub[s] = (uint32_t)++l->nstub;
        }
    }
    *common_size = 0;
    for (j = 0; j < l->nsyms; j++) {
        if (sym_shndx(l, j) == BCN_SHN_COMMON) {
            uint64_t a = l->syms[j].st_value ? l->syms[j].st_value : 8;
            if (a > BCN_PAGE)
                return fail(l, "the common symbol %s has an alignment above 64 KiB",
                            sym_name(l, &l->syms[j]));
            *common_size = align_up(*common_size, a);
            l->common_off[j] = *common_size;
            if (l->syms[j].st_size > ((uint64_t)1 << 30) - *common_size)
                return fail(l, "the common symbols are larger than 1 GiB");
            *common_size += l->syms[j].st_size;
        }
    }
    return 1;
}

/* Maps SIZE bytes at ADDR exactly, with PROT and FLAGS, or gives NULL. */
static void *map_at(uintptr_t addr, size_t size, int prot, int flags)
{
    void *p = mmap((void *)addr, size, prot, flags | MAP_FIXED_NOREPLACE, -1, 0);
    if (p == MAP_FAILED)
        return NULL;
    if ((uintptr_t)p != addr) {
        /* A system that takes the flag only as a hint. */
        munmap(p, size);
        return NULL;
    }
    return p;
}

/* The two mappings of the module, near the program: the code (with the
 * stubs), then the constants, the GOT and the data. */
static int map_module(bcn_load_t *l, struct bcn_module *m)
{
    uintptr_t start = (uintptr_t)__executable_start;
    uintptr_t lo = align_up((uintptr_t)_end, BCN_PAGE) + 16 * BCN_PAGE;
    size_t total = m->code_size + m->data_size;
    int code_prot = PROT_READ | PROT_WRITE, code_flags = MAP_PRIVATE | MAP_ANONYMOUS;
    uintptr_t hi, a;

#if defined(__x86_64__)
    /* R_X86_64_32S: each address of the module is below 2 GB, and the
     * module is within 2 GB of the program. */
    hi = 0x80000000u;
    if (start >= hi)
        return fail(l, "the program is above 2 GB, and a NIF object of cosmocc needs it below");
#else
    /* ADRP reaches 4 GB from the module to the program. */
    hi = start + 0xF0000000u;
#endif
    if (l->jit) {
        code_prot |= PROT_EXEC;
        code_flags |= MAP_JIT;
    }
    for (a = lo; a + total <= hi && a + total > a; a += 16u << 20) {
        void *code = map_at(a, m->code_size, code_prot, code_flags);
        void *data;
        if (!code)
            continue;
        data = map_at(a + m->code_size, m->data_size, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS);
        if (!data) {
            munmap(code, m->code_size);
            continue;
        }
        m->code = code;
        m->data = data;
        return 1;
    }
    return fail(l, "no free memory near the program for %zu bytes", total);
}

/* The address of the symbol I. */
static int sym_addr(bcn_load_t *l, size_t i, uintptr_t *out)
{
    const bcn_sym *s = &l->syms[i];
    uint32_t shndx;
    uintptr_t a;

    if (l->resolved[i] == 1) {
        *out = l->symaddr[i];
        return 1;
    }
    if (l->resolved[i] == 2)
        return 0;
    if ((s->st_info & 0xf) == BCN_STT_TLS)
        return fail(l, "thread-local data is not supported yet (%s)", sym_name(l, s));
    shndx = sym_shndx(l, i);
    if (shndx == BCN_SHN_UNDEF) {
        const char *name = sym_name(l, s);
        if (i == 0 || !*name)
            a = 0;
        else if (!strcmp(name, "__dso_handle"))
            a = l->dso_handle;
        else if (!strcmp(name, "_GLOBAL_OFFSET_TABLE_"))
            a = l->got_base;
        else if (!(a = (uintptr_t)l->lookup(name)) && (s->st_info >> 4) != BCN_STB_WEAK) {
            l->resolved[i] = 2;
            return fail(l, "the program has no symbol %s", name);
        }
    } else if (shndx == BCN_SHN_ABS) {
        a = (uintptr_t)s->st_value;
    } else if (shndx == BCN_SHN_COMMON) {
        a = l->common_base + (uintptr_t)l->common_off[i];
    } else if (shndx < l->nsec && l->secaddr[shndx]) {
        a = l->secaddr[shndx] + (uintptr_t)s->st_value;
    } else {
        l->resolved[i] = 2;
        return fail(l, "the symbol %s is in a section that is not loaded", sym_name(l, s));
    }
    l->symaddr[i] = a;
    l->resolved[i] = 1;
    *out = a;
    return 1;
}

static void put32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static void put64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }
static uint32_t get32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static int fits_s32(int64_t v) { return v >= INT32_MIN && v <= INT32_MAX; }
__attribute__((unused)) static int fits_bits(int64_t v, int bits) { return v >= -((int64_t)1 << (bits - 1)) && v < ((int64_t)1 << (bits - 1)); }

/* The GOT slot of the symbol I, with its address in it. */
static uintptr_t got_slot(bcn_load_t *l, size_t i, uintptr_t S)
{
    uintptr_t g = l->got_base + (uintptr_t)(l->got[i] - 1) * 8;
    put64((uint8_t *)g, S);
    return g;
}

/* The stub of the symbol I: a jump to S, from anywhere. */
static uintptr_t stub_slot(bcn_load_t *l, size_t i, uintptr_t S)
{
    uint8_t *p = (uint8_t *)(l->stub_base + (uintptr_t)(l->stub[i] - 1) * BCN_STUB_SIZE);
#if defined(__x86_64__)
    /* jmp *0(%rip), then the address */
    static const uint8_t jmp[8] = { 0xff, 0x25, 0, 0, 0, 0, 0xcc, 0xcc };
    memcpy(p, jmp, 6);
    put64(p + 6, S);
    p[14] = p[15] = 0xcc;
#else
    put32(p, 0x58000050u);     /* ldr x16, 8 */
    put32(p + 4, 0xd61f0200u); /* br x16 */
    put64(p + 8, S);
#endif
    return (uintptr_t)p;
}

#if defined(__aarch64__)
static uint32_t enc_adr(uint32_t insn, int64_t imm)
{
    return (insn & ~((3u << 29) | (0x7ffffu << 5))) | (((uint32_t)imm & 3) << 29) |
           ((((uint32_t)(imm >> 2)) & 0x7ffffu) << 5);
}

static uint32_t enc_imm12(uint32_t insn, uint64_t imm)
{
    return (insn & ~(0xfffu << 10)) | (((uint32_t)imm & 0xfffu) << 10);
}
#endif

static int relocate(bcn_load_t *l, const bcn_shdr *target, uintptr_t base, const bcn_rela *r)
{
    uint32_t type = (uint32_t)r->r_info;
    size_t si = (size_t)(r->r_info >> 32);
    uint8_t *w = (uint8_t *)(base + r->r_offset);
    uintptr_t P = (uintptr_t)w, S;
    int64_t A = r->r_addend, v;

    if (r->r_offset > target->sh_size || target->sh_size - r->r_offset < 4)
        return fail(l, "a relocation is out of its section");
    if (type == 0)
        return 1;
    if (!sym_addr(l, si, &S))
        return 0;
#if defined(__x86_64__)
    switch (type) {
    case R_X86_64_64:
    case R_X86_64_PC64:
    case R_X86_64_SIZE64:
        if (target->sh_size - r->r_offset < 8)
            return fail(l, "a relocation is out of its section");
        v = type == R_X86_64_64 ? (int64_t)(S + A)
            : type == R_X86_64_PC64 ? (int64_t)(S + A - P)
            : (int64_t)(l->syms[si].st_size + A);
        put64(w, (uint64_t)v);
        return 1;
    case R_X86_64_PC32:
    case R_X86_64_PLT32:
        v = (int64_t)(S + A - P);
        if (!fits_s32(v) && l->stub[si] && (target->sh_flags & BCN_SHF_EXECINSTR))
            v = (int64_t)(stub_slot(l, si, S) + A - P);
        if (!fits_s32(v))
            return fail(l, "%s is out of the range of a 32-bit offset", sym_name(l, &l->syms[si]));
        put32(w, (uint32_t)v);
        return 1;
    case R_X86_64_GOTPCREL:
    case R_X86_64_GOTPCRELX:
    case R_X86_64_REX_GOTPCRELX:
        v = (int64_t)(got_slot(l, si, S) + A - P);
        if (!fits_s32(v))
            return fail(l, "the GOT is out of the range of a 32-bit offset");
        put32(w, (uint32_t)v);
        return 1;
    case R_X86_64_32:
        v = (int64_t)(S + A);
        if (v < 0 || v > (int64_t)UINT32_MAX)
            return fail(l, "%s is above 4 GB for a 32-bit address", sym_name(l, &l->syms[si]));
        put32(w, (uint32_t)v);
        return 1;
    case R_X86_64_32S:
        v = (int64_t)(S + A);
        if (!fits_s32(v))
            return fail(l, "%s is above 2 GB for a 32-bit address", sym_name(l, &l->syms[si]));
        put32(w, (uint32_t)v);
        return 1;
    case R_X86_64_SIZE32:
        put32(w, (uint32_t)(l->syms[si].st_size + A));
        return 1;
    case R_X86_64_GOTPC32:
        v = (int64_t)(l->got_base + A - P);
        if (!fits_s32(v))
            return fail(l, "the GOT is out of the range of a 32-bit offset");
        put32(w, (uint32_t)v);
        return 1;
    case R_X86_64_GOTPC64:
    case R_X86_64_GOTOFF64:
        if (target->sh_size - r->r_offset < 8)
            return fail(l, "a relocation is out of its section");
        put64(w, type == R_X86_64_GOTPC64 ? l->got_base + A - P : S + A - l->got_base);
        return 1;
    }
#else
    {
        uint32_t insn = get32(w);
        uintptr_t G;
        switch (type) {
        case R_AARCH64_ABS64:
        case R_AARCH64_PREL64:
            if (target->sh_size - r->r_offset < 8)
                return fail(l, "a relocation is out of its section");
            put64(w, type == R_AARCH64_ABS64 ? S + A : S + A - P);
            return 1;
        case R_AARCH64_ABS32:
            v = (int64_t)(S + A);
            if (v < INT32_MIN || v > (int64_t)UINT32_MAX)
                return fail(l, "%s is out of the range of ABS32", sym_name(l, &l->syms[si]));
            put32(w, (uint32_t)v);
            return 1;
        case R_AARCH64_PREL32:
            v = (int64_t)(S + A - P);
            if (v < INT32_MIN || v > (int64_t)UINT32_MAX)
                return fail(l, "%s is out of the range of PREL32", sym_name(l, &l->syms[si]));
            put32(w, (uint32_t)v);
            return 1;
        case R_AARCH64_ABS16:
        case R_AARCH64_PREL16: {
            uint16_t h;
            v = type == R_AARCH64_ABS16 ? (int64_t)(S + A) : (int64_t)(S + A - P);
            if (v < INT16_MIN || v > (int64_t)UINT16_MAX)
                return fail(l, "%s is out of the range of a 16-bit value", sym_name(l, &l->syms[si]));
            h = (uint16_t)v;
            memcpy(w, &h, 2);
            return 1;
        }
        case R_AARCH64_MOVW_UABS_G0:
        case R_AARCH64_MOVW_UABS_G0_NC:
        case R_AARCH64_MOVW_UABS_G1:
        case R_AARCH64_MOVW_UABS_G1_NC:
        case R_AARCH64_MOVW_UABS_G2:
        case R_AARCH64_MOVW_UABS_G2_NC:
        case R_AARCH64_MOVW_UABS_G3: {
            int shift = 16 * ((int)(type - R_AARCH64_MOVW_UABS_G0) / 2);
            uint64_t x = (uint64_t)(S + A) >> shift;
            if ((type == R_AARCH64_MOVW_UABS_G0 || type == R_AARCH64_MOVW_UABS_G1 ||
                 type == R_AARCH64_MOVW_UABS_G2) && (x >> 16))
                return fail(l, "%s is out of the range of MOVW", sym_name(l, &l->syms[si]));
            put32(w, (insn & ~(0xffffu << 5)) | (((uint32_t)x & 0xffffu) << 5));
            return 1;
        }
        case R_AARCH64_LD_PREL_LO19:
        case R_AARCH64_CONDBR19:
            v = (int64_t)(S + A - P);
            if (!fits_bits(v, 21) || (v & 3))
                return fail(l, "%s is out of the range of a 19-bit offset", sym_name(l, &l->syms[si]));
            put32(w, (insn & ~(0x7ffffu << 5)) | ((((uint32_t)(v >> 2)) & 0x7ffffu) << 5));
            return 1;
        case R_AARCH64_TSTBR14:
            v = (int64_t)(S + A - P);
            if (!fits_bits(v, 16) || (v & 3))
                return fail(l, "%s is out of the range of a 14-bit offset", sym_name(l, &l->syms[si]));
            put32(w, (insn & ~(0x3fffu << 5)) | ((((uint32_t)(v >> 2)) & 0x3fffu) << 5));
            return 1;
        case R_AARCH64_ADR_PREL_LO21:
            v = (int64_t)(S + A - P);
            if (!fits_bits(v, 21))
                return fail(l, "%s is out of the range of ADR", sym_name(l, &l->syms[si]));
            put32(w, enc_adr(insn, v));
            return 1;
        case R_AARCH64_ADR_PREL_PG_HI21:
        case R_AARCH64_ADR_PREL_PG_HI21_NC:
            v = (int64_t)(((S + A) & ~(uintptr_t)0xfff) - (P & ~(uintptr_t)0xfff)) >> 12;
            if (type == R_AARCH64_ADR_PREL_PG_HI21 && !fits_bits(v, 21))
                return fail(l, "%s is out of the range of ADRP", sym_name(l, &l->syms[si]));
            put32(w, enc_adr(insn, v));
            return 1;
        case R_AARCH64_ADD_ABS_LO12_NC:
            put32(w, enc_imm12(insn, (S + A) & 0xfff));
            return 1;
        case R_AARCH64_LDST8_ABS_LO12_NC:
            put32(w, enc_imm12(insn, (S + A) & 0xfff));
            return 1;
        case R_AARCH64_LDST16_ABS_LO12_NC:
            put32(w, enc_imm12(insn, ((S + A) & 0xfff) >> 1));
            return 1;
        case R_AARCH64_LDST32_ABS_LO12_NC:
            put32(w, enc_imm12(insn, ((S + A) & 0xfff) >> 2));
            return 1;
        case R_AARCH64_LDST64_ABS_LO12_NC:
            put32(w, enc_imm12(insn, ((S + A) & 0xfff) >> 3));
            return 1;
        case R_AARCH64_LDST128_ABS_LO12_NC:
            put32(w, enc_imm12(insn, ((S + A) & 0xfff) >> 4));
            return 1;
        case R_AARCH64_CALL26:
        case R_AARCH64_JUMP26:
            v = (int64_t)(S + A - P);
            if (!fits_bits(v, 28) && l->stub[si] && (target->sh_flags & BCN_SHF_EXECINSTR))
                v = (int64_t)(stub_slot(l, si, S) + A - P);
            if (!fits_bits(v, 28) || (v & 3))
                return fail(l, "%s is out of the range of a call", sym_name(l, &l->syms[si]));
            put32(w, (insn & ~0x3ffffffu) | (((uint32_t)(v >> 2)) & 0x3ffffffu));
            return 1;
        case R_AARCH64_ADR_GOT_PAGE:
            G = got_slot(l, si, S);
            v = (int64_t)((G & ~(uintptr_t)0xfff) - (P & ~(uintptr_t)0xfff)) >> 12;
            if (!fits_bits(v, 21))
                return fail(l, "the GOT is out of the range of ADRP");
            put32(w, enc_adr(insn, v));
            return 1;
        case R_AARCH64_LD64_GOT_LO12_NC:
            G = got_slot(l, si, S);
            put32(w, enc_imm12(insn, (G & 0xfff) >> 3));
            return 1;
        }
    }
#endif
    if ((type >= 18 && type <= 23) || (type >= 512 && type <= 573) || (type >= 1024 && type <= 1032))
        return fail(l, "thread-local data is not supported yet");
    return fail(l, "the relocation type %u is not supported", type);
}

/* A list of CIE and FDE records that libunwind can read: each record in
 * the section, each FDE after its CIE, and a CIE of version 1 or 3 with
 * its augmentation string. libunwind reads the records with no checks,
 * so a broken section must not go to it. A record of length 0 ends the
 * list. With FDES, it also writes the offset of each FDE there. NFDES
 * gets the count of the FDE records. */
static int eh_frame_walk(const uint8_t *p, size_t size, uintptr_t *fdes, size_t *nfdes)
{
    size_t pos = 0, n = 0;
    uint8_t *cie_at = calloc(size ? size : 1, 1); /* 1 at the start of each CIE */
    int ok = 0;

    if (!cie_at)
        return 0;
    while (pos + 4 <= size) {
        uint32_t len = get32(p + pos), id;
        size_t start = pos, body;
        if (len == 0) {
            pos = size;
            break;
        }
        if (len == 0xffffffffu || len > size - pos - 4 || len < 4)
            goto out;
        body = pos + 4;
        id = get32(p + body);
        if (id == 0) {
            const uint8_t *aug = p + body + 5;
            if (len < 6 || (p[body + 4] != 1 && p[body + 4] != 3) || !memchr(aug, 0, len - 5))
                goto out;
            cie_at[start] = 1;
        } else {
            if (id > body || !cie_at[body - id])
                goto out;
            if (fdes)
                fdes[n] = start;
            n++;
        }
        pos = body + len;
    }
    ok = pos == size;
out:
    free(cie_at);
    *nfdes = n;
    return ok;
}

static int eh_frame_ok(const uint8_t *p, size_t size)
{
    size_t n;
    return eh_frame_walk(p, size, NULL, &n);
}

/* The priority of an .init_array section: .init_array.N runs before
 * .init_array, in the order of N. */
static unsigned long init_priority(const char *name, const char *prefix)
{
    size_t n = strlen(prefix);
    if (strncmp(name, prefix, n))
        return (unsigned long)-1;
    if (name[n] == '\0')
        return 65536;
    if (name[n] == '.')
        return strtoul(name + n + 1, NULL, 10);
    return (unsigned long)-1;
}

static void run_constructors(bcn_load_t *l)
{
    static const char *const kinds[] = { ".preinit_array", ".init_array" };
    static const uint32_t types[] = { BCN_SHT_PREINIT_ARRAY, BCN_SHT_INIT_ARRAY };
    unsigned k, i;

    for (k = 0; k < 2; k++) {
        unsigned long done = 0, next;
        /* In the order of the priorities, each section one time. */
        for (;;) {
            next = (unsigned long)-1;
            for (i = 0; i < l->nsec; i++) {
                unsigned long p = init_priority(sec_name(l, i), kinds[k]);
                if (l->secaddr[i] && l->sh[i].sh_type == types[k] && p != (unsigned long)-1 &&
                    p >= done && p < next)
                    next = p;
            }
            if (next == (unsigned long)-1)
                break;
            for (i = 0; i < l->nsec; i++) {
                if (l->secaddr[i] && l->sh[i].sh_type == types[k] &&
                    init_priority(sec_name(l, i), kinds[k]) == next) {
                    void (**f)(void) = (void (**)(void))l->secaddr[i];
                    size_t j, n = l->sh[i].sh_size / sizeof(*f);
                    for (j = 0; j < n; j++)
                        if (f[j] && f[j] != (void (*)(void))-1)
                            f[j]();
                }
            }
            done = next + 1;
        }
    }
    /* The old .ctors: in the reverse order. */
    for (i = 0; i < l->nsec; i++) {
        if (l->secaddr[i] && l->sh[i].sh_type == BCN_SHT_PROGBITS &&
            (l->sh[i].sh_flags & BCN_SHF_WRITE) && !strcmp(sec_name(l, i), ".ctors")) {
            void (**f)(void) = (void (**)(void))l->secaddr[i];
            size_t n = l->sh[i].sh_size / sizeof(*f);
            while (n--)
                if (f[n] && f[n] != (void (*)(void))-1)
                    f[n]();
        }
    }
}

static int cmp_global(const void *a, const void *b)
{
    return strcmp(((const struct bcn_global *)a)->name, ((const struct bcn_global *)b)->name);
}

/* The global symbols of the module, for bcn_symbol(). */
static int keep_globals(bcn_load_t *l, struct bcn_module *m)
{
    size_t i, n = 0, chars = 0;
    char *p;

    for (i = 1; i < l->nsyms; i++) {
        const bcn_sym *s = &l->syms[i];
        uint32_t x = sym_shndx(l, i);
        int bind = s->st_info >> 4;
        if ((bind == BCN_STB_GLOBAL || bind == BCN_STB_WEAK) && x != BCN_SHN_UNDEF &&
            sym_named(l, s)) {
            n++;
            chars += strlen(sym_name(l, s)) + 1;
        }
    }
    m->globals = calloc(n ? n : 1, sizeof(*m->globals));
    m->names = malloc(chars ? chars : 1);
    if (!m->globals || !m->names)
        return fail(l, "no memory");
    p = m->names;
    for (i = 1; i < l->nsyms; i++) {
        const bcn_sym *s = &l->syms[i];
        uint32_t x = sym_shndx(l, i);
        int bind = s->st_info >> 4;
        uintptr_t a;
        if ((bind == BCN_STB_GLOBAL || bind == BCN_STB_WEAK) && x != BCN_SHN_UNDEF &&
            sym_named(l, s)) {
            size_t len = strlen(sym_name(l, s)) + 1;
            if (!sym_addr(l, i, &a))
                return 0;
            memcpy(p, sym_name(l, s), len);
            m->globals[m->nglobals].name = p;
            m->globals[m->nglobals].addr = a;
            m->nglobals++;
            p += len;
        }
    }
    qsort(m->globals, m->nglobals, sizeof(*m->globals), cmp_global);
    return 1;
}

static void free_load(bcn_load_t *l)
{
    free(l->secaddr);
    free(l->symaddr);
    free(l->resolved);
    free(l->got);
    free(l->stub);
    free(l->common_off);
}

static void free_module(struct bcn_module *m)
{
    size_t i;
    for (i = 0; i < m->nfdes; i++)
        __unw_remove_dynamic_fde(m->fdes[i]);
    free(m->fdes);
    if (m->code)
        munmap(m->code, m->code_size);
    if (m->data)
        munmap(m->data, m->data_size);
    free(m->globals);
    free(m->names);
    free(m);
}

struct bcn_module *bcn_load(const uint8_t *bytes, size_t size, bcn_lookup_fn lookup,
                            char *error, size_t errsize)
{
    bcn_load_t l;
    struct bcn_module *m = calloc(1, sizeof(*m));
    uint64_t off[3] = { 0, 0, 0 }, *secoff = NULL, common_size = 0;
    uint64_t stub_off, got_off, common_off, dso_off, ro_map;
    uintptr_t group_base[3];
    unsigned i;
    size_t j;
    int ok = 0;

    memset(&l, 0, sizeof(l));
    l.bytes = bytes;
    l.size = size;
    l.lookup = lookup;
    l.error = error;
    l.errsize = errsize;
    error[0] = '\0';
#if defined(__aarch64__)
    l.jit = IsXnuSilicon();
#endif
    if (!m) {
        fail(&l, "no memory");
        return NULL;
    }
    if (!check_object(&l))
        goto out;
    l.secaddr = calloc(l.nsec, sizeof(*l.secaddr));
    secoff = calloc(l.nsec, sizeof(*secoff));
    l.symaddr = calloc(l.nsyms, sizeof(*l.symaddr));
    l.resolved = calloc(l.nsyms, 1);
    l.got = calloc(l.nsyms, sizeof(*l.got));
    l.stub = calloc(l.nsyms, sizeof(*l.stub));
    l.common_off = calloc(l.nsyms, sizeof(*l.common_off));
    if (!l.secaddr || !secoff || !l.symaddr || !l.resolved || !l.got || !l.stub || !l.common_off) {
        fail(&l, "no memory");
        goto out;
    }
    if (!count_slots(&l, &common_size))
        goto out;

    /* The layout: the offset of each section in its group. */
    for (i = 0; i < l.nsec; i++) {
        int g = sec_group(&l.sh[i]);
        if (g < 0)
            continue;
        off[g] = align_up(off[g], l.sh[i].sh_addralign ? l.sh[i].sh_addralign : 1);
        secoff[i] = off[g];
        off[g] += l.sh[i].sh_size;
    }
    stub_off = align_up(off[0], 16);
    m->code_size = align_up(stub_off + l.nstub * BCN_STUB_SIZE, BCN_PAGE);
    got_off = align_up(off[1], 8);
    ro_map = align_up(got_off + l.ngot * 8, BCN_PAGE);
    common_off = align_up(off[2], 64);
    dso_off = align_up(common_off + common_size, 8);
    m->data_size = ro_map + align_up(dso_off + 8, BCN_PAGE);
    if (m->code_size == 0)
        m->code_size = BCN_PAGE;
    if (!map_module(&l, m))
        goto out;
    group_base[0] = (uintptr_t)m->code;
    group_base[1] = (uintptr_t)m->data;
    group_base[2] = (uintptr_t)m->data + ro_map;
    l.stub_base = group_base[0] + stub_off;
    l.got_base = group_base[1] + got_off;
    l.common_base = group_base[2] + common_off;
    l.dso_handle = group_base[2] + dso_off;

    if (l.jit)
        __jit_begin();
    for (i = 0; i < l.nsec; i++) {
        int g = sec_group(&l.sh[i]);
        if (g < 0)
            continue;
        l.secaddr[i] = group_base[g] + secoff[i];
        if (l.sh[i].sh_type != BCN_SHT_NOBITS)
            memcpy((void *)l.secaddr[i], bytes + l.sh[i].sh_offset, l.sh[i].sh_size);
    }
    for (i = 0; i < l.nsec; i++) {
        const bcn_shdr *r = &l.sh[i];
        const bcn_rela *rel;
        size_t n;
        if (r->sh_type != BCN_SHT_RELA || !l.secaddr[r->sh_info])
            continue;
        rel = (const bcn_rela *)(bytes + r->sh_offset);
        n = r->sh_size / sizeof(bcn_rela);
        for (j = 0; j < n; j++)
            if (!relocate(&l, &l.sh[r->sh_info], l.secaddr[r->sh_info], &rel[j]))
                break;
        if (j < n)
            break;
    }
    if (l.jit)
        __jit_end();
    if (i < l.nsec)
        goto out;
#if defined(__aarch64__)
    __builtin___clear_cache((char *)m->code, (char *)m->code + m->code_size);
#endif
    if (!l.jit && mprotect(m->code, m->code_size, PROT_READ | PROT_EXEC)) {
        fail(&l, "the code cannot be executable: %s", strerror(errno));
        goto out;
    }
    if (ro_map && mprotect(m->data, ro_map, PROT_READ)) {
        fail(&l, "the constants cannot be read-only: %s", strerror(errno));
        goto out;
    }
    if (!keep_globals(&l, m))
        goto out;
    for (i = 0; i < l.nsec; i++) {
        if (bcn_unwind && l.secaddr[i] && !strcmp(sec_name(&l, i), ".eh_frame")) {
            /* Each FDE goes to libunwind alone: its walk of a whole
             * section does not stop at the end of the list. */
            const uint8_t *eh = (const uint8_t *)l.secaddr[i];
            size_t n, k;
            uintptr_t *fdes;
            if (!eh_frame_walk(eh, l.sh[i].sh_size, NULL, &n)) {
                fail(&l, "the unwind table (.eh_frame) is broken");
                goto out;
            }
            fdes = realloc(m->fdes, (m->nfdes + n + 1) * sizeof(*fdes));
            if (!fdes) {
                fail(&l, "no memory");
                goto out;
            }
            m->fdes = fdes;
            eh_frame_walk(eh, l.sh[i].sh_size, fdes + m->nfdes, &n);
            for (k = 0; k < n; k++) {
                fdes[m->nfdes + k] += l.secaddr[i];
                __unw_add_dynamic_fde(fdes[m->nfdes + k]);
            }
            m->nfdes += n;
        }
    }
    run_constructors(&l);
    ok = 1;
out:
    free(secoff);
    free_load(&l);
    if (!ok) {
        free_module(m);
        return NULL;
    }
    return m;
}

void *bcn_symbol(struct bcn_module *m, const char *name)
{
    struct bcn_global key = { name, 0 }, *g;
    g = bsearch(&key, m->globals, m->nglobals, sizeof(*m->globals), cmp_global);
    return g ? (void *)g->addr : NULL;
}

void bcn_range(struct bcn_module *m, uintptr_t *lo, uintptr_t *hi)
{
    *lo = (uintptr_t)m->code;
    *hi = (uintptr_t)m->data + m->data_size;
}

#ifndef BEAM_COM_NIF_TEST
/* ERTS: patches/otp/0003-wasm-nif.patch. load_nif/2 calls the hook
 * when the module has no static NIF. */
typedef struct enif_entry_t ErlNifEntry;
extern ErlNifEntry *(*erts_wasm_nif_open)(const char *path, char *error, size_t size);
extern void (*erts_wasm_nif_close)(ErlNifEntry *entry);

static ErlNifEntry *(*wasm_open)(const char *path, char *error, size_t size);
static void (*wasm_close)(ErlNifEntry *entry);
static int nif_debug;

/* The objects that the loader loaded. As dlopen() does, a second load of
 * the same file (the same path and the same bytes) gives the same module:
 * an upgrade of the module shares the static data of the object, and a
 * load that ERTS refuses keeps no copy. A module stays until the end of
 * the program, because its constructors ran. load_nif/2 runs with the
 * permission of the code loader, but the lock costs nothing. */
struct loaded {
    struct loaded *next;
    char *file;
    size_t size;
    uint64_t hash;
    struct bcn_module *m;
};
static struct loaded *loaded_list;
static pthread_mutex_t loaded_lock = PTHREAD_MUTEX_INITIALIZER;

static uint64_t fnv1a(const uint8_t *p, size_t n)
{
    uint64_t h = 14695981039346656037ull;
    while (n--)
        h = (h ^ *p++) * 1099511628211ull;
    return h;
}

/* The module of FILE, from the list or a new load. NULL and WHY when the
 * load fails. */
static struct bcn_module *load_once(const char *file, const uint8_t *bytes, size_t n,
                                    char *why, size_t whysize)
{
    uint64_t h = fnv1a(bytes, n);
    struct loaded *l;
    struct bcn_module *m = NULL;

    pthread_mutex_lock(&loaded_lock);
    for (l = loaded_list; l; l = l->next)
        if (l->size == n && l->hash == h && !strcmp(l->file, file)) {
            m = l->m;
            break;
        }
    if (!m && (m = bcn_load(bytes, n, beam_com_nif_lookup, why, whysize))) {
        l = malloc(sizeof(*l));
        if (l && (l->file = strdup(file))) {
            l->size = n;
            l->hash = h;
            l->m = m;
            l->next = loaded_list;
            loaded_list = l;
        } else {
            /* No list entry: the module stays, but a later load of the
             * file makes a new one. */
            free(l);
        }
    }
    pthread_mutex_unlock(&loaded_lock);
    return m;
}

/* Reads PATH. Gives 1, 0 when it does not exist, or -1 (errno). */
static int read_whole(const char *path, uint8_t **bytes, size_t *size)
{
    FILE *f = fopen(path, "rb");
    long n;
    if (!f)
        return errno == ENOENT || errno == ENOTDIR ? 0 : -1;
    if (fseek(f, 0, SEEK_END) || (n = ftell(f)) < 0 || fseek(f, 0, SEEK_SET)) {
        fclose(f);
        return -1;
    }
    *bytes = malloc(n ? (size_t)n : 1);
    if (!*bytes || fread(*bytes, 1, (size_t)n, f) != (size_t)n) {
        free(*bytes);
        *bytes = NULL;
        fclose(f);
        return -1;
    }
    fclose(f);
    *size = (size_t)n;
    return 1;
}

/* PATH.ARCH.o, else the loader of WebAssembly. The entry of a native
 * object is the function LIB_nif_init of a static NIF
 * (STATIC_ERLANG_NIF_LIBNAME, LIB: the name of the file), else
 * nif_init. The code of the object stays: its constructors ran. */
static ErlNifEntry *native_open(const char *path, char *error, size_t size)
{
    const char *native = getenv("BEAM_COM_NIF_NATIVE"), *base;
    char file[4096], init[512], why[512];
    struct bcn_module *m;
    uint8_t *bytes = NULL;
    size_t n = 0;
    void *fn;
    int r;

    error[0] = '\0';
    if ((native && !strcmp(native, "0")) ||
        snprintf(file, sizeof(file), "%s%s", path, bcn_suffix()) >= (int)sizeof(file))
        goto next;
    r = read_whole(file, &bytes, &n);
    if (r == 0)
        goto next;
    if (r < 0) {
        snprintf(error, size, "%.300s: %s", file, strerror(errno));
        return NULL;
    }
    m = load_once(file, bytes, n, why, sizeof(why));
    free(bytes);
    if (!m) {
        snprintf(error, size, "%.300s: %s", file, why);
        return NULL;
    }
    base = strrchr(path, '/');
    base = base ? base + 1 : path;
    snprintf(init, sizeof(init), "%s_nif_init", base);
    if (!(fn = bcn_symbol(m, init)) && !(fn = bcn_symbol(m, "nif_init"))) {
        snprintf(error, size, "%.300s: no function %.100s or nif_init", file, init);
        return NULL;
    }
    if (nif_debug)
        fprintf(stderr, "nif_native: %s\n", file);
    return ((ErlNifEntry * (*)(void)) fn)();
next:
    return wasm_open ? wasm_open(path, error, size) : NULL;
}

/* ERTS refused an entry. A native module stays in the list of the
 * loaded objects (its constructors ran); the loader of WebAssembly frees
 * its own entries, and it does not know the others. */
static void native_close(ErlNifEntry *entry)
{
    if (wasm_close)
        wasm_close(entry);
}

void beam_com_nif_hook(void)
{
    nif_debug = getenv("BEAM_COM_NIF_DEBUG") != NULL;
    /* The table of the program, now: one thread runs. */
    beam_com_nif_lookup("");
    wasm_open = erts_wasm_nif_open;
    wasm_close = erts_wasm_nif_close;
    erts_wasm_nif_open = native_open;
    erts_wasm_nif_close = native_close;
}
#endif
