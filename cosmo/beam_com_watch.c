/*
 * inotifywait, linked into BEAM.com: a file watcher with the command line
 * and the output of inotifywait of inotify-tools, for the programs that
 * use it (file_system, and so phoenix_live_reload). Only the options that
 * they use:
 *
 *   inotifywait [-m] [-r] [-q|--quiet] [-e EVENT]... [--format FORMAT] PATH...
 *
 * EVENT is modify, close_write, moved_to, moved_from, create, delete or
 * attrib (all when none is given). FORMAT has %w (the watched directory,
 * with a "/"), %e (the events, as "CREATE,ISDIR") and %f (the name in the
 * directory); the default is "%w %e %f". Without -m, it exits after the
 * first event.
 *
 * On Linux it uses inotify. Cosmopolitan has no wrappers for inotify, so
 * the system calls are made here (x86_64 and aarch64). On the other
 * systems it compares the files (stat()), and there is no MOVED_FROM or
 * MOVED_TO (a move is DELETE and CREATE). On macOS and the BSDs, kqueue
 * starts the comparison when a watched directory or file changes (all
 * directories first, then the files, up to half of RLIMIT_NOFILE
 * descriptors and at most 4096). The files are also compared every half
 * second, for the changes that kqueue does not see. When kqueue fails,
 * only this interval is used.
 *
 * As mac_listener (the watcher of file_system on macOS, with FSEvents),
 * it takes the same command line and writes the same lines:
 *
 *   mac_listener [--latency=SECONDS] [--no-defer] [--watch-root] [-F] PATH...
 *
 *   ID<TAB>0xFLAGS=[created,isfile]<TAB>/absolute/path
 *
 * The files are compared as on the other systems (the events are created,
 * removed, modified and inodemetamod, with isfile or isdir): when kqueue
 * sees a change, and every SECONDS (0.5 when not given, at most 5). It
 * exits when its input closes, as mac_listener does.
 */
#include <cosmo.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define W_ACCESS 0x001
#define W_MODIFY 0x002
#define W_ATTRIB 0x004
#define W_CLOSE_WRITE 0x008
#define W_MOVED_FROM 0x040
#define W_MOVED_TO 0x080
#define W_CREATE 0x100
#define W_DELETE 0x200
#define W_DELETE_SELF 0x400
#define W_IGNORED 0x8000
#define W_ISDIR 0x40000000

static const struct {
    const char *name;
    unsigned mask;
} watch_events[] = {
    {"MODIFY", W_MODIFY},         {"ATTRIB", W_ATTRIB},
    {"CLOSE_WRITE", W_CLOSE_WRITE}, {"MOVED_FROM", W_MOVED_FROM},
    {"MOVED_TO", W_MOVED_TO},     {"CREATE", W_CREATE},
    {"DELETE", W_DELETE},
};

struct watch {
    int wd;
    char *dir; /* with a "/" at the end */
};

static struct watch *watches;
static int nwatches, capwatches;
static unsigned wanted;
static int recursive, monitor;
static const char *format = "%w %e %f";
static int mac_mode;
static unsigned long long mac_id;

static void print_event(const char *dir, unsigned mask, const char *name)
{
    const char *p;
    size_t i;
    int first = 1;

    for (p = format; *p; p++) {
        if (*p != '%' || !p[1]) {
            putchar(*p);
            continue;
        }
        switch (*++p) {
        case 'w':
            fputs(dir, stdout);
            break;
        case 'f':
            fputs(name ? name : "", stdout);
            break;
        case 'e':
            for (i = 0; i < sizeof(watch_events) / sizeof(watch_events[0]); i++) {
                if (mask & watch_events[i].mask) {
                    printf("%s%s", first ? "" : ",", watch_events[i].name);
                    first = 0;
                }
            }
            if (mask & W_ISDIR)
                printf("%sISDIR", first ? "" : ",");
            break;
        default:
            putchar('%');
            putchar(*p);
        }
    }
    putchar('\n');
    fflush(stdout);
    if (!monitor)
        exit(0);
}

static char *dir_path(const char *path)
{
    size_t n = strlen(path);
    char *s = malloc(n + 2);

    memcpy(s, path, n + 1);
    if (n == 0 || s[n - 1] != '/')
        strcat(s, "/");
    return s;
}

