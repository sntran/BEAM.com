/*
 * The programs of the zip of this file (docs/PROGRAMS.md, "priv files as
 * real files").
 *
 * A path /zip/bin/NAME of a helper program (beam_com_zip_helper()) is
 * this file, executed again (beam_com_exec_helper() of beam_com.c). Each
 * other /zip path that names a regular file with an execute bit is a
 * program of the zip. The kernel cannot start a file of the zip, so
 * beam.com gives it a real file at the spawn:
 *
 *   - Linux: a memfd with the bytes of the program, sealed, and started
 *     with execve() of /proc/self/fd/N (beam_com_zip_memfd()). Only for
 *     an ELF program, and not in a sandbox.
 *   - The other systems, a sandbox, and each case where the memfd does
 *     not work: a copy in the cache, CACHE/bin/SHA256/NAME
 *     (beam_com_zip_cache()).
 *
 * The copy is written one time, and never changed: a new file with
 * O_EXCL, mode 0500, fsync(), then link() or rename() to its name. A
 * program that starts at the same time sees no half file, and a running
 * program keeps its file (macOS stops a signed program when its file
 * changes).
 */
#include <cosmo.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "libc/dce.h"
#include "beam_com_zipexec.h"

int memfd_create(const char *name, unsigned int flags);

/* The helper programs of beam_com_main() (beam_com.c), by name: a path
 * /zip/bin/NAME or /zip/erts-VSN/bin/NAME, with NAME, NAME.exe or
 * NAME.com, starts this file again. */
static const char *const zip_helpers[] = {
    "erl_child_setup", "inet_gethost", "epmd", "inotifywait", "mac_listener",
    "ssh_agent_bridge", "git_sha1dc", "make", "erl",
    /* The front end of erl in erts-VSN/bin, which peer starts when it
     * has no exec option: this file in erl mode. */
    "erlexec",
    /* The tools (elixir_tool() of beam_com.c). */
    "mix", "iex", "elixir", "elixirc", "escript", "rebar3"};

int beam_com_zip_helper(const char *path)
{
    const char *name, *p;
    size_t i, n;

    if (!path)
        return 0;
    if (strncmp(path, "/zip/bin/", 9) == 0) {
        name = path + 9;
    } else if (strncmp(path, "/zip/erts-", 10) == 0 && (p = strchr(path + 10, '/')) &&
               strncmp(p, "/bin/", 5) == 0) {
        name = p + 5;
    } else {
        return 0;
    }
    if (strchr(name, '/') || strchr(name, '\\'))
        return 0;
    for (i = 0; i < sizeof(zip_helpers) / sizeof(zip_helpers[0]); i++) {
        n = strlen(zip_helpers[i]);
        if (strncmp(name, zip_helpers[i], n) == 0 &&
            (name[n] == '\0' || strcmp(name + n, ".exe") == 0 || strcmp(name + n, ".com") == 0))
            return 1;
    }
    return 0;
}

int beam_com_zip_path(const char *path, char *out, size_t size)
{
    size_t n = 0, len, mark;
    const char *p = path, *end;

    if (!path || (path[0] != '/' && path[0] != '\\') || size < 6)
        return EINVAL;
    out[0] = '\0';
    while (*p) {
        while (*p == '/' || *p == '\\')
            p++;
        if (!*p)
            break;
        for (end = p; *end && *end != '/' && *end != '\\'; end++)
            ;
        len = end - p;
        if (len == 1 && p[0] == '.') {
            /* Nothing. */
        } else if (len == 2 && p[0] == '.' && p[1] == '.') {
            /* Back to the slash before the last part. */
            for (mark = n; mark > 0 && out[mark - 1] != '/'; mark--)
                ;
            n = mark > 0 ? mark - 1 : 0;
            out[n] = '\0';
        } else {
            if (n + 1 + len + 1 > size)
                return ENAMETOOLONG;
            out[n++] = '/';
            memcpy(out + n, p, len);
            n += len;
            out[n] = '\0';
        }
        p = end;
    }
    /* A program of the zip, not /zip itself. */
    if (strncmp(out, "/zip/", 5) != 0 || out[5] == '\0')
        return EINVAL;
    return 0;
}

