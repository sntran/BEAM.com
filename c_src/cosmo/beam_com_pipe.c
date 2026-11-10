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
 * of bytes, so the WriteFile() of Cosmopolitan completes at once. On the
 * other systems, and for other files, the wraps only call the functions
 * of the libc.
 *
 * Windows subtracts the size of a read that waits from this free space.
 * A reader that waits for 4096 bytes or more on an empty pipe gives 0, as
 * a full pipe does. So, for the value 0, the wrap starts a write of 1
 * byte with its own OVERLAPPED, and gives 1. To a reader that waits, this
 * write completes at once, and the free space is correct again. To a full
 * pipe, it waits in the pipe until the reader reads, as on Unix the data
 * waits in the buffer of a pipe. The wrap never cancels it: Windows can
 * cancel a write of a pipe after the reader took the byte, and report 0
 * bytes, so the caller would write the byte two times. While the byte
 * waits, a write gives EAGAIN, and select() does not report the pipe. It
 * waits in steps of at most PIPE_STEP_MS, and reports the pipe when the
 * write of the byte ends. So a full pipe uses no CPU.
 *
 * The close of the write end (__wrap_close() of beam_com.c calls
 * beam_com_pipe_forget()) keeps a copy of the handle while the byte waits:
 * a thread closes the copy after the end of the write. The reader thus
 * gets the byte, and then the end of the file, as on Unix.
 *
 * Windows cancels a write that waits at the exit of the process, also a
 * write of a closer thread. On Unix, the data stays in the pipe. So after
 * the first byte that waits, an atexit() handler waits at most
 * PIPE_EXIT_MS (2 s) for the end of these writes, for all of them
 * together. A reader that reads gets each byte, and a reader that never
 * reads holds the exit for at most 2 s. The exit() of Cosmopolitan runs
 * this handler also when another thread calls exit(), as ERTS does for
 * erlang:halt/0,1. _exit() and ExitProcess() do not wait. A process with
 * no byte that waited has no handler. When no byte waits at the exit, the
 * handler returns at once.
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
#include <stdlib.h>
#include <cosmo.h>
#include "libc/dce.h"
#include "libc/intrin/fds.h"
#include "libc/nt/enum/fileinformationclass.h"
#include "libc/nt/enum/filetype.h"
#include "libc/nt/enum/wait.h"
#include "libc/nt/errors.h"
#include "libc/nt/events.h"
#include "libc/nt/files.h"
#include "libc/nt/nt/file.h"
#include "libc/nt/runtime.h"
#include "libc/nt/struct/overlapped.h"
#include "libc/nt/struct/filepipelocalinformation.h"
#include "libc/nt/struct/iostatusblock.h"
#include "libc/nt/synchronization.h"

/* The longest wait of select() for a full pipe. */
#define PIPE_STEP_MS 5
/* The reads of the free space in one write(), at most. */
#define PIPE_ROUNDS 4
/* The parts of an iovec array that one writev() gives to the libc. */
#define PIPE_IOV 64

extern struct Fds g_fds;

ssize_t __real_write(int fd, const void *buf, size_t size);
ssize_t __real_writev(int fd, const struct iovec *iov, int iovcnt);
int __real_select(int nfds, fd_set *r, fd_set *w, fd_set *e, struct timeval *tv);
ssize_t __wrap_write(int fd, const void *buf, size_t size);
ssize_t __wrap_writev(int fd, const struct iovec *iov, int iovcnt);
int __wrap_select(int nfds, fd_set *r, fd_set *w, fd_set *e, struct timeval *tv);
void beam_com_pipe_forget(int fd);

/* The longest wait at the exit of the process for all the bytes that
 * wait, together. */
#define PIPE_EXIT_MS 2000

/* A write of 1 byte that waits in a pipe. */
struct pipe_byte {
    struct NtOverlapped ov;
    int64_t handle;
    struct pipe_byte *next; /* in the list of the closer threads */
    unsigned char byte;
};

/* For each fd: the write of 1 byte that waits, or NULL. The bytes of the
 * closer threads. The lock guards both. */
static struct pipe_byte *pipe_bytes[FD_SETSIZE];
static struct pipe_byte *pipe_closing;
static pthread_mutex_t pipe_lock = PTHREAD_MUTEX_INITIALIZER;
/* The wait at exit: one atexit() handler, for the process that added it. */
static pthread_once_t pipe_exit_once = PTHREAD_ONCE_INIT;
static int pipe_exit_pid;
static void pipe_exit_init(void);

static void pipe_byte_free(struct pipe_byte *b)
{
    CloseHandle(b->ov.hEvent);
    free(b);
}

/* 1 while the write of 1 byte of FD waits. When it ended, the wrap frees
 * it. With the pipe lock. */
