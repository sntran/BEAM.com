// The check of the libc for Windows on ARM64 (win_arm64_check.com): a
// normal C program. Its aarch64 half has the libc of Cosmopolitan with
// the Windows layer of patches/cosmo-libc. On Windows on ARM64, the
// x86_64 half starts the loader ape-arm64.exe of its zip, and the loader
// starts the aarch64 half through the normal start code (_start, cosmo,
// main). APE_NO_ARM64=1 keeps the x86_64 half.
//
// Each check prints one line. The exit status is the number of the
// checks that fail. The same file also runs on the other systems.
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <setjmp.h>
#include <netinet/in.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "libc/dce.h"
#include "libc/nt/dll.h"
#include "libc/runtime/runtime.h"

__static_yoink("zipos");

static int failures;

static void Check(const char *what, int ok) {
  printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
  failures += !ok;
}

#ifdef __x86_64__
// On Windows on ARM64 (this half runs under the x64 emulation): start
// the native loader with this file. It returns only when that fails.
static void TryNativeArm64(int argc, char **argv) {
  typedef int __attribute__((__ms_abi__)) IsWow64Process2_f(int64_t, uint16_t *, uint16_t *);
  IsWow64Process2_f *f = (void *)GetProcAddress(GetModuleHandle("kernel32.dll"), "IsWow64Process2");
  uint16_t process = 0, native = 0;
  if (!f || !f(-1, &process, &native) || native != 0xAA64) return;
  if (getenv("APE_NO_ARM64")) return;

  // The loader, from the zip of this file to a file of its size.
  char loader[512], self[512];
  struct stat st;
  const char *tmp = getenv("TEMP") ? getenv("TEMP") : ".";
  if (stat("/zip/ape-arm64.exe", &st)) return;
  snprintf(loader, sizeof(loader), "%s/.ape-arm64-%ld.exe", tmp, (long)st.st_size);
  if (access(loader, X_OK)) {
    char *data = malloc(st.st_size);
    int in = open("/zip/ape-arm64.exe", O_RDONLY);
    int out = open(loader, O_WRONLY | O_CREAT | O_TRUNC, 0755);
    if (in < 0 || out < 0 || read(in, data, st.st_size) != st.st_size ||
        write(out, data, st.st_size) != st.st_size) {
      fprintf(stderr, "cannot write %s: %s\n", loader, strerror(errno));
      return;
    }
    close(in), close(out), free(data);
  }

  // The path of this file for Windows: /C/dir/file is C:/dir/file.
  strlcpy(self, GetProgramExecutableName(), sizeof(self));
  if (self[0] == '/' && self[1] && self[2] == '/') self[0] = self[1], self[1] = ':';
  char **args = calloc(argc + 2, sizeof(char *));
  args[0] = loader, args[1] = self;
  for (int i = 1; i < argc; ++i) args[i + 1] = argv[i];
  execv(loader, args);
  fprintf(stderr, "cannot start %s: %s\n", loader, strerror(errno));
}
#endif

static void *Worker(void *arg) {
  long sum = 0;
  for (long i = 1; i <= (long)arg; ++i) sum += i;
  return (void *)sum;
}

static volatile int got_signal;
static sigjmp_buf jb;

static void OnUsr1(int sig) {
  got_signal = sig;
}

static void OnSegv(int sig) {
  siglongjmp(jb, sig);
}

// Floating point work that a signal can stop: about 1 ms.
static double Work(void) {
  double sum = 0;
  for (long i = 1; i <= 200000; ++i) sum += sqrt((double)i) * 1.000001;
  return sum;
}

// A signal handler that changes the vector registers.
static volatile int ticks;
static void OnTick(int sig) {
  char buf[256];
  volatile double a = 1.5;
  memset(buf, ticks, sizeof(buf));
  for (int i = 0; i < 64; ++i) a = a * 1.0000001 + buf[i];
  ++ticks;
}

static volatile int work_stop, work_bad;
static double work_expect;
static void *Worker2(void *arg) {
  while (!work_stop) {
    if (Work() != work_expect) work_bad = 1;
  }
  return 0;
}

static void *Server(void *arg) {
  char buf[16];
  int fd = accept((int)(long)arg, 0, 0);
  if (fd < 0) return 0;
  long n = read(fd, buf, sizeof(buf));
  if (n > 0) write(fd, buf, n);
  close(fd);
  return (void *)n;
}

