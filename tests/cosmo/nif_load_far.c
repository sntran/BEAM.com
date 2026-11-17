/*
 * The test object of a module far from the program
 * (tests/cosmo/nif_load_check.c), for aarch64 only. The large code model
 * (-mcmodel=large) reads each address of the program from the module
 * (R_AARCH64_ABS64), so the object has no PC-relative reference to the
 * program. The calls of the program go through stubs.
 */
#include <errno.h>
#include <string.h>

/* The program (the check) gives these. */
extern int host_add(int a, int b);
extern int host_value;

static const char far_text[] = "far module";
static int far_count;

/* Calls, data and values of the program, and data of the module. */
int far_call(int x, int *einval)
{
    *einval = EINVAL;
    host_value += 1;
    far_count++;
    return host_add(x, host_value) + (int)strlen(far_text) * 1000 + far_count * 100000;
}
