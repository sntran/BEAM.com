/*
 * The second part of the test object of tests/cosmo/nif_load_check.c
 * (see nif_load_obj_a.c).
 */
int b_counter = 5;

int b_twice(int x)
{
    return 2 * x;
}

const char *b_name(void)
{
    return "part b";
}

/* The one entry name of the object of part b (bcn_nif_init). */
int b_nif_init(void)
{
    return 2;
}
