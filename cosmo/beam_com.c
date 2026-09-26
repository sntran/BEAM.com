/*
 * BEAM.com multi-call entry point.
 *
 * The emulator, erl_child_setup and inet_gethost are linked into one
 * Actually Portable Executable. The program to run is selected from the
 * base name of argv[0]:
 *
 *   erl_child_setup*  -> the port program forker
 *   inet_gethost*     -> the native name resolver
 *   anything else     -> the BEAM emulator
 *
 * The emulator arguments are made the same way as erlexec would do it
 * for an OTP installation in /zip, from these files in the zip:
 *
 *   /zip/releases/start_erl.data  An OTP release ("ERTS_VSN REL_VSN"):
 *                                 boot releases/REL_VSN/start.boot, with
 *                                 sys.config and vm.args when they exist.
 *   /zip/.args                    More arguments, one on each line
 *                                 (redbean style).
 *
 * When there is neither, the program is a plain beam.smp.
 *
 * When the zip has the beam_com application and no release (the default
 * beam.com), the commands of beam.com run (help, version and build, see
 * apps/beam_com). "build" also runs when the zip has a release.
 */
#include <cosmo.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include "libc/intrin/fds.h"                 /* struct Fds, kFdZip */
#include "ape/ape.h"                            /* APE_VERSION_STR */
#include "libc/calls/pledge.h"                  /* __pledge_mode */

/* Cosmopolitan internals used for the Windows setup (see below). */
#include "libc/calls/sysdir.internal.h"     /* GetHostsTxtPath() */
#include "libc/nt/dll.h"                    /* LoadLibrary(), GetProcAddress() */
#include "libc/nt/runtime.h"                /* ExitProcess() */
#include "libc/runtime/runtime.h"           /* __get_tmpdir() */
#include "net/http/escape.h"                /* EncodeBase64() */
#include "third_party/musl/lookup.internal.h" /* __get_resolv_conf() */

/* erts_cosmo.h is included by the compiler (-include). */
#include "erl_version.h"                    /* ERLANG_VERSION */


#define BEAM_COM_ROOT "/zip"
#define BEAM_COM_BINDIR "/zip/bin"
#define BEAM_COM_ARGS "/zip/.args"
#define BEAM_COM_RELEASES "/zip/releases"
#define BEAM_COM_TOOL "/zip/lib/beam_com/ebin/beam_com.app"
#define BEAM_COM_ALLOW "/zip/.allow"

/* close() with the lock of the file descriptor table (UPSTREAM.md C25
 * and C26). The emulator is linked with -Wl,--wrap=close (build.sh), so
 * each call of close() comes here.
 *
 * C25: Cosmopolitan's close() of a kernel descriptor calls the close
 * system call, and then clears the entry of the descriptor in its table,
 * without the lock. In that gap, another thread can open a /zip file, get
 * the same number from the kernel (zipos reserves it with dup()), and
 * write its entry, which close() then clears. The lock prevents it: the
 * /zip open takes it too. The lock is recursive.
 *
 * C26: the close() of a /zip descriptor calls the close system call, and
 * only then frees the zipos handle and clears the entry. In that gap,
 * another thread can open a real file (which does not take the lock) and
 * get the same number from the kernel; its fstat() or read() then sees
 * the old /zip entry, and uses the freed handle (SIGSEGV in
 * __zipos_fstat). Here the entry is cleared first, then the kernel
 * descriptor is closed, then the handle is freed. Only in the process
 * itself: in a child of vfork(), which shares the memory, Cosmopolitan
 * only closes the kernel descriptor (the real close() does that).
 * Windows has no kernel descriptor for /zip files. */
struct ZiposHandle;
int __real_close(int fd);
/* From libc/calls/state.internal.h, which cannot be included here: it
 * includes libc/thread/tls.h, which stops with #error in the dependency
 * pass of cosmocc, where no CPU is defined (UPSTREAM.md C23). */
void __fds_lock(void);
void __fds_unlock(void);
extern struct Fds g_fds;
void __releasefd(int fd);
void __zipos_drop(struct ZiposHandle *h);
int sys_close(int fd);

static int close_pid;

__attribute__((__constructor__)) static void close_init(void)
{
    close_pid = getpid();
}

int __wrap_close(int fd)
{
    struct ZiposHandle *h;
    int rc;

    __fds_lock();
    if (fd >= 0 && (size_t)fd < g_fds.n && g_fds.p[fd].kind == kFdZip &&
        !beam_com_is_windows() && getpid() == close_pid) {
        h = (struct ZiposHandle *)(intptr_t)g_fds.p[fd].handle;
        __releasefd(fd);
        rc = sys_close(fd);
        __zipos_drop(h);
    } else {
        rc = __real_close(fd);
    }
    __fds_unlock();
    return rc;
}

/* mkdir() of a directory that exists (UPSTREAM.md C27). The emulator is
 * linked with -Wl,--wrap=mkdir (build.sh). On Windows, Cosmopolitan's
 * mkdir() of a drive root ("/C") gives EACCES (CreateDirectory() is
 * denied), not EEXIST. Elixir's File.mkdir_p/1 makes each parent from
 * the root and accepts only EEXIST for one that exists, so it failed
 * for each absolute path. POSIX gives EEXIST when the path exists. */
int __real_mkdir(const char *path, mode_t mode);

int __wrap_mkdir(const char *path, mode_t mode)
{
    struct stat st;
    int rc = __real_mkdir(path, mode), e = errno;

    if (rc == -1 && e == EACCES && beam_com_is_windows())
        errno = stat(path, &st) == 0 ? EEXIST : e;
    return rc;
}

extern int erl_child_setup_main(int argc, char **argv);
extern int inet_gethost_main(int argc, char **argv);
extern int epmd_main(int argc, char **argv);
extern int beam_com_inotifywait_main(int argc, char **argv);
extern int beam_com_mac_listener_main(int argc, char **argv);

struct arglist {
    char **v;
    int n;
    int cap;
};

/*
 * On Windows, Cosmopolitan's _Exit() gives Windows the POSIX wait status
 * (status << 8): cmd, PowerShell and other Windows programs then see 256
 * for status 1 (a Cosmopolitan parent decodes it). BEAM.com gives
 * Windows the status itself. For exit(), the status is given after the
 * exit handlers, in the last destructor (priority 101 runs last).
 */
static int windows_exit_status = -1;

__attribute__((__destructor__(101))) static void windows_exit(void)
{
    if (windows_exit_status >= 0)
        ExitProcess(windows_exit_status);
}

