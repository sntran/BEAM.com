# Sandbox: `--allow-read`, `--allow-write`, `--allow-net`, `--allow-run`

A program can give up what it does not need. The flags are the
permission flags of [Deno](https://docs.deno.com/runtime/fundamentals/security/),
and as with `deno compile`, they are stored in the program when you
build it:

```sh
beam.com server.erl --allow-net --allow-read=/etc/myapp --allow-write=/var/lib/myapp -o server.com
```

Without `--allow-*` flags, there is no sandbox: the program can do all
that its user can. With one or more of them, the program can do only
what they allow:

| Flag | Short | The program can |
|---|---|---|
| `--allow-read[=PATH,...]` | `-R` | read these files and directories (all, without a list) |
| `--allow-write[=PATH,...]` | `-W` | write and create these files and directories (all, without a list) |
| `--allow-net[=HOST,...]` | `-N` | use sockets and DNS, and read the files that they need (`/etc/hosts`, `/etc/resolv.conf`, the certificates of the OS); with a list, only for these hosts (see [A list of hosts](#a-list-of-hosts)) |
| `--allow-run[=PROGRAM,...]` | | start these programs as ports (all, without a list); a name without `/` is found in `PATH` |
| `--allow-all` | `-A` | do everything: no sandbox |

- The flags add up: `--allow-read=/a --allow-read=/b` allows both, and a
  flag without a list allows all.
- A directory includes all that is in it. A path that does not exist
  when the program starts is left out (the system can only allow paths
  that exist), so to create files, allow their directory:
  `--allow-write=/var/lib/myapp`, not `/var/lib/myapp/new.db`.
- A program always can read its own file (with the code), `/dev/null`
  and `/dev/urandom`, and the JIT keeps the directory of its code maps
  (`/dev/shm` on Linux, else `/tmp`).
- A program that runs other programs (`--allow-run=PROGRAM`) also gets
  the dynamic loader and the libraries (`/lib`, `/usr/lib`, ...). A
  shell script needs its shell too: `--allow-run=sh,./script.sh`.
  `--allow-run` without a list gives execute and read access to all
  files, so it is almost no sandbox (as in Deno).
- On Linux, `--allow-net` allows the options of a socket that
  `inet:setopts/2` and `inet:getopts/2` use, for example `sndbuf`,
  `recbuf`, `nodelay`, `keepalive`, `linger`, `reuseaddr` and
  `reuseport`, but not each option of the system. `inet:getopts/2`
  leaves out an option that the sandbox refuses, and `inet:setopts/2`
  can give `ok` for it.
- Not supported, because the sandbox cannot enforce them:
  `--allow-env`, `--allow-sys`, `--allow-ffi` and the `--deny-*` flags. A build
  (`beam.com INPUT -o OUTPUT`) stops with an error for them.

A forbidden action gives an error: reading or writing a hidden file
gives `{error, eacces}`, and a socket or a port without its flag
`{error, eperm}`. Without `--allow-run`, kernel uses its own DNS
client, because the native resolver is a port program.

| System | The sandbox |
|---|---|
| Linux | yes: seccomp (system calls) and Landlock (paths, Linux 5.13 and later) |
| OpenBSD | the paths only (`unveil()`: `--allow-read`, `--allow-write`, and the programs of `--allow-run`); sockets and ports are not limited, because OpenBSD stops ERTS under `pledge()` |
| Windows | in the process: the C library checks the paths and the sockets, and a job object stops new processes ([Windows](#windows)) |
| macOS arm64 | yes: a profile of Seatbelt ([macOS](#macos)) |
| macOS x86_64, FreeBSD, NetBSD | no: the flags are ignored |

## macOS

On macOS arm64, beam.com gives the rules to Seatbelt, the sandbox of
macOS, with `sandbox_init()` of libSystem
(`c_src/cosmo/beam_com_seatbelt.c`). The kernel applies the profile to
the process and to each program that it starts. The rules are the rules
of Linux:

- A read of the data of a file needs a path of `--allow-read` or
  `--allow-write`. The files of the system that start a process
  (`/System`, `/usr/lib`) can always be read. `stat()` needs no
  permission, as with Landlock.
- A change of a file needs a path of `--allow-write`.
- A new program needs a path of `--allow-run`. beam.com can always start
  its own file and its APE loader (the helper programs).
- Without `--allow-net`, each socket of the network is refused.
- A refused call gives `{error, eperm}`.

`BEAM_COM_VERBOSE=1` prints "the sandbox of macOS (Seatbelt) is on".

On macOS x86_64, a Cosmopolitan program cannot load libSystem, so the
flags have no effect there.

## Windows

Windows has no call that limits the paths of a process, so beam.com
checks the calls of the C library itself (`c_src/cosmo/beam_com_fs.c`):

- A read (`open()` for reading, `opendir()`, `readlink()`) needs a path
  of `--allow-read` or of `--allow-write`.
- A change (`open()` for writing, `mkdir()`, `rmdir()`, `unlink()`,
  `rename()`, `link()`, `symlink()`, `chmod()`, `chown()`, `truncate()`
  and the times) needs a path of `--allow-write`.
- `stat()` and `access()` need no permission, as with Landlock.
- A refused call gives `{error, eacces}`. A refused read of a path that
  does not exist gives `{error, enoent}`, as with Landlock.

The check uses the name of the path. beam.com makes the path absolute,
removes `.` and `..`, and ignores the case and the form of the drive
(`C:\x`, `c:/x` and `/C/x` are one path). The check refuses the names
that Windows reads in a different way: a part that ends with `.` or a
space (Windows reads `.. ` as `..`), a `:` after the drive (a stream of
a file), and a name that starts with `\\` (a share or a device). The
program can always read its own file, its zip (`/zip`), and the files
that beam.com writes at the start (the name servers and the
certificates of Windows).

Without `--allow-net`, a socket of IPv4 or IPv6 gives `{error, eacces}`.

Without `--allow-run`, the process is in a job object with a limit of
one process. Windows then refuses each new process, also for native
code. `BEAM_COM_VERBOSE=1` prints "a job object of one process".

`BEAM_COM_WINDOWS_SANDBOX=1` with `BEAM_COM_ALLOW` does the checks of
the paths and of the sockets on Linux too, for the tests.

## A list of hosts

`--allow-net=HOST,...` allows the network only for these hosts:

```sh
beam.com app.exs --allow-net='api.example.com,*.s3.amazonaws.com:443,db.internal:5432' -o app.com
```

| Entry | Allows |
|---|---|
| `NAME` | the name, on each port |
| `NAME:PORT` | the name, on this port |
| `*.DOMAIN` | each name under `DOMAIN` (`a.DOMAIN`, `a.b.DOMAIN`), but not `DOMAIN`; `DOMAIN` has two labels or more |
| `10.0.0.5`, `[::1]` | the address, on each port (an IPv6 address with a port is in brackets: `[::1]:8080`) |
| `ADDRESS:PORT` | the address, on this port, also for `gen_tcp:listen/2` (`0.0.0.0:4000` for all the addresses of the host) |

The list has 64 entries or fewer. The names are in lower case.

The kernel cannot filter by host, so beam.com does the check in the
process, with its own resolver of DNS:

1. Kernel asks only the resolver of beam.com, on `127.0.0.1`. The
   resolver sends a query to the name servers of the system only for a
   name of the list. Each other name gives `{error, nxdomain}`, and the
   query does not leave the process.
2. The resolver records each address of its answers, and of the names
   of their CNAME chains, for the entries that allow the name. The names
   of `/etc/hosts` count too.
3. Each `connect`, each UDP send, and each `bind` to a port other than 0
   needs one of these addresses, an address of the list, or the resolver
   itself, with an allowed port. Else the call gives `{error, eacces}`.

Thus kernel and the check get the same answer, also from a name server
that gives other addresses at each query. A program cannot ask another
name server: that address is not allowed.

On Linux 5.6 and later, a process of its own does the check of step 3,
in place of the C library, also for native code and for the programs of
`--allow-run`:

- At the start, beam.com forks. The parent is the supervisor, with the
  resolver and the addresses. The child is the program. `ps` shows two
  processes, and a signal to the parent (`SIGTERM`, `SIGHUP`, `SIGUSR1`,
  `SIGUSR2`) goes to the child. The parent ends with the status of the
  child.
- A seccomp filter of the program stops each `connect`, `bind`,
  `sendmsg`, `sendmmsg`, and `sendto` with an address. The supervisor
  copies the address and the data, checks the copy, and makes the call
  on a copy of the socket. Thus the program cannot change the address
  after the check. A call on a Unix socket goes on as usual.
- A program of `--allow-run` keeps the filter. When it asks a name
  server of the system over UDP, the supervisor first checks the name
  and records the answer. A name off the list gets `EACCES`, so it
  never goes to the name server. The program cannot use TCP to a name
  server.

The supervisor needs `pidfd_getfd()`, `process_vm_readv()`, and the
Yama setting `ptrace_scope` 0 or 1. Without them (an older kernel, a
container that refuses these calls), the C library does the check, as
on the other systems. `BEAM_COM_VERBOSE=1` tells which check is in use.

On Linux 6.7 and later, when each entry has a port, Landlock also allows
TCP `connect` and `bind` only for the ports of the list, in the kernel.

The list also works on Windows, macOS, FreeBSD and NetBSD, where the
other permissions have no effect or less effect, and on OpenBSD.

Limits of the list:

- Caution: without the supervisor, a program of `--allow-run` does not
  get the list. It can connect to each host, on the ports of Landlock
  only.
- With the supervisor, a program of `--allow-run` can send a query to a
  name server with `send()` on a connected socket (glibc does it for
  one question). The supervisor does not see that query, so it records
  no address, and the program cannot connect to the address of its
  answer. A query of two questions (`sendmmsg()`, as for IPv4 and IPv6
  together) works.
- A name of the list can send data to its name servers in the names of
  its queries, for example `secret.example.com` with `*.example.com`.
- Without the supervisor, native code that makes the system calls
  itself does not go through the check. The NIFs of beam.com use the C
  library.
- An address stays allowed for one hour after the TTL of its answer,
  because programs keep addresses for some time. An address that two
  names share is allowed for each of their entries.
- `BEAM_COM_VERBOSE=1` prints each name that the resolver refuses.
- With permissions from `BEAM_COM_ALLOW`, `BEAM_COM_DNS_UPSTREAM=IP:PORT`
  gives the name server of the resolver (for tests). A program with
  permissions in its file ignores it.

## Limits

The sandbox limits what a program can do, but it is not a complete
wall. Know these limits before you depend on it:

- Caution: on macOS x86_64, FreeBSD and NetBSD, the flags have no
  effect, and the program prints no warning. A program runs there with all the
  rights of its user.
- Caution: on Windows, only the calls of the C library get the check of
  the paths and of the sockets. Native code that calls Windows itself
  does not go through it. The check does not follow a link or a
  junction, so a link in an allowed directory can lead outside it.
- `--allow-write` also lets the program change the mode and the times
  of the other files of the user (`chmod`, `utime`). Landlock does not
  control these calls.
- `--allow-run` gives execute access to the directories of the
  libraries (`/lib`, `/usr/lib`, `/usr/libexec`, ...), and some
  programs are in these directories. On Linux, the programs that it
  starts keep the sandbox. On OpenBSD, the rules of `unveil()` do not
  apply after `exec`, so a program that it starts has no path limits.
- The paths of `--allow-run` come from `PATH` when the program starts,
  and the APE loader from `HOME` and `TMPDIR`. Give the programs as
  absolute paths, and do not put a writable directory in `PATH`.
- The JIT can write in `/dev/shm` on Linux, and in `/tmp` on the other
  systems, also without `--allow-write`.
- On macOS, `sandbox_init()` is a deprecated function of Apple. Apple
  can change the language of the profiles in a new macOS.

`BEAM_COM_ALLOW` gives permissions to a program that has none in its
file, to try a sandbox without a new build: the flags without
`--allow-`, separated by `;`, for example
`BEAM_COM_ALLOW='read=/etc;net' ./server.com`. A program with
permissions in its file (also `--allow-all`) ignores it, so the
environment cannot give a program more than its file allows.

The flags become Cosmopolitan's `pledge()` (system calls) and
`unveil()` (paths), which the program applies when it starts, before
ERTS starts its threads, so that they apply to all the threads of the
VM (on Linux, a rule applies to the thread that sets it and the threads
that it starts later). For the same reason there is no sandbox call for
Erlang code.
