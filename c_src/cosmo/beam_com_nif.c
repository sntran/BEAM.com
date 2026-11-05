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
 *   - Only the sections that the NIF uses go into memory (bcn_gc), as
 *     "ld --gc-sections" finds them. A C++ object brings the members of
 *     libc++ that it uses, and the table gives libc++abi.
 *   - Each symbol that the object does not define comes from the table
 *     of the program (beam_com_nif_syms.c): the functions enif_* and the
 *     functions and the values of the libc that NIFs use. A call that a
 *     relocation cannot reach goes through a stub, and a GOT holds the
 *     addresses for the GOT relocations.
 *   - The code becomes read-only and executable after the relocations
 *     (MAP_JIT on macOS on Apple silicon, as the JIT does). The constants
 *     become read-only. The unwind tables go to libunwind, and the
 *     constructors (.init_array) run.
 *   - Thread-local data: the program has one static TLS area
 *     (beam_com_nif_tls), and each module gets a part of it, at a fixed
 *     offset from the thread pointer of each thread. So each TLS model of
 *     the object becomes a fixed offset: local exec, initial exec (a GOT
 *     slot), general and local dynamic (__tls_get_addr of this file), and
 *     the TLS descriptors of aarch64. The initial values go into the
 *     template of the area, for the threads that start later, and into
 *     the area of each thread that runs (the thread list of
 *     Cosmopolitan). See "Thread-local data" below.
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
#include <libc/dce.h>
/* "cosmocc -MM" (the dependency files of ERTS) removes the macros of the
 * CPU, and tls.h then stops with #error. */
#if defined(__x86_64__) || defined(__aarch64__)
#include <libc/thread/posixthread.internal.h>
#include <libc/thread/tls.h>
#endif

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
#define BCN_SHF_LINK_ORDER 0x80
#define BCN_SHF_GNU_RETAIN 0x200000

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
#define R_X86_64_DTPMOD64 16
#define R_X86_64_DTPOFF64 17
#define R_X86_64_TPOFF64 18
#define R_X86_64_TLSGD 19
#define R_X86_64_TLSLD 20
#define R_X86_64_DTPOFF32 21
#define R_X86_64_GOTTPOFF 22
#define R_X86_64_TPOFF32 23

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
#define R_AARCH64_TLSIE_MOVW_GOTTPREL_G1 539
#define R_AARCH64_TLSIE_MOVW_GOTTPREL_G0_NC 540
#define R_AARCH64_TLSIE_ADR_GOTTPREL_PAGE21 541
#define R_AARCH64_TLSIE_LD64_GOTTPREL_LO12_NC 542
#define R_AARCH64_TLSIE_LD_GOTTPREL_PREL19 543
#define R_AARCH64_TLSLE_MOVW_TPREL_G2 544
#define R_AARCH64_TLSLE_MOVW_TPREL_G1 545
#define R_AARCH64_TLSLE_MOVW_TPREL_G1_NC 546
#define R_AARCH64_TLSLE_MOVW_TPREL_G0 547
#define R_AARCH64_TLSLE_MOVW_TPREL_G0_NC 548
#define R_AARCH64_TLSLE_ADD_TPREL_HI12 549
#define R_AARCH64_TLSLE_ADD_TPREL_LO12 550
#define R_AARCH64_TLSLE_ADD_TPREL_LO12_NC 551
#define R_AARCH64_TLSLE_LDST8_TPREL_LO12 552
#define R_AARCH64_TLSLE_LDST8_TPREL_LO12_NC 553
#define R_AARCH64_TLSLE_LDST16_TPREL_LO12 554
#define R_AARCH64_TLSLE_LDST16_TPREL_LO12_NC 555
#define R_AARCH64_TLSLE_LDST32_TPREL_LO12 556
#define R_AARCH64_TLSLE_LDST32_TPREL_LO12_NC 557
#define R_AARCH64_TLSLE_LDST64_TPREL_LO12 558
#define R_AARCH64_TLSLE_LDST64_TPREL_LO12_NC 559
#define R_AARCH64_TLSDESC_ADR_PAGE21 562
#define R_AARCH64_TLSDESC_LD64_LO12 563
#define R_AARCH64_TLSDESC_ADD_LO12 564
#define R_AARCH64_TLSDESC_LDR 567
#define R_AARCH64_TLSDESC_ADD 568
#define R_AARCH64_TLSDESC_CALL 569
#define R_AARCH64_TLSLE_LDST128_TPREL_LO12 570
#define R_AARCH64_TLSLE_LDST128_TPREL_LO12_NC 571

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
 * with no checks of their contents. A test that loads an object with no
 * program for it turns the constructors off. */
static int bcn_unwind = 1;
static int bcn_constructors = 1;
#else
#define bcn_unwind 1
#define bcn_constructors 1
#endif

/* Thread-local data.
 *
 * beam_com_nif_tls is the static TLS area of the modules: each thread has
 * its own copy, at the same offset from its thread pointer (bcn_tls_tpoff).
 * A module gets a part of the area, and never gives it back. Its first
 * BCN_TLS_MARK bytes hold a mark, so the loader finds the template of the
 * area in .tdata of the program: each new thread copies .tdata.
 *
 * The thread pointer is the TIB on x86_64 (%gs:0x30 in the code of
 * cosmocc), and x28 on aarch64 (the TIB + 1). Cosmopolitan does not set
 * tpidr_el0, but the code of Rust adds tpidr_el0 to the result of a TLS
 * descriptor: bcn_tlsdesc subtracts it. */
