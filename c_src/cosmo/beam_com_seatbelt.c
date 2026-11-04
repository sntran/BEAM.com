/*
 * --- Sandbox: Seatbelt on macOS -----------------------------------------
 *
 * macOS has no pledge() and no unveil(). Its sandbox is Seatbelt: a
 * profile in SBPL that sandbox_init() of libSystem applies to the
 * process and to each process that it starts later. apply_allow() of
 * beam_com.c gives each path of unveil() here (beam_com_seatbelt_allow()),
 * so the rules are the rules of Linux:
 *
 * - "r": the path can be read (file-read-data).
 * - "w" or "c": the path can be read and changed (file-write*).
 * - "x": the path can be read and executed (process-exec).
 *
 * The profile allows each other operation (allow default), and then it
 * refuses:
 *
 * - the read of the data of each file, except the paths of the rules and
 *   the files of the system, which hold no data of a person: /System,
 *   /usr, /bin, /sbin, /Library/Apple, /private/preboot (the cryptexes of
 *   the boot) and the shared cache of dyld. dyld of macOS 26 needs some
 *   of them to start a process: without them, it stops in
 *   ignition_halt() before main(), and the log has no refusal. The
 *   metadata (stat()) needs no permission, as with Landlock;
 * - each change of a file, except the paths of the rules, /dev/null,
 *   /dev/dtracehelper and the terminals;
 * - each new program, except the paths of the rules with "x" (this
 *   file, the APE loader, and the programs of --allow-run);
 * - the network, without --allow-net: the sockets of IP, a connection
 *   to a Unix socket with a path, and the DNS service of macOS. A pair
 *   of sockets (socketpair()) stays allowed: ERTS gives the requests of
 *   the ports to erl_child_setup over one, as with pledge() on Linux.
 *
 * Seatbelt takes the last rule that matches, among the rules with a
 * path, so the allowed paths come after the refusal of "/". A path of a
 * rule is its real path, because Seatbelt compares real paths (/tmp is
 * /private/tmp). A refused call gives EPERM.
 *
 * sandbox_init() is in libSystem, which only the APE loader of macOS
 * arm64 gives to a Cosmopolitan program (cosmo_dlopen()). On macOS
 * x86_64, there is no sandbox: the flags have no effect there.
 *
 * A helper program (erl_child_setup) keeps the profile of its parent,
 * so it does not apply it again.
 */
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef BEAM_COM_SEATBELT_TEST
#include <cosmo.h>
#include "libc/dce.h"              /* IsXnuSilicon() */
#include "libc/dlopen/dlfcn.h"     /* cosmo_dlopen() */
#endif
#include "beam_com_seatbelt.h"

#define SB_RULES 512
#define SB_PROFILE (256 * 1024)

struct sb_rule {
    char *path; /* a real path */
    int read, write, exec;
};

static struct sb_rule sb_rules[SB_RULES];
static int sb_nrules;
static int sb_net;
static int sb_full; /* a rule was left out: the profile refuses all */

/* The real path of path, or of its directory and its name when it does
 * not exist (a file of --allow-write that the program makes later).
 * NULL when the directory does not exist either. */
static char *sb_real(const char *path)
{
    char buf[PATH_MAX], dir[PATH_MAX], *slash, *real;

    if ((real = realpath(path, NULL)))
        return real;
    if (strlen(path) >= sizeof(dir))
        return NULL;
    strcpy(dir, path);
    if (!(slash = strrchr(dir, '/')) || !slash[1])
        return NULL;
    *slash = '\0';
    if (!realpath(*dir ? dir : "/", buf) ||
        strlen(buf) + strlen(slash + 1) + 2 > sizeof(buf))
        return NULL;
    if (strcmp(buf, "/") != 0)
        strcat(buf, "/");
    strcat(buf, slash + 1);
    return strdup(buf);
}

/* The program file (its real path) and the text of its permissions,
 * for the digest of BEAM_COM_SEATBELT. */
static char *sb_identity;

