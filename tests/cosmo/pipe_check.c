/*
 * The checks of c_src/cosmo/beam_com_pipe.c: the writes and select() of
 * a non-blocking pipe.
 *
 * - On Windows, a write gives at most the free space of the pipe, a full
 *   pipe gives EAGAIN and is not writable for select(), and the CPU stays
 *   free while the pipe is full.
 * - A blocking reader that waits in a read of 1, 4095, 4096 or 65536
 *   bytes gets all the data. On Windows, this reader makes the free space
 *   of the write end smaller, also to 0 for an empty pipe: the wraps use
 *   the query handle of the read end (beam_com_pipe_reader()).
 * - After the reader closes its end, a write gives EPIPE, also when
 *   another handle of the read end stays open until then.
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
#include <stdio.h>
#include <stdlib.h>

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
    beam_com_pipe_reader(fds[1], fds[0]);
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

int main(void)
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
    CHECK(pipe(fds) == 0);
    CHECK(fcntl(fds[1], F_SETFL, O_NONBLOCK) == 0);
    CHECK(fcntl(fds[0], F_SETFL, O_NONBLOCK) == 0);
    beam_com_pipe_reader(fds[1], fds[0]);

    if (IsWindows()) {
        /* Cosmopolitan makes a pipe of 4 KiB. */
        n = __wrap_write(fds[1], data, 10000);
        CHECK(n == 4096);
        sent = n > 0 ? n : 0;
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

    /* The reader closes its end: EPIPE, for an empty and a full pipe,
     * with and with no query handle. With a second handle of the read end
     * (dup()), the writes go on until its close. */
    for (i = 0; i < 6; i++) {
        int other = -1;
        CHECK(pipe(fds) == 0);
        CHECK(fcntl(fds[1], F_SETFL, O_NONBLOCK) == 0);
        if (i >= 2)
            beam_com_pipe_reader(fds[1], fds[0]);
        if (i >= 4)
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

    if (failures) {
        printf("pipe_check: %d failures\n", failures);
        return 1;
    }
    printf("pipe_check: ok\n");
    return 0;
}
