// The native loader of Windows on ARM64 for the aarch64 half of an APE
// file (the model of ape-m1.c for macOS). The x86_64 half of an APE file
// is a program of Windows (PE), which Windows on ARM64 runs under its
// x64 emulation. This loader runs the aarch64 half as native code.
//
//   ape-arm64.exe PROGRAM [ARGUMENTS]
//
// It finds the aarch64 ELF header in the shell header of PROGRAM, maps
// the PT_LOAD segments at their fixed addresses, and starts the program
// with the System V stack block. The program gets the pointer to
// struct WinLib in x15, and the number 4 (_HOSTWINDOWS) in x3. The libc
// of the program must have the Windows layer for aarch64
// (patches/cosmo-libc): it fills its import slots with the two
// functions of struct WinLib.
//
// The environment:
//   _APE_FORK         the address of the start function of a child of
//                     fork(), from the parent (see below)
//   APE_ARM64_DEBUG   a report for each exception, also an exception
//                     that the program handles
//
// The file needs no C library: clang --target=aarch64-pc-windows-msvc
// -ffreestanding, with an import library that llvm-dlltool makes
// (build_arm64_loader in scripts/steps.sh).
typedef unsigned long long u64;
typedef long long i64;
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;
typedef void *HANDLE;
typedef u16 wchar;

#define IMP __declspec(dllimport)
IMP wchar *GetCommandLineW(void);
IMP wchar **CommandLineToArgvW(const wchar *, int *);
IMP wchar *GetEnvironmentStringsW(void);
IMP int WideCharToMultiByte(u32, u32, const wchar *, int, char *, int, const char *, int *);
IMP HANDLE CreateFileW(const wchar *, u32, u32, void *, u32, u32, HANDLE);
IMP int ReadFile(HANDLE, void *, u32, u32 *, void *);
IMP int SetFilePointerEx(HANDLE, i64, i64 *, u32);
IMP int CloseHandle(HANDLE);
IMP void *VirtualAlloc(void *, u64, u32, u32);
IMP int VirtualProtect(void *, u64, u32, u32 *);
IMP u64 VirtualQuery(const void *, void *, u64);
IMP int FlushInstructionCache(HANDLE, const void *, u64);
IMP HANDLE GetCurrentProcess(void);
IMP HANDLE GetStdHandle(u32);
IMP int WriteFile(HANDLE, const void *, u32, u32 *, void *);
IMP void ExitProcess(u32);
IMP u32 GetLastError(void);
IMP void *LoadLibraryA(const char *);
IMP void *GetProcAddress(void *, const char *);
IMP u32 GetEnvironmentVariableW(const wchar *, wchar *, u32);
IMP void *AddVectoredExceptionHandler(u32, long (*)(void *));
IMP void *SetUnhandledExceptionFilter(long (*)(void *));

struct WinLib {
  u32 magic;
  u32 version;
  void *(*LoadLibraryA)(const char *);
  void *(*GetProcAddress)(void *, const char *);
};

struct Ehdr {
  u8 e_ident[16];
  u16 e_type, e_machine;
  u32 e_version;
  u64 e_entry, e_phoff, e_shoff;
  u32 e_flags;
  u16 e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx;
};

struct Phdr {
  u32 p_type, p_flags;
  u64 p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align;
};

#define PT_LOAD 1
#define PF_X 1
#define PF_W 2
#define EM_AARCH64 183
#define MAXPH 32

static struct WinLib lib;
static struct Phdr ph[MAXPH];
static char arena[1 << 20];
static u64 used;

// clang makes calls to these functions.
void *memset(void *d, int c, u64 n) {
  volatile char *p = d;
  while (n--) *p++ = c;
  return d;
}
void *memcpy(void *d, const void *s, u64 n) {
  volatile char *p = d;
  const char *q = s;
  while (n--) *p++ = *q++;
  return d;
}
// The stack is committed (/stack:RESERVE,COMMIT), so no probe is necessary.
__attribute__((naked)) void __chkstk(void) { __asm__("ret"); }

static u64 Len(const char *s) {
  u64 n = 0;
  while (s[n]) ++n;
  return n;
}

static void Print(const char *s) {
  u32 n;
  WriteFile(GetStdHandle((u32)-12), s, (u32)Len(s), &n, 0);
}

static void PrintHex(u64 x) {
  char b[19] = "0x";
  int i;
  for (i = 0; i < 16; ++i) b[2 + i] = "0123456789abcdef"[(x >> (60 - 4 * i)) & 15];
  b[18] = 0;
  Print(b);
}

__attribute__((noreturn)) static void Die(const char *what, u64 x) {
  Print("ape-arm64: ");
  Print(what);
  Print(" ");
  PrintHex(x);
  Print(" (error ");
  PrintHex(GetLastError());
  Print(")\n");
  ExitProcess(127);
  for (;;) {
  }
}

