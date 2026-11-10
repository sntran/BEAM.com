/*
 * --- Sandbox: the files where the system has none -----------------------
 *
 * On Linux and OpenBSD, unveil() limits the paths in the kernel. Windows
 * has no such call for a process, so there the wraps of the file calls of
 * the libc check each path against --allow-read and --allow-write (the
 * link has -Wl,--wrap for each one, FS_WRAPS of scripts/steps.sh):
 *
 * - A read (open() for reading, opendir(), readlink()) needs a path of
 *   --allow-read or of --allow-write.
 * - A change (open() for writing, creat(), mkdir(), rmdir(), unlink(),
 *   rename(), link(), symlink(), chmod(), chown(), truncate(), and the
 *   calls of the times) needs a path of --allow-write.
 * - stat() and access() need no permission, as with Landlock.
 * - A refused call gives EACCES, and a refused read of a path that does
 *   not exist gives ENOENT.
 *
 * The check uses the name: the path is made absolute (with the working
 * directory), "." and ".." go, and on Windows the case and the form of
 * the drive ("C:\" and "/C/") do not count. The program can always read
 * its own file, the zip in it (/zip), /dev/null, and the files of the
 * start that beam.com gives it (beam_com_fs_allow()).
 *
 * Caution: the check does not follow a link. A link or a junction in an
 * allowed directory can lead outside it. Native code that makes the
 * system calls itself does not go through the check.
 *
 * BEAM_COM_FS_CHECK=1 with BEAM_COM_ALLOW turns the check on also on
 * Linux, for the tests (apply_allow() of beam_com.c).
 */
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <utime.h>
#include <dirent.h>
#ifndef BEAM_COM_FS_TEST
#include <cosmo.h>
#include "libc/dce.h" /* IsWindows() */
#endif
#include "beam_com_fs.h"

#define FS_RULES 256
#define FS_PATH 4096

struct fs_rule {
    char *path; /* normalized */
    int write;
};

static struct fs_rule fs_rules[FS_RULES];
static int fs_nrules, fs_read_all, fs_write_all;
static int fs_policy; /* a policy exists */
static int fs_on;     /* the check runs */

#ifdef BEAM_COM_FS_TEST
static int fs_windows;
#define IS_WINDOWS() fs_windows
#else
#define IS_WINDOWS() IsWindows()
#endif

static char fs_lower(char c)
{
    return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c;
}

/* A name of Windows that a check of the name cannot see well: a part
 * that ends with "." or " " (Windows removes them, so ".. " is ".."), a
 * ":" after the drive (a stream, or a path relative to a drive), and
 * "//" at the start (a share, or a device: "\\?\", "\\.\"). */
static int fs_windows_bad(const char *p)
{
    size_t n;

    if (p[0] == '/' && p[1] == '/')
        return 1;
    if (strchr(p, ':'))
        return 1;
    while (*p) {
        while (*p == '/')
            p++;
        n = strcspn(p, "/");
        if (n && (p[n - 1] == '.' || p[n - 1] == ' ') && strncmp(p, ".", n) != 0 &&
            strncmp(p, "..", n) != 0)
            return 1;
        p += n;
    }
    return 0;
}

/* "\\" to "/", then fs_windows_bad(). */
static int fs_windows_slashes(char *p)
{
    char *c;

    for (c = p; *c; c++)
        if (*c == '\\')
            *c = '/';
    return fs_windows_bad(p);
}

/* The normal form of path in out (FS_PATH bytes): absolute, with "/"
 * only, no "." and "..", and on Windows "/c/..." in lower case. Gives
 * 0, or -1 for a path that is too long or that fs_windows_bad() refuses. */
