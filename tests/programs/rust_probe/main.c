#include <stdio.h>
int rs_probe(void);
int main(void) { int r = rs_probe(); printf("rs_probe: %d\n", r); return r; }
