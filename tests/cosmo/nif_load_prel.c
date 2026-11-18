/*
 * The test object of the range of PREL32 (tests/cosmo/nif_load_check.c),
 * for aarch64 only. Its one reference to the program is a PREL32 in the
 * data, with a range of 2 GB, not the 4 GB of ADRP. The large code model
 * (-mcmodel=large) reads each other address from the module.
 */
extern int host_value;

/* The offset from prel_ref to host_value. */
__asm__(".section .rodata.prel_ref,\"a\"\n"
        ".p2align 2\n"
        ".globl prel_ref\n"
        "prel_ref:\n"
        ".word host_value - .\n"
        ".text\n");
extern const int prel_ref;

/* The value of host_value, through the offset. */
int prel_value(void)
{
    return *(const int *)((const char *)&prel_ref + prel_ref);
}
