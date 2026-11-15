/*
 * The static NIF beam_com_fd (src/beam_com_reload/beam_com_fd.erl): send
 * a file descriptor to another process over a Unix socket, and receive
 * one (SCM_RIGHTS). The build of OTP has no socket NIF (--disable-esock),
 * and inet_drv cannot send a descriptor. With this NIF, a server gives
 * its listening socket to the next version of the program, and no
 * connection in the accept queue gets a reset (examples/bluegreen).
 *
 *   send_nif(Sock, Fd)        -> ok | {error, Errno}
 *   recv_nif(Sock, TimeoutMs) -> {ok, Fd} | {error, timeout | closed | Errno}
 *
 * Sock is the descriptor of a connected Unix socket (inet:getfd/1 of a
 * gen_tcp socket with {active, false}). One message has one byte and one
 * descriptor. The calls run on a dirty I/O scheduler, and they wait with
 * poll(), because inet_drv makes the socket non-blocking.
 *
 * Cosmopolitan gives struct msghdr to the kernel unchanged on BSD and
 * XNU, and its struct cmsghdr has the Linux layout (a 64-bit cmsg_len).
 * On these systems, the control message has the native layout, as in
 * sys_uds.c of the OTP patch (C17 of docs/UPSTREAM.md): uint32 len, int
 * level, int type, and then the data at offset 12 (XNU) or 16 (the BSDs).
 * The kernel also writes msg_flags in the upper half of the 64-bit
 * msg_controllen of Cosmopolitan.
 *
 * A received message with more than one descriptor, or with a cut
 * control message, closes each descriptor that it has and gives
 * {error, einval}: the receiver never keeps a descriptor that it did not
 * ask for, and the VM does not stop.
 */
#include <cosmo.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#include "erl_nif.h"

/* The name of an errno value, from ERTS (erl_driver.h has it). */
extern char *erl_errno_id(int error);

#define FD_HOSTXNU 8
#define FD_HOSTBSD (8 | 16 | 32 | 64) /* XNU, OpenBSD, FreeBSD, NetBSD */
#define FD_CONTROL 256
#define FD_MAX 16

static int native_cmsg(void)
{
    return (__hostos & FD_HOSTBSD) != 0;
}

static size_t cmsg_align(void)
{
    return (__hostos & FD_HOSTXNU) ? 4 : 8;
}

static size_t cmsg_hdrlen(void)
{
    return (__hostos & FD_HOSTXNU) ? 12 : 16;
}

static ERL_NIF_TERM error_tuple(ErlNifEnv *env, int err)
{
    const char *name = erl_errno_id(err);
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, name ? name : "unknown"));
}

static int64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Wait until fd is ready for events, for at most timeout ms (-1: no
 * limit). 1 when ready, 0 at the timeout, -1 with errno. */
static int wait_fd(int fd, short events, int timeout)
{
    int64_t deadline = timeout < 0 ? 0 : now_ms() + timeout;
    for (;;) {
        struct pollfd p = {.fd = fd, .events = events};
        int left = -1;
        if (timeout >= 0) {
            int64_t d = deadline - now_ms();
            left = d < 0 ? 0 : (int)d;
        }
        int n = poll(&p, 1, left);
        if (n > 0)
            return 1;
        if (n == 0)
            return 0;
        if (errno != EINTR)
            return -1;
    }
}

static ERL_NIF_TERM send_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int sock, fd;
    (void)argc;
    if (!enif_get_int(env, argv[0], &sock) || !enif_get_int(env, argv[1], &fd) ||
        sock < 0 || fd < 0)
        return enif_make_badarg(env);
    if (IsWindows())
        return error_tuple(env, ENOTSUP);

    /* The control message, in the layout of the kernel. The union keeps
     * the buffer aligned for struct cmsghdr. */
    union {
        struct cmsghdr align;
        char buf[CMSG_SPACE(sizeof(int)) + 16];
    } control;
    memset(&control, 0, sizeof(control));
    char byte = 'F';
    struct iovec iov = {.iov_base = &byte, .iov_len = 1};
    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.buf;
    if (native_cmsg()) {
        size_t hdr = cmsg_hdrlen(), align = cmsg_align();
        uint32_t len = (uint32_t)(hdr + sizeof(int));
        int level = SOL_SOCKET, type = SCM_RIGHTS;
        memcpy(control.buf, &len, sizeof(len));
        memcpy(control.buf + 4, &level, sizeof(level));
        memcpy(control.buf + 8, &type, sizeof(type));
        memcpy(control.buf + hdr, &fd, sizeof(fd));
        msg.msg_controllen = (hdr + sizeof(int) + align - 1) & ~(align - 1);
    } else {
        msg.msg_controllen = CMSG_SPACE(sizeof(int));
        struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(c), &fd, sizeof(fd));
    }

    for (;;) {
        ssize_t n = sendmsg(sock, &msg, 0);
        if (n == 1)
            return enif_make_atom(env, "ok");
        if (n >= 0)
            return error_tuple(env, EIO);
        if (errno == EINTR)
            continue;
        if (errno != EAGAIN && errno != EWOULDBLOCK)
            return error_tuple(env, errno);
        int w = wait_fd(sock, POLLOUT, 5000);
        if (w == 0)
            return error_tuple(env, ETIMEDOUT);
        if (w < 0)
            return error_tuple(env, errno);
    }
}

