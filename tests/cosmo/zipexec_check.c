/*
 * The checks of c_src/cosmo/beam_com_zipexec.c: the programs of the zip.
 *
 * - The helper names of /zip/bin, and the clean form of a /zip path.
 * - SHA-256, with the vectors of FIPS 180-4.
 * - The cache directory: BEAM_COM_CACHE, XDG_CACHE_HOME and HOME.
 * - The copy in the cache: its name CACHE/bin/SHA256/NAME (with .exe on
 *   Windows), its mode 0500, and no new file at a second use. 8 programs
 *   that make the same copy at the same time get one whole file, and no
 *   temporary file stays. The copy runs.
 * - A refusal, with no new file: a directory bin that other users can
 *   write, a symbolic link, a copy with another size or mode, and no copy
 *   when the call cannot write.
 * - The SHA-256 of a program from the file .programs of the zip, when it
 *   has the size of the program. A copy of bytes with another SHA-256 is
 *   refused.
 * - Linux: the memfd of an ELF program has its seals and FD_CLOEXEC, and
 *   it runs through /proc/self/fd. A file that is not ELF gives ENOEXEC.
 *
 * - The zip of the check (tests/cosmo/zipexec_check.sh adds the files):
 *   access() and stat() give the execute bit of an entry, the copy of an
 *   entry runs, and on Linux the memfd of an ELF entry runs.
 *
 * The program starts itself for the parts in other processes ("--child"
 * and "--cache"). The last line is "zipexec_check: ok".
 */
#include "../../c_src/cosmo/beam_com_zipexec.c"

#include <spawn.h>
#include <sys/wait.h>

int __sys_execve(const char *, char *const[], char *const[]);

static int failures;

#define CHECK(cond)                                                          \
    do {                                                                     \
        if (!(cond)) {                                                       \
            fprintf(stderr, "zipexec_check: line %d: %s\n", __LINE__, #cond); \
            failures++;                                                      \
        }                                                                    \
    } while (0)

extern char **environ;

static void sha_of(const char *data, size_t n, size_t repeat, char hex[65])
{
    struct zip_sha256 s;
    size_t i;

    zip_sha256_init(&s);
    for (i = 0; i < repeat; i++)
        zip_sha256_update(&s, data, n);
    zip_sha256_hex(&s, hex);
}

static void write_file(const char *path, const char *data, size_t n, int mode)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode);

    CHECK(fd >= 0);
    if (fd >= 0) {
        CHECK(write(fd, data, n) == (ssize_t)n);
        close(fd);
    }
}

/* A copy of the file FROM at TO, with the mode 0755. */
static void copy_file(const char *from, const char *to)
{
    int in = open(from, O_RDONLY), out = open(to, O_WRONLY | O_CREAT | O_TRUNC, 0755);

    CHECK(in >= 0 && out >= 0);
    if (in >= 0 && out >= 0)
        CHECK(zip_copy(in, out, NULL) == 0);
    if (in >= 0)
        close(in);
    if (out >= 0)
        close(out);
}

/* The number of entries of DIR, without "." and "..". */
static int entries(const char *dir)
{
    struct dirent *e;
    DIR *d = opendir(dir);
    int n = 0;

    if (!d)
        return -1;
    while ((e = readdir(d)))
        if (strcmp(e->d_name, ".") != 0 && strcmp(e->d_name, "..") != 0)
            n++;
    closedir(d);
    return n;
}