int beam_com_zip_program(const char *path)
{
    struct stat st;

    if (stat(path, &st) != 0)
        return errno;
    if (!S_ISREG(st.st_mode) || !(st.st_mode & 0111))
        return EACCES;
    return 0;
}

/* --- SHA-256 (FIPS 180-4) --------------------------------------------- */

struct zip_sha256 {
    uint32_t h[8];
    uint64_t bytes;
    unsigned char block[64];
    size_t used;
};

static const uint32_t zip_sha256_k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
    0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
    0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
    0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
    0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
    0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
    0xc67178f2};

#define ZIP_ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void zip_sha256_block(uint32_t h[8], const unsigned char *p)
{
    uint32_t w[64], a, b, c, d, e, f, g, k, t1, t2;
    int i;

    for (i = 0; i < 16; i++)
        w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 |
               (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
    for (i = 16; i < 64; i++)
        w[i] = w[i - 16] + (ZIP_ROR(w[i - 15], 7) ^ ZIP_ROR(w[i - 15], 18) ^ (w[i - 15] >> 3)) +
               w[i - 7] + (ZIP_ROR(w[i - 2], 17) ^ ZIP_ROR(w[i - 2], 19) ^ (w[i - 2] >> 10));
    a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], k = h[7];
    for (i = 0; i < 64; i++) {
        t1 = k + (ZIP_ROR(e, 6) ^ ZIP_ROR(e, 11) ^ ZIP_ROR(e, 25)) + ((e & f) ^ (~e & g)) +
             zip_sha256_k[i] + w[i];
        t2 = (ZIP_ROR(a, 2) ^ ZIP_ROR(a, 13) ^ ZIP_ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        k = g, g = f, f = e, e = d + t1, d = c, c = b, b = a, a = t1 + t2;
    }
    h[0] += a, h[1] += b, h[2] += c, h[3] += d, h[4] += e, h[5] += f, h[6] += g, h[7] += k;
}

static void zip_sha256_init(struct zip_sha256 *s)
{
    static const uint32_t h0[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                   0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    memcpy(s->h, h0, sizeof(h0));
    s->bytes = 0;
    s->used = 0;
}

static void zip_sha256_update(struct zip_sha256 *s, const void *data, size_t n)
{
    const unsigned char *p = data;
    size_t take;

    s->bytes += n;
    if (s->used) {
        take = 64 - s->used < n ? 64 - s->used : n;
        memcpy(s->block + s->used, p, take);
        s->used += take, p += take, n -= take;
        if (s->used < 64)
            return;
        zip_sha256_block(s->h, s->block);
        s->used = 0;
    }
    for (; n >= 64; p += 64, n -= 64)
        zip_sha256_block(s->h, p);
    memcpy(s->block, p, n);
    s->used = n;
}

static void zip_sha256_hex(struct zip_sha256 *s, char hex[65])
{
    static const char digits[] = "0123456789abcdef";
    uint64_t bits = s->bytes * 8;
    unsigned char pad = 0x80, len[8];
    int i;

    for (i = 0; i < 8; i++)
        len[i] = (unsigned char)(bits >> (56 - 8 * i));
    s->bytes = 0; /* The padding does not count. */
    zip_sha256_update(s, &pad, 1);
    pad = 0;
    while (s->used != 56)
        zip_sha256_update(s, &pad, 1);
    zip_sha256_update(s, len, 8);
    for (i = 0; i < 32; i++) {
        unsigned char b = (unsigned char)(s->h[i / 4] >> (24 - 8 * (i % 4)));
        hex[2 * i] = digits[b >> 4];
        hex[2 * i + 1] = digits[b & 15];
    }
    hex[64] = '\0';
}

#define ZIP_BUFFER (1 << 20)

/* Reads all of FD. With OUT >= 0, it also writes each byte to OUT. With
 * HEX, it gives the SHA-256. 0, or an errno value. */
static int zip_copy(int fd, int out, char *hex)
{
    struct zip_sha256 s;
    char *buf = malloc(ZIP_BUFFER);
    ssize_t n, w, done;
    int err = 0;

    if (!buf)
        return ENOMEM;
    zip_sha256_init(&s);
    for (;;) {
        n = read(fd, buf, ZIP_BUFFER);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0) {
            err = n < 0 ? errno : 0;
            break;
        }
        if (hex)
            zip_sha256_update(&s, buf, n);
        for (done = 0; out >= 0 && done < n; done += w) {
            w = write(out, buf + done, n - done);
            if (w < 0 && errno == EINTR) {
                w = 0;
            } else if (w <= 0) {
                err = w < 0 ? errno : EIO;
                break;
            }
        }
        if (err)
            break;
    }
    free(buf);
    if (!err && hex)
        zip_sha256_hex(&s, hex);
    return err;
}

/* The root of the zip; the tests give another directory. */
static const char *zip_root = "/zip";

/* The results for the paths of the zip. */
struct zip_memo {
    struct zip_memo *next;
    char hex[65];
    char path[];
};
static struct zip_memo *zip_memos;
static pthread_mutex_t zip_memo_lock = PTHREAD_MUTEX_INITIALIZER;

/* The text of ROOT/.programs, or NULL. */
static char *zip_programs;
static int zip_programs_read;

/* The largest .programs file that beam.com reads. */
#define ZIP_PROGRAMS_MAX (4 << 20)

/* A path of the zip: the part after ROOT/, else NULL. */
static const char *zip_name(const char *path)
{
    size_t n = strlen(zip_root);

    return strncmp(path, zip_root, n) == 0 && path[n] == '/' ? path + n + 1 : NULL;
}

/*
 * The SHA-256 of the program of the zip NAME (a path after /zip/) in
 * ROOT/.programs, which the builder of beam.com writes: one line
 * "SHA256 SIZE NAME" for each file of the zip with an execute bit. So a
 * start needs no read of the whole program. 1 when the line is there and
 * has the SIZE of the file. The caller holds zip_memo_lock.
 */
static int zip_listed(const char *name, long long size, char hex[65])
{
    char file[PATH_MAX], *line, *end, *sp;
    size_t n = strlen(name);
    ssize_t got;
    int fd;

    if (!zip_programs_read) {
        zip_programs_read = 1;
        snprintf(file, sizeof(file), "%s/.programs", zip_root);
        if ((fd = open(file, O_RDONLY | O_CLOEXEC)) >= 0) {
            if ((zip_programs = malloc(ZIP_PROGRAMS_MAX + 1))) {
                got = read(fd, zip_programs, ZIP_PROGRAMS_MAX + 1);
                if (got < 0 || got > ZIP_PROGRAMS_MAX) {
                    free(zip_programs);
                    zip_programs = NULL;
                } else {
                    zip_programs[got] = '\0';
                }
            }
            close(fd);
        }
    }
    for (line = zip_programs; line && *line; line = *end ? end + 1 : end) {
        if (!(end = strchr(line, '\n')))
            end = line + strlen(line);
        /* 64 digits, a space, the size, a space, the name. */
        if (end - line < 67 || line[64] != ' ' || !(sp = memchr(line + 65, ' ', end - line - 65)))
            continue;
        if ((size_t)(end - sp - 1) != n || memcmp(sp + 1, name, n) != 0 ||
            strtoll(line + 65, NULL, 10) != size)
            continue;
        memcpy(hex, line, 64);
        hex[64] = '\0';
        return strspn(hex, "0123456789abcdef") == 64;
    }
    return 0;
}

int beam_com_zip_hash(const char *path, char hex[65])
{
    const char *name = zip_name(path);
    struct zip_memo *m;
    struct stat st;
    int fd, err, listed = 0;

    if (name) {
        if (stat(path, &st) != 0)
            return errno;
        pthread_mutex_lock(&zip_memo_lock);
        for (m = zip_memos; m && strcmp(m->path, path) != 0; m = m->next)
            ;
        if (m)
            memcpy(hex, m->hex, 65);
        else
            listed = zip_listed(name, st.st_size, hex);
        pthread_mutex_unlock(&zip_memo_lock);
        if (m || listed)
            return 0;
    }
    if ((fd = open(path, O_RDONLY | O_CLOEXEC)) < 0)
        return errno;
    err = zip_copy(fd, -1, hex);
    close(fd);
    if (!err && name && (m = malloc(sizeof(*m) + strlen(path) + 1))) {
        strcpy(m->path, path);
        memcpy(m->hex, hex, 65);
        pthread_mutex_lock(&zip_memo_lock);
        m->next = zip_memos;
        zip_memos = m;
        pthread_mutex_unlock(&zip_memo_lock);
    }
    return err;
}

/* --- The copy in the cache ----------------------------------------------- */

static const char *zip_home(void)
{
    const char *home = getenv("HOME");

    if (!home || !*home)
        home = getenv("USERPROFILE");
    return home && *home ? home : NULL;
}

int beam_com_zip_cache_dir(char *out, size_t size)
{
    const char *cache = getenv("BEAM_COM_CACHE"), *xdg = getenv("XDG_CACHE_HOME");
    const char *home = zip_home();
    int n;

    if (cache && *cache)
        n = snprintf(out, size, "%s", cache);
    else if (IsXnu() && home)
        n = snprintf(out, size, "%s/Library/Caches/beam.com", home);
    else if (!IsXnu() && xdg && *xdg)
        n = snprintf(out, size, "%s/beam.com", xdg);
    else if (home)
        n = snprintf(out, size, "%s/.cache/beam.com", home);
    else
        return ENOENT;
    if (n < 0 || (size_t)n >= size)
        return ENAMETOOLONG;
    /* No "/" at the end. */
    while (n > 1 && (out[n - 1] == '/' || out[n - 1] == '\\'))
        out[--n] = '\0';
    return 0;
}

/* mkdir -p with mode 0700 for each directory that it makes. On Windows,
 * "\\" is a separator too. */
static void zip_make_dirs(char *path)
{
    char *p, c;

    for (p = path + 1; *p; p++) {
        if (*p == '/' || (IsWindows() && *p == '\\')) {
            c = *p;
            *p = '\0';
            mkdir(path, 0700);
            *p = c;
        }
    }
    mkdir(path, 0700);
}

/*
 * A directory or a file of the cache that beam.com can trust: a real
 * directory (or a regular file) of this user, not a symbolic link, that
 * no other user can write. Else another user could change the program
 * that beam.com runs. A file also has the size of the program.
 *
 * On Windows, Cosmopolitan gives each file the user of the process and
 * the modes 0777 or 0555 (fstat-nt.c). There, only the kind of file and
 * the size count, and the access lists of the profile of the user keep
 * other users out of the cache.
 */
static int zip_trust(const char *path, int dir, long long size, char *msg, size_t msgsize)
{
    struct stat st;

    if (lstat(path, &st) != 0) {
        snprintf(msg, msgsize, "%s: %s", path, strerror(errno));
        return errno;
    }
    if ((dir ? !S_ISDIR(st.st_mode) : !S_ISREG(st.st_mode)) ||
        (!IsWindows() && (st.st_uid != geteuid() || (st.st_mode & 022)))) {
        snprintf(msg, msgsize,
                 dir ? "%s is not a real directory of this user, or another user can "
                       "write it: beam.com runs no program from it"
                     : "%s is not a regular file of this user, or another user can write "
                       "it: beam.com does not run it",
                 path);
        return EACCES;
    }
    if (!dir && st.st_size != size) {
        snprintf(msg, msgsize, "%s does not have the size of the program: beam.com does not "
                               "run it (remove the file)", path);
        return EACCES;
    }
    return 0;
}

/* The name of the copy: the name of the program, with ".exe" on Windows
 * when the name has no suffix (Windows starts only such a file). */
static const char *zip_suffix(const char *name)
{
    return IsWindows() && !strchr(name, '.') ? ".exe" : "";
}

static const char *zip_base(const char *path)
{
    const char *base = path;

    for (; *path; path++)
        if (*path == '/' || *path == '\\')
            base = path + 1;
    return base;
}

/*
 * The SHA-256 of the bytes of the program names the directory of the
 * copy: from /zip/.programs (zip_listed()), else from a read of the
 * program. The copy gets the bytes only when they have that SHA-256.
 * Each start checks the kind, the owner, the modes and the size of the
 * copy, but not its SHA-256 again: that reads the whole file at each
 * start (about 0.4 s for 100 MB). beam.com writes the copy one time, and
 * the checks of the directories make sure that only this user can change
 * it. This user can change the program file in any case.
 */
int beam_com_zip_cache(const char *path, int write, char *out, size_t size, char *msg,
                       size_t msgsize)
{
    char cache[PATH_MAX], bin[PATH_MAX], dir[PATH_MAX], tmp[PATH_MAX + 64], hex[65], check[65];
    const char *name = zip_base(path);
    struct timespec now;
    struct stat st;
    int err, fd, in, n, placed = 0;

    msg[0] = '\0';
    if (stat(path, &st) != 0) {
        err = errno;
        snprintf(msg, msgsize, "%s: %s", path, strerror(err));
        return err;
    }
    if ((err = beam_com_zip_cache_dir(cache, sizeof(cache)))) {
        snprintf(msg, msgsize, "%s: no cache directory (HOME or BEAM_COM_CACHE) for a copy "
                               "of the program", path);
        return err;
    }
    if ((err = beam_com_zip_hash(path, hex))) {
        snprintf(msg, msgsize, "%s: %s", path, strerror(err));
        return err;
    }
    if (snprintf(bin, sizeof(bin), "%s/bin", cache) >= (int)sizeof(bin) ||
        snprintf(dir, sizeof(dir), "%s/%s", bin, hex) >= (int)sizeof(dir) ||
        (n = snprintf(out, size, "%s/%s%s", dir, name, zip_suffix(name))) < 0 ||
        (size_t)n >= size) {
        snprintf(msg, msgsize, "%s: the path of the copy is too long", path);
        return ENAMETOOLONG;
    }
    if (write)
        zip_make_dirs(bin);
    if ((err = zip_trust(bin, 1, 0, msg, msgsize)))
        return err;
    if (write)
        mkdir(dir, 0700);
    if (lstat(dir, &st) == 0 || errno != ENOENT) {
        if ((err = zip_trust(dir, 1, 0, msg, msgsize)))
            return err;
    }
    if (lstat(out, &st) == 0 || errno != ENOENT) {
        if (stat(path, &st) != 0)
            return errno;
        return zip_trust(out, 0, st.st_size, msg, msgsize);
    }
    if (!write) {
        snprintf(msg, msgsize, "%s: there is no copy of the program in %s, and the sandbox "
                               "lets beam.com make one only at the start", path, dir);
        return ENOENT;
    }
    /* A new file in the directory of the copy, then rename(). */
    clock_gettime(CLOCK_REALTIME, &now);
    if (snprintf(tmp, sizeof(tmp), "%s/.%d.%ld", dir, (int)getpid(), (long)now.tv_nsec) >=
        (int)sizeof(tmp))
        return ENAMETOOLONG;
    if ((in = open(path, O_RDONLY | O_CLOEXEC)) < 0) {
        err = errno;
        snprintf(msg, msgsize, "%s: %s", path, strerror(err));
        return err;
    }
    if ((fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0500)) < 0) {
        err = errno;
        close(in);
        snprintf(msg, msgsize, "%s: %s", tmp, strerror(err));
        return err;
    }
    err = zip_copy(in, fd, check);
    close(in);
    /* The bytes of the copy are the bytes of the name (the line of
     * .programs, or the file at the first read). */
    if (!err && strcmp(check, hex) != 0) {
        close(fd);
        unlink(tmp);
        snprintf(msg, msgsize, "%s: the bytes of the program do not have the SHA-256 of "
                               "%s/.programs, or the file changed", path, zip_root);
        return EIO;
    }
    if (!err && fsync(fd) != 0)
        err = errno;
    if (close(fd) != 0 && !err)
        err = errno;
    /* link() does not replace a copy that another program made at the
     * same time. A file system with no links gets rename(), which
     * replaces it with the same bytes. */
    if (!err && !IsWindows() && link(tmp, out) == 0)
        placed = 1;
    else if (!err && !IsWindows() && errno == EEXIST)
        placed = 1;
    if (!err && !placed && rename(tmp, out) != 0) {
        err = errno;
        /* Another program made the copy first (Windows refuses to replace
         * a file that runs). */
        if (lstat(out, &st) == 0)
            err = 0;
    }
    if (err) {
        unlink(tmp);
        snprintf(msg, msgsize, "%s: a copy in %s: %s", path, dir, strerror(err));
        return err;
    }
    unlink(tmp);
    if (stat(path, &st) != 0)
        return errno;
    return zip_trust(out, 0, st.st_size, msg, msgsize);
}