void beam_com_seatbelt_identity(const char *text)
{
    const char *nl = strchr(text, '\n');
    char *file, *real;
    size_t n;

    free(sb_identity);
    if (!nl || !(file = strndup(text, (size_t)(nl - text)))) {
        sb_identity = strdup(text);
        return;
    }
    real = sb_real(file);
    free(file);
    n = (real ? strlen(real) : 0) + strlen(nl) + 1;
    if ((sb_identity = malloc(n)))
        snprintf(sb_identity, n, "%s%s", real ? real : "", nl);
    free(real);
}

void beam_com_seatbelt_allow(const char *path, const char *permissions)
{
    struct sb_rule *r;
    char *real;

    if (!path || !*path || !(real = sb_real(path)))
        return;
    if (sb_nrules >= SB_RULES) {
        free(real);
        sb_full = 1;
        return;
    }
    r = &sb_rules[sb_nrules++];
    r->path = real;
    r->read = !!strpbrk(permissions, "rwcx");
    r->write = !!strpbrk(permissions, "wc");
    r->exec = !!strchr(permissions, 'x');
}

void beam_com_seatbelt_net(int allowed)
{
    sb_net = allowed;
}

/* A string of SBPL: "PATH", with \ and " escaped. 0 when it does not
 * fit, or when the path has a control character. */
static int sb_string(char *out, size_t *n, size_t size, const char *s)
{
    if (*n + 2 >= size)
        return 0;
    out[(*n)++] = '"';
    for (; *s; s++) {
        if ((unsigned char)*s < 0x20 || *s == 0x7f)
            return 0;
        if (*n + 4 >= size)
            return 0;
        if (*s == '"' || *s == '\\')
            out[(*n)++] = '\\';
        out[(*n)++] = *s;
    }
    out[(*n)++] = '"';
    out[*n] = '\0';
    return 1;
}

static int sb_text(char *out, size_t *n, size_t size, const char *s)
{
    size_t len = strlen(s);

    if (*n + len + 1 >= size)
        return 0;
    memcpy(out + *n, s, len + 1);
    *n += len;
    return 1;
}

/* One rule: "(allow OPERATION (subpath "PATH"))" for each rule with the
 * permission. A path of "/" is (subpath "/"). */
static int sb_allow(char *out, size_t *n, size_t size, const char *operation, int which)
{
    int i, ok = 1;

    for (i = 0; i < sb_nrules && ok; i++) {
        const struct sb_rule *r = &sb_rules[i];
        int want = which == 0 ? r->read : which == 1 ? r->write : r->exec;
        if (!want)
            continue;
        ok = sb_text(out, n, size, "(allow ") && sb_text(out, n, size, operation) &&
             sb_text(out, n, size, " (subpath ") && sb_string(out, n, size, r->path) &&
             sb_text(out, n, size, "))\n");
    }
    return ok;
}

/* The parts of the profile that BEAM_COM_SEATBELT_OMIT leaves out, for a
 * test that finds the part that stops a program (beam_com_seatbelt_omit()). */
static int sb_omit_read, sb_omit_write, sb_omit_exec, sb_omit_net;

void beam_com_seatbelt_omit(const char *parts)
{
    sb_omit_read = !!strstr(parts, "read");
    sb_omit_write = !!strstr(parts, "write");
    sb_omit_exec = !!strstr(parts, "exec");
    sb_omit_net = !!strstr(parts, "net");
}