void beam_com_exit(int status, int flush)
{
    status &= 255;
    if (beam_com_is_windows()) {
        if (!flush)
            ExitProcess(status);
        windows_exit_status = status;
    }
    if (flush)
        exit(status);
    _exit(status);
}

static void die(const char *what)
{
    fprintf(stderr, "beam.com: %s: %s\n", what, strerror(errno));
    beam_com_exit(127, 1);
}

static void push(struct arglist *l, char *arg)
{
    if (l->n + 1 >= l->cap) {
        l->cap = l->cap ? l->cap * 2 : 32;
        l->v = realloc(l->v, l->cap * sizeof(char *));
        if (!l->v)
            die("realloc");
    }
    l->v[l->n++] = arg;
    l->v[l->n] = NULL;
}

static int starts_with(const char *s, const char *prefix)
{
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

/*
 * Put one user argument in the correct list. As with erl, an argument
 * that starts with '+' is an emulator flag: "+S 2" becomes "-S 2" in
 * front of the first "--". The next argument is the value of the flag
 * when it does not start with '-' or '+'.
 */
static void add_user_arg(struct arglist *emu, struct arglist *init,
                         char **args, int *i, int n, int *extra)
{
    char *arg = args[*i];

    if (!*extra && arg[0] == '+' && arg[1] != '\0') {
        char *flag = strdup(arg);
        if (!flag)
            die("strdup");
        flag[0] = '-';
        push(emu, flag);
        if (*i + 1 < n && args[*i + 1][0] != '-' && args[*i + 1][0] != '+')
            push(emu, args[++*i]);
        return;
    }
    if (strcmp(arg, "-extra") == 0)
        *extra = 1;
    push(init, arg);
}

/*
 * Read /zip/.args. Each line is one argument. Blank lines and lines
 * that start with '#' are ignored. Returns 0 when there is no file.
 */
static int read_lines(const char *path, struct arglist *out)
{
    FILE *f;
    char *line = NULL;
    size_t cap = 0;
    ssize_t len;

    if (!(f = fopen(path, "r")))
        return 0;
    while ((len = getline(&line, &cap, f)) != -1) {
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = '\0';
        if (len == 0 || line[0] == '#')
            continue;
        push(out, strdup(line));
    }
    free(line);
    fclose(f);
    return 1;
}

static int read_zip_args(struct arglist *out)
{
    return read_lines(BEAM_COM_ARGS, out);
}

/*
 * --- Sandbox: the permissions of --allow-* -----------------------------
 *
 * A program can give up what it does not need. The permissions are those
 * of Deno (beam.com build --allow-read, --allow-write, --allow-net,
 * --allow-run, --allow-all), one on each line of /zip/.allow:
 *
 *   read, read=PATH,...     read all files, or only these
 *   write, write=PATH,...   write (and create) all files, or only these
 *   net                     sockets and DNS
 *   run, run=PROGRAM,...    start all programs (ports), or only these
 *   all                     no sandbox
 *
 * With permissions, the program can do only what they allow. BEAM_COM_ALLOW
 * (the same words, separated by ";") gives permissions to a program that
 * has none in its file, to try a sandbox without a new build; the
 * environment never changes the permissions of the file.
 *
 * They are applied with the pledge() (system calls) and unveil() (paths)
 * of Cosmopolitan, here, before ERTS starts its threads: on Linux,
 * seccomp (pledge) and Landlock (unveil) apply to the calling thread and
 * to the threads that it starts later. On OpenBSD they apply to the
 * process. On the other systems, pledge() and unveil() do nothing.
 *
 * A forbidden system call returns EPERM (Linux), so Erlang code gets an
 * error such as {error, eperm}; a hidden path gives EACCES. OpenBSD kills
 * the process on a forbidden system call.
 *
 * The helper programs (erl_child_setup, inet_gethost) are this file,
 * executed again. On Linux they keep the rules of their parent (and the
 * seccomp filter of unveil() forbids a second Landlock ruleset), so they
 * do not apply them again. On OpenBSD the rules end at exec, so the
 * helpers apply them; errors are not fatal there: a helper cannot get
 * more than its parent has.
 */
static char *join(const char *a, const char *b, const char *c);

struct allow {
    int all, net, run;
    int read_all, write_all, run_all;
    struct arglist read, write, programs;
};

static void sandbox_error(int helper, const char *what, const char *arg)
{
    if (helper)
        return;
    fprintf(stderr, "beam.com: %s %s: %s\n", what, arg, strerror(errno));
    beam_com_exit(127, 1);
}

static void sandbox_unveil(int helper, const char *path,
                           const char *permissions)
{
    if (unveil(path, permissions) == -1)
        sandbox_error(helper, "unveil", path);
}

/* A path that may not exist (unveil() fails with ENOENT for it): it is
 * left out. unveil() needs a path that exists; to create files, the
 * program needs their directory. */
static void sandbox_unveil_optional(int helper, const char *path,
                                    const char *permissions)
{
    if (path && unveil(path, permissions) == -1 && errno != ENOENT)
        sandbox_error(helper, "unveil", path);
}

/* The APE loader that Cosmopolitan's execve() uses to start an APE file
 * on Linux, when the kernel cannot (see libc/proc/execve-sysv.c). */
static void sandbox_unveil_loader(int helper)
{
    const char *home = getenv("HOME");

    sandbox_unveil_optional(helper, "/usr/bin/ape", "rx");
    sandbox_unveil_optional(helper,
                            join(__get_tmpdir(), "/.ape-", APE_VERSION_STR), "rx");
    if (home)
        sandbox_unveil_optional(helper, join(home, "/.ape-", APE_VERSION_STR), "rx");
}

/* A program of --allow-run, by path, or by name in PATH (as a port
 * finds it with os:find_executable/1). NULL when it is nowhere. */
static char *find_program(const char *name)
{
    const char *path = getenv("PATH");
    char *copy, *dir, *save, *file;

    if (strchr(name, '/'))
        return strdup(name);
    if (!path)
        return NULL;
    copy = strdup(path);
    for (dir = strtok_r(copy, ":", &save); dir; dir = strtok_r(NULL, ":", &save)) {
        file = join(*dir ? dir : ".", "/", name);
        if (access(file, X_OK) == 0)
            return file;
        free(file);
    }
    return NULL;
}

static void allow_list(char *value, struct arglist *out)
{
    char *item, *save;

    for (item = strtok_r(value, ",", &save); item; item = strtok_r(NULL, ",", &save))
        push(out, strdup(item));
}

/* One permission: "read", "read=/etc,/srv", "net", ... */
static void allow_parse(int helper, struct allow *a, char *word)
{
    char *value = strchr(word, '=');

    while (*word == ' ' || *word == '\t')
        word++;
    if (value)
        *value++ = '\0';
    if (strcmp(word, "all") == 0 && !value)
        a->all = 1;
    else if (strcmp(word, "net") == 0 && !value)
        a->net = 1;
    else if (strcmp(word, "read") == 0)
        value ? allow_list(value, &a->read) : (void)(a->read_all = 1);
    else if (strcmp(word, "write") == 0)
        value ? allow_list(value, &a->write) : (void)(a->write_all = 1);
    else if (strcmp(word, "run") == 0) {
        a->run = 1;
        value ? allow_list(value, &a->programs) : (void)(a->run_all = 1);
    } else if (!helper) {
        fprintf(stderr, "beam.com: unknown permission %s (read, write, net, "
                        "run or all)\n", word);
        beam_com_exit(127, 1);
    }
}

/* ERTS needs "stdio rpath" to start: without them, it waits forever
 * (seen on Linux). Threads are part of "stdio". unveil limits which files
 * "rpath" can read. The JIT needs "prot_exec" for the memory of its
 * code, and "cpath wpath" for shm_open(), which makes the file of its two
 * views (W^X): without them, asmjit maps its code writable and executable
 * (seen in the jit_maps check). unveil limits writes to the directory of
 * shm_open() and the paths of --allow-write. */
#ifdef BEAMASM
#define BEAM_COM_BASE_PROMISES "stdio rpath prot_exec cpath wpath "
#else
#define BEAM_COM_BASE_PROMISES "stdio rpath "
#endif

static void apply_allow(int helper, struct allow *a)
{
    static const char *libs[] = {"/lib", "/lib64", "/usr/lib", "/usr/lib64",
                                 "/usr/local/lib", "/usr/libexec"};
    static const char *net_files[] = {
        "/etc/resolv.conf", "/etc/hosts", "/etc/services", "/etc/protocols",
        /* The certificates of the OS, for public_key:cacerts_get(). */
        "/etc/ssl", "/etc/pki", "/usr/local/share/certs", "/usr/share/ca-certificates"};
    char promises[256];
    size_t k;
    int i;

    /* BEAM.com executes its own file again for the helper programs,
     * and ERTS opens /dev/null at start. */
    sandbox_unveil(helper, GetProgramExecutableName(), "rx");
    sandbox_unveil(helper, "/dev/null", "rw");
    sandbox_unveil(helper, "/dev/urandom", "r");
    sandbox_unveil_loader(helper);
#ifdef BEAMASM
    /* The JIT maps its code two times (W^X) with shm_open(), whose
     * file Cosmopolitan makes in /dev/shm on Linux, else in /tmp
     * (libc/calls/shm_path_np.c). Without it, asmjit maps the code
     * writable and executable, which OpenBSD refuses: "Cannot
     * allocate executable memory". */
    sandbox_unveil(helper, IsLinux() && access("/dev/shm", F_OK) == 0 ? "/dev/shm" : "/tmp",
                   "rwc");
#endif
    if (a->read_all)
        sandbox_unveil(helper, "/", "r");
    for (i = 0; i < a->read.n; i++)
        sandbox_unveil_optional(helper, a->read.v[i], "r");
    if (a->write_all)
        sandbox_unveil(helper, "/", "rwc");
    for (i = 0; i < a->write.n; i++)
        sandbox_unveil_optional(helper, a->write.v[i], "rwc");
    if (a->net)
        for (k = 0; k < sizeof(net_files) / sizeof(net_files[0]); k++)
            sandbox_unveil_optional(helper, net_files[k], "r");
    if (a->run_all)
        sandbox_unveil(helper, "/", "rx");
    if (a->programs.n) {
        /* The dynamic loader and the libraries of the programs. */
        for (k = 0; k < sizeof(libs) / sizeof(libs[0]); k++)
            sandbox_unveil_optional(helper, libs[k], "rx");
        sandbox_unveil_optional(helper, "/etc/ld.so.cache", "r");
        for (i = 0; i < a->programs.n; i++)
            sandbox_unveil_optional(helper, find_program(a->programs.v[i]), "rx");
    }
    if (unveil(NULL, NULL) == -1)
        sandbox_error(helper, "unveil", "(commit)");

    /* OpenBSD stops ERTS under any pledge() that BEAM.com has tried
     * (SIGABRT at the start, also for the interpreter), and it stops the
     * process on a forbidden system call instead of returning an error.
     * There the sandbox is unveil() only (the paths). */
    if (IsOpenbsd())
        return;
    snprintf(promises, sizeof(promises), "%s%s%s%s", BEAM_COM_BASE_PROMISES,
             a->write_all || a->write.n ? "wpath cpath fattr flock " : "",
             a->net ? "inet dns " : "",
             /* erl_child_setup gets the descriptors of a port over a
              * socket (SCM_RIGHTS). */
             a->run ? "proc exec sendfd recvfd " : "");
    if (pledge(promises, NULL) == -1)
        sandbox_error(helper, "pledge", promises);

    /* Without "proc exec", ERTS cannot start its port programs, and the
     * native name resolver is one: kernel halts when it cannot start it.
     * Kernel uses its own DNS client instead (as on Windows). */
    if (!a->run && !getenv("ERL_INETRC"))
        setenv("ERL_INETRC", BEAM_COM_BINDIR "/sandbox.inetrc", 1);
}

static void apply_sandbox(int helper)
{
    struct allow a = {0};
    struct arglist words = {0};
    char *env, *copy, *word, *save;
    int i;

    if (helper && IsLinux())
        return;
    __pledge_mode = PLEDGE_PENALTY_RETURN_EPERM;

    if (!read_lines(BEAM_COM_ALLOW, &words) && (env = getenv("BEAM_COM_ALLOW")) && *env) {
        copy = strdup(env);
        for (word = strtok_r(copy, ";\n", &save); word; word = strtok_r(NULL, ";\n", &save))
            push(&words, word);
    }
    if (!words.n)
        return;
    for (i = 0; i < words.n; i++)
        allow_parse(helper, &a, words.v[i]);
    if (!a.all)
        apply_allow(helper, &a);
}

static int file_exists(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f)
        return 0;
    fclose(f);
    return 1;
}