/* --- The memfd of Linux ---------------------------------------------------- */

#define ZIP_MFD_CLOEXEC 0x0001u
#define ZIP_MFD_ALLOW_SEALING 0x0002u
#define ZIP_MFD_EXEC 0x0010u /* Linux 6.3 */
#define ZIP_F_ADD_SEALS 1033
#define ZIP_SEALS (1 | 2 | 4 | 8) /* F_SEAL_SEAL, SHRINK, GROW and WRITE */

int beam_com_zip_memfd(const char *path)
{
    char head[4], name[64];
    int in, fd, err;

    if (!IsLinux()) {
        errno = ENOSYS;
        return -1;
    }
    if ((in = open(path, O_RDONLY | O_CLOEXEC)) < 0)
        return -1;
    /* A script or an APE file needs its path: the cache. */
    if (read(in, head, 4) != 4 || memcmp(head, "\177ELF", 4) != 0 || lseek(in, 0, SEEK_SET) != 0) {
        close(in);
        errno = ENOEXEC;
        return -1;
    }
    snprintf(name, sizeof(name), "%s", zip_base(path));
    /* MFD_EXEC: a kernel with vm.memfd_noexec=1 seals a memfd without it
     * against exec. An older kernel refuses the flag with EINVAL. */
    fd = memfd_create(name, ZIP_MFD_CLOEXEC | ZIP_MFD_ALLOW_SEALING | ZIP_MFD_EXEC);
    if (fd < 0 && errno == EINVAL)
        fd = memfd_create(name, ZIP_MFD_CLOEXEC | ZIP_MFD_ALLOW_SEALING);
    if (fd < 0) {
        err = errno;
        close(in);
        errno = err;
        return -1;
    }
    err = zip_copy(in, fd, NULL);
    close(in);
    /* The seals: the bytes do not change after this point. */
    if (!err && fcntl(fd, ZIP_F_ADD_SEALS, ZIP_SEALS) != 0)
        err = errno;
    if (err) {
        close(fd);
        errno = err;
        return -1;
    }
    return fd;
}

/* --- The programs of a directory of the zip ------------------------------- */

void beam_com_zip_walk(const char *dir, void (*fn)(const char *path, void *arg), void *arg)
{
    struct dirent *e;
    struct stat st;
    char *path;
    DIR *d;

    if (strcmp(dir, "/zip/bin") == 0 || !(d = opendir(dir)))
        return;
    while ((e = readdir(d))) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
            continue;
        if (!(path = malloc(strlen(dir) + strlen(e->d_name) + 2)))
            break;
        sprintf(path, "%s/%s", dir, e->d_name);
        if (stat(path, &st) == 0 && S_ISDIR(st.st_mode))
            beam_com_zip_walk(path, fn, arg);
        else if (beam_com_zip_program(path) == 0)
            fn(path, arg);
        free(path);
    }
    closedir(d);
}