// The checks have numbers. A check that is not in the list of the
// second argument does not run: thus a run can go around a crash.
static int Wanted(const char *list, int n) {
  char word[8];
  if (!list) return 1;
  snprintf(word, sizeof(word), ",%d,", n);
  return !!strstr(list, word);
}

int main(int argc, char **argv) {
#ifdef __x86_64__
  if (IsWindows()) TryNativeArm64(argc, argv);
  const char *half = "x86_64";
  int half_code = 8;
#else
  const char *half = "aarch64";
  int half_code = 9;
#endif
  // The child of check 12: its exit status tells its half.
  if (argc == 2 && !strcmp(argv[1], "--child")) return half_code;
  const char *os = IsWindows() ? "Windows" : IsXnu() ? "macOS" : IsLinux() ? "Linux" : "a BSD";
  const char *list = getenv("CHECKS");  // for example ",1,2,5,"
  setvbuf(stdout, 0, _IONBF, 0);
  printf("hello from the %s half on %s (printf of the libc of Cosmopolitan)\n", half, os);
  printf("  argc=%d", argc);
  for (int i = 0; i < argc; ++i) printf(" [%s]", argv[i]);
  printf("\n  program=%s\n  pid=%d pagesize=%d\n", GetProgramExecutableName(), getpid(),
         getpagesize());

  if (Wanted(list, 1)) {
    Check("1 arguments: argv[1] is one, argv[2] is two words",
          argc == 3 && !strcmp(argv[1], "one") && !strcmp(argv[2], "two words"));
  }

  if (Wanted(list, 2)) {
    const char *path = getenv("PATH");
    Check("2 environment: PATH is there", path && *path);
  }

  if (Wanted(list, 3)) {
    char *p = malloc(8 << 20);
    int ok = p != 0;
    if (ok) memset(p, 7, 8 << 20), ok = p[(8 << 20) - 1] == 7;
    free(p);
    char *q = mmap(0, 1 << 20, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    ok = ok && q != MAP_FAILED;
    if (q != MAP_FAILED) q[(1 << 20) - 1] = 1, ok = ok && !munmap(q, 1 << 20);
    Check("3 memory: malloc of 8 MiB, mmap and munmap of 1 MiB", ok);
  }

  if (Wanted(list, 4)) {
    struct timespec a, b, real;
    clock_gettime(CLOCK_REALTIME, &real);
    clock_gettime(CLOCK_MONOTONIC, &a);
    usleep(20000);
    clock_gettime(CLOCK_MONOTONIC, &b);
    long ms = (b.tv_sec - a.tv_sec) * 1000 + (b.tv_nsec - a.tv_nsec) / 1000000;
    printf("  time=%ld slept=%ld ms\n", (long)real.tv_sec, ms);
    Check("4 time: the clock is after 2026-01-01, and usleep waits", real.tv_sec > 1767225600 && ms >= 15 && ms < 2000);
  }

  if (Wanted(list, 5)) {
    char cwd[512] = "", name[64], data[64] = "";
    struct stat st = {0};
    snprintf(name, sizeof(name), "hello-%d.tmp", getpid());
    FILE *f = fopen(name, "w");
    int ok = f && fputs("a line of text\n", f) >= 0 && !fclose(f);
    ok = ok && !stat(name, &st) && st.st_size == 15;
    f = ok ? fopen(name, "r") : 0;
    ok = ok && f && fgets(data, sizeof(data), f) && !strcmp(data, "a line of text\n");
    if (f) fclose(f);
    ok = ok && !unlink(name) && access(name, F_OK) == -1 && errno == ENOENT;
    printf("  cwd=%s\n", getcwd(cwd, sizeof(cwd)) ? cwd : strerror(errno));
    Check("5 files: write, stat, read and unlink a file; getcwd", ok && cwd[0] == '/');
  }

  if (Wanted(list, 6)) {
    char data[64] = "";
    int fd = open("/zip/hello.txt", O_RDONLY);
    int n = fd >= 0 ? read(fd, data, sizeof(data) - 1) : -1;
    if (fd >= 0) close(fd);
    Check("6 zip: read /zip/hello.txt from this file", n > 0 && !strncmp(data, "a file in the zip", 17));
  }

  if (Wanted(list, 7)) {
    volatile double two = 2;
    char num[64];
    snprintf(num, sizeof(num), "%.6f %s", sqrt(two) * strtod("1e3", 0), "ok");
    Check("7 floating point: sqrt, strtod and printf", !strcmp(num, "1414.213562 ok"));
  }

  if (Wanted(list, 8)) {
    got_signal = 0;
    signal(SIGUSR1, OnUsr1);
    raise(SIGUSR1);
    Check("8 signals: raise gives SIGUSR1 to its handler", got_signal == SIGUSR1);
  }

  if (Wanted(list, 9)) {
    pthread_t th;
    void *res = 0;
    int rc = pthread_create(&th, 0, Worker, (void *)100000);
    if (!rc) rc = pthread_join(th, &res);
    if (rc) printf("  pthread error: %s\n", strerror(rc));
    Check("9 threads: pthread_create and pthread_join", !rc && (long)res == 5000050000);
  }

  if (Wanted(list, 10)) {
    struct sigaction sa = {.sa_handler = OnSegv};
    sigaction(SIGSEGV, &sa, 0);
    int sig = sigsetjmp(jb, 1);
    if (!sig) *(volatile int *)8 = 1;
    Check("10 crash signals: a bad store gives SIGSEGV, and siglongjmp continues", sig == SIGSEGV);
  }

  if (Wanted(list, 11)) {
    int fds[2], status = 0;
    char buf[8] = "";
    long n = -1;
    int rc = pipe(fds);
    int pid = rc ? -1 : fork();
    if (!pid) {
      close(fds[0]);
      write(fds[1], "child", 5);
      _exit(7);
    }
    if (pid > 0) {
      close(fds[1]);
      n = read(fds[0], buf, sizeof(buf));
      close(fds[0]);
      waitpid(pid, &status, 0);
    } else {
      printf("  fork: %s\n", strerror(errno));
    }
    Check("11 fork: the child writes to a pipe, and the parent gets its exit status",
          pid > 0 && n == 5 && !memcmp(buf, "child", 5) && WIFEXITED(status) &&
              WEXITSTATUS(status) == 7);
  }

  if (Wanted(list, 12)) {
    int pid = 0, status = 0;
    char *prog = GetProgramExecutableName();
    char *args[] = {prog, "--child", 0};
    int rc = posix_spawn(&pid, prog, 0, 0, args, environ);
    if (!rc) waitpid(pid, &status, 0);
    if (rc) printf("  posix_spawn: %s\n", strerror(rc));
    printf("  the child ran the half with the code %d (this half: %d)\n",
           WIFEXITED(status) ? WEXITSTATUS(status) : -1, half_code);
    Check("12 posix_spawn: this file as a child runs the same half",
          !rc && WIFEXITED(status) && WEXITSTATUS(status) == half_code);
  }

  if (Wanted(list, 13)) {
    struct itimerval on = {{0, 1000}, {0, 1000}}, off = {{0, 0}, {0, 0}};
    struct timespec t0, t1;
    double expect = Work();
    int bad = 0, runs = 0;
    ticks = 0;
    signal(SIGALRM, OnTick);
    setitimer(ITIMER_REAL, &on, 0);
    clock_gettime(CLOCK_MONOTONIC, &t0);
    do {
      if (Work() != expect) bad = 1;
      ++runs;
      clock_gettime(CLOCK_MONOTONIC, &t1);
    } while (ticks < 50 && t1.tv_sec - t0.tv_sec < 5);
    setitimer(ITIMER_REAL, &off, 0);
    printf("  %d timer signals during %d runs of the work\n", ticks, runs);
    Check("13 timer signals: the floating point work has the same result", ticks >= 50 && !bad);
  }

  if (Wanted(list, 14)) {
    pthread_t th;
    work_expect = Work();
    work_stop = work_bad = 0;
    ticks = 0;
    signal(SIGUSR2, OnTick);
    int rc = pthread_create(&th, 0, Worker2, 0);
    for (int i = 0; !rc && i < 50; ++i) {
      pthread_kill(th, SIGUSR2);
      usleep(2000);
    }
    work_stop = 1;
    if (!rc) pthread_join(th, 0);
    printf("  %d signals to the thread\n", ticks);
    Check("14 pthread_kill: a thread gets signals during floating point work",
          !rc && ticks >= 25 && !work_bad);
  }

  if (Wanted(list, 15)) {
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(0x7f000001)};
    socklen_t len = sizeof(addr);
    char buf[16] = "";
    pthread_t th;
    void *served = 0;
    int server = socket(AF_INET, SOCK_STREAM, 0);
    int ok = server >= 0 && !bind(server, (struct sockaddr *)&addr, sizeof(addr)) &&
             !listen(server, 1) && !getsockname(server, (struct sockaddr *)&addr, &len);
    int client = ok ? socket(AF_INET, SOCK_STREAM, 0) : -1;
    ok = ok && client >= 0 && !pthread_create(&th, 0, Server, (void *)(long)server);
    if (ok) {
      ok = !connect(client, (struct sockaddr *)&addr, sizeof(addr)) &&
           write(client, "hello", 5) == 5;
      struct pollfd pfd = {client, POLLIN};
      ok = ok && poll(&pfd, 1, 5000) == 1 && read(client, buf, sizeof(buf)) == 5;
      // Without a connection, the server thread waits in accept().
      if (!ok) shutdown(server, SHUT_RDWR), close(server), server = -1;
      pthread_join(th, &served);
    }
    if (client >= 0) close(client);
    if (server >= 0) close(server);
    Check("15 sockets: a TCP echo on the loopback address, with poll",
          ok && (long)served == 5 && !memcmp(buf, "hello", 5));
  }

  if (Wanted(list, 16)) {
    int fds[2];
    char buf[8] = "";
    int ok = !pipe(fds);
    struct pollfd pfd = {fds[0], POLLIN};
    ok = ok && poll(&pfd, 1, 0) == 0;
    ok = ok && write(fds[1], "abc", 3) == 3 && poll(&pfd, 1, 5000) == 1 &&
         (pfd.revents & POLLIN) && read(fds[0], buf, sizeof(buf)) == 3;
    int copy = ok ? dup(fds[0]) : -1;
    ok = ok && copy >= 0 && !close(fds[1]) && read(copy, buf, sizeof(buf)) == 0;
    if (copy >= 0) close(copy);
    close(fds[0]);
    Check("16 pipes: poll, read, write, dup and the end of the data", ok);
  }

  if (Wanted(list, 17)) {
    // chown() is a call that Windows does not have: the libc must give
    // ENOSYS, and not start a system call of another kernel. OTP calls
    // chown() before each change of a mode or of a time.
    const char *name = "win_arm64_check.17.tmp", *to = "win_arm64_check.17b.tmp";
    struct timeval tv[2] = {{1767225600, 0}, {1767225600, 0}};
    struct stat st = {0};
    int fd = open(name, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    int ok = fd >= 0 && write(fd, "abc", 3) == 3 && !close(fd);
    errno = 0;
    int rc = chown(name, -1, -1);
    ok = ok && (rc == 0 || (rc == -1 && errno == ENOSYS));
    ok = ok && !chmod(name, 0444) && !chmod(name, 0644);
    ok = ok && !utimes(name, tv) && !stat(name, &st) && st.st_mtime == 1767225600;
    ok = ok && !truncate(name, 1) && !stat(name, &st) && st.st_size == 1;
    ok = ok && !rename(name, to) && access(name, F_OK) == -1 && !access(to, F_OK);
    unlink(name);
    ok = !unlink(to) && ok;
    Check("17 file data: chown gives 0 or ENOSYS; chmod, utimes, truncate and rename", ok);
  }

  if (Wanted(list, 18)) {
    struct timespec a, b;
    int i, ok = 1;
    clock_gettime(CLOCK_MONOTONIC, &a);
    for (i = 0; i < 100000; i++) ok = ok && !sched_yield();
    clock_gettime(CLOCK_MONOTONIC, &b);
    long ms = (b.tv_sec - a.tv_sec) * 1000 + (b.tv_nsec - a.tv_nsec) / 1000000;
    printf("  100000 calls of sched_yield: %ld ms\n", ms);
    Check("18 sched_yield: 100000 calls give 0 in less than 10 s", ok && ms < 10000);
  }

  printf("%s\n", failures ? "some checks failed" : "all checks passed");
  return failures;
}