/*
 * The tools: "escript", and the tools of Elixir: "mix", "iex", "elixir"
 * and "elixirc", also with .com or .exe (mix.com is this file under the
 * name of the tool). NULL for another name.
 */
static const char *elixir_tool(const char *name)
{
    static const char *tools[] = {"mix", "iex", "elixir", "elixirc", "escript"};
    size_t i, n;

    for (i = 0; i < sizeof(tools) / sizeof(tools[0]); i++) {
        n = strlen(tools[i]);
        if (strncmp(name, tools[i], n) == 0 &&
            (name[n] == '\0' || strcmp(name + n, ".exe") == 0 ||
             strcmp(name + n, ".com") == 0))
            return tools[i];
    }
    return NULL;
}

/*
 * The emulator flags of an escript: a "%%!" line among its first three
 * lines (after "#!" and "%% coding: ..."), as the escript program of OTP
 * reads them. For example "+S 1", or "-escript main MODULE".
 */
static void escript_flags(const char *path, struct arglist *out)
{
    FILE *f = fopen(path, "rb");
    char line[4096], *word, *save;
    int n;

    if (!f)
        return;
    for (n = 0; n < 3 && fgets(line, sizeof(line), f); n++) {
        if (strncmp(line, "%%!", 3) == 0) {
            for (word = strtok_r(line + 3, " \t\r\n", &save); word;
                 word = strtok_r(NULL, " \t\r\n", &save))
                push(out, strdup(word));
            break;
        }
    }
    fclose(f);
}