static void add_watch_entry(int wd, const char *dir)
{
    if (nwatches == capwatches) {
        capwatches = capwatches ? capwatches * 2 : 64;
        watches = realloc(watches, capwatches * sizeof(*watches));
    }
    watches[nwatches].wd = wd;
    watches[nwatches].dir = dir_path(dir);
    nwatches++;
}

static int is_dir(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

/* --- Linux: inotify ---------------------------------------------------- */

static long linux_syscall(long n, long a, long b, long c)
{
    long r;
#if defined(__x86_64__)
    __asm__ volatile("syscall"
                     : "=a"(r)
                     : "0"(n), "D"(a), "S"(b), "d"(c)
                     : "rcx", "r11", "memory");
#elif defined(__aarch64__)
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a;
    register long x1 __asm__("x1") = b;
    register long x2 __asm__("x2") = c;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    r = x0;
#else
    r = -ENOSYS;
#endif
    if (r < 0 && r > -4096) {
        errno = -r;
        return -1;
    }
    return r;
}

#if defined(__x86_64__)
#define NR_INOTIFY_INIT1 294
#define NR_INOTIFY_ADD_WATCH 254
#else
#define NR_INOTIFY_INIT1 26
#define NR_INOTIFY_ADD_WATCH 27
#endif

static int ifd;

static void inotify_watch_tree(const char *path)
{
    unsigned mask = wanted | W_CREATE | W_MOVED_TO | W_DELETE_SELF;
    long wd = linux_syscall(NR_INOTIFY_ADD_WATCH, ifd, (long)path, mask);
    DIR *d;
    struct dirent *e;
    char *sub;

    if (wd < 0)
        return;
    add_watch_entry((int)wd, path);
    if (!recursive || !(d = opendir(path)))
        return;
    while ((e = readdir(d))) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
            continue;
        sub = malloc(strlen(path) + strlen(e->d_name) + 2);
        sprintf(sub, "%s%s%s", path, path[strlen(path) - 1] == '/' ? "" : "/", e->d_name);
        if (is_dir(sub))
            inotify_watch_tree(sub);
        free(sub);
    }
    closedir(d);
}

static const char *inotify_dir(int wd)
{
    int i;
    for (i = nwatches - 1; i >= 0; i--)
        if (watches[i].wd == wd)
            return watches[i].dir;
    return NULL;
}

static int run_inotify(char **paths, int npaths)
{
    char buf[16384], *p, *sub;
    const char *dir;
    long n;
    int i;

    ifd = (int)linux_syscall(NR_INOTIFY_INIT1, 0, 0, 0);
    if (ifd < 0)
        return -1;
    for (i = 0; i < npaths; i++)
        inotify_watch_tree(paths[i]);
    for (;;) {
        n = read(ifd, buf, sizeof(buf));
        if (n <= 0) {
            if (n < 0 && errno == EINTR)
                continue;
            return 1;
        }
        for (p = buf; p < buf + n;) {
            int wd = *(int *)p;
            unsigned mask = *(unsigned *)(p + 4);
            unsigned len = *(unsigned *)(p + 12);
            const char *name = len ? p + 16 : NULL;

            p += 16 + len;
            if (!(dir = inotify_dir(wd)))
                continue;
            /* A new directory in a recursive watch: watch it too. */
            if (recursive && name && (mask & W_ISDIR) && (mask & (W_CREATE | W_MOVED_TO))) {
                sub = malloc(strlen(dir) + strlen(name) + 1);
                sprintf(sub, "%s%s", dir, name);
                inotify_watch_tree(sub);
                free(sub);
                dir = inotify_dir(wd);
            }
            if (mask & wanted)
                print_event(dir, mask & (wanted | W_ISDIR), name);
        }
    }
}

/* --- Other systems: compare the files ---------------------------------- */

struct entry {
    char *path;
    int isdir, isreg;
    struct timespec mtime, ctime;
    off_t size;
    dev_t dev;
    ino_t ino;
    int fd; /* watched with kqueue, or -1 */
    int seen;
};

static struct entry *entries;
static int nentries, capentries;

