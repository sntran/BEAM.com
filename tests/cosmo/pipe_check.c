/*
 * The checks of c_src/cosmo/beam_com_pipe.c: the writes and select() of
 * a non-blocking pipe.
 *
 * - On Windows, a write gives at most the free space of the pipe. To a
 *   full pipe, a write gives 1 byte that waits in the pipe, then EAGAIN.
 *   select() does not report the pipe while the byte waits, and the CPU
 *   stays free.
 * - A blocking reader that waits in a read of 1, 4095, 4096 or 65536
 *   bytes gets all the data. On Windows, this reader makes the free space
 *   of the write end smaller, also to 0 for an empty pipe.
 * - After the close of the write end, the reader gets the byte that waits,
 *   and then the end of the file.
 * - After the reader closes its end, a write gives EPIPE, also when
 *   another handle of the read end stays open until then.
 * - The exit of the writer while a byte waits: a reader that reads late
 *   gets each byte. A reader that never reads holds the exit for at most
 *   PIPE_EXIT_MS. With no byte that waits, the exit does not wait. For
 *   this check, the program starts itself as the writer (--writer), and
 *   the writer starts it as the reader (--reader).
 *
 * All the data that a write reports arrives, in order. On the other
 * systems, the wraps only call the libc, and the same checks of the data
 * run. The last line is "pipe_check: ok".
 */
#define BEAM_COM_PIPE_TEST
#define __real_write write
#define __real_writev writev
#define __real_select select
#include "../../c_src/cosmo/beam_com_pipe.c"

#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>

static int failures;

