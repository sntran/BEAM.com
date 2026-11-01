/* The calls of a Rust staticlib (target *-unknown-linux-musl) to the C
 * library, translated for Cosmopolitan.
 *
 * The std of Rust for musl has the numbers of Linux in its code: the
 * clocks, errno, the flags of open() and mmap(), the keys of getauxval(),
 * and the futex as a system call. Cosmopolitan sets these values for each
 * system at run time, and has no system call futex outside Linux. The
 * pthread_attr_t of musl has 56 bytes, and that of Cosmopolitan 64.
 *
 * objcopy --redefine-sym gives each call below its beam_rs_ name in the
 * objects of the Rust archive. The other calls go to Cosmopolitan as they
 * are. */
#include <cosmo.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/mman.h>
#include <sys/random.h>
#include <time.h>
#include <unistd.h>

long syscall(long, ...); /* Linux only: Cosmopolitan has no header for it */

/* errno: the value of Cosmopolitan for this system, as a number of Linux. */
static int linux_errno(int e) {
  static const struct { const errno_t *host; int linux; } map[] = {
      {&EPERM, 1},    {&ENOENT, 2},   {&ESRCH, 3},      {&EINTR, 4},     {&EIO, 5},
      {&ENXIO, 6},    {&E2BIG, 7},    {&ENOEXEC, 8},    {&EBADF, 9},     {&ECHILD, 10},
      {&EAGAIN, 11},  {&ENOMEM, 12},  {&EACCES, 13},    {&EFAULT, 14},   {&EBUSY, 16},
      {&EEXIST, 17},  {&EXDEV, 18},   {&ENODEV, 19},    {&ENOTDIR, 20},  {&EISDIR, 21},
      {&EINVAL, 22},  {&ENFILE, 23},  {&EMFILE, 24},    {&ENOTTY, 25},   {&EFBIG, 27},
      {&ENOSPC, 28},  {&ESPIPE, 29},  {&EROFS, 30},     {&EMLINK, 31},   {&EPIPE, 32},
      {&EDOM, 33},    {&ERANGE, 34},  {&EDEADLK, 35},   {&ENAMETOOLONG, 36},
      {&ENOSYS, 38},  {&ENOTEMPTY, 39}, {&ELOOP, 40},   {&EOVERFLOW, 75},
      {&ENOTSUP, 95}, {&EADDRINUSE, 98}, {&ECONNREFUSED, 111},
      {&ETIMEDOUT, 110}, {&EINPROGRESS, 115},
  };
  for (size_t i = 0; i < sizeof(map) / sizeof(map[0]); i++)
    if (*map[i].host == e) return map[i].linux;
  return e;
}

static _Thread_local int last_errno = -1;

int *beam_rs___errno_location(void) {
  /* Rust reads errno just after a failed call. The value is translated
   * once: a second read of the same value keeps it. */
  int *e = __errno_location();
  if (*e != last_errno) last_errno = *e = linux_errno(*e);
  return e;
}

static void set_linux_errno(int linux) { last_errno = *__errno_location() = linux; }

/* The clocks of Linux. */
static int host_clock(int linux) {
  switch (linux) {
    case 0: return CLOCK_REALTIME;
    case 1: return CLOCK_MONOTONIC;
    case 2: return CLOCK_PROCESS_CPUTIME_ID;
    case 3: return CLOCK_THREAD_CPUTIME_ID;
    case 4: return CLOCK_MONOTONIC_RAW;
    case 5: return CLOCK_REALTIME_COARSE;
    case 6: return CLOCK_MONOTONIC_COARSE;
    case 7: return CLOCK_BOOTTIME;
    default: return -1;
  }
}

int beam_rs_clock_gettime(int clock, struct timespec *ts) {
  int c = host_clock(clock);
  if (c == -1) return set_linux_errno(22), -1;
  return clock_gettime(c, ts);
}

int beam_rs_clock_nanosleep(int clock, int flags, const struct timespec *t, struct timespec *rem) {
  int c = host_clock(clock);
  if (c == -1) return 22;
  int r = clock_nanosleep(c, flags, t, rem); /* TIMER_ABSTIME is 1 everywhere */
  return r ? linux_errno(r) : 0;
}

/* syscall(): the futex and getrandom on each system, else Linux only. */
#ifdef __x86_64__
#define SYS_FUTEX 202
#define SYS_GETRANDOM 318
#else
#define SYS_FUTEX 98
#define SYS_GETRANDOM 278
#endif

long beam_rs_syscall(long n, long a, long b, long c, long d, long e, long f) {
  if (n == SYS_FUTEX) {
    int op = b & ~128; /* FUTEX_PRIVATE_FLAG */
    if (op == 0 || op == 9) { /* FUTEX_WAIT, FUTEX_WAIT_BITSET (absolute, monotonic) */
      struct timespec abs, *t = (struct timespec *)d;
      if (t && op == 0) { /* FUTEX_WAIT has a relative time */
        clock_gettime(CLOCK_MONOTONIC, &abs);
        abs.tv_sec += t->tv_sec;
        abs.tv_nsec += t->tv_nsec;
        if (abs.tv_nsec >= 1000000000) abs.tv_sec++, abs.tv_nsec -= 1000000000;
        t = &abs;
      }
      int r = cosmo_futex_wait((_Atomic(int) *)a, (int)c, 0, CLOCK_MONOTONIC, t);
      if (r < 0) return set_linux_errno(linux_errno(-r)), -1;
      return 0;
    }
    if (op == 1) { /* FUTEX_WAKE */
      int r = cosmo_futex_wake((_Atomic(int) *)a, (int)c, 0);
      return r < 0 ? 0 : r;
    }
    return set_linux_errno(38), -1;
  }
  if (n == SYS_GETRANDOM) {
    ssize_t r = getrandom((void *)a, (size_t)b, 0);
    return r < 0 ? (set_linux_errno(linux_errno(errno)), -1) : r;
  }
  if (IsLinux()) return syscall(n, a, b, c, d, e, f);
  return set_linux_errno(38), -1;
}