static struct entry *find_entry(const char *path)
{
    int i;
    for (i = 0; i < nentries; i++)
        if (strcmp(entries[i].path, path) == 0)
            return &entries[i];
    return NULL;
}

/* --- macOS and the BSDs: kqueue wakes the comparison ------------------- */

/* Cosmopolitan has no kqueue() and kevent() wrappers, but its libc has
 * the system calls (with the numbers of each system, -1 and errno on an
 * error, ENOSYS on Linux). On NetBSD, sys_kevent is __kevent50 (435),
 * which takes the struct kevent of NetBSD 10 and earlier (NetBSD 11
 * keeps it in compat_100). See C29 in docs/UPSTREAM.md. */
int sys_kqueue(void);
int sys_kevent(int, const void *, int, void *, int, const struct timespec *);

/* struct kevent of macOS (with #pragma pack(4), which changes nothing on
 * 64-bit systems) and OpenBSD. FreeBSD 12 and later add ext[4]. */
struct kev {
    uintptr_t ident;
    int16_t filter;
    uint16_t flags;
    uint32_t fflags;
    int64_t data;
    void *udata;
};

struct kev_freebsd {
    struct kev k;
    uint64_t ext[4];
};

/* NetBSD: the filter and the flags are 32 bits. */
struct kev_netbsd {
    uintptr_t ident;
    uint32_t filter;
    uint32_t flags;
    uint32_t fflags;
    int64_t data;
    void *udata;
};

_Static_assert(sizeof(struct kev) == 32, "struct kevent (macOS, OpenBSD)");
_Static_assert(sizeof(struct kev_freebsd) == 64, "struct kevent (FreeBSD)");
_Static_assert(sizeof(struct kev_netbsd) == 40, "struct kevent (NetBSD)");
_Static_assert(offsetof(struct kev_netbsd, data) == 24, "NetBSD kevent data");

/* The same values on the four systems, except the filters of NetBSD. */
#define KQ_EV_ADD 0x0001
#define KQ_EV_CLEAR 0x0020
#define KQ_NOTE_DELETE 0x0001
#define KQ_NOTE_WRITE 0x0002
#define KQ_NOTE_EXTEND 0x0004
#define KQ_NOTE_ATTRIB 0x0008
#define KQ_NOTE_LINK 0x0010
#define KQ_NOTE_RENAME 0x0020
#define KQ_NOTES (KQ_NOTE_DELETE | KQ_NOTE_WRITE | KQ_NOTE_EXTEND | \
                  KQ_NOTE_ATTRIB | KQ_NOTE_LINK | KQ_NOTE_RENAME)
#define KQ_FILTER_READ (IsNetbsd() ? 0 : -1)
#define KQ_FILTER_VNODE (IsNetbsd() ? 3 : -4)
#define KQ_MAX_EVENTS 64
#define KQ_MAX_FILES 4096

static int kq = -1, kq_files, kq_max_files, kq_stdin;

static size_t kev_size(void)
{
    return IsNetbsd() ? sizeof(struct kev_netbsd)
         : IsFreebsd() ? sizeof(struct kev_freebsd) : sizeof(struct kev);
}

static void kev_set(void *p, int ident, int filter, unsigned flags, unsigned fflags)
{
    memset(p, 0, kev_size());
    if (IsNetbsd()) {
        struct kev_netbsd *k = p;
        k->ident = ident;
        k->filter = filter;
        k->flags = flags;
        k->fflags = fflags;
    } else {
        struct kev *k = p;
        k->ident = ident;
        k->filter = filter;
        k->flags = flags;
        k->fflags = fflags;
    }
}

static void kev_get(const void *p, uintptr_t *ident, int *filter)
{
    if (IsNetbsd()) {
        const struct kev_netbsd *k = p;
        *ident = k->ident;
        *filter = (int)k->filter;
    } else {
        const struct kev *k = p;
        *ident = k->ident;
        *filter = k->filter;
    }
}

/* Add one event to the kqueue. Without room for events, kevent() gives
 * -1 and errno when the change fails. */
