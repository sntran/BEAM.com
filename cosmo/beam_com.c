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
 */
#include <cosmo.h>
#include <errno.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* erts_cosmo.h is included by the compiler (-include). */


#define BEAM_COM_ROOT "/zip"
#define BEAM_COM_BINDIR "/zip/bin"
#define BEAM_COM_ARGS "/zip/.args"
#define BEAM_COM_RELEASES "/zip/releases"

extern int erl_child_setup_main(int argc, char **argv);
extern int inet_gethost_main(int argc, char **argv);

struct arglist {
    char **v;
    int n;
    int cap;
};

static void die(const char *what)
{
    fprintf(stderr, "beam.com: %s: %s\n", what, strerror(errno));
    exit(127);
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
        exit(127);
    }
    fclose(f);

    dir = join(BEAM_COM_RELEASES "/", rel_vsn, "/");
    path = join(dir, "start", ".boot");
    if (!file_exists(path)) {
        fprintf(stderr, "beam.com: %s not found\n", path);
        exit(127);
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
    struct arglist file = {0}, emu = {0}, init = {0}, all = {0};
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

    has_release = read_release(&file);
    has_args = read_zip_args(&file);
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
     * it. Use the DNS client of Erlang instead, unless the user gave an
     * inetrc file. */
    if (beam_com_is_windows() && !getenv("ERL_INETRC"))
        setenv("ERL_INETRC", BEAM_COM_BINDIR "/windows.inetrc", 1);

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
