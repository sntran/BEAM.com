/*
 * erl_child_setup, linked into BEAM.com. The build script copies this
 * file into erts/emulator/sys/unix/ so it compiles with the ERTS flags.
 */
#define main erl_child_setup_main
#define sys_sigblock beam_com_cs_sys_sigblock
#define sys_sigrelease beam_com_cs_sys_sigrelease
#include "erl_child_setup.c"
