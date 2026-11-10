/*
 * nif_needs OBJECT...: the names that each native NIF object needs and
 * that the program does not give it (docs/NIFS.md). It loads each object
 * of this CPU with the loader of c_src/cosmo/beam_com_nif.c, with no
 * constructors, and with the table of beam_com_nif_syms.c (the names
 * only, BEAM_COM_NIF_NAMES). Only the sections that the NIF uses count,
 * as at a load of the program. A weak name that is missing is no error.
 *
 * For each object, it writes "nif_needs: FILE: ok", or a line
 * "nif_needs: FILE: no NAME" for each missing name. It exits with 1 when
 * a name is missing or an object does not load. step_test of
 * scripts/steps.sh builds and checks it; CI runs it on the objects of the
 * NIF parts of the store before a program loads them.
 */
#define BEAM_COM_NIF_TEST
#include "../../c_src/cosmo/beam_com_nif.c"
#define BEAM_COM_NIF_NAMES
#include "../../c_src/cosmo/beam_com_nif_syms.c"

static const char *current;
static int missing;

/* The bytes of the file PATH: 1, else 0 (errno). */
static int read_file(const char *path, uint8_t **bytes, size_t *size)
{
    FILE *f = fopen(path, "rb");
    long n;
    if (!f)
        return 0;
    if (fseek(f, 0, SEEK_END) || (n = ftell(f)) < 0 || fseek(f, 0, SEEK_SET) ||
        !(*bytes = malloc(n ? (size_t)n : 1)) || fread(*bytes, 1, (size_t)n, f) != (size_t)n) {
        fclose(f);
        return 0;
    }
    fclose(f);
    *size = (size_t)n;
    return 1;
}

static void on_missing(const char *name)
{
    printf("nif_needs: %s: no %s\n", current, name);
    missing++;
}

int main(int argc, char **argv)
{
    int i, status = 0;

    if (argc < 2) {
        fprintf(stderr, "usage: nif_needs OBJECT...\n");
        return 2;
    }
    bcn_constructors = 0;
    bcn_missing = on_missing;
    for (i = 1; i < argc; i++) {
        uint8_t *bytes = NULL;
        size_t n = 0;
        char err[512];
        struct bcn_module *m;

        current = argv[i];
        missing = 0;
        if (!read_file(current, &bytes, &n)) {
            printf("nif_needs: %s: %s\n", current, strerror(errno));
            status = 1;
            continue;
        }
        m = bcn_load(bytes, n, beam_com_nif_lookup, err, sizeof(err));
        free(bytes);
        if (!m) {
            printf("nif_needs: %s: the load failed: %s\n", current, err);
            status = 1;
        } else if (missing) {
            status = 1;
        } else {
            printf("nif_needs: %s: ok\n", current);
        }
    }
    return status;
}