#define CHECK(cond)                                                      \
    do {                                                                 \
        if (!(cond)) {                                                   \
            fprintf(stderr, "pipe_check: line %d: %s\n", __LINE__, #cond); \
            failures++;                                                  \
        }                                                                \
    } while (0)

#define TOTAL (1 << 20)
/* The data for each blocking reader. */
#define PART (128 << 10)

static unsigned char data[TOTAL];

struct reader {
    int fd;
    size_t size;  /* the size of each read */
    int late_ms;  /* the time before the first read */
    size_t total; /* the read stops after this number of bytes */
    unsigned char *got;
    size_t ngot;
};

static void *reader(void *arg)
{
    struct reader *r = arg;
    size_t want;
    ssize_t n;

    if (r->late_ms)
        usleep(r->late_ms * 1000);
    while (r->ngot < r->total) {
        want = r->total - r->ngot < r->size ? r->total - r->ngot : r->size;
        n = read(r->fd, r->got + r->ngot, want);
        if (n > 0)
            r->ngot += n;
        else if (n == 0 || (errno != EAGAIN && errno != EINTR))
            break;
        else
            usleep(1000);
    }
    return 0;
}

static int writable(int fd, int ms)
{
    fd_set w;
    struct timeval tv = {ms / 1000, (ms % 1000) * 1000};
    FD_ZERO(&w);
    FD_SET(fd, &w);
    return __wrap_select(fd + 1, 0, &w, 0, &tv) == 1 && FD_ISSET(fd, &w);
}

static int64_t cpu_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Writes data[from..to) with writev() of two parts and select(). 0 when
 * the pipe stays not writable for 2 s, or when a write fails. */
static int send_all(int fd, size_t from, size_t to)
{
    size_t sent = from;
    ssize_t n;

    while (sent < to) {
        struct iovec iov[2];
        size_t left = to - sent, a = left < 3000 ? left : 3000;
        iov[0].iov_base = data + sent;
        iov[0].iov_len = a;
        iov[1].iov_base = data + sent + a;
        iov[1].iov_len = left - a < 9000 ? left - a : 9000;
        n = __wrap_writev(fd, iov, 2);
        if (n > 0) {
            sent += n;
        } else if (n < 0 && errno == EAGAIN) {
            if (!writable(fd, 2000)) {
                fprintf(stderr, "pipe_check: no space after 2 s, at %zu of %zu\n",
                        sent - from, to - from);
                return 0;
            }
        } else {
            fprintf(stderr, "pipe_check: write: %s\n", strerror(errno));
            return 0;
        }
    }
    return 1;
}

/* A blocking reader with reads of SIZE bytes. With LATE_MS 0, the reader
 * waits in its read before the first write. */
static void blocking_reader(size_t size, int late_ms)
{
    struct reader r = {0};
    int fds[2];
    pthread_t t;
    int64_t t0 = now_ms();

    CHECK(pipe(fds) == 0);
    CHECK(fcntl(fds[1], F_SETFL, O_NONBLOCK) == 0);
    r.fd = fds[0];
    r.size = size;
    r.late_ms = late_ms;
    r.total = PART;
    r.got = malloc(PART);
    CHECK(pthread_create(&t, 0, reader, &r) == 0);
    if (!late_ms)
        usleep(200000); /* the reader waits in its read */
    /* The first write: also when Windows reports no free space. */
    if (!send_all(fds[1], 0, PART))
        fprintf(stderr, "pipe_check: reads of %zu, %d ms late: no write\n",
                size, late_ms);
    beam_com_pipe_forget(fds[1]);
    close(fds[1]);
    pthread_join(t, 0);
    close(fds[0]);
    CHECK(r.ngot == PART);
    CHECK(memcmp(r.got, data, PART) == 0);
    printf("pipe_check: reads of %zu bytes, %d ms late: %zu bytes, %d ms\n",
           size, late_ms, r.ngot, (int)(now_ms() - t0));
    free(r.got);
}

/* A full pipe for 1 s: select() does not report it, and the CPU stays
 * free. */
static void full_pipe(int fd)
{
    int64_t t0 = now_ms(), c0 = cpu_ms(), left;
    int tries = 0;

    while ((left = 1000 - (now_ms() - t0)) > 0) {
        if (!writable(fd, (int)left))
            continue;
        tries++;
        CHECK(__wrap_write(fd, data, 100) == -1 && errno == EAGAIN);
    }
    printf("pipe_check: full pipe for 1 s: %d reports, %d ms of CPU\n", tries,
           (int)(cpu_ms() - c0));
    CHECK(tries == 0);
    CHECK(now_ms() - t0 >= 990);
    CHECK(cpu_ms() - c0 < 100);
}

/* Starts this program with ARGV, with the fd IN as its fd 0 and the fd
 * OUT as its fd 1 (-1: the same as this process). The pid, or -1. */
static pid_t start_self(char **argv, int in, int out)
{
    posix_spawn_file_actions_t fa;
    extern char **environ;
    pid_t pid;
    int rc;

    posix_spawn_file_actions_init(&fa);
    if (in >= 0)
        posix_spawn_file_actions_adddup2(&fa, in, 0);
    if (out >= 0)
        posix_spawn_file_actions_adddup2(&fa, out, 1);
    argv[0] = (char *)GetProgramExecutableName();
    rc = posix_spawn(&pid, argv[0], &fa, 0, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    return rc == 0 ? pid : -1;
}

/* The reader: it waits DELAY_MS, reads its input to the end, and writes
 * the number of bytes to the file PATH. */
static int exit_reader(int delay_ms, const char *path)
{
    static unsigned char in[65536];
    char tmp[512];
    size_t got = 0;
    ssize_t n;
    FILE *f;

    usleep(delay_ms * 1000);
    while ((n = read(0, in, sizeof(in))) > 0 || (n < 0 && errno == EINTR))
        if (n > 0)
            got += n;
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    if (!(f = fopen(tmp, "w")))
        return 1;
    fprintf(f, "%zu\n", got);
    fclose(f);
    return rename(tmp, path) != 0;
}

/* The exit of the writer, from a thread that is not the main thread, as
 * ERTS calls exit() for erlang:halt/1. */
static void *exit_thread(void *arg)
{
    (void)arg;
    exit(0);
}

/* The writer: it starts the reader, writes SIZE bytes to it with the
 * wraps, writes a line to its output, and exits at once. With CLOSE, it
 * closes the pipe before the exit: a closer thread then holds the byte
 * that waits. */
static int exit_writer(char *delay, char *path, size_t size, int close_fd)
{
    char *argv[] = {0, "--reader", delay, path, 0};
    int fds[2];
    size_t sent = 0;
    pthread_t t;
    ssize_t n;

    if (pipe2(fds, O_CLOEXEC) != 0 || fcntl(fds[1], F_SETFL, O_NONBLOCK) != 0 ||
        start_self(argv, fds[0], -1) < 0)
        return 1;
    close(fds[0]);
    while (sent < size) {
        n = __wrap_write(fds[1], data + sent, size - sent);
        if (n > 0)
            sent += n;
        else if (n < 0 && errno == EAGAIN)
            writable(fds[1], 100);
        else
            return 1;
    }
    if (close_fd) {
        beam_com_pipe_forget(fds[1]);
        close(fds[1]);
    }
    printf("written\n");
    fflush(stdout);
    /* The exit of the process: the wait for a byte runs. The main thread
     * waits meanwhile. */
    if (pthread_create(&t, 0, exit_thread, 0) == 0)
        pthread_join(t, 0);
    return 1;
}

/* The exit of a writer of SIZE bytes, with a reader that reads DELAY_MS
 * late. With CLOSE_FD, the writer closes the pipe before its exit. The
 * time from the end of the writes to the end of the writer must be from
 * MIN_MS to less than MAX_MS. With EXACT, the reader must get all the
 * bytes. */
static void exit_check(int delay_ms, size_t size, int close_fd, int min_ms,
                       int max_ms, int exact)
{
    char delay[16], nsize[32], path[64], line[64];
    char *argv[] = {0, "--writer", delay, path, nsize,
                    close_fd ? "close" : "keep", 0};
    int64_t t0, t1;
    size_t got = 0;
    int fds[2], status = -1, ok = 0;
    pid_t pid;
    FILE *f;

    snprintf(delay, sizeof(delay), "%d", delay_ms);
    snprintf(nsize, sizeof(nsize), "%zu", size);
    snprintf(path, sizeof(path), "pipe_check.%d.%d.%zu.%d", (int)getpid(),
             delay_ms, size, close_fd);
    unlink(path);
    CHECK(pipe2(fds, O_CLOEXEC) == 0);
    pid = start_self(argv, -1, fds[1]);
    CHECK(pid > 0);
    close(fds[1]);
    /* The line comes after the writes. */
    if (read(fds[0], line, sizeof(line)) > 0)
        ok = 1;
    t0 = now_ms();
    CHECK(pid > 0 && waitpid(pid, &status, 0) == pid);
    t1 = now_ms();
    close(fds[0]);
    CHECK(ok);
    CHECK(status == 0);
    /* The reader writes the file at the end of its input. */
    while (!(f = fopen(path, "r")) && now_ms() - t1 < 15000)
        usleep(10000);
    CHECK(f && fscanf(f, "%zu", &got) == 1);
    if (f)
        fclose(f);
    unlink(path);
    printf("pipe_check: exit after %zu bytes%s, reader %d ms late: %d ms, "
           "the reader got %zu\n",
           size, close_fd ? " and the close" : "", delay_ms, (int)(t1 - t0),
           got);
    CHECK(t1 - t0 >= min_ms);
    CHECK(t1 - t0 < max_ms);
    if (exact)
        CHECK(got == size);
}

int main(int argc, char **argv)
{
    static const size_t sizes[] = {1, 4095, 4096, 65536};
    struct reader r = {0};
    int fds[2], i;
    size_t sent = 0;
    pthread_t t;
    ssize_t n;

    signal(SIGPIPE, SIG_IGN);
    for (i = 0; i < TOTAL; i++)
        data[i] = (unsigned char)(i * 7 + i / 251);
    if (argc == 4 && !strcmp(argv[1], "--reader"))
        return exit_reader(atoi(argv[2]), argv[3]);
    if (argc == 6 && !strcmp(argv[1], "--writer"))
        return exit_writer(argv[2], argv[3], strtoul(argv[4], 0, 10),
                           !strcmp(argv[5], "close"));
    CHECK(pipe(fds) == 0);
    CHECK(fcntl(fds[1], F_SETFL, O_NONBLOCK) == 0);
    CHECK(fcntl(fds[0], F_SETFL, O_NONBLOCK) == 0);

    if (IsWindows()) {
        /* Cosmopolitan makes a pipe of 4 KiB. */
        n = __wrap_write(fds[1], data, 10000);
        CHECK(n == 4096);
        sent = n > 0 ? n : 0;
        /* One byte waits in the pipe, then EAGAIN. */
        n = __wrap_write(fds[1], data + sent, 100);
        CHECK(n == 1);
        sent += n > 0 ? n : 0;
        CHECK(__wrap_write(fds[1], data + sent, 100) == -1 && errno == EAGAIN);
        full_pipe(fds[1]);
    }

    /* The rest, while a non-blocking reader reads after 100 ms. */
    r.fd = fds[0];
    r.size = TOTAL;
    r.late_ms = 100;
    r.total = TOTAL;
    r.got = malloc(TOTAL);
    CHECK(pthread_create(&t, 0, reader, &r) == 0);
    CHECK(send_all(fds[1], sent, TOTAL));
    beam_com_pipe_forget(fds[1]);
    close(fds[1]);
    pthread_join(t, 0);
    close(fds[0]);
    CHECK(r.ngot == TOTAL);
    CHECK(memcmp(r.got, data, TOTAL) == 0);
    free(r.got);

    /* Blocking readers with large reads, which wait before the first
     * write, or which read late. */
    for (i = 0; i < (int)(sizeof(sizes) / sizeof(sizes[0])); i++) {
        blocking_reader(sizes[i], 0);
        blocking_reader(sizes[i], 300);
    }

    /* The close of the write end while a byte waits: the reader gets the
     * byte, then the end of the file. */
    if (IsWindows()) {
        static unsigned char in[8192];
        size_t got = 0;
        CHECK(pipe(fds) == 0);
        CHECK(fcntl(fds[1], F_SETFL, O_NONBLOCK) == 0);
        CHECK(__wrap_write(fds[1], data, 4096) == 4096);
        CHECK(__wrap_write(fds[1], data + 4096, 100) == 1);
        beam_com_pipe_forget(fds[1]);
        close(fds[1]);
        while ((n = read(fds[0], in + got, sizeof(in) - got)) > 0)
            got += n;
        CHECK(n == 0);
        CHECK(got == 4097);
        CHECK(memcmp(in, data, got) == 0);
        close(fds[0]);
    }

    /* The reader closes its end: EPIPE, for an empty and a full pipe,
     * also with a byte that waits. With a second handle of the read end
     * (dup()), the writes go on until its close. */
    for (i = 0; i < 4; i++) {
        int other = -1;
        CHECK(pipe(fds) == 0);
        CHECK(fcntl(fds[1], F_SETFL, O_NONBLOCK) == 0);
        if (i >= 2)
            CHECK((other = dup(fds[0])) >= 0);
        if (i & 1)
            while (__wrap_write(fds[1], data, 4096) > 0)
                ;
        close(fds[0]);
        if (other >= 0) {
            if (!(i & 1))
                CHECK(__wrap_write(fds[1], data, 100) == 100);
            close(other);
        }
        errno = 0;
        CHECK(__wrap_write(fds[1], data, 100) == -1 && errno == EPIPE);
        CHECK(writable(fds[1], 1000));
        beam_com_pipe_forget(fds[1]);
        close(fds[1]);
    }

    /* The exit of the writer. With 4097 bytes, 1 byte waits in the full
     * pipe on Windows: the reader that reads 300 ms late gets it, also
     * after the close of the pipe. A reader that never reads (4 s late)
     * holds the exit for PIPE_EXIT_MS. With 4096 bytes, no byte waits, and
     * the exit does not wait. */
    exit_check(300, 4097, 0, 0, PIPE_EXIT_MS + 1000, 1);
    exit_check(300, 4097, 1, 0, PIPE_EXIT_MS + 1000, 1);
    exit_check(4000, 4097, 0, IsWindows() ? PIPE_EXIT_MS - 100 : 0,
               PIPE_EXIT_MS + 1000, 0);
    exit_check(1000, 4096, 0, 0, PIPE_EXIT_MS / 2, 1);

    if (failures) {
        printf("pipe_check: %d failures\n", failures);
        return 1;
    }
    printf("pipe_check: ok\n");
    return 0;
}
