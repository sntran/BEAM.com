/*
 * erl_child_setup, linked into BEAM.com. The build script copies this
 * file into erts/emulator/sys/unix/ so it compiles with the ERTS flags.
 */
#define main erl_child_setup_main
#define sys_sigblock beam_com_cs_sys_sigblock
#define sys_sigrelease beam_com_cs_sys_sigrelease
/* The shell of a port of {spawn, Command}: beam_com_execle() of
 * beam_com.c checks the shell as beam_com_execve() checks the program of
 * spawn_executable (the list of --allow-run on Linux without Landlock). */
#define execle beam_com_execle
int erl_child_setup_main(int argc, char **argv);
#include "erl_child_setup.c"
