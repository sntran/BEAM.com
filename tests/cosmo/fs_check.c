/*
 * The checks of c_src/cosmo/beam_com_fs.c, the sandbox of the paths of
 * Windows: the normal form of a path, the names that Windows reads in a
 * different way, and the rules. step_test of scripts/steps.sh compiles
 * it with cosmocc and runs it, also on Linux (fs_windows gives the rules
 * of Windows). The last line is "fs_check: ok".
 */
#define BEAM_COM_FS_TEST
#define __real_open open
#define __real_openat openat
#define __real_creat creat
#define __real_opendir opendir
#define __real_readlink readlink
#define __real_readlinkat readlinkat
#define __real_unlink unlink
#define __real_unlinkat unlinkat
#define __real_rmdir rmdir
#define __real_rename rename
#define __real_renameat renameat
#define __real_link link
#define __real_linkat linkat
#define __real_symlink symlink
#define __real_symlinkat symlinkat
#define __real_chmod chmod
#define __real_fchmodat fchmodat
#define __real_truncate truncate
#define __real_utimes utimes
#define __real_utimensat utimensat
#define __real_utime utime
#define __real_mkdirat mkdirat
#define __real_lchown lchown
#define __real_fchownat fchownat
#include "../../c_src/cosmo/beam_com_fs.c"

static int failures;