const char *beam_com_seatbelt_profile(void)
{
    static char out[SB_PROFILE];
    size_t n = 0;
    int ok;

    /* A rule that does not fit refuses each operation: never a profile
     * with less than the rules. */
    if (sb_full)
        return "(version 1)\n(deny default)\n";
    ok = sb_text(out, &n, sizeof(out), "(version 1)\n(allow default)\n");
    /* The reads. */
    if (ok && !sb_omit_read)
        ok = sb_text(out, &n, sizeof(out),
                     "(deny file-read-data (subpath \"/\"))\n"
                     "(allow file-read-data (literal \"/\") (subpath \"/System\")\n"
                     "    (subpath \"/usr\") (subpath \"/bin\") (subpath \"/sbin\")\n"
                     "    (subpath \"/Library/Apple\") (subpath \"/private/preboot\")\n"
                     "    (subpath \"/private/var/db/dyld\") (literal \"/dev/autofs_nowait\")\n"
                     "    (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/random\")\n"
                     "    (literal \"/dev/urandom\") (literal \"/dev/dtracehelper\")\n"
                     "    (regex #\"^/dev/tty\") (regex #\"^/dev/fd/\"))\n") &&
             sb_allow(out, &n, sizeof(out), "file-read-data", 0);
    /* The changes. */
    if (ok && !sb_omit_write)
        ok = sb_text(out, &n, sizeof(out),
                     "(deny file-write* (subpath \"/\"))\n"
                     "(allow file-write* (literal \"/dev/null\") (literal \"/dev/dtracehelper\")\n"
                     "    (regex #\"^/dev/tty\") (regex #\"^/dev/fd/\"))\n") &&
             sb_allow(out, &n, sizeof(out), "file-write*", 1);
    /* The programs. */
    if (ok && !sb_omit_exec)
        ok = sb_text(out, &n, sizeof(out), "(deny process-exec* (subpath \"/\"))\n") &&
             sb_allow(out, &n, sizeof(out), "process-exec*", 2);
    /* The network. */
    if (ok && !sb_net && !sb_omit_net)
        ok = sb_text(out, &n, sizeof(out),
                     "(deny network* (local ip \"*:*\") (remote ip \"*:*\")\n"
                     "    (remote unix-socket))\n"
                     "(deny mach-lookup (global-name \"com.apple.dnssd.service\"))\n");
    if (!ok)
        return "(version 1)\n(deny default)\n";
    return out;
}

/* The FNV-1a hash of 64 bits of a text, as 16 hexadecimal digits.
 * beam_com_seatbelt_apply() keeps the digest of the identity (the
 * program file and its permissions) in BEAM_COM_SEATBELT. */
const char *beam_com_seatbelt_digest(const char *text)
{
    static char out[17];
    uint64_t h = 14695981039346656037ull;
    const unsigned char *p;

    for (p = (const unsigned char *)text; *p; p++)
        h = (h ^ *p) * 1099511628211ull;
    snprintf(out, sizeof(out), "%016llx", (unsigned long long)h);
    return out;
}

#ifndef BEAM_COM_SEATBELT_TEST
/*
 * getcwd() in the sandbox. The getcwd() of Cosmopolitan on XNU opens "."
 * and asks for its path (F_GETPATH), and the open needs file-read-data
 * on the directory, which the profile refuses: kernel then cannot start
 * ("loader cannot read current directory"). On Linux, Landlock does not
 * check getcwd(). Here getattrlist() of libSystem gives the path
 * (ATTR_CMN_FULLPATH), which needs only the metadata. The link has
 * -Wl,--wrap=getcwd (MAC_WRAPS of scripts/steps.sh).
 */
struct sb_attrlist {
    uint16_t bitmapcount, reserved;
    uint32_t commonattr, volattr, dirattr, fileattr, forkattr;
};
#define SB_ATTR_BIT_MAP_COUNT 5
#define SB_ATTR_CMN_FULLPATH 0x08000000u

static int (*sb_getattrlist)(const char *, void *, void *, size_t, unsigned long);
static int sb_on;

char *__real_getcwd(char *, size_t);
char *__wrap_getcwd(char *, size_t);