static int fs_norm(const char *path, char *out)
{
    char tmp[FS_PATH], cwd[FS_PATH];
    char *seg[FS_PATH / 2];
    size_t n = 0, i, len;
    int nseg = 0, k;
    char *p, *save = NULL;

    if (!path || !*path || strlen(path) >= FS_PATH - 4)
        return -1;
    /* "C:", "C:\x" and "C:/x" are "/C", "/C/x". */
    if (IS_WINDOWS() && ((path[0] | 0x20) >= 'a' && (path[0] | 0x20) <= 'z') &&
        path[1] == ':' && (path[2] == '\\' || path[2] == '/' || !path[2]))
        snprintf(tmp, sizeof(tmp), "/%c%s", path[0], path + 2);
    else
        snprintf(tmp, sizeof(tmp), "%s", path);
    if (IS_WINDOWS() && fs_windows_slashes(tmp))
        return -1;
    if (tmp[0] != '/') {
        if (!getcwd(cwd, sizeof(cwd)) || strlen(cwd) + strlen(tmp) + 2 > sizeof(cwd))
            return -1;
        strcat(cwd, "/");
        strcat(cwd, tmp);
        snprintf(tmp, sizeof(tmp), "%s", cwd);
        if (IS_WINDOWS() && fs_windows_slashes(tmp))
            return -1;
    }
    for (p = strtok_r(tmp, "/", &save); p; p = strtok_r(NULL, "/", &save)) {
        if (strcmp(p, ".") == 0)
            continue;
        if (strcmp(p, "..") == 0) {
            if (nseg)
                nseg--;
            continue;
        }
        seg[nseg++] = p;
    }
    out[n++] = '/';
    for (k = 0; k < nseg; k++) {
        len = strlen(seg[k]);
        if (n + len + 2 >= FS_PATH)
            return -1;
        if (k)
            out[n++] = '/';
        for (i = 0; i < len; i++)
            out[n++] = IS_WINDOWS() ? fs_lower(seg[k][i]) : seg[k][i];
    }
    out[n] = '\0';
    return 0;
}

static int fs_under(const char *path, const char *rule)
{
    size_t n = strlen(rule);
    if (n == 1 && rule[0] == '/')
        return 1;
    return strncmp(path, rule, n) == 0 && (path[n] == '\0' || path[n] == '/');
}

void beam_com_fs_allow(const char *path, int write)
{
    char norm[FS_PATH];

    if (fs_nrules >= FS_RULES || fs_norm(path, norm))
        return;
    fs_rules[fs_nrules].path = strdup(norm);
    fs_rules[fs_nrules].write = write;
    if (fs_rules[fs_nrules].path)
        fs_nrules++;
}

void beam_com_fs_allow_all(int write)
{
    if (write)
        fs_write_all = 1;
    fs_read_all = 1;
}

void beam_com_fs_policy(void)
{
    fs_policy = 1;
    beam_com_fs_allow("/dev/null", 1);
    beam_com_fs_allow("/zip", 0);
#ifndef BEAM_COM_FS_TEST
    beam_com_fs_allow(GetProgramExecutableName(), 0);
#endif
}

void beam_com_fs_start(void)
{
    if (fs_policy)
        fs_on = 1;
}

int beam_com_fs_check(const char *path, int write)
{
    char norm[FS_PATH];
    struct stat st;
    int i;

    if (!fs_on || (write ? fs_write_all : fs_read_all))
        return 0;
    if (path && fs_norm(path, norm) == 0)
        for (i = 0; i < fs_nrules; i++)
            if ((fs_rules[i].write || !write) && fs_under(norm, fs_rules[i].path))
                return 0;
    /* A read of a path that does not exist gives ENOENT, as with
     * Landlock: stat() needs no permission, so this tells nothing new.
     * init reads ~/.erlang, and an EACCES gives an error report. */
    errno = !write && path && stat(path, &st) == -1 && errno == ENOENT ? ENOENT : EACCES;
    return -1;
}

/* A path relative to a directory descriptor: only AT_FDCWD (or an
 * absolute path) has a name for the check. */
static int fs_check_at(int dirfd, const char *path, int write)
{
    if (!fs_on || (write ? fs_write_all : fs_read_all))
        return 0;
    if (dirfd != AT_FDCWD && path && path[0] != '/' &&
        !(IS_WINDOWS() && path[0] && path[1] == ':')) {
        errno = EACCES;
        return -1;
    }
    return beam_com_fs_check(path, write);
}

static int fs_open_writes(int flags)
{
    return (flags & O_ACCMODE) != O_RDONLY || (flags & (O_CREAT | O_TRUNC | O_APPEND));
}

/* --- The wraps ------------------------------------------------------- */

