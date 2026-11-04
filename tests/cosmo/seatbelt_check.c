/*
 * The checks of c_src/cosmo/beam_com_seatbelt.c that need no macOS: the
 * profile of Seatbelt for the rules, the real paths, and the strings of
 * SBPL. step_test of scripts/steps.sh compiles it with cosmocc and runs
 * it. The last line is "seatbelt_check: ok".
 */
#define BEAM_COM_SEATBELT_TEST
#include "../../c_src/cosmo/beam_com_seatbelt.c"

static int failures;

#define CHECK(cond)                                                          \
    do {                                                                     \
        if (!(cond)) {                                                       \
            fprintf(stderr, "seatbelt_check: line %d: %s\n", __LINE__, #cond); \
            failures++;                                                      \
        }                                                                    \
    } while (0)

static void reset(void)
{
    int i;

    for (i = 0; i < sb_nrules; i++)
        free(sb_rules[i].path);
    sb_nrules = sb_net = sb_full = 0;
}

static int has(const char *profile, const char *text)
{
    if (strstr(profile, text))
        return 1;
    fprintf(stderr, "seatbelt_check: no \"%s\" in:\n%s", text, profile);
    return 0;
}

/* The position of text in profile, or -1. */
static long at(const char *profile, const char *text)
{
    const char *p = strstr(profile, text);
    return p ? p - profile : -1;
}

int main(void)
{
    const char *p;
    char real_tmp[PATH_MAX], want[PATH_MAX + 64];
    int i;

    /* No rule, no net: the base refusals. */
    reset();
    p = beam_com_seatbelt_profile();
    CHECK(has(p, "(version 1)\n(allow default)\n"));
    CHECK(has(p, "(deny file-read-data (subpath \"/\"))"));
    CHECK(has(p, "(deny file-write* (subpath \"/\"))"));
    CHECK(has(p, "(deny process-exec* (subpath \"/\"))"));
    CHECK(has(p, "(deny network* (local ip \"*:*\") (remote ip \"*:*\")"));
    CHECK(has(p, "(remote unix-socket))"));
    CHECK(has(p, "(deny mach-lookup (global-name \"com.apple.dnssd.service\"))"));
    CHECK(!strstr(p, "(allow file-read-data (subpath \"/etc"));

    /* The rules: each one after the refusal of its operation. */
    reset();
    beam_com_seatbelt_allow("/etc", "r");
    beam_com_seatbelt_allow("/tmp", "rwc");
    beam_com_seatbelt_allow("/bin/sh", "rx");
    beam_com_seatbelt_net(1);
    p = beam_com_seatbelt_profile();
    CHECK(realpath("/tmp", real_tmp) != NULL);
    CHECK(has(p, "(allow file-read-data (subpath \"/etc\"))"));
    snprintf(want, sizeof(want), "(allow file-write* (subpath \"%s\"))", real_tmp);
    CHECK(has(p, want));
    snprintf(want, sizeof(want), "(allow file-read-data (subpath \"%s\"))", real_tmp);
    CHECK(has(p, want));
    CHECK(!strstr(p, "(allow file-write* (subpath \"/etc\"))"));
    CHECK(strstr(p, "(allow process-exec* (subpath \"/") != NULL);
    CHECK(!strstr(p, "(deny network*"));
    CHECK(!strstr(p, "dnssd"));
    CHECK(at(p, "(deny file-read-data (subpath \"/\"))") <
          at(p, "(allow file-read-data (subpath \"/etc\"))"));
    CHECK(at(p, "(deny file-write* (subpath \"/\"))") < at(p, want) ||
          at(p, "(deny file-write* (subpath \"/\"))") <
              at(p, "(allow file-write* (subpath \""));
    CHECK(at(p, "(deny process-exec* (subpath \"/\"))") <
          at(p, "(allow process-exec* (subpath \""));

    /* A file that does not exist yet: the real path of its directory. A
     * directory that does not exist: no rule. */
    reset();
    beam_com_seatbelt_allow("/tmp/beam_com_no_such_file", "rwc");
    beam_com_seatbelt_allow("/no/such/dir/file", "rwc");
    CHECK(sb_nrules == 1);
    snprintf(want, sizeof(want), "%s/beam_com_no_such_file", real_tmp);
    CHECK(sb_nrules == 1 && strcmp(sb_rules[0].path, want) == 0);

    /* "x" alone: read and execute, no change. */
    reset();
    beam_com_seatbelt_allow("/", "x");
    CHECK(sb_rules[0].read && sb_rules[0].exec && !sb_rules[0].write);

    /* A quote and a backslash: escaped. A control character: the profile
     * refuses all. */
    reset();
    beam_com_seatbelt_allow("/tmp/a\"b\\c", "r");
    p = beam_com_seatbelt_profile();
    snprintf(want, sizeof(want), "(subpath \"%s/a\\\"b\\\\c\")", real_tmp);
    CHECK(has(p, want));
    reset();
    beam_com_seatbelt_allow("/tmp/a\nb", "r");
    CHECK(strcmp(beam_com_seatbelt_profile(), "(version 1)\n(deny default)\n") == 0);

    /* The parts that BEAM_COM_SEATBELT_OMIT leaves out. */
    reset();
    beam_com_seatbelt_omit("read,exec");
    p = beam_com_seatbelt_profile();
    CHECK(!strstr(p, "file-read-data"));
    CHECK(!strstr(p, "process-exec"));
    CHECK(has(p, "(deny file-write* (subpath \"/\"))"));
    CHECK(has(p, "(deny network*"));
    beam_com_seatbelt_omit("");

    /* Too many rules: the profile refuses all. */
    reset();
    for (i = 0; i <= SB_RULES; i++)
        beam_com_seatbelt_allow("/etc", "r");
    CHECK(sb_full);
    CHECK(strcmp(beam_com_seatbelt_profile(), "(version 1)\n(deny default)\n") == 0);
    reset();

    /* The digest of BEAM_COM_SEATBELT: 16 hexadecimal digits, the same
     * for the same profile, and another for another profile. */
    {
        char one[17], two[17];

        beam_com_seatbelt_allow("/etc", "r");
        snprintf(one, sizeof(one), "%s", beam_com_seatbelt_digest(beam_com_seatbelt_profile()));
        snprintf(two, sizeof(two), "%s", beam_com_seatbelt_digest(beam_com_seatbelt_profile()));
        CHECK(strlen(one) == 16 && strspn(one, "0123456789abcdef") == 16);
        CHECK(strcmp(one, two) == 0);
        beam_com_seatbelt_allow("/srv", "r");
        snprintf(two, sizeof(two), "%s", beam_com_seatbelt_digest(beam_com_seatbelt_profile()));
        CHECK(strcmp(one, two) != 0);
        CHECK(strcmp(beam_com_seatbelt_digest(""), "cbf29ce484222325") == 0);
        reset();

        /* The identity has the real path of the program file. */
        beam_com_seatbelt_identity("/tmp/../tmp\nread=/etc;run=true;");
        CHECK(sb_identity && strstr(sb_identity, "\nread=/etc;run=true;"));
        CHECK(sb_identity && strstr(sb_identity, "/../") == NULL);
        snprintf(one, sizeof(one), "%s", beam_com_seatbelt_digest(sb_identity));
        beam_com_seatbelt_identity("/tmp\nread=/etc;run=true;");
        CHECK(strcmp(one, beam_com_seatbelt_digest(sb_identity)) == 0);
        beam_com_seatbelt_identity("/tmp\nread=/etc;");
        CHECK(strcmp(one, beam_com_seatbelt_digest(sb_identity)) != 0);
    }

    if (failures) {
        printf("seatbelt_check: %d failures\n", failures);
        return 1;
    }
    printf("seatbelt_check: ok\n");
    return 0;
}
