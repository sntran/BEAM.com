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
 * When the first argument is a command of beam.com ("build") and the
 * zip has the beam_com application, the command runs instead of the
 * release (see apps/beam_com).
 */
#include <cosmo.h>
#include <errno.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

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

extern int erl_child_setup_main(int argc, char **argv);
extern int inet_gethost_main(int argc, char **argv);

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
static int read_zip_args(struct arglist *out)
{
    FILE *f;
    char *line = NULL;
    size_t cap = 0;
    ssize_t len;

    if (!(f = fopen(BEAM_COM_ARGS, "r")))
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

static int file_exists(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f)
        return 0;
    fclose(f);
    return 1;
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

void beam_com_main(int *argcp, char ***argvp)
{
    int argc = *argcp;
    char **argv = *argvp;
    const char *name = beam_com_basename(argv[0]);
    char *program = getenv("BEAM_COM_PROGRAM");
    struct arglist file = {0}, emu = {0}, init = {0}, windows = {0}, all = {0};
    int i, extra = 0, used_cli = 0, has_release, has_args;

    /* Set by beam_com_exec_helper(). Remove it, so that the programs
     * that the helper starts do not see it. */
    if (program) {
        name = strdup(program);
        unsetenv("BEAM_COM_PROGRAM");
    }

    if (starts_with(name, "erl_child_setup"))
        exit(erl_child_setup_main(argc, argv));
    if (starts_with(name, "inet_gethost"))
        exit(inet_gethost_main(argc, argv));

    if (argc > 1 && strcmp(argv[1], "build") == 0 && file_exists(BEAM_COM_TOOL)) {
        /* A command of beam.com. It gets the arguments with
         * init:get_plain_arguments() (after "-extra", below). */
        push(&file, "-boot");
        push(&file, BEAM_COM_BINDIR "/start_clean");
        push(&file, "-noshell");
        push(&file, "-beam_com_exe");
        push(&file, GetProgramExecutableName());
        push(&file, "-run");
        push(&file, "beam_com");
        push(&file, "main");
        has_release = 1;
        has_args = 0;
    } else {
        has_release = read_release(&file);
        has_args = read_zip_args(&file);
    }
    if (!has_release && !has_args)
        return; /* Not a bundle: behave like a plain beam.smp. */

    /* ERL_FLAGS has more flags, as with erl. */
    if (getenv("ERL_FLAGS")) {
        struct arglist flags = {0};
        char *copy = strdup(getenv("ERL_FLAGS")), *word, *save;
        for (word = strtok_r(copy, " \t\r\n", &save); word;
             word = strtok_r(NULL, " \t\r\n", &save))
            push(&flags, word);
        for (i = 0; i < flags.n; i++)
            add_user_arg(&emu, &init, flags.v, &i, flags.n, &extra);
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
    push(&all, "--");
    for (i = 0; i < windows.n; i++)
        push(&all, windows.v[i]);
    for (i = 0; i < init.n; i++)
        push(&all, init.v[i]);

    if (getenv("BEAM_COM_VERBOSE")) {
        fprintf(stderr, "beam.com: executing:");
        for (i = 0; i < all.n; i++)
            fprintf(stderr, " %s", all.v[i]);
        fprintf(stderr, "\n");
    }

    *argcp = all.n;
    *argvp = all.v;
}