#ifndef BEAM_COM_NIF_TLS_SIZE
#define BEAM_COM_NIF_TLS_SIZE 32768
#endif
#define BCN_TLS_MARK 64
#define BCN_TLS_ALIGN 64
static const unsigned char bcn_tls_mark[32] = {
    'B', 'E', 'A', 'M', '.', 'c', 'o', 'm', ' ', 'N', 'I', 'F', ' ', 'T', 'L', 'S',
    0x5a, 0x3c, 0x96, 0xe1, 0x0f, 0x77, 0x2b, 0xd4, 0x81, 0x6e, 0x39, 0xc2, 0x47, 0xa5, 0x1d, 0xf8,
};
_Thread_local unsigned char beam_com_nif_tls[BEAM_COM_NIF_TLS_SIZE]
    __attribute__((aligned(BCN_TLS_ALIGN))) = {
    'B', 'E', 'A', 'M', '.', 'c', 'o', 'm', ' ', 'N', 'I', 'F', ' ', 'T', 'L', 'S',
    0x5a, 0x3c, 0x96, 0xe1, 0x0f, 0x77, 0x2b, 0xd4, 0x81, 0x6e, 0x39, 0xc2, 0x47, 0xa5, 0x1d, 0xf8,
};
/* The template of .tdata (ape.lds of Cosmopolitan). It is in the
 * segment of the constants, after the code: a segment starts on its own
 * page, so the pages of the template hold no code. */
extern char _tdata_start[];
extern char _tdata_size[];

static pthread_mutex_t bcn_tls_lock = PTHREAD_MUTEX_INITIALIZER;
static size_t bcn_tls_used = BCN_TLS_MARK;
static unsigned char *bcn_tls_template; /* the area in the template */
static intptr_t bcn_tls_tpoff;           /* the offset of the area from the thread pointer */
static int bcn_tls_state;                /* 0: not checked, 1: ready, -1: not usable */
static const char *bcn_tls_why = "";

/* The thread pointer of the thread of TIB: the code of cosmocc adds its
 * TLS offsets to it. */
static char *tls_pointer(struct CosmoTib *tib)
{
#if defined(__aarch64__)
    return (char *)(tib + 1);
#else
    return (char *)tib;
#endif
}

/* The size of .tdata: an absolute symbol, which ADRP of aarch64 cannot
 * reach. */
static size_t tdata_size(void)
{
#if defined(__aarch64__)
    size_t n;
    __asm__("movz %0, #:abs_g1:_tdata_size\n\tmovk %0, #:abs_g0_nc:_tdata_size" : "=r"(n));
    return n;
#else
    return (size_t)_tdata_size;
#endif
}

/* Finds the template of the area, and checks the thread list, once. */
static int tls_ready(void)
{
    pthread_mutex_lock(&bcn_tls_lock);
    if (!bcn_tls_state) {
        unsigned char *t = (unsigned char *)_tdata_start;
        size_t size = tdata_size(), k, hits = 0;
        struct Dll *e;
        int self = 0;
        for (k = 0; k + BEAM_COM_NIF_TLS_SIZE <= size; k++)
            if (t[k] == 'B' && !memcmp(t + k, bcn_tls_mark, sizeof(bcn_tls_mark))) {
                bcn_tls_template = t + k;
                hits++;
            }
        bcn_tls_tpoff = (char *)beam_com_nif_tls - tls_pointer(__get_tls());
        _pthread_lock();
        for (e = dll_first(_pthread_list); e; e = dll_next(_pthread_list, e))
            if (POSIXTHREAD_CONTAINER(e) == _pthread_self())
                self = 1;
        _pthread_unlock();
        bcn_tls_state = -1;
        if (hits != 1)
            bcn_tls_why = "the template of the TLS area is not in .tdata";
        else if (_pthread_self()->tib != __get_tls() || !self)
            bcn_tls_why = "the thread list of Cosmopolitan is not as the loader knows it";
        else
            bcn_tls_state = 1;
    }
    pthread_mutex_unlock(&bcn_tls_lock);
    return bcn_tls_state == 1;
}

/* __tls_get_addr of the general and local dynamic models: TI is the
 * offset of the module in the area, and the offset in the module. */
static void *bcn_tls_get_addr(const uint64_t *ti)
{
    return beam_com_nif_tls + ti[0] + ti[1];
}

#if defined(__aarch64__)
/* The function of a TLS descriptor {bcn_tlsdesc, offset from x28}: it
 * gives the offset from tpidr_el0, and changes only x0. */
void bcn_tlsdesc(void);
__asm__(".text\n"
        ".balign 16\n"
        "bcn_tlsdesc:\n"
        "\tldr x0, [x0, #8]\n"
        "\tadd x0, x0, x28\n"
        "\tstr x1, [sp, #-16]!\n"
        "\tmrs x1, tpidr_el0\n"
        "\tsub x0, x0, x1\n"
        "\tldr x1, [sp], #16\n"
        "\tret\n");
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
    unsigned nsec, shstrndx;
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
    /* Thread-local data. */
    unsigned char *tlssym;   /* 1: the symbol is in a TLS section */
    uint64_t *tls_secoff;    /* the offset of each TLS section in the image */
    unsigned char *tls_image; /* the initial values (.tdata, .tbss) */
    size_t tls_size, tls_align;
    size_t tls_off;          /* the offset of the module in beam_com_nif_tls */
    struct bcn_tls_slot *tls_slots;
    size_t ntls_slots;
    void **seen;             /* the threads that got the initial values */
    size_t nseen, seen_cap;
    /* The sections that the module needs (bcn_gc): 1 live, 0 dead. */
    unsigned char *live;
    /* For each RELA section of .eh_frame: 1 for a relocation of the
     * record of a dead function, which the loader does not apply. */
    unsigned char **eh_skip;
    /* For each .eh_frame section: the start of each record, and 1 for a
     * live record. */
    struct bcn_eh_records *eh_records;
} bcn_load_t;

struct bcn_eh_records {
    size_t n;
    uint64_t *start;
    unsigned char *live;
};

