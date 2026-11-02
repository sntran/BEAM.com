/*
 * The sandbox of the network with a list of hosts (--allow-net=HOST,...):
 * see c_src/cosmo/beam_com_net.c.
 */
#ifndef BEAM_COM_NET_H
#define BEAM_COM_NET_H

#include <stddef.h>

/* The most entries in the list. */
#define BEAM_COM_NET_RULES 64

/* Add one entry of the list: "HOST", "HOST:PORT", "*.DOMAIN",
 * "*.DOMAIN:PORT", an IPv4 address, or an IPv6 address in brackets, each
 * with an optional port. Gives 0, or -1 with the reason in error. */
int beam_com_net_rule(const char *text, char *error, size_t size);

/* Before the sandbox: the name servers, the hosts file, the sockets of
 * the resolver, and on Linux the TCP ports in Landlock. from_env: the
 * permissions come from BEAM_COM_ALLOW, so BEAM_COM_DNS_UPSTREAM can
 * give the name server. Gives NULL, or the step that failed (errno has
 * the reason). */
const char *beam_com_net_prepare(int from_env);

/* After the sandbox: start the resolver, and give its address to kernel
 * in BEAM_COM_DNS. Gives NULL, or the step that failed. */
const char *beam_com_net_start(void);

#endif
