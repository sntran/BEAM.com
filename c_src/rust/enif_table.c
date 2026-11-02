/* dlsym() for the NIFs of Rustler, in a static beam.com.
 *
 * Rustler fills its table of the NIF functions with dlopen(NULL) and
 * dlsym("enif_..."). The objects of a Rust NIF call these beam_rs_dl*
 * functions in place of dlopen() and dlsym() (objcopy --redefine-sym):
 * they find the functions of ERTS in the table below.
 *
 * enif_names.h has one line X(NAME) for each function of the API, with
 * the #if lines: the build makes it from erl_nif_api_funcs.h of OTP. */
#include <stddef.h>
#include <string.h>
#include "erl_nif.h"

static const struct {
  const char *name;
  void *fn;
} enif_table[] = {
#define X(NAME) {#NAME, (void *)&NAME},
#include "enif_names.h"
#undef X
};

static char handle; /* the handle of the program: dlopen(NULL) */

void *beam_rs_dlopen(const char *path, int flags) {
  (void)flags;
  return path ? NULL : &handle;
}

void *beam_rs_dlsym(void *h, const char *name) {
  if (h != &handle) return NULL;
  for (size_t i = 0; i < sizeof(enif_table) / sizeof(enif_table[0]); i++)
    if (!strcmp(enif_table[i].name, name)) return enif_table[i].fn;
  return NULL;
}

char *beam_rs_dlerror(void) { return NULL; }

int beam_rs_dlclose(void *h) { return h == &handle ? 0 : -1; }
