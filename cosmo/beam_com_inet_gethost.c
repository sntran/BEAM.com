/*
 * inet_gethost, linked into BEAM.com. The build script copies this
 * file into erts/emulator/sys/unix/ so it compiles with the ERTS flags.
 */
#define main inet_gethost_main
#define reap_children beam_com_ig_reap_children
#include "../../../etc/common/inet_gethost.c"