#define CHECK(cond)                                                          \
    do {                                                                     \
        if (!(cond)) {                                                       \
            fprintf(stderr, "fs_check: line %d: %s\n", __LINE__, #cond);     \
            failures++;                                                      \
        }                                                                    \
    } while (0)

static int norm_is(const char *path, const char *want)
{
    char out[FS_PATH];

    if (fs_norm(path, out))
        return want == NULL;
    if (want == NULL || strcmp(out, want) != 0) {
        fprintf(stderr, "fs_check: %s gives %s\n", path, out);
        return 0;
    }
    return 1;
}

static void reset(int windows)
{
    int i;

    for (i = 0; i < fs_nrules; i++)
        free(fs_rules[i].path);
    fs_nrules = fs_read_all = fs_write_all = fs_policy = fs_on = 0;
    fs_windows = windows;
}

static int allowed(const char *path, int write)
{
    errno = 0;
    if (beam_com_fs_check(path, write) == 0)
        return 1;
    /* A refused read of a path that does not exist gives ENOENT. */
    return errno == EACCES || (!write && errno == ENOENT) ? 0 : -1;
}

static void check_norm(void)
{
    char cwd[FS_PATH], want[FS_PATH + 8];

    reset(0);
    CHECK(norm_is("/", "/"));
    CHECK(norm_is("/a/b/c", "/a/b/c"));
    CHECK(norm_is("/a//b/./c/", "/a/b/c"));
    CHECK(norm_is("/a/b/../c", "/a/c"));
    CHECK(norm_is("/../../a", "/a"));
    CHECK(norm_is("/A/B", "/A/B"));
    CHECK(norm_is("/a/b. /c", "/a/b. /c"));
    CHECK(norm_is("", NULL));
    CHECK(norm_is(NULL, NULL));
    CHECK(getcwd(cwd, sizeof(cwd)) != NULL);
    snprintf(want, sizeof(want), "%s/x", strcmp(cwd, "/") ? cwd : "");
    CHECK(norm_is("x", want));
    CHECK(norm_is("./x/y/..", want));

    reset(1);
    CHECK(norm_is("C:\\Users\\Me", "/c/users/me"));
    CHECK(norm_is("c:/Users/Me/", "/c/users/me"));
    CHECK(norm_is("C:", "/c"));
    CHECK(norm_is("/C/Windows/../Temp", "/c/temp"));
    CHECK(norm_is("\\C\\Temp", "/c/temp"));
    /* The names that Windows reads in a different way. */
    CHECK(norm_is("C:\\work\\.. \\secret", NULL));
    CHECK(norm_is("C:\\work\\...\\secret", NULL));
    CHECK(norm_is("C:\\work\\file.", NULL));
    CHECK(norm_is("C:\\work\\file ", NULL));
    CHECK(norm_is("C:\\work\\file:stream", NULL));
    CHECK(norm_is("C:work", NULL));
    CHECK(norm_is("\\\\server\\share\\x", NULL));
    CHECK(norm_is("\\\\?\\C:\\x", NULL));
    CHECK(norm_is("//./pipe/x", NULL));
    CHECK(norm_is("C:\\work\\.\\..\\work\\x", "/c/work/x"));
}

static void check_rules(void)
{
    /* No policy: each call goes on. */
    reset(1);
    CHECK(allowed("C:\\secret", 1) == 1);
    beam_com_fs_allow("C:\\Work", 1);
    beam_com_fs_allow("C:\\Data\\", 0);
    beam_com_fs_policy();
    CHECK(allowed("C:\\secret", 1) == 1); /* not started */
    beam_com_fs_start();

    CHECK(allowed("C:\\work\\a.txt", 1) == 1);
    CHECK(allowed("c:/WORK/sub/a.txt", 0) == 1);
    CHECK(allowed("/C/Work", 1) == 1);
    CHECK(allowed("C:\\workshop\\a.txt", 0) == 0);
    CHECK(allowed("C:\\work\\..\\secret", 0) == 0);
    CHECK(allowed("C:\\data\\a.txt", 0) == 1);
    CHECK(allowed("C:\\data\\a.txt", 1) == 0);
    CHECK(allowed("C:\\data", 1) == 0);
    CHECK(allowed("C:\\secret", 0) == 0);
    CHECK(allowed("C:\\work\\.. \\secret", 0) == 0);
    CHECK(allowed("C:\\work\\a.txt:hidden", 1) == 0);
    CHECK(allowed("/dev/null", 1) == 1);
    CHECK(allowed("/zip/lib/kernel", 0) == 1);
    CHECK(allowed("/zip/lib/kernel", 1) == 0);
    CHECK(allowed(NULL, 0) == 0);
    /* A read of a path that does not exist: ENOENT. A write: EACCES. */
    CHECK(beam_com_fs_check("/no/such/file", 0) == -1 && errno == ENOENT);
    CHECK(beam_com_fs_check("/no/such/file", 1) == -1 && errno == EACCES);

    /* A path relative to a directory descriptor has no name. */
    CHECK(fs_check_at(AT_FDCWD, "C:\\work\\a", 1) == 0);
    CHECK(fs_check_at(3, "C:\\work\\a", 1) == 0);
    CHECK(fs_check_at(3, "a", 0) == -1 && errno == EACCES);

    /* Read of all, and write of all. */
    beam_com_fs_allow_all(0);
    CHECK(allowed("C:\\secret", 0) == 1);
    CHECK(allowed("C:\\secret", 1) == 0);
    beam_com_fs_allow_all(1);
    CHECK(allowed("C:\\secret", 1) == 1);

    /* A rule "/" (unveil("/", "r")) is each path. */
    reset(0);
    beam_com_fs_allow("/", 0);
    beam_com_fs_allow("/srv/out", 1);
    beam_com_fs_policy();
    beam_com_fs_start();
    CHECK(allowed("/etc/passwd", 0) == 1);
    CHECK(allowed("/etc/passwd", 1) == 0);
    CHECK(allowed("/srv/out/x", 1) == 1);
    CHECK(allowed("/srv/outside", 1) == 0);
    /* The name on Linux keeps its case. */
    CHECK(allowed("/SRV/out/x", 1) == 0);
}

/* The open flags that write. */
static void check_flags(void)
{
    CHECK(!fs_open_writes(O_RDONLY));
    CHECK(fs_open_writes(O_WRONLY));
    CHECK(fs_open_writes(O_RDWR));
    CHECK(fs_open_writes(O_RDONLY | O_CREAT));
    CHECK(fs_open_writes(O_RDONLY | O_TRUNC));
    CHECK(fs_open_writes(O_RDONLY | O_APPEND));
}

/* Random paths: fs_norm() never writes past its buffer, and a normal
 * form is a fixed point. */
static void check_random(void)
{
    static const char parts[] = "aZ./\\: .";
    char path[FS_PATH + 16], out[FS_PATH], again[FS_PATH];
    unsigned seed = 1;
    int i, k, len;

    for (i = 0; i < 20000; i++) {
        fs_windows = i & 1;
        seed = seed * 1103515245u + 12345u;
        len = (int)(seed >> 16) % (i % 100 ? 40 : FS_PATH + 8);
        for (k = 0; k < len; k++) {
            seed = seed * 1103515245u + 12345u;
            path[k] = parts[(seed >> 16) % (sizeof(parts) - 1)];
        }
        path[len] = '\0';
        if (fs_norm(path, out) == 0) {
            CHECK(out[0] == '/');
            CHECK(fs_norm(out, again) == 0 && strcmp(out, again) == 0);
        }
    }
}

int main(void)
{
    check_norm();
    check_rules();
    check_flags();
    check_random();
    reset(0);
    if (failures) {
        printf("fs_check: %d failures\n", failures);
        return 1;
    }
    printf("fs_check: ok\n");
    return 0;
}
