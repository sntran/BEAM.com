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
 * The free space of the pipe comes from NtQueryInformationFile().
 * write() and writev() write at most that number of bytes, so the
 * WriteFile() of Cosmopolitan completes at once, and they give EAGAIN for
 * a full pipe. select() does not report a full pipe: it waits in steps of
 * at most PIPE_STEP_MS, and reports the pipe when it has space again. On
 * the other systems, and for other files, the wraps only call the
 * functions of the libc.
 *
 * The free space of the write end (WriteQuotaAvailable) is not correct
 * when a reader waits: Windows subtracts the size of the read that waits.
 * A reader that waits for 4096 bytes or more on an empty pipe gives 0, as
 * a full pipe does. A write of 1 byte to find the difference is not safe:
 * Windows can cancel it after the reader took the byte, and then the
 * caller writes the byte again. So, as Cygwin, the spawn driver gives the
 * read end of the pipe of each port program to beam_com_pipe_reader().
 * It keeps a query handle of the read end, with FILE_READ_ATTRIBUTES
 * only. The free space is then InboundQuota - ReadDataAvailable of the
 * read end, which a read that waits does not change.
 *
 * The query handle keeps the read end open. So when the handle count of
 * the read end is 1 (only the query handle), the wrap closes the query
 * handle, and the next write gives EPIPE. beam_com_pipe_forget() closes
 * it when the write end closes (__wrap_close() of beam_com.c). A pipe
 * with no query handle (for example the standard output of the emulator)
 * uses the free space of the write end.
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
#include <pthread.h>
#include <cosmo.h>
#include "libc/dce.h"
#include "libc/intrin/fds.h"
#include "libc/nt/enum/accessmask.h"
#include "libc/nt/enum/fileinformationclass.h"
#include "libc/nt/enum/filetype.h"
#include "libc/nt/files.h"
#include "libc/nt/enum/objectinformationclass.h"
#include "libc/nt/nt/file.h"
#include "libc/nt/ntdll.h"
#include "libc/nt/runtime.h"
#include "libc/nt/struct/objectbasicinformation.h"
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
void beam_com_pipe_reader(int wfd, int rfd);
void beam_com_pipe_forget(int fd);

/* For each write end FD: its handle, and the query handle of its read
 * end. The lock guards the table, also while a query uses a handle. */
static struct {
    int64_t write;
    int64_t query;
} pipe_ends[FD_SETSIZE];
static pthread_mutex_t pipe_lock = PTHREAD_MUTEX_INITIALIZER;

/* The write end of a pipe of Cosmopolitan on Windows. */
static int pipe_write_end(int fd)
{
    struct Fd *f;

    if (!IsWindows() || fd < 0 || (size_t)fd >= g_fds.n)
        return 0;
    f = g_fds.p + fd;
    return f->kind == kFdFile && (f->flags & O_ACCMODE) == O_WRONLY &&
           GetFileType(f->handle) == kNtFileTypePipe;
}

/* The pipe of WFD (the write end) and RFD (the read end): keep a query
 * handle of the read end. Before the close of RFD. */
void beam_com_pipe_reader(int wfd, int rfd)
{
    int64_t query = 0;

    if (!pipe_write_end(wfd) || wfd >= FD_SETSIZE || rfd < 0 ||
        (size_t)rfd >= g_fds.n || g_fds.p[rfd].kind != kFdFile)
        return;
    if (!DuplicateHandle(GetCurrentProcess(), g_fds.p[rfd].handle,
                         GetCurrentProcess(), &query, kNtFileReadAttributes,
                         0, 0))
        return; /* The free space of the write end. */
    pthread_mutex_lock(&pipe_lock);
    if (pipe_ends[wfd].query)
        CloseHandle(pipe_ends[wfd].query);
    pipe_ends[wfd].write = g_fds.p[wfd].handle;
    pipe_ends[wfd].query = query;
    pthread_mutex_unlock(&pipe_lock);
}

/* Before the close of FD. */
void beam_com_pipe_forget(int fd)
{
    if (!IsWindows() || fd < 0 || fd >= FD_SETSIZE)
        return;
    pthread_mutex_lock(&pipe_lock);
    if (pipe_ends[fd].query) {
        CloseHandle(pipe_ends[fd].query);
        pipe_ends[fd].query = 0;
        pipe_ends[fd].write = 0;
    }
    pthread_mutex_unlock(&pipe_lock);
}

/* The free space of the pipe of the write end FD from its query handle:
 * 1, or 0 when FD has no query handle. With the pipe lock. */
static int pipe_reader_space(int fd, int64_t handle, uint32_t *quota)
{
    struct NtFilePipeLocalInformation pi;
    struct NtObjectBasicInformation ob;
    struct NtIoStatusBlock io;
    int64_t query;

    if (fd >= FD_SETSIZE || !(query = pipe_ends[fd].query))
        return 0;
    if (pipe_ends[fd].write != handle) {
        /* An old entry (the close of FD did not call the wrap). */
        CloseHandle(query);
        pipe_ends[fd].query = 0;
        return 0;
    }
    memset(&ob, 0, sizeof(ob));
    memset(&pi, 0, sizeof(pi));
    if (NtQueryObject((void *)query, kNtObjectBasicInformation, &ob,
                      sizeof(ob), 0) != 0 || ob.HandleCount <= 1 ||
        NtQueryInformationFile(query, &io, &pi, sizeof(pi),
                               kNtFilePipeLocalInformation) != 0) {
        /* No reader: the write end gives EPIPE when the read end closes. */
        CloseHandle(query);
        pipe_ends[fd].query = 0;
        return 0;
    }
    *quota = pi.ReadDataAvailable < pi.InboundQuota
                 ? pi.InboundQuota - pi.ReadDataAvailable : 0;
    return 1;
}

/* 1 when FD is the write end of a non-blocking pipe on Windows, with its
 * free space in *quota: from the query handle of its read end, else from
 * the write end. 0 for another file, and for a pipe that gives no free
 * space (for example a broken pipe): the libc then gives the error. */
static int pipe_quota(int fd, uint32_t *quota)
{
    struct NtFilePipeLocalInformation pi;
    struct NtIoStatusBlock io;
    int ok;

    if (!pipe_write_end(fd) || !(g_fds.p[fd].flags & O_NONBLOCK))
        return 0;
    pthread_mutex_lock(&pipe_lock);
    ok = pipe_reader_space(fd, g_fds.p[fd].handle, quota);
    pthread_mutex_unlock(&pipe_lock);
    if (ok)
        return 1;
    memset(&pi, 0, sizeof(pi));
    if (NtQueryInformationFile(g_fds.p[fd].handle, &io, &pi, sizeof(pi),
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