/* Runs PROG with ARGV and gives its output in OUT. The exit status. */
static int run(const char *prog, char *const argv[], char *out, size_t size)
{
    posix_spawn_file_actions_t fa;
    int fds[2], pid, status = -1;
    ssize_t n, total = 0;

    out[0] = '\0';
    if (pipe(fds) != 0)
        return -1;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
    posix_spawn_file_actions_addclose(&fa, fds[0]);
    if (posix_spawn(&pid, prog, &fa, NULL, argv, environ) != 0) {
        posix_spawn_file_actions_destroy(&fa);
        close(fds[0]);
        close(fds[1]);
        return -1;
    }
    posix_spawn_file_actions_destroy(&fa);
    close(fds[1]);
    while ((n = read(fds[0], out + total, size - 1 - total)) > 0)
        total += n;
    out[total] = '\0';
    close(fds[0]);
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static void check_names(void)
{
    char out[PATH_MAX];

    CHECK(beam_com_zip_helper("/zip/bin/erl_child_setup"));
    CHECK(beam_com_zip_helper("/zip/bin/inet_gethost"));
    CHECK(beam_com_zip_helper("/zip/bin/epmd"));
    CHECK(beam_com_zip_helper("/zip/bin/git_sha1dc"));
    CHECK(beam_com_zip_helper("/zip/bin/ssh_agent_bridge"));
    CHECK(beam_com_zip_helper("/zip/bin/mix"));
    CHECK(beam_com_zip_helper("/zip/bin/make.exe"));
    CHECK(beam_com_zip_helper("/zip/bin/erl.com"));
    CHECK(!beam_com_zip_helper("/zip/bin/tailwind"));
    CHECK(!beam_com_zip_helper("/zip/bin/epmdx"));
    CHECK(!beam_com_zip_helper("/zip/bin/epmd.sh"));
    CHECK(!beam_com_zip_helper("/zip/bin/sub/epmd"));
    CHECK(!beam_com_zip_helper("/zip/lib/app-1.0/priv/bin/epmd"));
    CHECK(!beam_com_zip_helper("/usr/bin/epmd"));
    CHECK(!beam_com_zip_helper(NULL));

    CHECK(beam_com_zip_path("/zip/lib/a/priv/bin/x", out, sizeof(out)) == 0 &&
          strcmp(out, "/zip/lib/a/priv/bin/x") == 0);
    CHECK(beam_com_zip_path("/zip//lib/./a/../b/priv\\bin/x/", out, sizeof(out)) == 0 &&
          strcmp(out, "/zip/lib/b/priv/bin/x") == 0);
    CHECK(beam_com_zip_path("/zip/bin/../bin/epmd", out, sizeof(out)) == 0 &&
          strcmp(out, "/zip/bin/epmd") == 0);
    CHECK(beam_com_zip_path("/zip/../etc/passwd", out, sizeof(out)) == EINVAL);
    CHECK(beam_com_zip_path("/zip/..", out, sizeof(out)) == EINVAL);
    CHECK(beam_com_zip_path("/zip", out, sizeof(out)) == EINVAL);
    CHECK(beam_com_zip_path("zip/a", out, sizeof(out)) == EINVAL);
    CHECK(beam_com_zip_path("/zipx/a", out, sizeof(out)) == EINVAL);
    CHECK(beam_com_zip_path("/zip/a/bcdef", out, 10) == ENAMETOOLONG);
}

static void check_sha256(void)
{
    char hex[65], *mega;

    sha_of("", 0, 1, hex);
    CHECK(strcmp(hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") == 0);
    sha_of("abc", 3, 1, hex);
    CHECK(strcmp(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") == 0);
    sha_of("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56, 1, hex);
    CHECK(strcmp(hex, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1") == 0);
    /* One million "a", in parts of 7 bytes, so that the parts cross the
     * blocks of 64 bytes. */
    mega = malloc(1000000);
    memset(mega, 'a', 1000000);
    sha_of(mega, 1000000, 1, hex);
    CHECK(strcmp(hex, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0") == 0);
    free(mega);
    {
        struct zip_sha256 s;
        int i;
        zip_sha256_init(&s);
        for (i = 0; i < 142857; i++)
            zip_sha256_update(&s, "aaaaaaa", 7);
        zip_sha256_update(&s, "a", 1);
        zip_sha256_hex(&s, hex);
        CHECK(strcmp(hex, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0") ==
              0);
    }
}

static void check_cache_dir(void)
{
    char out[PATH_MAX], want[PATH_MAX];
    char *cache = getenv("BEAM_COM_CACHE") ? strdup(getenv("BEAM_COM_CACHE")) : NULL;
    char *xdg = getenv("XDG_CACHE_HOME") ? strdup(getenv("XDG_CACHE_HOME")) : NULL;
    char *home = getenv("HOME") ? strdup(getenv("HOME")) : NULL;

    setenv("BEAM_COM_CACHE", "/c/cache/", 1);
    CHECK(beam_com_zip_cache_dir(out, sizeof(out)) == 0 && strcmp(out, "/c/cache") == 0);
    setenv("BEAM_COM_CACHE", "", 1);
    setenv("XDG_CACHE_HOME", "/x", 1);
    setenv("HOME", "/h", 1);
    snprintf(want, sizeof(want), "%s", IsXnu() ? "/h/Library/Caches/beam.com" : "/x/beam.com");
    CHECK(beam_com_zip_cache_dir(out, sizeof(out)) == 0 && strcmp(out, want) == 0);
    unsetenv("XDG_CACHE_HOME");
    snprintf(want, sizeof(want), "%s",
             IsXnu() ? "/h/Library/Caches/beam.com" : "/h/.cache/beam.com");
    CHECK(beam_com_zip_cache_dir(out, sizeof(out)) == 0 && strcmp(out, want) == 0);
    CHECK(beam_com_zip_cache_dir(out, 5) == ENAMETOOLONG);
    cache ? setenv("BEAM_COM_CACHE", cache, 1) : unsetenv("BEAM_COM_CACHE");
    xdg ? setenv("XDG_CACHE_HOME", xdg, 1) : unsetenv("XDG_CACHE_HOME");
    home ? setenv("HOME", home, 1) : unsetenv("HOME");
}

static void check_cache(const char *self, const char *work)
{
    char cache[256], prog[256], other[256], out[PATH_MAX], out2[PATH_MAX];
    char dir[512], bin[300], msg[PATH_MAX + 256], hex[65], text[256];
    char *child[] = {"prog", "--child", "hello", NULL};
    struct stat st, st2;
    int pids[8], i, status, ok;

    snprintf(cache, sizeof(cache), "%s/cache", work);
    snprintf(bin, sizeof(bin), "%s/bin", cache);
    snprintf(prog, sizeof(prog), "%s/prog", work);
    copy_file(self, prog);
    setenv("BEAM_COM_CACHE", cache, 1);

    CHECK(beam_com_zip_program(prog) == 0);
    CHECK(beam_com_zip_program(work) == EACCES);
    CHECK(beam_com_zip_hash(prog, hex) == 0);

    /* The first copy. */
    CHECK(beam_com_zip_cache(prog, 1, out, sizeof(out), msg, sizeof(msg)) == 0);
    if (msg[0])
        fprintf(stderr, "zipexec_check: %s\n", msg);
    snprintf(dir, sizeof(dir), "%s/%s", bin, hex);
    snprintf(out2, sizeof(out2), "%s/prog%s", dir, IsWindows() ? ".exe" : "");
    CHECK(strcmp(out, out2) == 0);
    CHECK(stat(out, &st) == 0 && stat(prog, &st2) == 0 && st.st_size == st2.st_size);
    if (!IsWindows()) {
        CHECK((st.st_mode & 0777) == 0500);
        CHECK(stat(dir, &st2) == 0 && (st2.st_mode & 0777) == 0700);
        CHECK(stat(bin, &st2) == 0 && (st2.st_mode & 0777) == 0700);
    }
    CHECK(entries(dir) == 1);
    /* The copy runs. */
    CHECK(run(out, child, text, sizeof(text)) == 0 && strcmp(text, "child hello\n") == 0);

    /* A second use: the same file, no new file. */
    CHECK(beam_com_zip_cache(prog, 1, out2, sizeof(out2), msg, sizeof(msg)) == 0);
    CHECK(strcmp(out, out2) == 0);
    CHECK(stat(out, &st2) == 0 && st2.st_ino == st.st_ino &&
          st2.st_mtim.tv_sec == st.st_mtim.tv_sec && st2.st_mtim.tv_nsec == st.st_mtim.tv_nsec);
    CHECK(entries(dir) == 1);
    /* With no write: the copy is there. */
    CHECK(beam_com_zip_cache(prog, 0, out2, sizeof(out2), msg, sizeof(msg)) == 0);

    /* A new program (other bytes) with no write: no copy, no file. */
    snprintf(other, sizeof(other), "%s/other", work);
    write_file(other, "#!/bin/sh\necho other\n", 21, 0755);
    CHECK(beam_com_zip_cache(other, 0, out2, sizeof(out2), msg, sizeof(msg)) == ENOENT);
    CHECK(strstr(msg, "there is no copy") != NULL);
    CHECK(entries(bin) == 1);

    /* 8 programs make the copy of "other" at the same time. */
    for (i = 0; i < 8; i++) {
        char *args[] = {"zipexec_check", "--cache", other, NULL};
        if (posix_spawn(&pids[i], self, NULL, NULL, args, environ) != 0)
            pids[i] = -1;
    }
    ok = 0;
    for (i = 0; i < 8; i++)
        if (pids[i] > 0 && waitpid(pids[i], &status, 0) == pids[i] && WIFEXITED(status) &&
            WEXITSTATUS(status) == 0)
            ok++;
    CHECK(ok == 8);
    CHECK(entries(bin) == 2);
    CHECK(beam_com_zip_cache(other, 0, out2, sizeof(out2), msg, sizeof(msg)) == 0);
    CHECK(stat(out2, &st2) == 0 && st2.st_size == 21);
    {
        char sub[PATH_MAX];
        snprintf(sub, sizeof(sub), "%s", out2);
        *strrchr(sub, '/') = '\0';
        CHECK(entries(sub) == 1);
    }

    if (IsWindows())
        return;

    /* A copy with another mode, then another size: refused. */
    chmod(out, 0777);
    CHECK(beam_com_zip_cache(prog, 1, out2, sizeof(out2), msg, sizeof(msg)) == EACCES);
    CHECK(strstr(msg, "another user can write") != NULL);
    chmod(out, 0700);
    truncate(out, 10);
    chmod(out, 0500);
    CHECK(beam_com_zip_cache(prog, 1, out2, sizeof(out2), msg, sizeof(msg)) == EACCES);
    CHECK(strstr(msg, "size") != NULL);
    unlink(out);
    CHECK(beam_com_zip_cache(prog, 1, out2, sizeof(out2), msg, sizeof(msg)) == 0);

    /* A directory bin that other users can write: refused, and no new
     * directory or file in it. */
    chmod(bin, 0777);
    write_file(other, "#!/bin/sh\necho changed\n", 23, 0755);
    CHECK(beam_com_zip_cache(other, 1, out2, sizeof(out2), msg, sizeof(msg)) == EACCES);
    CHECK(strstr(msg, "is not a real directory of this user") != NULL);
    CHECK(entries(bin) == 2);
    CHECK(beam_com_zip_cache(prog, 1, out2, sizeof(out2), msg, sizeof(msg)) == EACCES);
    chmod(bin, 0700);

    /* A directory of the copy that other users can write: refused. */
    chmod(dir, 0777);
    CHECK(beam_com_zip_cache(prog, 1, out2, sizeof(out2), msg, sizeof(msg)) == EACCES);
    chmod(dir, 0700);

    /* bin as a symbolic link: refused. */
    snprintf(out2, sizeof(out2), "%s/bin.real", cache);
    CHECK(rename(bin, out2) == 0);
    CHECK(symlink(out2, bin) == 0);
    CHECK(beam_com_zip_cache(prog, 1, out, sizeof(out), msg, sizeof(msg)) == EACCES);
    unlink(bin);
    rename(out2, bin);
    CHECK(beam_com_zip_cache(prog, 1, out, sizeof(out), msg, sizeof(msg)) == 0);
}

static void check_memfd(const char *work)
{
    /* sh, not echo: the echo of uutils (Ubuntu 26.04) refuses to run when
     * the name of /proc/self/exe is not the name of a tool. */
    const char *elf = NULL, *list[] = {"/bin/sh", "/usr/bin/sh"};
    char text[256], path[PATH_MAX], proc[32];
    char *argv[] = {"sh", "-c", "echo memfd ok", NULL};
    int fd, fds[2], pid, status, flags;
    size_t i;
    ssize_t n;

    snprintf(path, sizeof(path), "%s/text", work);
    write_file(path, "#!/bin/sh\n", 10, 0755);
    errno = 0;
    CHECK(beam_com_zip_memfd(path) == -1 && errno == (IsLinux() ? ENOEXEC : ENOSYS));
    if (!IsLinux())
        return;
    for (i = 0; i < sizeof(list) / sizeof(list[0]) && !elf; i++)
        if (access(list[i], X_OK) == 0)
            elf = list[i];
    if (!elf) {
        printf("zipexec_check: no sh program: no check of the memfd\n");
        return;
    }
    fd = beam_com_zip_memfd(elf);
    if (fd < 0 && (errno == ENOSYS || errno == EACCES || errno == EPERM)) {
        printf("zipexec_check: the kernel gives no memfd (%s): no check of it\n",
               strerror(errno));
        return;
    }
    CHECK(fd >= 0);
    if (fd < 0)
        return;
    CHECK(fcntl(fd, 1034 /* F_GET_SEALS */) == ZIP_SEALS);
    CHECK((flags = fcntl(fd, F_GETFD)) >= 0 && (flags & FD_CLOEXEC));
    CHECK(write(fd, "x", 1) == -1 && errno == EPERM);
    CHECK(pipe(fds) == 0);
    if ((pid = fork()) == 0) {
        dup2(fds[1], 1);
        snprintf(proc, sizeof(proc), "/proc/self/fd/%d", fd);
        __sys_execve(proc, argv, environ);
        _exit(127);
    }
    close(fds[1]);
    n = read(fds[0], text, sizeof(text) - 1);
    text[n > 0 ? n : 0] = '\0';
    close(fds[0]);
    waitpid(pid, &status, 0);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0 && strcmp(text, "memfd ok\n") == 0);
    close(fd);
}

/* The file .programs of the zip, in WORK as the root of the zip. */
static void check_programs(const char *work)
{
    char prog[256], fake[256], list[1024], hex[65], real[65], out[PATH_MAX];
    char msg[PATH_MAX + 256], cache[256];
    int n;

    zip_root = work;
    snprintf(cache, sizeof(cache), "%s/cache2", work);
    setenv("BEAM_COM_CACHE", cache, 1);
    snprintf(prog, sizeof(prog), "%s/listed", work);
    write_file(prog, "listed program", 14, 0755);
    snprintf(fake, sizeof(fake), "%s/fake", work);
    write_file(fake, "fake program", 12, 0755);
    sha_of("listed program", 14, 1, real);
    n = snprintf(list, sizeof(list),
                 "%s 14 listed\n"
                 "%s 12 fake\n"
                 "%s 99 other size\n"
                 "short line\n",
                 real, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    snprintf(out, sizeof(out), "%s/.programs", work);
    write_file(out, list, n, 0644);
    /* A line of the file gives the SHA-256, with no read of the program. */
    CHECK(beam_com_zip_hash(fake, hex) == 0 &&
          strcmp(hex, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") == 0);
    CHECK(beam_com_zip_hash(prog, hex) == 0 && strcmp(hex, real) == 0);
    CHECK(beam_com_zip_cache(prog, 1, out, sizeof(out), msg, sizeof(msg)) == 0);
    CHECK(strstr(out, real) != NULL);
    /* The bytes of "fake" do not have its SHA-256: no copy. */
    CHECK(beam_com_zip_cache(fake, 1, out, sizeof(out), msg, sizeof(msg)) == EIO);
    CHECK(strstr(msg, "do not have the SHA-256") != NULL);
    snprintf(out, sizeof(out), "%s/bin/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
             cache);
    CHECK(entries(out) == 0);
    /* A line with another size does not count: the SHA-256 of the bytes. */
    snprintf(prog, sizeof(prog), "%s/other size", work);
    write_file(prog, "x", 1, 0755);
    sha_of("x", 1, 1, real);
    CHECK(beam_com_zip_hash(prog, hex) == 0 && strcmp(hex, real) == 0);
    zip_root = "/zip";
}

static int walked;

static void count(const char *path, void *arg);

/* The files of the zip (tests/cosmo/zipexec_check.sh). */
static void check_zip(const char *work)
{
    char cache[256], out[PATH_MAX], msg[PATH_MAX + 256], text[256], proc[32], hex[65];
    char *child[] = {"prog", "--child", "zip", NULL};
    char *sh[] = {"sh", "-c", "echo memfd zip", NULL};
    int fd, fds[2], pid, status, programs = 1;
    ssize_t n;

    if (access("/zip/zipexec/prog", F_OK) != 0) {
        printf("zipexec_check: no /zip/zipexec (tests/cosmo/zipexec_check.sh): no check of the "
               "zip\n");
        return;
    }
    CHECK(beam_com_zip_program("/zip/zipexec/prog") == 0);
    CHECK(access("/zip/zipexec/prog", X_OK) == 0);
    CHECK(beam_com_zip_program("/zip/zipexec/data") == EACCES);
    CHECK(access("/zip/zipexec/data", X_OK) != 0);
    CHECK(beam_com_zip_program("/zip/zipexec") == EACCES);
    CHECK(beam_com_zip_program("/zip/zipexec/none") == ENOENT);
    snprintf(cache, sizeof(cache), "%s/cache3", work);
    setenv("BEAM_COM_CACHE", cache, 1);
    CHECK(beam_com_zip_cache("/zip/zipexec/prog", 1, out, sizeof(out), msg, sizeof(msg)) == 0);
    if (msg[0])
        fprintf(stderr, "zipexec_check: %s\n", msg);
    CHECK(run(out, child, text, sizeof(text)) == 0 && strcmp(text, "child zip\n") == 0);
    /* The second hash comes from memory. */
    CHECK(beam_com_zip_hash("/zip/zipexec/prog", hex) == 0 && strstr(out, hex) != NULL);
    if (access("/zip/zipexec/sh", F_OK) == 0) {
        programs++;
        if (IsLinux() && (fd = beam_com_zip_memfd("/zip/zipexec/sh")) >= 0) {
            CHECK(pipe(fds) == 0);
            if ((pid = fork()) == 0) {
                dup2(fds[1], 1);
                snprintf(proc, sizeof(proc), "/proc/self/fd/%d", fd);
                __sys_execve(proc, sh, environ);
                _exit(127);
            }
            close(fds[1]);
            n = read(fds[0], text, sizeof(text) - 1);
            text[n > 0 ? n : 0] = '\0';
            close(fds[0]);
            waitpid(pid, &status, 0);
            CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0 &&
                  strcmp(text, "memfd zip\n") == 0);
            close(fd);
        }
    }
    walked = 0;
    beam_com_zip_walk("/zip/zipexec", count, NULL);
    CHECK(walked == programs);
}

static void count(const char *path, void *arg)
{
    (void)arg;
    (void)path;
    walked++;
}

static void check_walk(const char *work)
{
    char dir[PATH_MAX], file[PATH_MAX];

    snprintf(dir, sizeof(dir), "%s/walk", work);
    mkdir(dir, 0700);
    snprintf(file, sizeof(file), "%s/walk/sub", work);
    mkdir(file, 0700);
    snprintf(file, sizeof(file), "%s/walk/sub/a", work);
    write_file(file, "a", 1, 0755);
    snprintf(file, sizeof(file), "%s/walk/b", work);
    write_file(file, "b", 1, 0644);
    beam_com_zip_walk(dir, count, NULL);
    /* Windows has no execute bit: a file is executable by its suffix. */
    CHECK(walked == (IsWindows() ? 0 : 1));
}

/* rm -rf, also for the files of mode 0500. */
static void remove_tree(const char *path)
{
    struct dirent *e;
    struct stat st;
    char sub[PATH_MAX];
    DIR *d;

    if (lstat(path, &st) != 0)
        return;
    if (S_ISDIR(st.st_mode) && (d = opendir(path))) {
        chmod(path, 0700);
        while ((e = readdir(d)))
            if (strcmp(e->d_name, ".") != 0 && strcmp(e->d_name, "..") != 0) {
                snprintf(sub, sizeof(sub), "%s/%s", path, e->d_name);
                remove_tree(sub);
            }
        closedir(d);
        rmdir(path);
    } else {
        chmod(path, 0700);
        unlink(path);
    }
}

int main(int argc, char *argv[])
{
    char work[64], msg[PATH_MAX + 256], out[PATH_MAX];
    const char *self = GetProgramExecutableName();

    if (argc == 3 && strcmp(argv[1], "--child") == 0) {
        printf("child %s\n", argv[2]);
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "--cache") == 0) {
        if (beam_com_zip_cache(argv[2], 1, out, sizeof(out), msg, sizeof(msg)) != 0) {
            fprintf(stderr, "zipexec_check: --cache: %s\n", msg);
            return 1;
        }
        return 0;
    }
    snprintf(work, sizeof(work), "zipexec_check.tmp.%d", (int)getpid());
    CHECK(mkdir(work, 0700) == 0);
    check_names();
    check_sha256();
    check_cache_dir();
    check_cache(self, work);
    check_programs(work);
    check_memfd(work);
    check_walk(work);
    check_zip(work);
    if (failures) {
        printf("zipexec_check: %d failures (the files are in %s)\n", failures, work);
        return 1;
    }
    remove_tree(work);
    printf("zipexec_check: ok\n");
    return 0;
}
