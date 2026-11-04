/*
 * The second file of the native NIF of native_nif_check.c: the build
 * joins the two objects with `ld -r`, as a NIF with more than one file.
 */
#include <stddef.h>

int util_calls;
static const char *const names[] = { "zero", "one", "two", "three" };

const char *util_name(int i)
{
    util_calls++;
    return i >= 0 && i < 4 ? names[i] : "many";
}

/* A table of function pointers in the data of an other object. */
static long op_add(long a, long b) { return a + b; }
static long op_sub(long a, long b) { return a - b; }
static long op_mul(long a, long b) { return a * b; }
long (*const util_ops[3])(long, long) = { op_add, op_sub, op_mul };