static int pipe_busy(int fd)
{
    struct pipe_byte *b;

    if (fd < 0 || fd >= FD_SETSIZE || !(b = pipe_bytes[fd]))
        return 0;
    if (b->handle != g_fds.p[fd].handle) {
        /* An old entry: the close of FD did not call the wrap. The write
         * can still use the memory, so it stays. */
        pipe_bytes[fd] = NULL;
        return 0;
    }
    if (WaitForSingleObject(b->ov.hEvent, 0) == kNtWaitTimeout)
        return 1;
    /* The end of the write: also an error, for example a broken pipe. The
     * next write then gets the error from the libc. */
    pipe_bytes[fd] = NULL;
    pipe_byte_free(b);
    return 0;
}

/* The write of the first byte of BUF to the pipe FD with no free space: 1,
 * or -1 and the error. With the pipe lock. */
static ssize_t pipe_try_byte(int fd, const void *buf)
{
    struct pipe_byte *b;
    int64_t h = g_fds.p[fd].handle;

    if (fd >= FD_SETSIZE || !(b = calloc(1, sizeof(*b)))) {
        errno = EAGAIN;
        return -1;
    }
    if (!(b->ov.hEvent = CreateEvent(0, 1, 0, 0))) {
        free(b);
        errno = EAGAIN;
        return -1;
    }
    b->handle = h;
    b->byte = *(const unsigned char *)buf;
    if (WriteFile(h, &b->byte, 1, 0, &b->ov)) {
        pipe_byte_free(b); /* Done at once. */
        return 1;
    }
    if (GetLastError() != kNtErrorIoPending) {
        /* For example a broken pipe: the libc gives the error. */
        pipe_byte_free(b);
        return __real_write(fd, buf, 1);
    }
    pipe_bytes[fd] = b; /* The byte is in the pipe now. */
    return 1;
}

/* Removes B from the list of the closer threads. */
static void pipe_unlink(struct pipe_byte *b)
{
    struct pipe_byte **p;

    pthread_mutex_lock(&pipe_lock);
    for (p = &pipe_closing; *p; p = &(*p)->next)
        if (*p == b) {
            *p = b->next;
            break;
        }
    pthread_mutex_unlock(&pipe_lock);
}

/* The thread for a closed fd: it waits for the end of the write of its
 * byte, then closes its copy of the handle. */
static void *pipe_closer(void *arg)
{
    struct pipe_byte *b = arg;

    WaitForSingleObject(b->ov.hEvent, -1u);
    pipe_unlink(b);
    CloseHandle(b->handle);
    pipe_byte_free(b);
    return 0;
}

/* Before the close of FD: while its byte waits, a copy of the handle stays
 * open until the end of the write. */
void beam_com_pipe_forget(int fd)
{
    struct pipe_byte *b;
    pthread_attr_t attr;
    pthread_t t;
    int64_t copy;

    if (!IsWindows() || fd < 0 || fd >= FD_SETSIZE)
        return;
    pthread_mutex_lock(&pipe_lock);
    if (!pipe_busy(fd)) {
        pthread_mutex_unlock(&pipe_lock);
        return;
    }
    b = pipe_bytes[fd];
    if (!DuplicateHandle(GetCurrentProcess(), b->handle, GetCurrentProcess(),
                         &copy, 0, 0, kNtDuplicateSameAccess)) {
        pipe_bytes[fd] = NULL;
        pthread_mutex_unlock(&pipe_lock);
        return; /* The write can still use B, so it stays. */
    }
    pipe_bytes[fd] = NULL;
    b->handle = copy;
    b->next = pipe_closing;
    pipe_closing = b; /* The wait at exit also waits for this byte. */
    pthread_mutex_unlock(&pipe_lock);
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attr, 65536);
    if (pthread_create(&t, &attr, pipe_closer, b) != 0) {
        pipe_unlink(b);
        CloseHandle(copy); /* The write ends with the close; B stays. */
    }
    pthread_attr_destroy(&attr);
}

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

/* The first SKIP bytes of IOV are written: the next bytes, at most MAX,
 * in at most PIPE_IOV parts in PART. The number of parts. */
static int pipe_parts(const struct iovec *iov, int iovcnt, size_t skip,
                      size_t max, struct iovec *part)
{
    int i, n = 0;

    for (i = 0; i < iovcnt && max > 0 && n < PIPE_IOV; i++) {
        if (iov[i].iov_len <= skip) {
            skip -= iov[i].iov_len;
            continue;
        }
        part[n].iov_base = (char *)iov[i].iov_base + skip;
        part[n].iov_len = iov[i].iov_len - skip;
        skip = 0;
        if (part[n].iov_len > max)
            part[n].iov_len = max;
        max -= part[n].iov_len;
        n++;
    }
    return n;
}

/* writev() of SIZE bytes (SIZE > 0) of IOV to the pipe FD, with its free
 * space QUOTA. After a write, it reads the free space again, at most
 * PIPE_ROUNDS times. */