/* mkdir -p */
static void make_dirs(char *path)
{
    char *p;

    for (p = path + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(path, 0755);
            *p = '/';
        }
    }
    mkdir(path, 0755);
}

/*
 * file_system (and so phoenix_live_reload) watches files with inotifywait
 * of inotify-tools (FILESYSTEM_FSINOTIFY_EXECUTABLE_FILE, else PATH), and
 * on macOS with mac_listener (FILESYSTEM_FSMAC_EXECUTABLE_FILE). For the
 * tools of Elixir, the variable names a file in the cache of BEAM.com
 * (BEAM_COM_CACHE, else the user cache, as beam_com_script), so that the
 * watcher of this file runs (cosmo/beam_com_watch.c):
 *
 *   - Linux and the BSDs: a link named inotifywait to this file.
 *   - macOS: a script mac_listener that runs this file with
 *     BEAM_COM_PROGRAM=mac_listener (the name of a link can be lost when
 *     the APE loader starts the file).
 *
 * Not when the variable is set, and not on Windows (file_system has its
 * own watcher there).
 */
static void watch_link(void)
{
    const char *cache = getenv("BEAM_COM_CACHE"), *xdg = getenv("XDG_CACHE_HOME"),
               *home = getenv("HOME"), *exe = GetProgramExecutableName();
    const char *var = IsXnu() ? "FILESYSTEM_FSMAC_EXECUTABLE_FILE"
                              : "FILESYSTEM_FSINOTIFY_EXECUTABLE_FILE";
    char *dir, *link, *tmp, *script, target[4096];
    ssize_t n;
    int fd, ok;

    if (getenv(var) || beam_com_is_windows() || !exe || *exe != '/' || strchr(exe, '\''))
        return;
    if (cache && *cache)
        dir = join(cache, "/bin", "");
    else if (xdg && *xdg)
        dir = join(xdg, "/beam.com/bin", "");
    else if (home)
        dir = join(home, "/.cache/beam.com/bin", "");
    else
        return;
    make_dirs(dir);
    link = join(dir, IsXnu() ? "/mac_listener" : "/inotifywait", "");
    /* A new file, then rename(): two tools that start at the same time
     * do not see a missing file. */
    snprintf(target, sizeof(target), "%s.%d", link, (int)getpid());
    tmp = strdup(target);
    if (IsXnu()) {
        script = join("#!/bin/sh\nBEAM_COM_PROGRAM=mac_listener exec '", exe, "' \"$@\"\n");
        fd = open(link, O_RDONLY);
        n = fd >= 0 ? read(fd, target, sizeof(target) - 1) : -1;
        if (fd >= 0)
            close(fd);
        if (n < 0 || (target[n] = '\0', strcmp(target, script) != 0)) {
            unlink(tmp);
            fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0755);
            ok = fd >= 0 && write(fd, script, strlen(script)) == (ssize_t)strlen(script);
            if (fd >= 0)
                close(fd);
            if (!ok || rename(tmp, link) != 0) {
                unlink(tmp);
                return;
            }
        }
    } else {
        n = readlink(link, target, sizeof(target) - 1);
        if (n < 0 || (target[n] = '\0', strcmp(target, exe) != 0)) {
            unlink(tmp);
            if (symlink(exe, tmp) != 0 || rename(tmp, link) != 0) {
                unlink(tmp);
                return;
            }
        }
    }
    setenv(var, link, 1);
}

/* The zip has Elixir: a directory lib/elixir-VSN (not with ELIXIR=0). */
static int zip_has_elixir(void)
{
    DIR *dir = opendir(BEAM_COM_ROOT "/lib");
    struct dirent *entry;
    int found = 0;

    if (!dir)
        return 0;
    while (!found && (entry = readdir(dir)))
        found = starts_with(entry->d_name, "elixir-");
    closedir(dir);
    return found;
}

static char *join(const char *a, const char *b, const char *c)
{
    size_t n = strlen(a) + strlen(b) + strlen(c) + 1;
    char *s = malloc(n);
    if (!s)
        die("malloc");
    snprintf(s, n, "%s%s%s", a, b, c);
    return s;
}

/*
 * Read a vm.args file. Arguments are separated by white space, and '#'
 * starts a comment to the end of the line. Quotes are not supported.
 */
static void read_vm_args(const char *path, struct arglist *out)
{
    FILE *f;
    char *line = NULL, *word, *save;
    size_t cap = 0;

    if (!(f = fopen(path, "r")))
        return;
    while (getline(&line, &cap, f) != -1) {
        char *hash = strchr(line, '#');
        if (hash)
            *hash = '\0';
        for (word = strtok_r(line, " \t\r\n", &save); word;
             word = strtok_r(NULL, " \t\r\n", &save))
            push(out, strdup(word));
    }
    free(line);
    fclose(f);
}

/*
 * Read /zip/releases/start_erl.data and add the arguments that boot
 * that release. Returns 0 when there is no release.
 */
