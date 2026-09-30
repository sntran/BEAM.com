/*
 * epmd (the Erlang port mapper daemon), linked into BEAM.com: the
 * launcher starts "epmd -daemon" for -sname and -name, as erlexec does.
 * beam_com_epmd*.c compile the three files of epmd with the ERTS flags
 * (the build script copies them into erts/emulator/sys/unix/). Their
 * global names get a prefix, so that they cannot clash with the names of
 * the emulator, and EPMD_PORT_NO is the value of the epmd Makefile.
 */
#define EPMD_PORT_NO 4369
#define main epmd_main
#define run beam_com_epmd_run
#define dbg_perror beam_com_epmd_dbg_perror
#define dbg_printf beam_com_epmd_dbg_printf
#define dbg_tty_printf beam_com_epmd_dbg_tty_printf
#define epmd_call beam_com_epmd_call
#define epmd_cleanup_exit beam_com_epmd_cleanup_exit
#define epmd_conn_close beam_com_epmd_conn_close
#define kill_epmd beam_com_kill_epmd
#define stop_cli beam_com_epmd_stop_cli