int __real_open(const char *, int, ...);
int __real_openat(int, const char *, int, ...);
int __real_creat(const char *, mode_t);
DIR *__real_opendir(const char *);
ssize_t __real_readlink(const char *, char *, size_t);
ssize_t __real_readlinkat(int, const char *, char *, size_t);
int __real_unlink(const char *);
int __real_unlinkat(int, const char *, int);
int __real_rmdir(const char *);
int __real_rename(const char *, const char *);
int __real_renameat(int, const char *, int, const char *);
int __real_link(const char *, const char *);
int __real_linkat(int, const char *, int, const char *, int);
int __real_symlink(const char *, const char *);
int __real_symlinkat(const char *, int, const char *);
int __real_chmod(const char *, mode_t);
int __real_fchmodat(int, const char *, mode_t, int);
int __real_truncate(const char *, off_t);
int __real_utimes(const char *, const struct timeval[2]);
int __real_utimensat(int, const char *, const struct timespec[2], int);
int __real_utime(const char *, const struct utimbuf *);
int __real_mkdirat(int, const char *, mode_t);
int __real_lchown(const char *, uid_t, gid_t);
int __real_fchownat(int, const char *, uid_t, gid_t, int);

int __wrap_open(const char *, int, ...);
int __wrap_openat(int, const char *, int, ...);
int __wrap_creat(const char *, mode_t);
DIR *__wrap_opendir(const char *);
ssize_t __wrap_readlink(const char *, char *, size_t);
ssize_t __wrap_readlinkat(int, const char *, char *, size_t);
int __wrap_unlink(const char *);
int __wrap_unlinkat(int, const char *, int);
int __wrap_rmdir(const char *);
int __wrap_rename(const char *, const char *);
int __wrap_renameat(int, const char *, int, const char *);
int __wrap_link(const char *, const char *);
int __wrap_linkat(int, const char *, int, const char *, int);
int __wrap_symlink(const char *, const char *);
int __wrap_symlinkat(const char *, int, const char *);
int __wrap_chmod(const char *, mode_t);
int __wrap_fchmodat(int, const char *, mode_t, int);
int __wrap_truncate(const char *, off_t);
int __wrap_utimes(const char *, const struct timeval[2]);
int __wrap_utimensat(int, const char *, const struct timespec[2], int);
int __wrap_utime(const char *, const struct utimbuf *);
int __wrap_mkdirat(int, const char *, mode_t);
int __wrap_lchown(const char *, uid_t, gid_t);
int __wrap_fchownat(int, const char *, uid_t, gid_t, int);

int __wrap_open(const char *path, int flags, ...)
{
    va_list ap;
    unsigned mode = 0;

    va_start(ap, flags);
    if (flags & O_CREAT)
        mode = va_arg(ap, unsigned);
    va_end(ap);
    if (beam_com_fs_check(path, fs_open_writes(flags)))
        return -1;
    return __real_open(path, flags, mode);
}

int __wrap_openat(int dirfd, const char *path, int flags, ...)
{
    va_list ap;
    unsigned mode = 0;

    va_start(ap, flags);
    if (flags & O_CREAT)
        mode = va_arg(ap, unsigned);
    va_end(ap);
    if (fs_check_at(dirfd, path, fs_open_writes(flags)))
        return -1;
    return __real_openat(dirfd, path, flags, mode);
}

int __wrap_creat(const char *path, mode_t mode)
{
    return beam_com_fs_check(path, 1) ? -1 : __real_creat(path, mode);
}

DIR *__wrap_opendir(const char *path)
{
    return beam_com_fs_check(path, 0) ? NULL : __real_opendir(path);
}

ssize_t __wrap_readlink(const char *path, char *buf, size_t n)
{
    return beam_com_fs_check(path, 0) ? -1 : __real_readlink(path, buf, n);
}

ssize_t __wrap_readlinkat(int dirfd, const char *path, char *buf, size_t n)
{
    return fs_check_at(dirfd, path, 0) ? -1 : __real_readlinkat(dirfd, path, buf, n);
}

int __wrap_unlink(const char *path)
{
    return beam_com_fs_check(path, 1) ? -1 : __real_unlink(path);
}

int __wrap_unlinkat(int dirfd, const char *path, int flags)
{
    return fs_check_at(dirfd, path, 1) ? -1 : __real_unlinkat(dirfd, path, flags);
}

int __wrap_rmdir(const char *path)
{
    return beam_com_fs_check(path, 1) ? -1 : __real_rmdir(path);
}

int __wrap_rename(const char *from, const char *to)
{
    if (beam_com_fs_check(from, 1) || beam_com_fs_check(to, 1))
        return -1;
    return __real_rename(from, to);
}

int __wrap_renameat(int fromfd, const char *from, int tofd, const char *to)
{
    if (fs_check_at(fromfd, from, 1) || fs_check_at(tofd, to, 1))
        return -1;
    return __real_renameat(fromfd, from, tofd, to);
}

