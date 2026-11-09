/*
 * The checks of c_src/cosmo/beam_com_pipe.c: the writes and select() of
 * a non-blocking pipe. On Windows, a write gives at most the free space
 * of the pipe, a full pipe gives EAGAIN and is not writable for select(),
 * and the pipe is writable again after a read. All the data that a write
 * reports arrives, in order. On the other systems, the wraps only call the
 * libc, and the same checks of the data run. The last line is
 * "pipe_check: ok".
 */
#define BEAM_COM_PIPE_TEST
#define __real_write write
#define __real_writev writev
#define __real_select select
#include "../../c_src/cosmo/beam_com_pipe.c"

#include <pthread.h>
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

static int rfd;
static unsigned char *got;
static size_t ngot;

/* The reader: it waits 100 ms, then reads all the data. */
static void *reader(void *arg)
{
    ssize_t n;
    (void)arg;
    usleep(100000);
    for (;;) {
        n = read(rfd, got + ngot, TOTAL - ngot);
        if (n > 0)
            ngot += n;
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

int main(void)
{
    static unsigned char data[TOTAL];
    int fds[2], i;
    size_t sent = 0;
    pthread_t t;
    int64_t t0;
    ssize_t n;

    for (i = 0; i < TOTAL; i++)
        data[i] = (unsigned char)(i * 7 + i / 251);
    got = malloc(TOTAL);
    CHECK(pipe(fds) == 0);
    rfd = fds[0];
    CHECK(fcntl(fds[1], F_SETFL, O_NONBLOCK) == 0);
    CHECK(fcntl(fds[0], F_SETFL, O_NONBLOCK) == 0);

    if (IsWindows()) {
        /* Cosmopolitan makes a pipe of 4 KiB. */
        n = __wrap_write(fds[1], data, 10000);
        CHECK(n == 4096);
        sent = n > 0 ? n : 0;
        CHECK(__wrap_write(fds[1], data + sent, 100) == -1 && errno == EAGAIN);
        t0 = now_ms();
        CHECK(!writable(fds[1], 50));
        CHECK(now_ms() - t0 >= 45);
    }

    /* The rest, with writev() of two parts and select(), while the reader
     * reads. */
    CHECK(pthread_create(&t, 0, reader, 0) == 0);
    while (sent < TOTAL) {
        struct iovec iov[2];
        size_t left = TOTAL - sent, a = left < 3000 ? left : 3000;
        iov[0].iov_base = data + sent;
        iov[0].iov_len = a;
        iov[1].iov_base = data + sent + a;
        iov[1].iov_len = left - a < 9000 ? left - a : 9000;
        n = __wrap_writev(fds[1], iov, 2);
        if (n > 0) {
            sent += n;
        } else if (n < 0 && errno == EAGAIN) {
            if (!writable(fds[1], 2000)) {
                CHECK(!"the pipe is not writable after 2 s");
                break;
            }
        } else {
            CHECK(!"a write failed");
            break;
        }
    }
    close(fds[1]);
    pthread_join(t, 0);
    CHECK(ngot == TOTAL);
    CHECK(memcmp(got, data, TOTAL) == 0);

    if (failures) {
        printf("pipe_check: %d failures\n", failures);
        return 1;
    }
    printf("pipe_check: ok\n");
    return 0;
}