static int read_release(struct arglist *out)
{
    FILE *f;
    char erts_vsn[64], rel_vsn[256];
    char *dir, *path;

    if (!(f = fopen(BEAM_COM_RELEASES "/start_erl.data", "r")))
        return 0;
    if (fscanf(f, "%63s %255s", erts_vsn, rel_vsn) != 2) {
        fclose(f);
        fprintf(stderr, "beam.com: bad " BEAM_COM_RELEASES "/start_erl.data\n");
        beam_com_exit(127, 1);
    }
    fclose(f);

    /* A release made for another ERTS can fail in unexpected ways. */
    if (strcmp(erts_vsn, ERLANG_VERSION) != 0)
        fprintf(stderr, "beam.com: warning: the release is for ERTS %s, "
                "and this is ERTS " ERLANG_VERSION "\n", erts_vsn);

    dir = join(BEAM_COM_RELEASES "/", rel_vsn, "/");
    path = join(dir, "start", ".boot");
    if (!file_exists(path)) {
        fprintf(stderr, "beam.com: %s not found\n", path);
        beam_com_exit(127, 1);
    }
    push(out, "-boot");
    push(out, join(dir, "start", ""));

    path = join(dir, "sys", ".config");
    if (file_exists(path)) {
        push(out, "-config");
        push(out, join(dir, "sys", ""));
    }

    read_vm_args(join(dir, "vm", ".args"), out);
    return 1;
}

static char *home_dir(void)
{
    char *home = getenv("HOME");
    if (!home || !*home)
        home = getenv("USERPROFILE");
    if (!home || !*home)
        home = "/";
    return home;
}

/*
 * --- Windows ----------------------------------------------------------
 *
 * Under Cosmopolitan, ERTS is the Unix build: os:type() is
 * {unix, windows}, so kernel and public_key take their Unix code paths.
 * Two of them do not work on Windows without help:
 *
 * 1. Names. The native resolver (inet_gethost) is a port program, and
 *    there are no port programs on Windows. Kernel must use its own DNS
 *    client (inet_res), which needs name servers. Kernel would read them
 *    from /etc/resolv.conf, which does not exist. Worse, inet_db watches
 *    that file and *replaces* the name server list with the (empty)
 *    content of the missing file before every lookup, so name servers
 *    added with inet_db:add_ns/1 are lost and every lookup is nxdomain.
 *
 *    BEAM.com writes an inetrc file at start with {resolv_conf, ""} (stop
 *    watching the file), the Windows hosts file, and the name servers of
 *    Windows (from the registry, as Cosmopolitan's own resolver reads
 *    them), and points ERL_INETRC at it.
 *
 * 2. Certificates. public_key:cacerts_get/0 only reads the Windows
 *    certificate store for os:type() {win32, _}, with a Windows-only NIF.
 *    BEAM.com exports the trusted roots of Windows (crypt32) to a PEM
 *    file at start and gives it to public_key with the application
 *    parameter cacerts_path (-public_key cacerts_path "File"), which the
 *    stock public_key honours.
 *
 * Both files are in the temp directory of the user and are removed at
 * exit. The user's own settings win: ERL_INETRC and -public_key
 * cacerts_path are left alone when they are given.
 */

static char *windows_tmp_files[2];

static void windows_remove_tmp_files(void)
{
    size_t i;
    for (i = 0; i < sizeof(windows_tmp_files) / sizeof(*windows_tmp_files); i++)
        if (windows_tmp_files[i])
            unlink(windows_tmp_files[i]);
}

/* Windows paths for Erlang strings: forward slashes, no quotes. */
static void erlang_path(char *s)
{
    for (; *s; s++)
        if (*s == '\\')
            *s = '/';
        else if (*s == '"')
            *s = '_';
}

/* Open a new file in the temp directory: <tmp>/beam_com.<pid>.<suffix> */
static FILE *windows_tmp_file(int slot, const char *suffix, char **pathp)
{
    char name[64];
    char *path;
    FILE *f;

    snprintf(name, sizeof(name), "beam_com.%d.%s", (int)getpid(), suffix);
    path = join(__get_tmpdir(), name, ""); /* __get_tmpdir() ends with '/' */
    erlang_path(path);
    if (!(f = fopen(path, "w"))) {
        free(path);
        return NULL;
    }
    if (!windows_tmp_files[0] && !windows_tmp_files[1])
        atexit(windows_remove_tmp_files);
    windows_tmp_files[slot] = path;
    *pathp = path;
    return f;
}

/*
 * Write an inetrc for Windows. The name servers come from the registry
 * (Tcpip\Parameters\Interfaces\*\{Dhcp,}NameServer) through the function
 * that Cosmopolitan's resolver uses. IPv4 only, at most MAXNS (3).
 * Returns the file name, or NULL when the file cannot be made.
 */
static char *windows_write_inetrc(void)
{
    struct resolvconf rc;
    char buf[512], hosts[512];
    const char *hosts_path;
    char *path;
    FILE *f;
    unsigned i;

    if (!(f = windows_tmp_file(0, "inetrc", &path)))
        return NULL;
    fprintf(f, "%%%% Made by BEAM.com at start; see /zip/bin/windows.inetrc.\n"
               "%%%% Set ERL_INETRC to use your own file.\n"
               "{lookup, [file, dns]}.\n"
               "{resolv_conf, \"\"}.\n");
    memset(&rc, 0, sizeof(rc));
    if (__get_resolv_conf(&rc, NULL, 0) == 0) {
        for (i = 0; i < rc.nns && i < MAXNS; i++) {
            const unsigned char *a = rc.ns[i].addr;
            if (rc.ns[i].family == AF_INET)
                fprintf(f, "{nameserver, {%u,%u,%u,%u}}.\n",
                        a[0], a[1], a[2], a[3]);
        }
    }
    /* C:\Windows\System32\drivers\etc\hosts. inet_db only accepts an
     * absolute name (filename:pathtype/1), and for the Unix build of ERTS
     * "C:/..." is relative: write the Cosmopolitan form "/C/...". An
     * entry that kernel does not accept stops the rest of the file, so
     * this line comes last. */
    if ((hosts_path = GetHostsTxtPath(buf, sizeof(buf)))) {
        snprintf(hosts, sizeof(hosts), "%s", hosts_path);
        erlang_path(hosts);
        if (hosts[0] && hosts[1] == ':' && hosts[2] == '/') {
            hosts[1] = hosts[0];
            hosts[0] = '/';
        }
        if (hosts[0] == '/')
            fprintf(f, "{hosts_file, \"%s\"}.\n", hosts);
    }
    if (ferror(f) | fclose(f))
        return NULL;
    return path;
}

