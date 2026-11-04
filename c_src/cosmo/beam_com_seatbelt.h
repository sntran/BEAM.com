/*
 * The sandbox of macOS (Seatbelt): see c_src/cosmo/beam_com_seatbelt.c.
 */
#ifndef BEAM_COM_SEATBELT_H
#define BEAM_COM_SEATBELT_H

/* A path of unveil() with its permissions ("r", "rwc", "rx", ...). */
void beam_com_seatbelt_allow(const char *path, const char *permissions);

/* 1: --allow-net (all hosts, or a list of hosts). */
void beam_com_seatbelt_net(int allowed);

/* Leave parts of the profile out: "read", "write", "exec" and "net" in
 * parts. Only for tests (BEAM_COM_SEATBELT_OMIT with BEAM_COM_ALLOW). */
void beam_com_seatbelt_omit(const char *parts);

/* The profile in SBPL of the rules so far. */
const char *beam_com_seatbelt_profile(void);

/* The digest of a text: 16 hexadecimal digits. */
const char *beam_com_seatbelt_digest(const char *text);

/* The program file and its permissions, for the digest of
 * BEAM_COM_SEATBELT. The real path of the file goes in the digest. */
void beam_com_seatbelt_identity(const char *text);

/* Apply the profile with sandbox_init() (macOS arm64 only). Gives NULL,
 * or the reason of the failure. A process with the program file and the
 * permissions of its parent (BEAM_COM_SEATBELT) keeps the profile of the
 * parent, and also gives NULL. */
const char *beam_com_seatbelt_apply(void);

#endif
