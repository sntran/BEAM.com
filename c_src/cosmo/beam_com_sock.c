/*
 * Non-blocking sends on a socket on Windows (C60 of docs/UPSTREAM.md).
 *
 * On Windows, send(), sendto(), sendmsg(), write() and writev() of
 * Cosmopolitan start an overlapped WSASend() and wait for its end, also
 * for a socket with O_NONBLOCK: sys_send_nt() and sys_sendto_nt() give
 * nonblock=false to __winsock_block() (libc/sock/send-nt.c). The libc
 * does not cancel a send that waits, because then WSAGetOverlappedResult()
 * can report an error for a send that completed. Thus a send of ERTS
 * waited until the peer read the data, and the scheduler thread that ran
 * the port waited with it. A transfer between two processes of one VM
 * got about 1.1 MB/s, or it did not end.
 *
 * For a socket with O_NONBLOCK, the wraps of send() (here), write() and
 * writev() (beam_com_pipe.c), and sendto() and sendmsg() with no address
 * (beam_com_net.c) call beam_com_sock_send(). It puts the socket in the
 * non-blocking mode of Winsock (FIONBIO), and calls WSASend() with no
 * OVERLAPPED. Such a call never waits: it sends the bytes that fit and
 * gives their exact count, or it fails with WSAEWOULDBLOCK (EAGAIN). The
 * libc also puts each socket of connect() and accept() in this mode
 * (libc/sock/connect-nt.c, accept-nt.c), and its overlapped calls on the
 * socket (recv(), and a send without O_NONBLOCK) still wait as before.
 *
 * A send to an address (sendto() and sendmsg() with an address, for UDP)
 * stays with the libc: a datagram does not wait for the peer.
 *
 * The close of a socket with SO_LINGER on and a time above 0 (C65 of
 * docs/UPSTREAM.md): Winsock refuses closesocket() of a non-blocking
 * socket in this state with WSAEWOULDBLOCK, and the socket stays open.
 * The libc frees the fd all the same, so the connection stayed open with
 * no owner: the peer never got the end of the stream, and the handle
 * leaked. beam_com_sock_close() turns the linger off before the close.
 * Then closesocket() returns at once, and Windows sends the data that
 * waits and the end of the stream in the background, as with no linger.
 * A linger with the time 0 (a reset) does not change.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <cosmo.h>
#include "libc/dce.h"
#include "libc/intrin/fds.h"
#include "libc/nt/struct/iovec.h"
#include "libc/nt/winsock.h"
#include "libc/sock/internal.h" /* __winsockerr() */

#include "beam_com_sock.h"

/* The flags of send() that the libc takes on Windows, with the values of
 * libc/sock/send-nt.c. */
#define SOCK_MSG_OOB       1
#define SOCK_MSG_DONTROUTE 4
#define SOCK_MSG_DONTWAIT  64
#define SOCK_MSG_NOSIGNAL  0x10000000

/* The parts of an iovec array in one WSASend(), at most. A larger
 * array gives a partial send, as a send of a non-blocking socket can. */
#define SOCK_IOV 64

/* The sockets in the non-blocking mode of Winsock: for each fd, the
 * handle plus 1, or 0. A larger fd calls ioctlsocket() at each send. */
#define SOCK_FDS 4096

__msabi extern typeof(__sys_ioctlsocket_nt) *const __imp_ioctlsocket;

extern struct Fds g_fds;

ssize_t __real_send(int fd, const void *buf, size_t size, int flags);
ssize_t __wrap_send(int fd, const void *buf, size_t size, int flags);

static _Atomic(int64_t) sock_nbio[SOCK_FDS];

int beam_com_sock_nonblock(int fd)
{
    struct Fd *f;

    if (!IsWindows() || fd < 0 || (size_t)fd >= g_fds.n)
        return 0;
    f = g_fds.p + fd;
    return f->kind == kFdSocket && (f->flags & O_NONBLOCK);
}

void beam_com_sock_close(int fd)
{
    struct linger l;
    socklen_t len = sizeof(l);

    if (fd >= 0 && fd < SOCK_FDS)
        sock_nbio[fd] = 0;
    if (!IsWindows() || fd < 0 || (size_t)fd >= g_fds.n || g_fds.p[fd].kind != kFdSocket)
        return;
    if (getsockopt(fd, SOL_SOCKET, SO_LINGER, &l, &len) == 0 && l.l_onoff && l.l_linger > 0) {
        l.l_onoff = 0;
        l.l_linger = 0;
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &l, sizeof(l));
    }
}

/* Puts the socket of FD in the non-blocking mode of Winsock. */
static int sock_nbio_set(int fd, int64_t handle)
{
    uint32_t mode = 1;

    if (fd < SOCK_FDS && sock_nbio[fd] == handle + 1)
        return 0;
    if (__imp_ioctlsocket(handle, FIONBIO, &mode))
        return __winsockerr();
    if (fd < SOCK_FDS)
        sock_nbio[fd] = handle + 1;
    return 0;
}

ssize_t beam_com_sock_send(int fd, const struct iovec *iov, int iovcnt, int flags)
{
    struct NtIovec nt[SOCK_IOV];
    uint32_t sent = 0, n = 0;
    int64_t handle;
    int i;

    if (flags & ~(SOCK_MSG_OOB | SOCK_MSG_DONTROUTE | SOCK_MSG_DONTWAIT | SOCK_MSG_NOSIGNAL)) {
        errno = EINVAL;
        return -1;
    }
    if (iovcnt < 0) {
        errno = EINVAL;
        return -1;
    }
    handle = g_fds.p[fd].handle;
    if (sock_nbio_set(fd, handle) == -1)
        return -1;
    /* A part of 2 GiB or more is cut: a partial send. */
    for (i = 0; i < iovcnt && n < SOCK_IOV; i++) {
        if (!iov[i].iov_len)
            continue;
        nt[n].buf = iov[i].iov_base;
        nt[n].len = iov[i].iov_len > 0x7fffffff ? 0x7fffffff : (uint32_t)iov[i].iov_len;
        n++;
        if (iov[i].iov_len > 0x7fffffff)
            break;
    }
    /* A send of 0 bytes: one empty part, as the libc does. */
    if (n == 0) {
        nt[0].buf = iovcnt > 0 ? iov[0].iov_base : NULL;
        nt[0].len = 0;
        n = 1;
    }
    if (WSASend(handle, nt, n, &sent, flags & (SOCK_MSG_OOB | SOCK_MSG_DONTROUTE), NULL, NULL)) {
        __winsockerr();
        /* As sys_send_nt(): a send after the end of the connection gives
         * EPIPE and SIGPIPE. */
        if (errno == ESHUTDOWN || errno == ECONNABORTED) {
            errno = EPIPE;
            if (!(flags & SOCK_MSG_NOSIGNAL))
                raise(SIGPIPE);
        }
        return -1;
    }
    return sent;
}

ssize_t __wrap_send(int fd, const void *buf, size_t size, int flags)
{
    struct iovec iov;

    if (!beam_com_sock_nonblock(fd))
        return __real_send(fd, buf, size, flags);
    iov.iov_base = (void *)buf;
    iov.iov_len = size;
    return beam_com_sock_send(fd, &iov, 1, flags);
}