#ifdef __x86_64__
/*
 * The trusted root certificates of Windows, as PEM. crypt32.dll is not
 * among the DLLs that Cosmopolitan imports, so it is loaded here. The
 * functions have the Microsoft x64 calling convention (__ms_abi__).
 * This is what lib/public_key/c_src/public_key.c does on a Windows
 * build of OTP (current user "ROOT" store, X509_ASN_ENCODING).
 */
struct nt_cert_context {
    uint32_t dwCertEncodingType;
    uint8_t *pbCertEncoded;
    uint32_t cbCertEncoded;
    void *pCertInfo;
    void *hCertStore;
};
#define NT_X509_ASN_ENCODING 1u

typedef void *(__attribute__((__ms_abi__)) *nt_CertOpenSystemStoreW)(
    uintptr_t hProv, const char16_t *szSubsystemProtocol);
typedef const struct nt_cert_context *(__attribute__((__ms_abi__))
                                       *nt_CertEnumCertificatesInStore)(
    void *hCertStore, const struct nt_cert_context *pPrevCertContext);
typedef int (__attribute__((__ms_abi__)) *nt_CertCloseStore)(
    void *hCertStore, uint32_t dwFlags);

static void write_pem_certificate(FILE *f, const uint8_t *der, size_t len)
{
    size_t n, i;
    char *b64 = EncodeBase64((const char *)der, len, &n);
    if (!b64)
        return;
    fputs("-----BEGIN CERTIFICATE-----\n", f);
    for (i = 0; i < n; i += 64)
        fprintf(f, "%.64s\n", b64 + i);
    fputs("-----END CERTIFICATE-----\n", f);
    free(b64);
}

/* Returns the number of certificates written, or -1. */
static int windows_export_cacerts(FILE *f)
{
    int64_t crypt32;
    nt_CertOpenSystemStoreW open_store;
    nt_CertEnumCertificatesInStore enum_certs;
    nt_CertCloseStore close_store;
    const struct nt_cert_context *c = NULL;
    void *store;
    int count = 0;

    if (!(crypt32 = LoadLibrary(u"crypt32.dll")))
        return -1;
    open_store = (nt_CertOpenSystemStoreW)
        GetProcAddress(crypt32, "CertOpenSystemStoreW");
    enum_certs = (nt_CertEnumCertificatesInStore)
        GetProcAddress(crypt32, "CertEnumCertificatesInStore");
    close_store = (nt_CertCloseStore)
        GetProcAddress(crypt32, "CertCloseStore");
    if (!open_store || !enum_certs || !close_store)
        return -1;
    if (!(store = open_store(0, u"ROOT")))
        return -1;
    while ((c = enum_certs(store, c))) {
        if (c->dwCertEncodingType & NT_X509_ASN_ENCODING) {
            write_pem_certificate(f, c->pbCertEncoded, c->cbCertEncoded);
            count++;
        }
    }
    close_store(store, 0);
    return count;
}
#else
static int windows_export_cacerts(FILE *f)
{
    (void)f;
    return -1;
}
#endif

/* Returns the PEM file name, or NULL when there are no certificates. */
static char *windows_write_cacerts(void)
{
    char *path;
    FILE *f;
    int count;

    if (!(f = windows_tmp_file(1, "cacerts.pem", &path)))
        return NULL;
    fputs("# Trusted root certificates of Windows, exported by BEAM.com.\n", f);
    count = windows_export_cacerts(f);
    if ((ferror(f) | fclose(f)) || count <= 0) {
        unlink(path);
        windows_tmp_files[1] = NULL;
        return NULL;
    }
    return path;
}

static int has_arg(const struct arglist *l, const char *arg)
{
    int i;
    for (i = 0; i < l->n; i++)
        if (strcmp(l->v[i], arg) == 0)
            return 1;
    return 0;
}

/*
 * The arguments go to *out, which comes before the arguments of the user
 * (after "-extra", every argument is a plain argument). *init holds the
 * arguments of the user, to see if they give -public_key themselves.
 */
static void windows_setup(const struct arglist *init, struct arglist *out)
{
    char *path;

    if (!getenv("ERL_INETRC")) {
        path = windows_write_inetrc();
        setenv("ERL_INETRC", path ? path : BEAM_COM_BINDIR "/windows.inetrc", 1);
    }
    if (!has_arg(init, "-public_key") && (path = windows_write_cacerts())) {
        push(out, "-public_key");
        push(out, "cacerts_path");
        push(out, join("\"", path, "\""));
    }
}

int beam_com_exec_helper(const char *path, char *const argv[],
                         char *const envp[])
{
    extern char **environ;
    char *const *src = envp ? envp : environ;
    struct arglist env = {0};
    size_t i;

    for (i = 0; src[i]; i++)
        if (strncmp(src[i], "BEAM_COM_PROGRAM=", 17) != 0)
            push(&env, src[i]);
    push(&env, join("BEAM_COM_PROGRAM=", beam_com_basename(path), ""));
    return execve(GetProgramExecutableName(), argv, env.v);
}

/*
 * Distributed Erlang needs epmd. It starts only for -sname, -name (the
 * long form) or -remsh, never otherwise, as erlexec starts "epmd -daemon"
 * before the emulator (unless -start_epmd false). epmd is this file: the
 * child runs as epmd (BEAM_COM_PROGRAM), and "-daemon" returns at once
 * when an epmd already runs, or after the daemon has started.
 */
static void start_epmd(struct arglist *all)
{
    extern char **environ;
    struct arglist env = {0};
    char *args[] = {"epmd", "-daemon", NULL};
    int i, named = 0, status;
    pid_t pid;

    for (i = 0; i < all->n; i++) {
        if (strcmp(all->v[i], "-sname") == 0 || strcmp(all->v[i], "-name") == 0 ||
            strcmp(all->v[i], "-remsh") == 0)
            named = 1;
        if (strcmp(all->v[i], "-start_epmd") == 0 && i + 1 < all->n &&
            strcmp(all->v[i + 1], "false") == 0)
            return;
    }
    if (!named)
        return;
    for (i = 0; environ[i]; i++)
        if (strncmp(environ[i], "BEAM_COM_PROGRAM=", 17) != 0)
            push(&env, environ[i]);
    push(&env, "BEAM_COM_PROGRAM=epmd");
    if ((pid = fork()) == 0) {
        execve(GetProgramExecutableName(), args, env.v);
        _exit(127);
    }
    if (pid > 0)
        waitpid(pid, &status, 0);
}

