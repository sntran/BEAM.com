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
 * When the executable holds a /zip/.args file (redbean style), the
 * emulator arguments are made from that file, the same way as erlexec
 * would do it for an OTP installation in /zip.
 */
#include <cosmo.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* erts_cosmo.h is included by the compiler (-include). */


#define BEAM_COM_ROOT "/zip"
#define BEAM_COM_BINDIR "/zip/bin"
#define BEAM_COM_ARGS "/zip/.args"

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

static char *home_dir(void)
{
    char *home = getenv("HOME");
    if (!home || !*home)
        home = getenv("USERPROFILE");
    if (!home || !*home)
        home = "/";
    return home;
}

void beam_com_main(int *argcp, char ***argvp)
{
    int argc = *argcp;
    char **argv = *argvp;
    const char *name = beam_com_basename(argv[0]);
    struct arglist file = {0}, emu = {0}, init = {0}, all = {0};
    int i, extra = 0, used_cli = 0;

    if (starts_with(name, "erl_child_setup"))
        exit(erl_child_setup_main(argc, argv));
    if (starts_with(name, "inet_gethost"))
        exit(inet_gethost_main(argc, argv));

    if (!read_zip_args(&file))
        return; /* Not a bundle: behave like a plain beam.smp. */

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
    if (!used_cli) {
        for (i = 1; i < argc; i++)
            add_user_arg(&emu, &init, argv, &i, argc, &extra);
    }

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