static int kq_add(int fd, int filter, unsigned flags, unsigned fflags)
{
    struct kev_freebsd ev; /* the largest */

    kev_set(&ev, fd, filter, KQ_EV_ADD | flags, fflags);
    return sys_kevent(kq, &ev, 1, NULL, 0, NULL);
}

static void kq_unwatch(struct entry *e)
{
    if (e->fd < 0)
        return;
    close(e->fd); /* this also removes it from the kqueue */
    e->fd = -1;
    kq_files--;
}

static void kq_start(void)
{
    struct rlimit rl;

    if (!(IsXnu() || IsFreebsd() || IsNetbsd() || IsOpenbsd()) ||
        (kq = sys_kqueue()) < 0)
        return;
    kq_max_files = KQ_MAX_FILES;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur / 2 < (rlim_t)kq_max_files)
        kq_max_files = rl.rlim_cur / 2;
    /* mac_listener: a closed input wakes the wait (else wait_scan()
     * checks it after each wait). Without EV_CLEAR, the event comes
     * again while there is data to read before the end of the input. */
    if (mac_mode)
        kq_stdin = kq_add(0, KQ_FILTER_READ, 0, 0) == 0;
}

/* Back to the comparison at each interval only. */
static void kq_stop(void)
{
    int i;

    for (i = 0; i < nentries; i++)
        kq_unwatch(&entries[i]);
    close(kq);
    kq = -1;
    kq_stdin = 0;
}

/* After each comparison: watch the new directories, then the new files,
 * while there are descriptors for them. Only directories and regular
 * files are opened (the open of a FIFO can wait). On macOS, O_EVTONLY
 * is better, but open() of Cosmopolitan cannot give it (C30 in
 * docs/UPSTREAM.md). Gives 1 when a descriptor was added. */
static int kq_sync(void)
{
    int i, pass, fd, added = 0;
    struct entry *e;

    for (pass = 0; pass < 2; pass++) {
        for (i = 0; i < nentries && kq_files < kq_max_files; i++) {
            e = &entries[i];
            if (e->fd >= 0 || (pass == 0 ? !e->isdir : !e->isreg))
                continue;
            if ((fd = open(e->path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)) < 0)
                continue;
            if (kq_add(fd, KQ_FILTER_VNODE, KQ_EV_CLEAR, KQ_NOTES) != 0) {
                close(fd);
                continue;
            }
            e->fd = fd;
            kq_files++;
            added = 1;
        }
    }
    return added;
}

/* Handle the events that came: a closed input stops mac_listener. */
static void kq_events(const char *evs, int n)
{
    uintptr_t ident;
    int i, filter;
    char buf[256];

    for (i = 0; i < n; i++) {
        kev_get(evs + i * kev_size(), &ident, &filter);
        if (ident == 0 && filter == KQ_FILTER_READ && read(0, buf, sizeof(buf)) <= 0)
            exit(1);
    }
}

/* Wait for an event or for the end of the interval. After an event, wait
 * until there are no more events for 50 ms (at most 0.5 s): a program
 * often writes a file in more than one step. Gives -1 when kevent()
 * fails. */
static int kq_wait(int ms)
{
    char evs[KQ_MAX_EVENTS * sizeof(struct kev_freebsd)];
    struct timespec ts = {ms / 1000, (ms % 1000) * 1000000L};
    struct timespec settle = {0, 50000000L};
    int n, i;

    n = sys_kevent(kq, NULL, 0, evs, KQ_MAX_EVENTS, &ts);
    if (n < 0)
        return errno == EINTR ? 0 : -1;
    kq_events(evs, n);
    for (i = 0; n > 0 && i < 10; i++) {
        n = sys_kevent(kq, NULL, 0, evs, KQ_MAX_EVENTS, &settle);
        if (n < 0)
            return errno == EINTR ? 0 : -1;
        kq_events(evs, n);
    }
    return 0;
}

/* The flags of FSEvents (kFSEventStreamEventFlagItem*), with the names
 * that mac_listener gives them. */
