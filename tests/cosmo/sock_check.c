/*
 * The check of c_src/cosmo/beam_com_sock.c: sends on a non-blocking socket
 * on Windows never wait (C60 of docs/UPSTREAM.md).
 *
 * One thread moves 32 MiB through a pair of loopback TCP sockets with
 * O_NONBLOCK: it sends while select() reports the sender as writable, and
 * reads while it reports the reader as readable. The sends rotate through
 * send() (the wrap), and beam_com_sock_send() as write(), writev() and
 * sendmsg() call it, with parts of different sizes. The byte at the
 * offset K of the stream is K mod 251, so a count of a partial send that
 * is not exact gives a wrong byte.
 *
 * Before the fix, the first send that did not fit waited for a read, and
 * the reads of the same thread never came: a watchdog thread stops the
 * check after 60 s. Also a send into a full socket must give EAGAIN.
 *
 * The last line is "sock_check: ok". On the other systems, the calls go
 * to the libc, and the check is the same.
 */
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#include "../../c_src/cosmo/beam_com_sock.c"

#define TOTAL (32 << 20)
#define CHUNK (256 << 10)

static void *watchdog(void *arg)
{
    (void)arg;
    sleep(60);
    printf("sock_check: no end after 60 s (a send waits)\n");
    fflush(stdout);
    _exit(1);
}

static double now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static void fail(const char *what)
{
    printf("sock_check: %s: %s\n", what, strerror(errno));
    exit(1);
}

static void nonblock(int fd)
{
    if (fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0)
        fail("fcntl");
}

/* A send of the bytes from OFF, with the method WAY, as the wraps call
 * beam_com_sock_send(). */
static ssize_t send_part(int fd, const unsigned char *pat, long off, size_t size, int way)
{
    const unsigned char *p = pat + off % 251;
    struct iovec iov[3];
    size_t a = size / 3, b = size / 5;

    switch (way % 4) {
    case 0:
        return send(fd, p, size, 0);
    case 1: /* write() */
        iov[0].iov_base = (void *)p;
        iov[0].iov_len = size;
        return beam_com_sock_nonblock(fd) ? beam_com_sock_send(fd, iov, 1, 0) : write(fd, p, size);
    case 2: /* writev(), three parts, one of them empty */
        iov[0].iov_base = (void *)p;
        iov[0].iov_len = a;
        iov[1].iov_base = (void *)(p + a);
        iov[1].iov_len = 0;
        iov[2].iov_base = (void *)(p + a);
        iov[2].iov_len = size - a;
        return beam_com_sock_nonblock(fd) ? beam_com_sock_send(fd, iov, 3, 0) : writev(fd, iov, 3);
    default: { /* sendmsg(), two parts */
        struct msghdr msg;
        iov[0].iov_base = (void *)p;
        iov[0].iov_len = b;
        iov[1].iov_base = (void *)(p + b);
        iov[1].iov_len = size - b;
        memset(&msg, 0, sizeof(msg));
        msg.msg_iov = iov;
        msg.msg_iovlen = 2;
        return beam_com_sock_nonblock(fd) ? beam_com_sock_send(fd, iov, 2, 0) : sendmsg(fd, &msg, 0);
    }
    }
}

int main(void)
{
    struct sockaddr_in addr;
    socklen_t len = sizeof(addr);
    unsigned char *pat, *buf;
    long sent = 0, got = 0, eagain = 0, sends = 0;
    int lsn, wr, rd, one = 1, i;
    pthread_t dog;
    double t0, ms;

    pthread_create(&dog, NULL, watchdog, NULL);
    pthread_detach(dog);
    /* The pattern: CHUNK bytes from each offset mod 251. */
    pat = malloc(CHUNK + 251);
    buf = malloc(CHUNK);
    for (i = 0; i < CHUNK + 251; i++)
        pat[i] = i % 251;

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if ((lsn = socket(AF_INET, SOCK_STREAM, 0)) < 0 || bind(lsn, (void *)&addr, sizeof(addr)) < 0 ||
        listen(lsn, 1) < 0 || getsockname(lsn, (void *)&addr, &len) < 0)
        fail("listen");
    if ((wr = socket(AF_INET, SOCK_STREAM, 0)) < 0 || connect(wr, (void *)&addr, sizeof(addr)) < 0)
        fail("connect");
    if ((rd = accept(lsn, NULL, NULL)) < 0)
        fail("accept");
    setsockopt(wr, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    nonblock(wr);
    nonblock(rd);

    /* A socket that nobody reads fills, and then a send gives EAGAIN. */
    for (i = 0; i < 4096; i++) {
        ssize_t n = send_part(wr, pat, sent, CHUNK, i);
        if (n < 0) {
            if (errno != EAGAIN && errno != EWOULDBLOCK)
                fail("send into a full socket");
            break;
        }
        sent += n;
    }
    if (i == 4096) {
        printf("sock_check: no EAGAIN after %ld bytes\n", sent);
        return 1;
    }
    printf("sock_check: EAGAIN after %ld bytes\n", sent);

    t0 = now_ms();
    while (got < TOTAL) {
        fd_set r, w;
        FD_ZERO(&r);
        FD_ZERO(&w);
        FD_SET(rd, &r);
        if (sent < TOTAL)
            FD_SET(wr, &w);
        if (select((rd > wr ? rd : wr) + 1, &r, &w, NULL, NULL) < 0) {
            if (errno == EINTR)
                continue;
            fail("select");
        }
        if (FD_ISSET(wr, &w)) {
            size_t size = TOTAL - sent < CHUNK ? TOTAL - sent : CHUNK;
            /* Parts of different sizes: 1 byte to CHUNK bytes. */
            if (sends % 7 == 3)
                size = size < 1 + sends % 1000 ? size : 1 + sends % 1000;
            ssize_t n = send_part(wr, pat, sent, size, (int)sends++);
            if (n > 0)
                sent += n;
            else if (n < 0 && errno == EAGAIN)
                eagain++;
            else if (n < 0)
                fail("send");
        }
        if (FD_ISSET(rd, &r)) {
            ssize_t n = recv(rd, buf, CHUNK, 0);
            if (n < 0 && errno != EAGAIN)
                fail("recv");
            for (i = 0; i < n; i++)
                if (buf[i] != (got + i) % 251) {
                    printf("sock_check: wrong byte at %ld\n", got + i);
                    return 1;
                }
            if (n > 0)
                got += n;
            if (n == 0) {
                printf("sock_check: end of the stream after %ld bytes\n", got);
                return 1;
            }
        }
    }
    ms = now_ms() - t0;
    printf("sock_check: %d MiB in %.0f ms, %ld sends, %ld EAGAIN\n", TOTAL >> 20, ms, sends, eagain);
    close(wr);
    close(rd);
    close(lsn);
    printf("sock_check: ok\n");
    return 0;
}