/* A GOT slot of a TLS relocation: one slot of an offset from the thread
 * pointer (KIND 0), or two slots (KIND 1: a TLS descriptor on aarch64, the
 * argument of __tls_get_addr on x86_64; KIND 2: the module, for the local
 * dynamic model). */
struct bcn_tls_slot {
    size_t sym;
    int64_t addend;
    int kind;
    uint32_t slot; /* the first GOT slot, + 1 */
};

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
static int sec_group_of(const bcn_shdr *s)
{
    /* A TLS section is in the TLS image, not in a mapping. */
    if (!(s->sh_flags & BCN_SHF_ALLOC) || s->sh_size == 0 || (s->sh_flags & BCN_SHF_TLS))
        return -1;
    if (s->sh_flags & BCN_SHF_EXECINSTR)
        return 0;
    if (s->sh_flags & BCN_SHF_WRITE)
        return 2;
    return 1;
}

/* The group of the section I, or -1 for a dead section (bcn_gc). */
static int sec_group(bcn_load_t *l, unsigned i)
{
    return l->live[i] ? sec_group_of(&l->sh[i]) : -1;
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
    if (eh->e_shentsize != sizeof(bcn_shdr) || eh->e_shoff > l->size ||
        l->size - eh->e_shoff < sizeof(bcn_shdr))
        return fail(l, "bad section headers");
    l->sh = (const bcn_shdr *)(l->bytes + eh->e_shoff);
    /* More than 65279 sections (a large C++ object): the count is in the
     * sh_size of section 0, and the index of the names in its sh_link. */
    l->nsec = eh->e_shnum ? eh->e_shnum
              : l->sh[0].sh_size <= UINT32_MAX ? (unsigned)l->sh[0].sh_size : 0;
    l->shstrndx = eh->e_shstrndx == BCN_SHN_XINDEX ? l->sh[0].sh_link : eh->e_shstrndx;
    if (l->nsec == 0 || (uint64_t)l->nsec * sizeof(bcn_shdr) > l->size - eh->e_shoff)
        return fail(l, "bad section headers");
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
        if ((s->sh_flags & BCN_SHF_ALLOC) && (s->sh_flags & BCN_SHF_TLS) && s->sh_size &&
            s->sh_addralign > BCN_TLS_ALIGN)
            return fail(l, "the thread-local section %u has an alignment above %d", i, BCN_TLS_ALIGN);
        if (s->sh_type == BCN_SHT_REL)
            return fail(l, "REL relocations are not supported (only RELA)");
    }
    if (l->shstrndx >= l->nsec || !is_strtab(&l->sh[l->shstrndx], l->bytes))
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
    const bcn_shdr *names;
    if (l->shstrndx >= l->nsec)
        return "";
    names = &l->sh[l->shstrndx];
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

/* The kind of the GOT slot of a TLS relocation, or -1 for no slot. */
static int tls_slot_kind(uint32_t type)
{
#if defined(__x86_64__)
    switch (type) {
    case R_X86_64_GOTTPOFF: return 0;
    case R_X86_64_TLSGD: return 1;
    case R_X86_64_TLSLD: return 2;
    }
#else
    switch (type) {
    case R_AARCH64_TLSIE_ADR_GOTTPREL_PAGE21:
    case R_AARCH64_TLSIE_LD64_GOTTPREL_LO12_NC:
    case R_AARCH64_TLSIE_LD_GOTTPREL_PREL19:
        return 0;
    case R_AARCH64_TLSDESC_ADR_PAGE21:
    case R_AARCH64_TLSDESC_LD64_LO12:
    case R_AARCH64_TLSDESC_ADD_LO12:
        return 1;
    }
#endif
    return -1;
}

/* A relocation of thread-local data. */
static int is_tls_reloc(uint32_t type)
{
#if defined(__x86_64__)
    return type >= R_X86_64_DTPMOD64 && type <= R_X86_64_TPOFF32;
#else
    return type >= 512 && type <= 573;
#endif
}

/* The addend that names the slot: on aarch64 the slot holds S + A; on
 * x86_64 the addend of the relocation is for the PC. */
static int64_t tls_slot_addend(int64_t addend)
{
#if defined(__x86_64__)
    (void)addend;
    return 0;
#else
    return addend;
#endif
}

/* The slot of SYM, ADDEND, and KIND (KIND 2: one for the module), or 0. */
static uint32_t tls_slot_find(bcn_load_t *l, size_t sym, int64_t addend, int kind)
{
    size_t k;
    for (k = 0; k < l->ntls_slots; k++) {
        struct bcn_tls_slot *t = &l->tls_slots[k];
        if (t->kind == kind && (kind == 2 || (t->sym == sym && t->addend == addend)))
            return t->slot;
    }
    return 0;
}