// The exception data of Windows on ARM64.
struct Exception {
  struct {
    u32 code, flags;
    void *next, *address;
    u32 count, pad;
    u64 info[15];
  } *record;
  struct {
    u32 flags, cpsr;
    u64 x[31], sp, pc;
  } *context;
};

static u64 image_lo, image_hi;

static void PrintException(const char *what, struct Exception *e) {
  Print("ape-arm64: ");
  Print(what);
  Print(" code ");
  PrintHex(e->record->code);
  Print(" pc ");
  PrintHex(e->context->pc);
  Print(" lr ");
  PrintHex(e->context->x[30]);
  Print(" sp ");
  PrintHex(e->context->sp);
  if (e->record->count >= 2) {
    Print(e->record->info[0] == 1 ? " write of " : e->record->info[0] == 8 ? " execute of " : " read of ");
    PrintHex(e->record->info[1]);
  }
  Print("\n  x0-x3 ");
  for (int i = 0; i < 4; ++i) PrintHex(e->context->x[i]), Print(" ");
  Print("x16 ");
  PrintHex(e->context->x[16]);
  Print(" x28 ");
  PrintHex(e->context->x[28]);
  Print(" fp ");
  PrintHex(e->context->x[29]);
  Print("\n  image ");
  PrintHex(image_lo);
  Print(" to ");
  PrintHex(image_hi);
  // The return addresses of the frame chain (fp, lr pairs).
  Print("\n  frames");
  u64 *fp = (u64 *)e->context->x[29];
  char mi[48];
  for (int i = 0; i < 16 && fp && !((u64)fp & 7); ++i) {
    if (!VirtualQuery(fp, mi, sizeof(mi)) || *(u32 *)(mi + 32) != 0x1000) break;
    Print(" ");
    PrintHex(fp[1]);
    fp = (u64 *)fp[0];
  }
  Print("\n");
}

// With APE_ARM64_DEBUG, each exception gives one report, also an
// exception that the program handles.
static long OnEachException(void *e) {
  PrintException("exception", e);
  return 0;  // EXCEPTION_CONTINUE_SEARCH
}

static long OnLastException(void *e) {
  PrintException("the program stopped:", e);
  ExitProcess(128 + 11);
  return 0;
}

static char *Utf8(const wchar *w) {
  int room = (int)(sizeof(arena) - used);
  int n = WideCharToMultiByte(65001, 0, w, -1, arena + used, room, 0, 0);
  char *s = arena + used;
  if (n <= 0) Die("a string is too long, at", used);
  used += n;
  return s;
}

static void ReadAt(HANDLE f, u64 off, void *buf, u64 size) {
  u32 got;
  char *p = buf;
  if (!SetFilePointerEx(f, (i64)off, 0, 0)) Die("seek to", off);
  while (size) {
    u32 want = size > (1u << 30) ? (1u << 30) : (u32)size;
    if (!ReadFile(f, p, want, &got, 0) || !got) Die("read at", off);
    p += got;
    size -= got;
  }
}

static int IsPrintf(const char *s) {
  const char *k = "printf '";
  int i;
  for (i = 0; i < 8; ++i)
    if (s[i] != k[i]) return 0;
  return 1;
}

// The ELF header of the aarch64 half: a printf statement of the shell
// header has it, with octal escapes (as ape-m1.c reads it).
static int FindEhdr(const char *buf, u64 size, struct Ehdr *e) {
  u64 p, i;
  char out[sizeof(struct Ehdr)];
  for (p = 0; p + 8 < size; ++p) {
    if (!IsPrintf(buf + p)) continue;
    i = 0;
    u64 q = p + 8;
    while (q + 3 < size && i < sizeof(out)) {
      int c = (u8)buf[q++];
      if (c == '\'') break;
      if (c == '\\' && buf[q] >= '0' && buf[q] <= '7') {
        c = buf[q++] - '0';
        if (buf[q] >= '0' && buf[q] <= '7') {
          c = c * 8 + buf[q++] - '0';
          if (buf[q] >= '0' && buf[q] <= '7') c = c * 8 + buf[q++] - '0';
        }
      }
      out[i++] = (char)c;
    }
    if (i < sizeof(out)) continue;
    memcpy(e, out, sizeof(out));
    if (e->e_ident[0] == 127 && e->e_ident[1] == 'E' && e->e_ident[2] == 'L' &&
        e->e_ident[3] == 'F' && e->e_machine == EM_AARCH64 &&
        e->e_phentsize == sizeof(struct Phdr) && e->e_phnum && e->e_phnum <= MAXPH)
      return 1;
  }
  return 0;
}

__attribute__((naked, noreturn)) static void Launch(u64 entry, u64 sp, u64 winlib,
                                                    u64 exename, u64 os) {
  __asm__("mov x16, x0\n"
          "mov sp, x1\n"
          "mov x15, x2\n"
          "mov x1, x2\n"
          "mov x2, x3\n"
          "mov x3, x4\n"
          "mov x0, #0\n"
          "mov x29, #0\n"
          "mov x30, #0\n"
          "br x16\n");
}