static ssize_t pipe_writev(int fd, const struct iovec *iov, int iovcnt,
                           size_t size, uint32_t quota)
{
    struct iovec part[PIPE_IOV];
    size_t done = 0;
    ssize_t rc;
    int round, n, busy;

    pthread_mutex_lock(&pipe_lock);
    busy = pipe_busy(fd);
    pthread_mutex_unlock(&pipe_lock);
    if (busy) {
        errno = EAGAIN;
        return -1;
    }
    for (round = 0; round < PIPE_ROUNDS && done < size; round++) {
        if (round > 0 && !pipe_quota(fd, &quota))
            break;
        if (quota == 0 && done > 0)
            break;
        n = pipe_parts(iov, iovcnt, done, quota ? quota : 1, part);
        if (n == 0)
            break;
        if (quota) {
            rc = __real_writev(fd, part, n);
        } else {
            pthread_mutex_lock(&pipe_lock);
            rc = pipe_try_byte(fd, part[0].iov_base);
            busy = rc > 0 && pipe_bytes[fd];
            pthread_mutex_unlock(&pipe_lock);
        }
        if (rc <= 0)
            return done > 0 ? (ssize_t)done : rc;
        done += rc;
        if (quota == 0 && busy) {
            /* The byte waits in the pipe: the exit waits for it. */
            pthread_once(&pipe_exit_once, pipe_exit_init);
            break;
        }
    }
    return done;
}

ssize_t __wrap_write(int fd, const void *buf, size_t size)
{
    struct iovec iov;
    uint32_t quota;

    if (size == 0 || !pipe_quota(fd, &quota))
        return __real_write(fd, buf, size);
    iov.iov_base = (void *)buf;
    iov.iov_len = size;
    return pipe_writev(fd, &iov, 1, size, quota);
}

ssize_t __wrap_writev(int fd, const struct iovec *iov, int iovcnt)
{
    uint32_t quota;
    size_t size = 0;
    int i;

    if (iovcnt <= 0 || !pipe_quota(fd, &quota))
        return __real_writev(fd, iov, iovcnt);
    for (i = 0; i < iovcnt; i++)
        size += iov[i].iov_len;
    if (size == 0) /* No data: as the libc. */
        return __real_writev(fd, iov, iovcnt);
    return pipe_writev(fd, iov, iovcnt, size, quota);
}

static int64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* The handler of atexit(): it waits for the end of the writes of the
 * bytes that wait, at most PIPE_EXIT_MS for all together. Windows cancels
 * such a write at the exit of the process. A reader that reads thus gets
 * each byte that write() reported, as on Unix. */
static void pipe_exit_wait(void)
{
    static int64_t events[2 * FD_SETSIZE];
    struct pipe_byte *b;
    int64_t self = GetCurrentProcess(), left, end;
    int fd, n = 0, i, part;

    if (getpid() != pipe_exit_pid)
        return; /* A child of fork(): the writes are of the parent. */
    pthread_mutex_lock(&pipe_lock);
    for (fd = 0; fd < FD_SETSIZE; fd++)
        if ((b = pipe_bytes[fd]) &&
            DuplicateHandle(self, b->ov.hEvent, self, &events[n], 0, 0,
                            kNtDuplicateSameAccess))
            n++;
    for (b = pipe_closing; b && n < 2 * FD_SETSIZE; b = b->next)
        if (DuplicateHandle(self, b->ov.hEvent, self, &events[n], 0, 0,
                            kNtDuplicateSameAccess))
            n++;
    pthread_mutex_unlock(&pipe_lock);
    /* The copies of the events stay valid when a thread frees a byte. */
    end = now_ms() + PIPE_EXIT_MS;
    for (i = 0; i < n; i += part) {
        part = n - i < 64 ? n - i : 64; /* MAXIMUM_WAIT_OBJECTS */
        left = end - now_ms();
        WaitForMultipleObjects(part, events + i, 1, left > 0 ? left : 0);
    }
    for (i = 0; i < n; i++)
        CloseHandle(events[i]);
}

static void pipe_exit_init(void)
{
    pipe_exit_pid = getpid();
    atexit(pipe_exit_wait);
}

/* 1 when FD is the write end of a pipe with a byte that waits. */
static int pipe_waits(int fd)
{
    uint32_t quota;
    int busy;

    if (!pipe_quota(fd, &quota))
        return 0;
    pthread_mutex_lock(&pipe_lock);
    busy = pipe_busy(fd);
    pthread_mutex_unlock(&pipe_lock);
    return busy;
}

int __wrap_select(int nfds, fd_set *r, fd_set *w, fd_set *e, struct timeval *tv)
{
    fd_set held, r0, w0, e0;
    struct timeval step;
    int64_t end = 0, left;
    int fd, nheld = 0, rc, more, lim;

    if (!IsWindows() || !w || nfds <= 0)
        return __real_select(nfds, r, w, e, tv);
    lim = nfds > FD_SETSIZE ? FD_SETSIZE : nfds;
    FD_ZERO(&held);
    for (fd = 0; fd < lim; fd++)
        if (FD_ISSET(fd, w) && pipe_waits(fd)) {
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
            if (FD_ISSET(fd, &held) && !pipe_waits(fd)) {
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