int __wrap_link(const char *from, const char *to)
{
    if (beam_com_fs_check(from, 0) || beam_com_fs_check(to, 1))
        return -1;
    return __real_link(from, to);
}

int __wrap_linkat(int fromfd, const char *from, int tofd, const char *to, int flags)
{
    if (fs_check_at(fromfd, from, 0) || fs_check_at(tofd, to, 1))
        return -1;
    return __real_linkat(fromfd, from, tofd, to, flags);
}

/* The target of a link is text: only the new name counts. */
/*
 * On Windows, symlink() of Cosmopolitan makes a link to a directory only
 * when the target is a directory, but it reads a relative target from the
 * working directory, not from the directory of the link (C54 of
 * docs/UPSTREAM.md). Mix makes _build/prod/lib/APP/priv with the target
 * ../../../../priv, and Windows then gives EACCES for each stat() and
 * open() through the link. When the target, read from the directory of
 * the link, is a directory, this gives the target with a "/" at the end:
 * then Cosmopolitan makes a link to a directory. Buf has FS_PATH bytes.
 */
static const char *fs_link_target(const char *target, int dirfd, const char *path, char *buf)
{
    size_t n = strlen(target), d = 0, i;
    struct stat st;

    if (!IS_WINDOWS() || n == 0 || target[n - 1] == '/' || target[n - 1] == '\\'
        || target[0] == '/' || target[0] == '\\' || (n > 1 && target[1] == ':')
        || dirfd != AT_FDCWD)
        return target;
    for (i = 0; path[i]; i++)
        if (path[i] == '/' || path[i] == '\\')
            d = i + 1;
    if (d + n + 2 > FS_PATH)
        return target;
    memcpy(buf, path, d);
    memcpy(buf + d, target, n + 1);
    if (stat(buf, &st) != 0 || !S_ISDIR(st.st_mode))
        return target;
    memcpy(buf, target, n);
    buf[n] = '/';
    buf[n + 1] = 0;
    return buf;
}

int __wrap_symlink(const char *target, const char *path)
{
    char buf[FS_PATH];

    if (beam_com_fs_check(path, 1))
        return -1;
    return __real_symlink(fs_link_target(target, AT_FDCWD, path, buf), path);
}

int __wrap_symlinkat(const char *target, int dirfd, const char *path)
{
    char buf[FS_PATH];

    if (fs_check_at(dirfd, path, 1))
        return -1;
    return __real_symlinkat(fs_link_target(target, dirfd, path, buf), dirfd, path);
}

int __wrap_chmod(const char *path, mode_t mode)
{
    return beam_com_fs_check(path, 1) ? -1 : __real_chmod(path, mode);
}

int __wrap_fchmodat(int dirfd, const char *path, mode_t mode, int flags)
{
    return fs_check_at(dirfd, path, 1) ? -1 : __real_fchmodat(dirfd, path, mode, flags);
}

int __wrap_truncate(const char *path, off_t size)
{
    return beam_com_fs_check(path, 1) ? -1 : __real_truncate(path, size);
}

int __wrap_utimes(const char *path, const struct timeval tv[2])
{
    return beam_com_fs_check(path, 1) ? -1 : __real_utimes(path, tv);
}

int __wrap_utimensat(int dirfd, const char *path, const struct timespec ts[2], int flags)
{
    /* A NULL path changes the times of dirfd itself (futimens()). */
    if (path && fs_check_at(dirfd, path, 1))
        return -1;
    return __real_utimensat(dirfd, path, ts, flags);
}

int __wrap_utime(const char *path, const struct utimbuf *t)
{
    return beam_com_fs_check(path, 1) ? -1 : __real_utime(path, t);
}

int __wrap_mkdirat(int dirfd, const char *path, mode_t mode)
{
    return fs_check_at(dirfd, path, 1) ? -1 : __real_mkdirat(dirfd, path, mode);
}

int __wrap_lchown(const char *path, uid_t uid, gid_t gid)
{
    return beam_com_fs_check(path, 1) ? -1 : __real_lchown(path, uid, gid);
}

int __wrap_fchownat(int dirfd, const char *path, uid_t uid, gid_t gid, int flags)
{
    return fs_check_at(dirfd, path, 1) ? -1 : __real_fchownat(dirfd, path, uid, gid, flags);
}
