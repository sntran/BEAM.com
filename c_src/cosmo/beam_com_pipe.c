/*
 * Non-blocking writes to a pipe on Windows (C16 of docs/UPSTREAM.md).
 *
 * Cosmopolitan has two problems with a non-blocking pipe on Windows:
 *
 * - write() starts an overlapped WriteFile(). When the data does not fit
 *   in the pipe, it cancels the write and gives EAGAIN. When a reader
 *   waits, a part of the data can go into the pipe before the cancel, and
 *   the caller does not know it: the data is lost.
 * - select() and poll() always report the write end of a pipe as
 *   writable, also when the pipe is full. A program that writes until
 *   EAGAIN and then waits for the pipe (as ERTS does for a port program)
 *   then uses all the CPU.
 *
 * The wraps of write(), writev() and select() (PIPE_WRAPS of
 * scripts/steps.sh) fix both for the write end of a non-blocking pipe.
 * The free space of the pipe comes from NtQueryInformationFile()
 * (WriteQuotaAvailable). write() and writev() write at most that number
 * of bytes, so the WriteFile() of Cosmopolitan completes at once, and
 * they give EAGAIN for a full pipe. select() does not report a full pipe:
 * it waits in steps of at most PIPE_STEP_MS, and reports the pipe when it
 * has space again. On the other systems, and for other files, the wraps
 * only call the functions of the libc.
 *
 * With BEAM_COM_PIPE_TEST, the file compiles for the test
 * tests/cosmo/pipe_check.c.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/select.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>
#include <cosmo.h>
#include "libc/dce.h"
#include "libc/intrin/fds.h"
#include "libc/nt/enum/fileinformationclass.h"
#include "libc/nt/enum/filetype.h"
#include "libc/nt/files.h"
#include "libc/nt/nt/file.h"
#include "libc/nt/struct/filepipelocalinformation.h"
#include "libc/nt/struct/iostatusblock.h"

/* The longest wait of select() for a full pipe. */
#define PIPE_STEP_MS 5
/* The parts of an iovec array that one writev() gives to the libc. */
#define PIPE_IOV 64

extern struct Fds g_fds;

ssize_t __real_write(int fd, const void *buf, size_t size);
ssize_t __real_writev(int fd, const struct iovec *iov, int iovcnt);
int __real_select(int nfds, fd_set *r, fd_set *w, fd_set *e, struct timeval *tv);
ssize_t __wrap_write(int fd, const void *buf, size_t size);
ssize_t __wrap_writev(int fd, const struct iovec *iov, int iovcnt);
int __wrap_select(int nfds, fd_set *r, fd_set *w, fd_set *e, struct timeval *tv);

/* 1 when FD is the write end of a non-blocking pipe on Windows, with its
 * free space in *quota. 0 for another file, and for a pipe that gives no
 * free space (for example a broken pipe): the libc then gives the error. */
static int pipe_quota(int fd, uint32_t *quota)
{
    struct NtFilePipeLocalInformation pi;
    struct NtIoStatusBlock io;
    struct Fd *f;

    if (!IsWindows() || fd < 0 || (size_t)fd >= g_fds.n)
        return 0;
    f = g_fds.p + fd;
    if (f->kind != kFdFile || !(f->flags & O_NONBLOCK) ||
        (f->flags & O_ACCMODE) != O_WRONLY)
        return 0;
    if (GetFileType(f->handle) != kNtFileTypePipe)
        return 0;
    memset(&pi, 0, sizeof(pi));
    if (NtQueryInformationFile(f->handle, &io, &pi, sizeof(pi),
                               kNtFilePipeLocalInformation) != 0)
        return 0;
    *quota = pi.WriteQuotaAvailable;
    return 1;
}

ssize_t __wrap_write(int fd, const void *buf, size_t size)
{
    uint32_t quota;

    if (size == 0 || !pipe_quota(fd, &quota))
        return __real_write(fd, buf, size);
    if (quota == 0) {
        errno = EAGAIN;
        return -1;
    }
    return __real_write(fd, buf, size < quota ? size : quota);
}

ssize_t __wrap_writev(int fd, const struct iovec *iov, int iovcnt)
{
    struct iovec part[PIPE_IOV];
    uint32_t quota;
    size_t left;
    int i, n = 0;

    if (iovcnt <= 0 || !pipe_quota(fd, &quota))
        return __real_writev(fd, iov, iovcnt);
    /* The first QUOTA bytes, in at most PIPE_IOV parts. */
    left = quota;
    for (i = 0; i < iovcnt && left > 0 && n < PIPE_IOV; i++) {
        if (iov[i].iov_len == 0)
            continue;
        part[n] = iov[i];
        if (part[n].iov_len > left)
            part[n].iov_len = left;
        left -= part[n].iov_len;
        n++;
    }
    if (n == 0) {
        for (i = 0; i < iovcnt && iov[i].iov_len == 0; i++)
            ;
        if (i == iovcnt) /* No data: as the libc. */
            return __real_writev(fd, iov, iovcnt);
        errno = EAGAIN;
        return -1;
    }
    return __real_writev(fd, part, n);
}

static int64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int __wrap_select(int nfds, fd_set *r, fd_set *w, fd_set *e, struct timeval *tv)
{
    fd_set held, r0, w0, e0;
    struct timeval step;
    int64_t end = 0, left;
    uint32_t quota;
    int fd, nheld = 0, rc, more, lim;

    if (!IsWindows() || !w || nfds <= 0)
        return __real_select(nfds, r, w, e, tv);
    lim = nfds > FD_SETSIZE ? FD_SETSIZE : nfds;
    FD_ZERO(&held);
    for (fd = 0; fd < lim; fd++)
        if (FD_ISSET(fd, w) && pipe_quota(fd, &quota) && quota == 0) {
            FD_CLR(fd, w);
            FD_SET(fd, &held);
            nheld++;
        }
    if (nheld == 0)
        return __real_select(nfds, r, w, e, tv);

    if (r)
        r0 = *r;
    w0 = *w;
    if (e)
        e0 = *e;
    if (tv)
        end = now_ms() + (int64_t)tv->tv_sec * 1000 + tv->tv_usec / 1000;
    for (;;) {
        left = PIPE_STEP_MS;
        if (tv) {
            left = end - now_ms();
            if (left < 0)
                left = 0;
            if (left > PIPE_STEP_MS)
                left = PIPE_STEP_MS;
        }
        step.tv_sec = 0;
        step.tv_usec = left * 1000;
        rc = __real_select(nfds, r, w, e, &step);
        if (rc < 0)
            return rc;
        more = 0;
        for (fd = 0; fd < lim; fd++)
            if (FD_ISSET(fd, &held) && (!pipe_quota(fd, &quota) || quota > 0)) {
                FD_SET(fd, w);
                more++;
            }
        if (rc + more > 0)
            return rc + more;
        if (tv && end - now_ms() <= 0)
            return 0;
        /* Nothing yet: the sets again, for the next step. */
        if (r)
            *r = r0;
        *w = w0;
        if (e)
            *e = e0;
    }
}
