#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  printf("Hello from C, in WebAssembly.\n");
  for (int i = 1; i < argc; i++) printf("argument %d: %s\n", i, argv[i]);
  const char *who = getenv("WHO");
  if (who) printf("WHO=%s\n", who);
  fprintf(stderr, "a line on stderr\n");
  return argc > 2 ? 3 : 0;
}