/* The path of the working directory in out, or -1. */
static int sb_cwd(char *out, size_t size)
{
    struct sb_attrlist list = {SB_ATTR_BIT_MAP_COUNT, 0, SB_ATTR_CMN_FULLPATH, 0, 0, 0, 0};
    union {
        char bytes[PATH_MAX + 64];
        uint32_t align;
    } buf;
    int32_t offset;
    uint32_t length, total;

    if (sb_getattrlist(".", &list, buf.bytes, sizeof(buf.bytes), 0) != 0)
        return -1;
    /* The buffer: a total length, then the reference of the path (an
     * offset from the reference, and a length with the final NUL). */
    memcpy(&total, buf.bytes, 4);
    memcpy(&offset, buf.bytes + 4, 4);
    memcpy(&length, buf.bytes + 8, 4);
    if (total > sizeof(buf.bytes) || offset < 8 || length < 2 ||
        (size_t)offset + 4 + length > total || buf.bytes[4 + offset] != '/' ||
        buf.bytes[4 + offset + length - 1] != '\0')
        return -1;
    if (length > size) {
        errno = ERANGE;
        return -2;
    }
    memcpy(out, buf.bytes + 4 + offset, length);
    return 0;
}

char *__wrap_getcwd(char *buf, size_t size)
{
    char path[PATH_MAX];
    int rc;

    if (!sb_on)
        return __real_getcwd(buf, size);
    rc = sb_cwd(path, sizeof(path));
    if (rc == -1)
        return __real_getcwd(buf, size);
    if (rc == -2)
        return NULL;
    if (!buf)
        return size && strlen(path) + 1 > size ? (errno = ERANGE, NULL) : strdup(path);
    if (strlen(path) + 1 > size) {
        errno = ERANGE;
        return NULL;
    }
    return strcpy(buf, path);
}

const char *beam_com_seatbelt_apply(void)
{
    int (*init)(const char *, uint64_t, char **);
    void (*free_error)(char *);
    int (*executable_path)(char *, unsigned *);
    void *lib, *f, *g, *h;
    char *error = NULL, loader[PATH_MAX], digest[17];
    const char *profile, *inherited;
    unsigned size = sizeof(loader);
    static char reason[512];

    if (!IsXnuSilicon())
        return NULL;
    /* The APE loader that runs this process: the helper programs
     * (beam_com_spawn_helper()) start with it. */
    if ((lib = cosmo_dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY)) &&
        (h = cosmo_dlsym(lib, "_NSGetExecutablePath")) && (executable_path = cosmo_dltramp(h)) &&
        executable_path(loader, &size) == 0)
        beam_com_seatbelt_allow(loader, "rx");
    if (!lib || !(f = cosmo_dlsym(lib, "sandbox_init")) ||
        !(f = cosmo_dlsym(lib, "sandbox_init")) || !(g = cosmo_dlsym(lib, "sandbox_free_error")) ||
        !(init = cosmo_dltramp(f)) || !(free_error = cosmo_dltramp(g)))
        return "sandbox_init() of libSystem is not there";
    if ((h = cosmo_dlsym(lib, "getattrlist")))
        sb_getattrlist = cosmo_dltramp(h);
    profile = beam_com_seatbelt_profile();
    snprintf(digest, sizeof(digest), "%s",
             beam_com_seatbelt_digest(sb_identity ? sb_identity : profile));
    if (init(profile, 0, &error) != 0) {
        /* sandbox_init() refuses a process that has a profile already
         * (EPERM): for example the new VM of erl mode, which keeps the
         * profile of the program that started it. When the digest of
         * the program file and the permissions of the parent
         * (BEAM_COM_SEATBELT) is the digest of this process, the
         * process goes on in that profile. The text of a profile can
         * differ between the two (the path of the APE loader). Another
         * program or other permissions stop it. The variable cannot
         * remove a rule: the kernel applies the profile of the parent
         * all the same. */
        inherited = getenv("BEAM_COM_SEATBELT");
        snprintf(reason, sizeof(reason), "sandbox_init(): %s (digest %s, BEAM_COM_SEATBELT %s)",
                 error ? error : "error", digest, inherited ? inherited : "not set");
        if (error)
            free_error(error);
        if (inherited && strcmp(inherited, digest) == 0) {
            sb_on = sb_getattrlist != NULL;
            return NULL;
        }
        return reason;
    }
    setenv("BEAM_COM_SEATBELT", digest, 1);
    sb_on = sb_getattrlist != NULL;
    return NULL;
}
#endif