static void report_mac(const char *path, unsigned mask)
{
    static const struct {
        unsigned w, flag;
        const char *name;
    } flags[] = {
        {W_CREATE, 0x100, "created"},     {W_DELETE, 0x200, "removed"},
        {W_ATTRIB, 0x400, "inodemetamod"}, {W_MODIFY, 0x1000, "modified"},
    };
    char names[128] = "";
    unsigned flag = 0;
    size_t i;

    for (i = 0; i < sizeof(flags) / sizeof(flags[0]); i++) {
        if (mask & flags[i].w) {
            flag |= flags[i].flag;
            if (*names)
                strcat(names, ",");
            strcat(names, flags[i].name);
        }
    }
    if (!flag)
        return;
    flag |= (mask & W_ISDIR) ? 0x20000 : 0x10000;
    strcat(names, (mask & W_ISDIR) ? ",isdir" : ",isfile");
    printf("%llu\t%#.8x=[%s]\t%s\n", ++mac_id, flag, names, path);
    fflush(stdout);
}

static void report(const char *path, unsigned mask)
{
    const char *slash = strrchr(path, '/');
    char *dir;

    if (mac_mode) {
        report_mac(path, mask);
        return;
    }
    if (!(mask & wanted))
        return;
    dir = strndup(path, slash ? (size_t)(slash - path + 1) : 0);
    print_event(*dir ? dir : "./", mask & (wanted | W_ISDIR), slash ? slash + 1 : path);
    free(dir);
}

static void scan(const char *path, int depth, int report_changes)
{
    struct stat st;
    struct entry *e;
    DIR *d;
    struct dirent *de;
    char *sub;

    if (stat(path, &st) != 0)
        return;
    e = find_entry(path);
    if (e && (st.st_dev != e->dev || st.st_ino != e->ino)) {
        /* An other file has this name now (a move, or the save of an
         * editor). Its descriptor for kqueue is for the old file. */
        kq_unwatch(e);
        e->dev = st.st_dev;
        e->ino = st.st_ino;
        e->isreg = S_ISREG(st.st_mode);
    }
    if (!e) {
        if (nentries == capentries) {
            capentries = capentries ? capentries * 2 : 256;
            entries = realloc(entries, capentries * sizeof(*entries));
        }
        e = &entries[nentries++];
        e->path = strdup(path);
        e->isdir = S_ISDIR(st.st_mode);
        e->isreg = S_ISREG(st.st_mode);
        e->mtime = st.st_mtim;
        e->ctime = st.st_ctim;
        e->size = st.st_size;
        e->dev = st.st_dev;
        e->ino = st.st_ino;
        e->fd = -1;
        if (report_changes && depth > 0)
            report(path, W_CREATE | (e->isdir ? W_ISDIR : 0));
    } else if (!e->isdir &&
               (st.st_mtim.tv_sec != e->mtime.tv_sec ||
                st.st_mtim.tv_nsec != e->mtime.tv_nsec || st.st_size != e->size)) {
        e->mtime = st.st_mtim;
        e->ctime = st.st_ctim;
        e->size = st.st_size;
        report(path, W_MODIFY);
        report(path, W_CLOSE_WRITE);
    } else if (st.st_ctim.tv_sec != e->ctime.tv_sec ||
               st.st_ctim.tv_nsec != e->ctime.tv_nsec) {
        e->ctime = st.st_ctim;
        report(path, W_ATTRIB | (e->isdir ? W_ISDIR : 0));
    }
    e->seen = 1;
    if (!S_ISDIR(st.st_mode) || (depth > 0 && !recursive) || !(d = opendir(path)))
        return;
    while ((de = readdir(d))) {
        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
            continue;
        sub = malloc(strlen(path) + strlen(de->d_name) + 2);
        sprintf(sub, "%s%s%s", path, path[strlen(path) - 1] == '/' ? "" : "/", de->d_name);
        scan(sub, depth + 1, report_changes);
        free(sub);
    }
    closedir(d);
}

/* Wait for the next comparison. mac_listener exits when its input
 * closes (the port of file_system). */
static void wait_scan(int ms)
{
    struct timespec ts = {ms / 1000, (ms % 1000) * 1000000L};
    struct pollfd pfd = {0, POLLIN, 0};
    char buf[256];

    if (kq >= 0) {
        if (kq_wait(ms) != 0)
            kq_stop();
        else if (!mac_mode || kq_stdin)
            return;
        else
            ms = 0; /* the input is not in the kqueue: check it now */
    }
    if (!mac_mode) {
        nanosleep(&ts, NULL);
        return;
    }
    if (poll(&pfd, 1, ms) > 0 && read(0, buf, sizeof(buf)) <= 0)
        exit(1);
}