static int tls_slot_add(bcn_load_t *l, size_t sym, int64_t addend, int kind)
{
    struct bcn_tls_slot *t;
    if (tls_slot_find(l, sym, addend, kind))
        return 1;
    t = realloc(l->tls_slots, (l->ntls_slots + 1) * sizeof(*t));
    if (!t)
        return fail(l, "no memory");
    l->tls_slots = t;
    t += l->ntls_slots++;
    t->sym = sym;
    t->addend = addend;
    t->kind = kind;
    t->slot = (uint32_t)l->ngot + 1;
    l->ngot += kind ? 2 : 1;
    return 1;
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
        if (r->sh_type != BCN_SHT_RELA || sec_group(l, r->sh_info) < 0)
            continue;
        rel = (const bcn_rela *)(l->bytes + r->sh_offset);
        n = r->sh_size / sizeof(bcn_rela);
        for (j = 0; j < n; j++) {
            uint32_t type = (uint32_t)rel[j].r_info;
            size_t s = (size_t)(rel[j].r_info >> 32);
            if (l->eh_skip[i] && l->eh_skip[i][j])
                continue;
            if (s >= l->nsyms)
                return fail(l, "a relocation names symbol %zu of %zu", s, l->nsyms);
            if (is_got_reloc(type) && !l->got[s])
                l->got[s] = (uint32_t)++l->ngot;
            if (tls_slot_kind(type) >= 0 &&
                !tls_slot_add(l, s, tls_slot_addend(rel[j].r_addend), tls_slot_kind(type)))
                return 0;
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
    shndx = sym_shndx(l, i);
    /* A symbol of thread-local data: its offset in the TLS image. */
    if (shndx < l->nsec && shndx != BCN_SHN_UNDEF && (l->sh[shndx].sh_flags & BCN_SHF_TLS)) {
        l->symaddr[i] = (uintptr_t)(l->tls_secoff[shndx] + s->st_value);
        l->resolved[i] = 1;
        l->tlssym[i] = 1;
        *out = l->symaddr[i];
        return 1;
    }
    if ((s->st_info & 0xf) == BCN_STT_TLS) {
        l->resolved[i] = 2;
        return fail(l, "the thread-local symbol %s is not in the object", sym_name(l, s));
    }
    if (shndx == BCN_SHN_UNDEF) {
        const char *name = sym_name(l, s);
        if (i == 0 || !*name)
            a = 0;
        else if (!strcmp(name, "__dso_handle"))
            a = l->dso_handle;
        else if (!strcmp(name, "_GLOBAL_OFFSET_TABLE_"))
            a = l->got_base;
        else if (!strcmp(name, "__tls_get_addr"))
            a = (uintptr_t)bcn_tls_get_addr;
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

/* The offset of the TLS symbol at S + A (an offset in the TLS image)
 * from the thread pointer. */
static int64_t tls_tpoff(bcn_load_t *l, uintptr_t S, int64_t A)
{
    return (int64_t)bcn_tls_tpoff + (int64_t)l->tls_off + (int64_t)S + A;
}

/* The GOT slot of a TLS relocation, with its values in it. */
static uintptr_t tls_slot(bcn_load_t *l, size_t si, uintptr_t S, int64_t A, int kind)
{
    int64_t a = tls_slot_addend(A);
    uint32_t slot = tls_slot_find(l, si, a, kind);
    uint8_t *g = (uint8_t *)(l->got_base + (uintptr_t)(slot - 1) * 8);
    if (kind == 0) {
        put64(g, (uint64_t)tls_tpoff(l, S, a));
    } else if (kind == 2) {
        put64(g, l->tls_off);
        put64(g + 8, 0);
    } else {
#if defined(__x86_64__)
        put64(g, l->tls_off);
        put64(g + 8, S);
#else
        put64(g, (uint64_t)(uintptr_t)bcn_tlsdesc);
        put64(g + 8, (uint64_t)tls_tpoff(l, S, a));
#endif
    }
    return (uintptr_t)g;
}

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
    if (is_tls_reloc(type) != l->tlssym[si])
        return fail(l, "the relocation type %u does not fit the symbol %s", type, sym_name(l, &l->syms[si]));
#if defined(__x86_64__)
    switch (type) {
    case R_X86_64_TPOFF32:
        v = tls_tpoff(l, S, A);
        if (!fits_s32(v))
            return fail(l, "the thread-local offset of %s is out of range", sym_name(l, &l->syms[si]));
        put32(w, (uint32_t)v);
        return 1;
    case R_X86_64_GOTTPOFF:
    case R_X86_64_TLSGD:
    case R_X86_64_TLSLD:
        v = (int64_t)(tls_slot(l, si, S, A, tls_slot_kind(type)) + A - P);
        if (!fits_s32(v))
            return fail(l, "the GOT is out of the range of a 32-bit offset");
        put32(w, (uint32_t)v);
        return 1;
    case R_X86_64_DTPOFF32:
        put32(w, (uint32_t)(S + A));
        return 1;
    case R_X86_64_TPOFF64:
    case R_X86_64_DTPOFF64:
    case R_X86_64_DTPMOD64:
        if (target->sh_size - r->r_offset < 8)
            return fail(l, "a relocation is out of its section");
        put64(w, type == R_X86_64_TPOFF64 ? (uint64_t)tls_tpoff(l, S, A)
                 : type == R_X86_64_DTPOFF64 ? S + A : l->tls_off);
        return 1;
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
        /* Thread-local data: the offset from x28 (local exec), a GOT
         * slot with it (initial exec), or a TLS descriptor. */
        case R_AARCH64_TLSLE_ADD_TPREL_HI12:
            v = tls_tpoff(l, S, A);
            if (v < 0 || v >= (1 << 24))
                return fail(l, "the thread-local offset of %s is out of range", sym_name(l, &l->syms[si]));
            put32(w, enc_imm12(insn, (uint64_t)v >> 12));
            return 1;
        case R_AARCH64_TLSLE_ADD_TPREL_LO12:
        case R_AARCH64_TLSLE_ADD_TPREL_LO12_NC:
        case R_AARCH64_TLSLE_LDST8_TPREL_LO12:
        case R_AARCH64_TLSLE_LDST8_TPREL_LO12_NC:
        case R_AARCH64_TLSLE_LDST16_TPREL_LO12:
        case R_AARCH64_TLSLE_LDST16_TPREL_LO12_NC:
        case R_AARCH64_TLSLE_LDST32_TPREL_LO12:
        case R_AARCH64_TLSLE_LDST32_TPREL_LO12_NC:
        case R_AARCH64_TLSLE_LDST64_TPREL_LO12:
        case R_AARCH64_TLSLE_LDST64_TPREL_LO12_NC:
        case R_AARCH64_TLSLE_LDST128_TPREL_LO12:
        case R_AARCH64_TLSLE_LDST128_TPREL_LO12_NC: {
            int scale = type <= R_AARCH64_TLSLE_ADD_TPREL_LO12_NC ? 0
                        : type >= R_AARCH64_TLSLE_LDST128_TPREL_LO12 ? 4
                        : (int)(type - R_AARCH64_TLSLE_LDST8_TPREL_LO12) / 2;
            int nc = type == R_AARCH64_TLSLE_LDST128_TPREL_LO12_NC ||
                     (type < R_AARCH64_TLSLE_LDST128_TPREL_LO12 &&
                      ((type - R_AARCH64_TLSLE_ADD_TPREL_LO12) & 1));
            v = tls_tpoff(l, S, A);
            if (v < 0 || (!nc && v >= 4096) || (v & ((1 << scale) - 1)))
                return fail(l, "the thread-local offset of %s is out of range", sym_name(l, &l->syms[si]));
            put32(w, enc_imm12(insn, ((uint64_t)v & 0xfff) >> scale));
            return 1;
        }
        case R_AARCH64_TLSLE_MOVW_TPREL_G2:
        case R_AARCH64_TLSLE_MOVW_TPREL_G1:
        case R_AARCH64_TLSLE_MOVW_TPREL_G1_NC:
        case R_AARCH64_TLSLE_MOVW_TPREL_G0:
        case R_AARCH64_TLSLE_MOVW_TPREL_G0_NC: {
            int shift = type == R_AARCH64_TLSLE_MOVW_TPREL_G2 ? 32
                        : type <= R_AARCH64_TLSLE_MOVW_TPREL_G1_NC ? 16 : 0;
            int nc = type == R_AARCH64_TLSLE_MOVW_TPREL_G1_NC || type == R_AARCH64_TLSLE_MOVW_TPREL_G0_NC;
            v = tls_tpoff(l, S, A);
            if (v < 0 || (!nc && ((uint64_t)v >> (shift + 16))))
                return fail(l, "the thread-local offset of %s is out of range", sym_name(l, &l->syms[si]));
            put32(w, (insn & ~(0xffffu << 5)) | ((((uint64_t)v >> shift) & 0xffffu) << 5));
            return 1;
        }
        case R_AARCH64_TLSIE_ADR_GOTTPREL_PAGE21:
        case R_AARCH64_TLSDESC_ADR_PAGE21:
            G = tls_slot(l, si, S, A, tls_slot_kind(type));
            v = (int64_t)((G & ~(uintptr_t)0xfff) - (P & ~(uintptr_t)0xfff)) >> 12;
            if (!fits_bits(v, 21))
                return fail(l, "the GOT is out of the range of ADRP");
            put32(w, enc_adr(insn, v));
            return 1;
        case R_AARCH64_TLSIE_LD64_GOTTPREL_LO12_NC:
        case R_AARCH64_TLSDESC_LD64_LO12:
            G = tls_slot(l, si, S, A, tls_slot_kind(type));
            put32(w, enc_imm12(insn, (G & 0xfff) >> 3));
            return 1;
        case R_AARCH64_TLSDESC_ADD_LO12:
            G = tls_slot(l, si, S, A, 1);
            put32(w, enc_imm12(insn, G & 0xfff));
            return 1;
        case R_AARCH64_TLSIE_LD_GOTTPREL_PREL19:
            G = tls_slot(l, si, S, A, 0);
            v = (int64_t)(G - P);
            if (!fits_bits(v, 21) || (v & 3))
                return fail(l, "the GOT is out of the range of a 19-bit offset");
            put32(w, (insn & ~(0x7ffffu << 5)) | ((((uint32_t)(v >> 2)) & 0x7ffffu) << 5));
            return 1;
        case R_AARCH64_TLSDESC_CALL:
        case R_AARCH64_TLSDESC_LDR:
        case R_AARCH64_TLSDESC_ADD:
            /* Marks for the relaxations of a linker: no change. */
            return 1;
        }
    }
#endif
    if (is_tls_reloc(type))
        return fail(l, "the thread-local relocation type %u is not supported (the TLS model of the object)", type);
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

/* The check of the unwind table, for tests/cosmo/nif_load_check.c. */
__attribute__((unused)) static int eh_frame_ok(const uint8_t *p, size_t size)
{
    size_t n;
    return eh_frame_walk(p, size, NULL, &n);
}

/* The sections that the module needs, as "ld --gc-sections" finds them:
 * the sections of the global symbols (a NIF object of the build keeps only
 * its init function global), the constructors, SHF_GNU_RETAIN, the notes,
 * and the sections with a C name (__start_ and __stop_); then each section
 * that a relocation of a live section names. A section with
 * SHF_LINK_ORDER (__patchable_function_entries of each function) is live
 * when the section of its sh_link is live. A record of .eh_frame marks
 * its targets (its LSDA) only when its function is live, and the loader
 * applies no relocation of a dead record. So a dead function can name a
 * symbol that the program does not have, as in a static link. */
static int is_c_name(const char *s)
{
    if (!*s)
        return 0;
    for (; *s; s++)
        if (!((*s >= 'a' && *s <= 'z') || (*s >= 'A' && *s <= 'Z') || (*s >= '0' && *s <= '9') || *s == '_'))
            return 0;
    return 1;
}

/* The section that defines the symbol I, or -1. */
static int sym_section(bcn_load_t *l, size_t i)
{
    uint32_t x = sym_shndx(l, i);
    return x != BCN_SHN_UNDEF && x < l->nsec ? (int)x : -1;
}

/* The record of R that holds the offset OFF. */
static size_t eh_record_of(const struct bcn_eh_records *r, uint64_t off)
{
    size_t lo = 0, hi = r->n;
    while (hi - lo > 1) {
        size_t mid = lo + (hi - lo) / 2;
        if (r->start[mid] <= off)
            lo = mid;
        else
            hi = mid;
    }
    return lo;
}

/* The records of the .eh_frame section E: the start of each one. A
 * record of a broken section ends the list (eh_frame_walk refuses the
 * section later). */
static int eh_records_of(bcn_load_t *l, unsigned e)
{
    const uint8_t *p = l->bytes + l->sh[e].sh_offset;
    size_t size = l->sh[e].sh_type == BCN_SHT_NOBITS ? 0 : (size_t)l->sh[e].sh_size, pos = 0, n = 0;
    struct bcn_eh_records *r = &l->eh_records[e];

    while (pos + 4 <= size) {
        uint32_t len = get32(p + pos);
        if (len == 0 || len == 0xffffffffu || len > size - pos - 4)
            break;
        n++;
        pos += 4 + (size_t)len;
    }
    r->start = calloc(n ? n : 1, sizeof(*r->start));
    r->live = calloc(n ? n : 1, 1);
    if (!r->start || !r->live)
        return fail(l, "no memory");
    for (pos = 0, r->n = 0; r->n < n; r->n++) {
        r->start[r->n] = pos;
        pos += 4 + (size_t)get32(p + pos);
    }
    return 1;
}

static int bcn_gc(bcn_load_t *l)
{
    unsigned *stack = malloc((l->nsec + 1) * sizeof(*stack)), top = 0, i;
    int *rela_first = malloc((l->nsec + 1) * sizeof(int)), *rela_next = malloc((l->nsec + 1) * sizeof(int));
    int changed, ok = 0;
    size_t j;

    l->live = calloc(l->nsec, 1);
    l->eh_skip = calloc(l->nsec, sizeof(*l->eh_skip));
    l->eh_records = calloc(l->nsec, sizeof(*l->eh_records));
    if (!stack || !rela_first || !rela_next || !l->live || !l->eh_skip || !l->eh_records) {
        fail(l, "no memory");
        goto out;
    }
#define BCN_MARK(x)                                                                                \
    do {                                                                                           \
        unsigned m_ = (unsigned)(x);                                                               \
        if (!l->live[m_]) {                                                                        \
            l->live[m_] = 1;                                                                       \
            stack[top++] = m_;                                                                     \
        }                                                                                          \
    } while (0)
    for (i = 0; i < l->nsec; i++)
        rela_first[i] = -1;
    for (i = l->nsec; i-- > 0;)
        if (l->sh[i].sh_type == BCN_SHT_RELA) {
            rela_next[i] = rela_first[l->sh[i].sh_info];
            rela_first[l->sh[i].sh_info] = (int)i;
        }
    for (i = 0; i < l->nsec; i++) {
        const bcn_shdr *t = &l->sh[i];
        const char *name = sec_name(l, i);
        if (!(t->sh_flags & BCN_SHF_ALLOC) || (t->sh_flags & BCN_SHF_LINK_ORDER))
            continue;
        if (!strcmp(name, ".eh_frame")) {
            /* Live, but only its live records mark. */
            l->live[i] = 1;
            if (!eh_records_of(l, i))
                goto out;
            continue;
        }
        if (t->sh_type == BCN_SHT_INIT_ARRAY || t->sh_type == BCN_SHT_FINI_ARRAY ||
            t->sh_type == BCN_SHT_PREINIT_ARRAY || t->sh_type == 7 /* SHT_NOTE */ ||
            !strncmp(name, ".init_array", 11) || !strncmp(name, ".fini_array", 11) ||
            !strncmp(name, ".preinit_array", 14) || !strncmp(name, ".ctors", 6) ||
            !strncmp(name, ".dtors", 6) || (t->sh_flags & BCN_SHF_GNU_RETAIN) || is_c_name(name))
            BCN_MARK(i);
    }
    for (j = 1; j < l->nsyms; j++) {
        int bind = l->syms[j].st_info >> 4, x = sym_section(l, j);
        if ((bind == BCN_STB_GLOBAL || bind == BCN_STB_WEAK) && x >= 0)
            BCN_MARK(x);
    }
    do {
        changed = 0;
        while (top) {
            unsigned sec = stack[--top];
            int r;
            for (r = rela_first[sec]; r >= 0; r = rela_next[r]) {
                const bcn_rela *rel = (const bcn_rela *)(l->bytes + l->sh[r].sh_offset);
                size_t n = l->sh[r].sh_size / sizeof(bcn_rela);
                for (j = 0; j < n; j++) {
                    size_t si = (size_t)(rel[j].r_info >> 32);
                    int x = si < l->nsyms ? sym_section(l, si) : -1;
                    if (x >= 0)
                        BCN_MARK(x);
                }
            }
        }
        /* The records of .eh_frame: a CIE is live, and an FDE is live
         * when the section of its function (the target of its pc_begin,
         * at its offset 8) is live. */
        for (i = 0; i < l->nsec; i++) {
            struct bcn_eh_records *er = &l->eh_records[i];
            const uint8_t *p = l->bytes + l->sh[i].sh_offset;
            int r;
            if (!er->start)
                continue;
            for (r = rela_first[i]; r >= 0; r = rela_next[r]) {
                const bcn_rela *rel = (const bcn_rela *)(l->bytes + l->sh[r].sh_offset);
                size_t n = l->sh[r].sh_size / sizeof(bcn_rela);
                for (j = 0; j < n; j++) {
                    size_t si = (size_t)(rel[j].r_info >> 32), k;
                    int x = si < l->nsyms ? sym_section(l, si) : -1;
                    if (!er->n || rel[j].r_offset < er->start[0])
                        continue;
                    k = eh_record_of(er, rel[j].r_offset);
                    if (!er->live[k] && (get32(p + er->start[k] + 4) == 0 ||
                                         (rel[j].r_offset == er->start[k] + 8 && x >= 0 && l->live[x]))) {
                        er->live[k] = 1;
                        changed = 1;
                    }
                }
                /* The targets of the live records: a second loop, so
                 * a record that the first loop made live marks too. */
                for (j = 0; j < n; j++) {
                    size_t si = (size_t)(rel[j].r_info >> 32), k;
                    int x = si < l->nsyms ? sym_section(l, si) : -1;
                    if (!er->n || rel[j].r_offset < er->start[0] || x < 0)
                        continue;
                    k = eh_record_of(er, rel[j].r_offset);
                    if (er->live[k] && !l->live[x]) {
                        BCN_MARK(x);
                        changed = 1;
                    }
                }
            }
        }
        /* The sections with SHF_LINK_ORDER of the live sections. */
        for (i = 0; i < l->nsec; i++)
            if ((l->sh[i].sh_flags & BCN_SHF_ALLOC) && (l->sh[i].sh_flags & BCN_SHF_LINK_ORDER) &&
                !l->live[i] && l->sh[i].sh_link < l->nsec && l->live[l->sh[i].sh_link]) {
                BCN_MARK(i);
                changed = 1;
            }
    } while (changed || top);
#undef BCN_MARK
    /* The relocations of the dead records. */
    for (i = 0; i < l->nsec; i++) {
        const bcn_shdr *r = &l->sh[i];
        struct bcn_eh_records *er;
        const bcn_rela *rel;
        size_t n;
        if (r->sh_type != BCN_SHT_RELA || !l->eh_records[r->sh_info].start)
            continue;
        er = &l->eh_records[r->sh_info];
        rel = (const bcn_rela *)(l->bytes + r->sh_offset);
        n = r->sh_size / sizeof(bcn_rela);
        if (!(l->eh_skip[i] = calloc(n ? n : 1, 1))) {
            fail(l, "no memory");
            goto out;
        }
        for (j = 0; j < n; j++)
            l->eh_skip[i][j] = er->n && rel[j].r_offset >= er->start[0] &&
                               !er->live[eh_record_of(er, rel[j].r_offset)];
    }
    ok = 1;
out:
    free(stack);
    free(rela_first);
    free(rela_next);
    return ok;
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
            /* A TLS symbol: its address in the thread that loads, as
             * dlsym() gives. */
            if (l->tlssym[i])
                a += (uintptr_t)(beam_com_nif_tls + l->tls_off);
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
    unsigned i;
    if (l->eh_skip)
        for (i = 0; i < l->nsec; i++)
            free(l->eh_skip[i]);
    if (l->eh_records)
        for (i = 0; i < l->nsec; i++) {
            free(l->eh_records[i].start);
            free(l->eh_records[i].live);
        }
    free(l->eh_skip);
    free(l->eh_records);
    free(l->live);
    free(l->tlssym);
    free(l->tls_secoff);
    free(l->tls_image);
    free(l->tls_slots);
    free(l->seen);
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

/* Writes the TLS image of the module into the area of each thread of the
 * list. With SECOND, only into the threads that the first pass did not
 * see: the threads that started during the load. pthread_create() copies
 * the template before it puts the thread in the list, so a thread can be
 * in neither pass only when its start takes all of the load. */
static void tls_write_threads(bcn_load_t *l, int second)
{
    struct Dll *e;
    size_t k;

    _pthread_lock();
    for (e = dll_first(_pthread_list); e; e = dll_next(_pthread_list, e)) {
        struct PosixThread *pt = POSIXTHREAD_CONTAINER(e);
        for (k = 0; k < l->nseen && l->seen[k] != pt; k++)
            ;
        if (!pt->tib || (second && k < l->nseen))
            continue;
        memcpy(tls_pointer(pt->tib) + bcn_tls_tpoff + l->tls_off, l->tls_image, l->tls_size);
        if (!second && k == l->nseen && l->nseen < l->seen_cap)
            l->seen[l->nseen++] = pt;
    }
    _pthread_unlock();
}

/* The initial values of the TLS of the module: into the template of the
 * area (the threads that start later), and into the area of each thread
 * of the list. The template is in the read-only part of the program: its
 * pages stay writable after the first module with initial values that are
 * not zero. A system that refuses it (OpenBSD makes the program
 * immutable) refuses such a module. */
static int tls_install(bcn_load_t *l)
{
    unsigned char *t = bcn_tls_template + l->tls_off;
    size_t k;

    for (k = 0; k < l->tls_size && !l->tls_image[k]; k++)
        ;
    if (k < l->tls_size) {
        uintptr_t page = (uintptr_t)sysconf(_SC_PAGESIZE);
        uintptr_t a = (uintptr_t)t & ~(page - 1), b = (uintptr_t)t + l->tls_size;
        if (mprotect((void *)a, b - a, PROT_READ | PROT_WRITE))
            return fail(l, "the initial values of the thread-local data cannot go into the template: %s",
                        strerror(errno));
        memcpy(t, l->tls_image, l->tls_size);
    }
    l->seen_cap = (size_t)_pthread_count + 64;
    if (!(l->seen = malloc(l->seen_cap * sizeof(*l->seen))))
        return fail(l, "no memory");
    l->seen[l->nseen++] = _pthread_self();
    memcpy(beam_com_nif_tls + l->tls_off, l->tls_image, l->tls_size);
    tls_write_threads(l, 0);
    return 1;
}

#if defined(__x86_64__)
/* The TLS code of cosmocc reads the thread pointer with "mov %gs:0x30" (or
 * "add %gs:0x30"). Cosmopolitan changes these instructions in the program
 * on Windows (the TLS slot of the thread) and on OpenBSD and NetBSD (%fs)
 * at its start (__morph_tls): this does the same in the code of a
 * module, with the same pattern. */
static void tls_morph(uint8_t *p, size_t n)
{
    static const uint8_t mask[8] = { 0xff, 0xfb, 0xff, 0xc7, 0xff, 0xff, 0xff, 0xff };
    static const uint8_t mov[8] = { 0x65, 0x48, 0x8b, 0x04, 0x25, 0x30, 0, 0 };
    static const uint8_t add[8] = { 0x65, 0x48, 0x03, 0x04, 0x25, 0x30, 0, 0 };
    unsigned dis = 0x1480 + __tls_index * 8;
    uint8_t *end = p + n;
    int k, is_mov, is_add;

    if (!IsWindows() && !IsOpenbsd() && !IsNetbsd())
        return;
    for (; p + 9 <= end; p++) {
        if (p[0] != 0x65)
            continue;
        for (is_mov = is_add = 1, k = 0; k < 8; k++) {
            is_mov &= (p[k] & mask[k]) == mov[k];
            is_add &= (p[k] & mask[k]) == add[k];
        }
        if ((!is_mov && !is_add) || p[8])
            continue;
        if (IsWindows()) {
            p[5] = (uint8_t)dis;
            p[6] = (uint8_t)(dis >> 8);
            p[7] = (uint8_t)(dis >> 16);
            p[8] = (uint8_t)(dis >> 24);
        } else {
            p[0] = 0x64;
        }
        p += 8;
    }
}
#endif

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
    l.tlssym = calloc(l.nsyms, 1);
    l.tls_secoff = calloc(l.nsec, sizeof(*l.tls_secoff));
    if (!l.secaddr || !secoff || !l.symaddr || !l.resolved || !l.got || !l.stub || !l.common_off ||
        !l.tlssym || !l.tls_secoff) {
        fail(&l, "no memory");
        goto out;
    }
    if (!bcn_gc(&l) || !count_slots(&l, &common_size))
        goto out;

    /* The TLS image: the TLS sections, and the part of beam_com_nif_tls
     * of the module. */
    for (i = 0; i < l.nsec; i++) {
        const bcn_shdr *t = &l.sh[i];
        size_t a = t->sh_addralign ? (size_t)t->sh_addralign : 1;
        if (!l.live[i] || !(t->sh_flags & BCN_SHF_ALLOC) || !(t->sh_flags & BCN_SHF_TLS) || !t->sh_size)
            continue;
        l.tls_size = align_up(l.tls_size, a);
        l.tls_secoff[i] = l.tls_size;
        l.tls_size += t->sh_size;
        if (a > l.tls_align)
            l.tls_align = a;
    }
    if (l.tls_size) {
        if (!tls_ready()) {
            fail(&l, "thread-local data: %s", bcn_tls_why);
            goto out;
        }
        if (l.tls_size > BEAM_COM_NIF_TLS_SIZE || !(l.tls_image = calloc(1, l.tls_size))) {
            fail(&l, "the thread-local data of the object is larger than %d bytes", BEAM_COM_NIF_TLS_SIZE);
            goto out;
        }
        pthread_mutex_lock(&bcn_tls_lock);
        l.tls_off = align_up(bcn_tls_used, l.tls_align);
        if (l.tls_off + l.tls_size <= BEAM_COM_NIF_TLS_SIZE)
            bcn_tls_used = l.tls_off + l.tls_size;
        pthread_mutex_unlock(&bcn_tls_lock);
        if (l.tls_off + l.tls_size > BEAM_COM_NIF_TLS_SIZE) {
            fail(&l, "the thread-local data of the NIF objects is larger than %d bytes in all",
                 BEAM_COM_NIF_TLS_SIZE);
            goto out;
        }
        for (i = 0; i < l.nsec; i++) {
            const bcn_shdr *t = &l.sh[i];
            if (!l.live[i] || !(t->sh_flags & BCN_SHF_ALLOC) || !(t->sh_flags & BCN_SHF_TLS) || !t->sh_size)
                continue;
            l.secaddr[i] = (uintptr_t)(l.tls_image + l.tls_secoff[i]);
            if (t->sh_type != BCN_SHT_NOBITS)
                memcpy(l.tls_image + l.tls_secoff[i], bytes + t->sh_offset, t->sh_size);
        }
    }

    /* The layout: the offset of each section in its group. */
    for (i = 0; i < l.nsec; i++) {
        int g = sec_group(&l, i);
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
        int g = sec_group(&l, i);
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
            if (!(l.eh_skip[i] && l.eh_skip[i][j]) &&
                !relocate(&l, &l.sh[r->sh_info], l.secaddr[r->sh_info], &rel[j]))
                break;
        if (j < n)
            break;
    }
    if (i < l.nsec) {
        if (l.jit)
            __jit_end();
        goto out;
    }
#if defined(__x86_64__)
    if (l.tls_size)
        tls_morph(m->code, (size_t)off[0]);
#endif
    if (l.jit)
        __jit_end();
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
            size_t n, k, base;
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
            for (k = 0, base = m->nfdes; k < n; k++) {
                const struct bcn_eh_records *er = &l.eh_records[i];
                uintptr_t off = fdes[base + k];
                /* The record of a dead function has no relocations. */
                if (er->n && !er->live[eh_record_of(er, off)])
                    continue;
                fdes[m->nfdes] = off + l.secaddr[i];
                __unw_add_dynamic_fde(fdes[m->nfdes]);
                m->nfdes++;
            }
        }
    }
    if (l.tls_size && !tls_install(&l))
        goto out;
    if (bcn_constructors)
        run_constructors(&l);
    if (l.tls_size)
        tls_write_threads(&l, 1);
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