/* Close each descriptor of a received control message. */
static void close_all(int *fds, int n)
{
    for (int i = 0; i < n; i++)
        close(fds[i]);
}

static ERL_NIF_TERM recv_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int sock, timeout;
    (void)argc;
    if (!enif_get_int(env, argv[0], &sock) || !enif_get_int(env, argv[1], &timeout) ||
        sock < 0 || timeout < -1)
        return enif_make_badarg(env);
    if (IsWindows())
        return error_tuple(env, ENOTSUP);

    union {
        struct cmsghdr align;
        char buf[FD_CONTROL];
    } control;
    char byte;
    struct iovec iov = {.iov_base = &byte, .iov_len = 1};
    struct msghdr msg;
    ssize_t n;
    int64_t deadline = timeout < 0 ? 0 : now_ms() + timeout;
    for (;;) {
        memset(&control, 0, sizeof(control));
        memset(&msg, 0, sizeof(msg));
        msg.msg_iov = &iov;
        msg.msg_iovlen = 1;
        msg.msg_control = control.buf;
        msg.msg_controllen = sizeof(control.buf);
        /* No MSG_CMSG_CLOEXEC: not each system has it. FD_CLOEXEC is
         * set below. */
        n = recvmsg(sock, &msg, 0);
        if (n >= 0)
            break;
        if (errno == EINTR)
            continue;
        if (errno != EAGAIN && errno != EWOULDBLOCK)
            return error_tuple(env, errno);
        int left = -1;
        if (timeout >= 0) {
            int64_t d = deadline - now_ms();
            if (d <= 0)
                return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                        enif_make_atom(env, "timeout"));
            left = (int)d;
        }
        int w = wait_fd(sock, POLLIN, left);
        if (w < 0)
            return error_tuple(env, errno);
    }

    /* The descriptors of the message, at most FD_MAX of them. */
    int fds[FD_MAX], count = 0, truncated;
    if (native_cmsg()) {
        size_t controllen = (uint32_t)msg.msg_controllen;
        unsigned flags = (unsigned)((uint64_t)msg.msg_controllen >> 32);
        size_t hdr = cmsg_hdrlen(), align = cmsg_align();
        char *p = control.buf, *end = control.buf + controllen;
        truncated = (flags & MSG_CTRUNC) == MSG_CTRUNC;
        if (controllen > sizeof(control.buf))
            end = control.buf + sizeof(control.buf);
        while (p + hdr <= end) {
            uint32_t len;
            int level, type;
            memcpy(&len, p, sizeof(len));
            memcpy(&level, p + 4, sizeof(level));
            memcpy(&type, p + 8, sizeof(type));
            if (len < hdr || len > (size_t)(end - p))
                break;
            if (level == SOL_SOCKET && type == SCM_RIGHTS) {
                for (char *d = p + hdr; d + sizeof(int) <= p + len; d += sizeof(int)) {
                    int got;
                    memcpy(&got, d, sizeof(got));
                    if (count < FD_MAX) {
                        fds[count++] = got;
                    } else {
                        close(got);
                        truncated = 1;
                    }
                }
            }
            p += (len + align - 1) & ~(align - 1);
        }
    } else {
        truncated = (msg.msg_flags & MSG_CTRUNC) == MSG_CTRUNC;
        for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
            if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS)
                continue;
            unsigned char *d = CMSG_DATA(c), *e = (unsigned char *)c + c->cmsg_len;
            for (; d + sizeof(int) <= e; d += sizeof(int)) {
                int got;
                memcpy(&got, d, sizeof(got));
                if (count < FD_MAX) {
                    fds[count++] = got;
                } else {
                    close(got);
                    truncated = 1;
                }
            }
        }
    }

    if (n == 0 && count == 0)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "closed"));
    if (n != 1 || count != 1 || truncated) {
        close_all(fds, count);
        return error_tuple(env, EINVAL);
    }
    int flags = fcntl(fds[0], F_GETFD);
    if (flags >= 0)
        fcntl(fds[0], F_SETFD, flags | FD_CLOEXEC);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_int(env, fds[0]));
}

static ErlNifFunc nif_funcs[] = {
    {"send_nif", 2, send_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"recv_nif", 2, recv_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(beam_com_fd, nif_funcs, NULL, NULL, NULL, NULL)