void Entry(void) {
  __attribute__((aligned(16))) i64 block[4096];
  static char head[8192];
  struct Ehdr e;
  int argc, i, n = 0;
  u32 got, old;
  u64 lo = ~0ull, hi = 0;
  lib.magic = 0x57494e41;  // "WINA"
  lib.version = 1;
  lib.LoadLibraryA = LoadLibraryA;
  lib.GetProcAddress = GetProcAddress;
  SetUnhandledExceptionFilter(OnLastException);

  // A child of fork(): the parent wrote the memory of the program into
  // this process. The variable _APE_FORK has the address of the start
  // function of the child, as 16 hexadecimal digits.
  wchar child[20];
  if (GetEnvironmentVariableW(L"_APE_FORK", child, 20) == 16) {
    u64 addr = 0;
    for (i = 0; i < 16; ++i) {
      addr = addr << 4 | (child[i] <= '9' ? child[i] - '0' : child[i] - 'a' + 10);
    }
    ((void (*)(struct WinLib *))addr)(&lib);
    ExitProcess(127);
  }

  wchar **wargv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!wargv || argc < 2) {
    Print("usage: ape-arm64.exe PROGRAM [ARGUMENTS]\n");
    ExitProcess(2);
  }
  HANDLE f = CreateFileW(wargv[1], 0x80000000u, 7, 0, 3, 0, 0);
  if (f == (HANDLE)-1) Die("cannot open the program", 0);
  if (!ReadFile(f, head, sizeof(head), &got, 0)) Die("read the header", 0);
  if (!FindEhdr(head, got, &e)) Die("no aarch64 ELF header in the first bytes:", got);
  ReadAt(f, e.e_phoff, ph, (u64)e.e_phnum * sizeof(struct Phdr));
  for (i = 0; i < e.e_phnum; ++i) {
    if (ph[i].p_type != PT_LOAD || !ph[i].p_memsz) continue;
    u64 a = ph[i].p_vaddr & ~0xffffull;
    u64 b = (ph[i].p_vaddr + ph[i].p_memsz + 0xffff) & ~0xffffull;
    if (a < lo) lo = a;
    if (b > hi) hi = b;
  }
  if (lo >= hi) Die("no PT_LOAD segment", 0);
  // One reservation for the image. The fixed addresses of the program
  // must be free: Windows gives memory at an address of 64 KiB.
  if (VirtualAlloc((void *)lo, hi - lo, 0x3000, 4) != (void *)lo) Die("cannot map the image at", lo);
  image_lo = lo, image_hi = hi;
  wchar debug[4];
  if (GetEnvironmentVariableW(L"APE_ARM64_DEBUG", debug, 4)) AddVectoredExceptionHandler(1, OnEachException);
  for (i = 0; i < e.e_phnum; ++i) {
    if (ph[i].p_type != PT_LOAD || !ph[i].p_filesz) continue;
    ReadAt(f, ph[i].p_offset, (void *)ph[i].p_vaddr, ph[i].p_filesz);
  }
  for (i = 0; i < e.e_phnum; ++i) {
    if (ph[i].p_type != PT_LOAD || !ph[i].p_memsz) continue;
    u64 a = ph[i].p_vaddr & ~0xfffull;
    u64 b = (ph[i].p_vaddr + ph[i].p_memsz + 0xfff) & ~0xfffull;
    u32 prot = ph[i].p_flags & PF_X ? (ph[i].p_flags & PF_W ? 0x40 : 0x20)
                                    : (ph[i].p_flags & PF_W ? 4 : 2);
    if (!VirtualProtect((void *)a, b - a, prot, &old)) Die("cannot protect", a);
    if (ph[i].p_flags & PF_X) FlushInstructionCache(GetCurrentProcess(), (void *)a, b - a);
  }
  CloseHandle(f);

  // The System V block: argc, argv, 0, envp, 0, auxv.
  char *exe = Utf8(wargv[1]);
  block[n++] = argc - 1;
  block[n++] = (i64)exe;
  for (i = 2; i < argc; ++i) block[n++] = (i64)Utf8(wargv[i]);
  block[n++] = 0;
  wchar *env = GetEnvironmentStringsW();
  while (env && *env && n < 4000) {
    block[n++] = (i64)Utf8(env);
    while (*env) ++env;
    ++env;
  }
  block[n++] = 0;
  block[n++] = 3, block[n++] = (i64)ph;              // AT_PHDR
  block[n++] = 4, block[n++] = sizeof(struct Phdr);  // AT_PHENT
  block[n++] = 5, block[n++] = e.e_phnum;            // AT_PHNUM
  block[n++] = 9, block[n++] = (i64)e.e_entry;       // AT_ENTRY
  block[n++] = 6, block[n++] = 4096;                 // AT_PAGESZ
  block[n++] = 31, block[n++] = (i64)exe;            // AT_EXECFN
  block[n++] = 0, block[n++] = 0;

  Launch(e.e_entry, (u64)block, (u64)&lib, (u64)exe, 4);
}