void beam_com_main(int *argcp, char ***argvp)
{
    int argc = *argcp;
    char **argv = *argvp;
    const char *name = beam_com_basename(argv[0]);
    char *program = getenv("BEAM_COM_PROGRAM");
    struct arglist file = {0}, emu = {0}, init = {0}, windows = {0}, all = {0};
    int i, extra = 0, used_cli = 0, has_release, has_args, erl_mode;
    const char *tool;

    /* Set by beam_com_exec_helper(). Remove it, so that the programs
     * that the helper starts do not see it. */
    if (program) {
        name = strdup(program);
        unsetenv("BEAM_COM_PROGRAM");
    }

    /* A backtrace (with the symbols of /zip/.symtab.*) when the emulator
     * dies on a fatal signal: SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP or
     * SIGABRT. ERTS does not use these signals, and it sets its own
     * handler for SIGQUIT later. BEAM_COM_CRASH_REPORTS=0 turns it off. */
    if (!getenv("BEAM_COM_CRASH_REPORTS") ||
        strcmp(getenv("BEAM_COM_CRASH_REPORTS"), "0") != 0)
        ShowCrashReports();

    apply_sandbox(starts_with(name, "erl_child_setup") ||
                  starts_with(name, "inet_gethost") || starts_with(name, "epmd"));

    if (starts_with(name, "erl_child_setup"))
        exit(erl_child_setup_main(argc, argv));
    if (starts_with(name, "inet_gethost"))
        exit(inet_gethost_main(argc, argv));
    /* epmd: started by start_epmd() below, or by the user ("epmd
     * -names", with a link named epmd, or "beam.com epmd -names"). */
    if (starts_with(name, "epmd"))
        exit(epmd_main(argc, argv));
    if (argc > 1 && strcmp(argv[1], "epmd") == 0 && file_exists(BEAM_COM_TOOL) &&
        !file_exists(BEAM_COM_RELEASES "/start_erl.data")) {
        argv[1] = "epmd";
        exit(epmd_main(argc - 1, argv + 1));
    }
    /* inotifywait: the file watcher (cosmo/beam_com_watch.c), by name
     * (the link that watch_link() makes) or as "beam.com inotifywait". */
    if (starts_with(name, "inotifywait"))
        exit(beam_com_inotifywait_main(argc, argv));
    if (argc > 1 && strcmp(argv[1], "inotifywait") == 0 && file_exists(BEAM_COM_TOOL) &&
        !file_exists(BEAM_COM_RELEASES "/start_erl.data"))
        exit(beam_com_inotifywait_main(argc - 1, argv + 1));
    /* mac_listener: the same watcher, as the watcher of file_system on
     * macOS (the script that watch_link() makes), or "beam.com
     * mac_listener". */
    if (starts_with(name, "mac_listener"))
        exit(beam_com_mac_listener_main(argc, argv));
    if (argc > 1 && strcmp(argv[1], "mac_listener") == 0 && file_exists(BEAM_COM_TOOL) &&
        !file_exists(BEAM_COM_RELEASES "/start_erl.data"))
        exit(beam_com_mac_listener_main(argc - 1, argv + 1));

    /* erl mode: the program behaves as erl (the runtime of its zip, with
     * /zip as the root and all its applications in the code path), not
     * as its release. For code that starts another Erlang node of the
     * program (peer, or a worker in a sandbox): run the program file with
     * the name "erl" (a link), or with BEAM_COM_ERL=1. All the arguments
     * are erl arguments. */
    erl_mode = strcmp(name, "erl") == 0 || strcmp(name, "erl.exe") == 0 ||
               strcmp(name, "erl.com") == 0 ||
               (getenv("BEAM_COM_ERL") && strcmp(getenv("BEAM_COM_ERL"), "1") == 0);
    /* beam.com with the flags of erl ("beam.com -sname me -remsh app",
     * "beam.com +S 1 -eval ..."): erl mode too, in a file without a
     * release (whose arguments are its own). -h, --help and --version are
     * commands of beam.com. Not for a tool (elixir.com -e ...). */
    if (!erl_mode && argc > 1 && (argv[1][0] == '-' || argv[1][0] == '+') &&
        !elixir_tool(name) &&
        strcmp(argv[1], "-h") != 0 && strcmp(argv[1], "--help") != 0 &&
        strcmp(argv[1], "--version") != 0 && file_exists(BEAM_COM_TOOL) &&
        !file_exists(BEAM_COM_RELEASES "/start_erl.data"))
        erl_mode = 1;
    /* "app.com remote": a shell in the running node of the release in
     * the zip, as "bin/app remote" of rebar3 and mix release: erl mode
     * with -remsh and the node name (-sname or -name) and -setcookie of
     * the vm.args of the release. The new node is hidden, and gets a
     * random name (-remsh does that since OTP 25). */
    if (!erl_mode && argc > 1 && strcmp(argv[1], "remote") == 0 &&
        file_exists(BEAM_COM_RELEASES "/start_erl.data")) {
        struct arglist rel = {0}, args = {0};
        const char *node = NULL, *cookie = NULL;

        read_release(&rel);
        for (i = 0; i + 1 < rel.n; i++) {
            if (strcmp(rel.v[i], "-sname") == 0 || strcmp(rel.v[i], "-name") == 0)
                node = rel.v[i + 1];
            else if (strcmp(rel.v[i], "-setcookie") == 0)
                cookie = rel.v[i + 1];
        }
        if (!node) {
            fprintf(stderr, "%s: remote: the release has no -sname or -name "
                            "(in its vm.args)\n", name);
            exit(1);
        }
        push(&args, argv[0]);
        push(&args, "-remsh");
        push(&args, (char *)node);
        push(&args, "-hidden");
        if (cookie) {
            push(&args, "-setcookie");
            push(&args, (char *)cookie);
        }
        for (i = 2; i < argc; i++)
            push(&args, argv[i]);
        argc = args.n;
        argv = args.v;
        erl_mode = 1;
    }
    /* The tools: escript, and the Elixir tools as the scripts of Elixir
     * start them. The name of the file (a copy or a link named mix.com,
     * iex.com, elixir.com, elixirc.com or escript, with or without .com
     * or .exe), or the first argument of the file ("beam.com mix test").
     * They run with all the applications of the zip in the code path. */
    tool = erl_mode ? NULL : elixir_tool(name);
    if (!erl_mode && !tool && argc > 1 && file_exists(BEAM_COM_TOOL) &&
        (tool = elixir_tool(argv[1])) && strchr(argv[1], '.') == NULL) {
        /* "beam.com mix test": mix gets "test". */
        argv[1] = argv[0];
        argv++;
        argc--;
    }
    /* "iex -S mix": Elixir looks for an executable mix in PATH and
     * loads it as a script; the script of mix is in the zip. */
    if (tool && (strcmp(tool, "iex") == 0 || strcmp(tool, "elixir") == 0)) {
        for (i = 1; i + 1 < argc; i++) {
            if (strcmp(argv[i], "-S") == 0) {
                if (strcmp(argv[i + 1], "mix") == 0)
                    argv[i + 1] = BEAM_COM_BINDIR "/mix";
                break;
            }
        }
    }
    if (tool && strcmp(tool, "escript") != 0 && !zip_has_elixir()) {
        fprintf(stderr, "beam.com: %s: Elixir is not in this file "
                        "(built with ELIXIR=0)\n", tool);
        exit(1);
    }
    if (erl_mode) {
        unsetenv("BEAM_COM_ERL");
        push(&file, "-boot");
        push(&file, BEAM_COM_BINDIR "/start_clean");
        push(&file, "...");
        has_release = 1;
        has_args = 0;
    } else if (tool && strcmp(tool, "escript") == 0) {
        /* As the escript program of OTP: "escript FILE ARGS". */
        push(&file, "-boot");
        push(&file, BEAM_COM_BINDIR "/no_dot_erlang");
        push(&file, "-noshell");
        if (argc > 1)
            escript_flags(argv[1], &file);
        push(&file, "-run");
        push(&file, "escript");
        push(&file, "start");
        push(&file, "-extra");
        has_release = 1;
        has_args = 0;
    } else if (tool) {
        watch_link();
        push(&file, "-boot");
        push(&file, BEAM_COM_BINDIR "/start_clean");
        push(&file, "-noshell");
        if (strcmp(tool, "iex") == 0) {
            push(&file, "-user");
            push(&file, "elixir");
            push(&file, "-extra");
            push(&file, "--no-halt");
            push(&file, "+iex");
        } else {
            push(&file, "-s");
            push(&file, "elixir");
            push(&file, "start_cli");
            push(&file, "-extra");
            if (strcmp(tool, "elixirc") == 0)
                push(&file, "+elixirc");
            else if (strcmp(tool, "mix") == 0)
                push(&file, BEAM_COM_BINDIR "/mix");
        }
        has_release = 1;
        has_args = 0;
    } else {
        has_release = read_release(&file);
        has_args = read_zip_args(&file);
    }
    if (!erl_mode && !tool && file_exists(BEAM_COM_TOOL) &&
        ((!has_release && !has_args) ||
         (argc > 1 && strcmp(argv[1], "build") == 0))) {
        /* The commands of beam.com: when the zip has no release (the
         * default beam.com), and "build" also when it has one. They get
         * the arguments with init:get_plain_arguments() (after "-extra",
         * below). */
        file = (struct arglist){0};
        push(&file, "-boot");
        push(&file, BEAM_COM_BINDIR "/start_clean");
        push(&file, "-noshell");
        push(&file, "-run");
        push(&file, "beam_com");
        push(&file, "main");
        has_release = 1;
        has_args = 0;
    }
    if (!has_release && !has_args)
        return; /* Not a bundle: behave like a plain beam.smp. */

    /* ERL_FLAGS has more flags, as with erl, and ELIXIR_ERL_OPTIONS for
     * the Elixir tools, as with the scripts of Elixir. */
    {
        const char *flag_vars[2];
        int v;
        flag_vars[0] = "ERL_FLAGS";
        flag_vars[1] = tool ? "ELIXIR_ERL_OPTIONS" : NULL;
        for (v = 0; v < 2; v++) {
            struct arglist flags = {0};
            char *copy, *word, *save;
            if (!flag_vars[v] || !getenv(flag_vars[v]))
                continue;
            copy = strdup(getenv(flag_vars[v]));
            for (word = strtok_r(copy, " \t\r\n", &save); word;
                 word = strtok_r(NULL, " \t\r\n", &save))
                push(&flags, word);
            for (i = 0; i < flags.n; i++)
                add_user_arg(&emu, &init, flags.v, &i, flags.n, &extra);
        }
    }

    for (i = 0; i < file.n; i++) {
        if (strcmp(file.v[i], "...") == 0) {
            int j;
            for (j = 1; j < argc; j++)
                add_user_arg(&emu, &init, argv, &j, argc, &extra);
            used_cli = 1;
        } else {
            add_user_arg(&emu, &init, file.v, &i, file.n, &extra);
        }
    }

    /* Without "...", the command line arguments are plain arguments
     * for the program (init:get_plain_arguments/0). */
    if (!used_cli && argc > 1) {
        if (!extra)
            push(&init, "-extra");
        for (i = 1; i < argc; i++)
            push(&init, argv[i]);
    }

    /* On Windows there are no port programs, and the native resolver
     * (inet_gethost) is one: kernel halts the node when it cannot start
     * it. Give kernel the name servers of Windows and public_key the
     * certificates of Windows (see windows_setup()). */
    if (beam_com_is_windows())
        windows_setup(&init, &windows);

    setenv("ROOTDIR", BEAM_COM_ROOT, 1);
    setenv("BINDIR", BEAM_COM_BINDIR, 1);
    setenv("EMU", "beam", 1);
    setenv("PROGNAME", "beam.com", 1);

    push(&all, argv[0]);
    for (i = 0; i < emu.n; i++)
        push(&all, emu.v[i]);
    push(&all, "--");
    push(&all, "-root");
    push(&all, BEAM_COM_ROOT);
    push(&all, "-bindir");
    push(&all, BEAM_COM_BINDIR);
    push(&all, "-progname");
    push(&all, "beam.com");
    push(&all, "--");
    push(&all, "-home");
    push(&all, home_dir());
    /* The path of this file, for the program: init:get_argument(
     * beam_com_exe) (for example to start it again in erl mode). */
    push(&all, "-beam_com_exe");
    push(&all, GetProgramExecutableName());
    push(&all, "--");
    for (i = 0; i < windows.n; i++)
        push(&all, windows.v[i]);
    for (i = 0; i < init.n; i++)
        push(&all, init.v[i]);

    start_epmd(&all);

    if (getenv("BEAM_COM_VERBOSE")) {
        fprintf(stderr, "beam.com: executing:");
        for (i = 0; i < all.n; i++)
            fprintf(stderr, " %s", all.v[i]);
        fprintf(stderr, "\n");
    }

    *argcp = all.n;
    *argvp = all.v;
}