static void run_poll(char **paths, int npaths, int ms)
{
    int i, first = 1, added = 0;

    kq_start();
    for (;;) {
        for (i = 0; i < nentries; i++)
            entries[i].seen = 0;
        for (i = 0; i < npaths; i++)
            scan(paths[i], 0, !first);
        for (i = 0; i < nentries;) {
            if (!entries[i].seen) {
                report(entries[i].path, W_DELETE | (entries[i].isdir ? W_ISDIR : 0));
                kq_unwatch(&entries[i]);
                free(entries[i].path);
                entries[i] = entries[--nentries];
            } else {
                i++;
            }
        }
        first = 0;
        if (kq >= 0)
            added = kq_sync();
        /* A change between the comparison and the open of a new file
         * gives no event: compare again soon. */
        wait_scan(added && ms > 100 ? 100 : ms);
    }
}

int beam_com_inotifywait_main(int argc, char **argv);

int beam_com_inotifywait_main(int argc, char **argv)
{
    char **paths = calloc(argc, sizeof(char *));
    int i, npaths = 0;
    size_t k;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-m") == 0 || strcmp(argv[i], "--monitor") == 0) {
            monitor = 1;
        } else if (strcmp(argv[i], "-r") == 0 || strcmp(argv[i], "--recursive") == 0) {
            recursive = 1;
        } else if (strcmp(argv[i], "-q") == 0 || strcmp(argv[i], "--quiet") == 0) {
        } else if ((strcmp(argv[i], "-e") == 0 || strcmp(argv[i], "--event") == 0) && i + 1 < argc) {
            i++;
            for (k = 0; k < sizeof(watch_events) / sizeof(watch_events[0]); k++)
                if (strcasecmp(argv[i], watch_events[k].name) == 0)
                    wanted |= watch_events[k].mask;
        } else if (strcmp(argv[i], "--format") == 0 && i + 1 < argc) {
            format = argv[++i];
        } else if (strcmp(argv[i], "--") == 0) {
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "inotifywait (BEAM.com): unknown option %s\n", argv[i]);
            return 1;
        } else {
            paths[npaths++] = argv[i];
        }
    }
    if (!npaths) {
        fprintf(stderr, "usage: inotifywait [-m] [-r] [-q] [-e EVENT]... "
                        "[--format FORMAT] PATH...\n");
        return 1;
    }
    if (!wanted)
        for (k = 0; k < sizeof(watch_events) / sizeof(watch_events[0]); k++)
            wanted |= watch_events[k].mask;
    if (IsLinux() && run_inotify(paths, npaths) >= 0)
        return 0;
    run_poll(paths, npaths, 500);
    return 0;
}

int beam_com_mac_listener_main(int argc, char **argv);

int beam_com_mac_listener_main(int argc, char **argv)
{
    char **paths = calloc(argc, sizeof(char *));
    int i, npaths = 0, ms = 500;
    double latency;

    mac_mode = recursive = monitor = 1;
    for (i = 1; i < argc; i++) {
        if (strncmp(argv[i], "--latency=", 10) == 0) {
            latency = atof(argv[i] + 10);
            ms = latency < 0.1 ? 100 : latency > 5 ? 5000 : (int)(latency * 1000);
        } else if (strcmp(argv[i], "--latency") == 0 && i + 1 < argc) {
            latency = atof(argv[++i]);
            ms = latency < 0.1 ? 100 : latency > 5 ? 5000 : (int)(latency * 1000);
        } else if (argv[i][0] == '-') {
            /* --no-defer, --watch-root, -F (--file-events) and the others
             * change nothing here. */
        } else {
            paths[npaths++] = argv[i];
        }
    }
    if (!npaths) {
        fprintf(stderr, "usage: mac_listener [--latency=SECONDS] [-F] PATH...\n");
        return 1;
    }
    run_poll(paths, npaths, ms);
    return 0;
}