/* pthread_attr_t: Rust gives 56 bytes. They keep a pointer to the
 * pthread_attr_t of Cosmopolitan (64 bytes). */
struct boxed_attr { uint64_t magic; pthread_attr_t *real; };
#define BOXED 0x6265616d61747472ull /* "beamattr" */

static pthread_attr_t *unbox(void *attr) {
  struct boxed_attr *b = attr;
  return b && b->magic == BOXED ? b->real : NULL;
}

int beam_rs_pthread_attr_init(void *attr) {
  struct boxed_attr *b = attr;
  pthread_attr_t *real = malloc(sizeof(pthread_attr_t));
  if (!real) return 12;
  int r = pthread_attr_init(real);
  if (r) return free(real), linux_errno(r);
  b->magic = BOXED;
  b->real = real;
  return 0;
}

int beam_rs_pthread_attr_destroy(void *attr) {
  pthread_attr_t *real = unbox(attr);
  if (!real) return 22;
  pthread_attr_destroy(real);
  free(real);
  ((struct boxed_attr *)attr)->magic = 0;
  return 0;
}

int beam_rs_pthread_attr_setstacksize(void *attr, size_t size) {
  pthread_attr_t *real = unbox(attr);
  return real ? linux_errno(pthread_attr_setstacksize(real, size)) : 22;
}

int beam_rs_pthread_attr_getstack(void *attr, void **addr, size_t *size) {
  pthread_attr_t *real = unbox(attr);
  return real ? linux_errno(pthread_attr_getstack(real, addr, size)) : 22;
}

int beam_rs_pthread_attr_getguardsize(void *attr, size_t *size) {
  pthread_attr_t *real = unbox(attr);
  return real ? linux_errno(pthread_attr_getguardsize(real, size)) : 22;
}

int beam_rs_pthread_getattr_np(pthread_t thread, void *attr) {
  int r = beam_rs_pthread_attr_init(attr);
  if (r) return r;
  return linux_errno(pthread_getattr_np(thread, unbox(attr)));
}

int beam_rs_pthread_create(pthread_t *t, void *attr, void *(*fn)(void *), void *arg) {
  return linux_errno(pthread_create(t, attr ? unbox(attr) : NULL, fn, arg));
}

/* open() and openat(): the flags of Linux. */
static int host_oflags(int f) {
  int r = f & 3; /* O_RDONLY, O_WRONLY, O_RDWR */
  if (f & 0x40) r |= O_CREAT;
  if (f & 0x80) r |= O_EXCL;
  if (f & 0x200) r |= O_TRUNC;
  if (f & 0x400) r |= O_APPEND;
  if (f & 0x800) r |= O_NONBLOCK;
  if (f & 0x10000) r |= O_DIRECTORY;
  if (f & 0x20000) r |= O_NOFOLLOW;
  if (f & 0x80000) r |= O_CLOEXEC;
  return r;
}

int beam_rs_open(const char *path, int flags, ...) {
  va_list va;
  va_start(va, flags);
  unsigned mode = va_arg(va, unsigned);
  va_end(va);
  int r = open(path, host_oflags(flags), mode);
  if (r < 0) set_linux_errno(linux_errno(errno));
  return r;
}

int beam_rs_openat(int dir, const char *path, int flags, ...) {
  va_list va;
  va_start(va, flags);
  unsigned mode = va_arg(va, unsigned);
  va_end(va);
  int r = openat(dir == -100 ? AT_FDCWD : dir, path, host_oflags(flags), mode);
  if (r < 0) set_linux_errno(linux_errno(errno));
  return r;
}

/* mmap(): the flags of Linux. PROT_* are the same everywhere. */
void *beam_rs_mmap(void *addr, size_t len, int prot, int flags, int fd, long off) {
  int f = 0;
  if (flags & 0x01) f |= MAP_SHARED;
  if (flags & 0x02) f |= MAP_PRIVATE;
  if (flags & 0x10) f |= MAP_FIXED;
  if (flags & 0x20) f |= MAP_ANONYMOUS;
  if (flags & 0x4000) f |= MAP_NORESERVE;
  /* MAP_STACK (0x20000) is a hint: Cosmopolitan has none. */
  void *r = mmap(addr, len, prot, f, fd, off);
  if (r == MAP_FAILED) set_linux_errno(linux_errno(errno));
  return r;
}

/* getauxval(): the keys of Linux. */
unsigned long beam_rs_getauxval(unsigned long key) {
  switch (key) {
    case 6: return getauxval(AT_PAGESZ);
    case 16: return getauxval(AT_HWCAP);
    case 26: return getauxval(AT_HWCAP2);
    default: return 0;
  }
}

/* sched_getaffinity(): the cpu_set_t of musl differs. A failure makes Rust
 * take the number of CPUs from sysconf(), whose keys are the same. */
int beam_rs_sched_getaffinity(int pid, size_t size, void *set) {
  (void)pid, (void)size, (void)set;
  return set_linux_errno(38), -1;
}
