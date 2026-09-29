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
| `--allow-net` | `-N` | use sockets and DNS, and read the files that they need (`/etc/hosts`, `/etc/resolv.conf`, the certificates of the OS) |
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
- Not supported, because the sandbox cannot enforce them:
  `--allow-net=HOST` (no filter by host), `--allow-env`,
  `--allow-sys`, `--allow-ffi` and the `--deny-*` flags. A build
  (`beam.com INPUT -o OUTPUT`) stops with an error for them.

A forbidden action gives an error: reading or writing a hidden file
gives `{error, eacces}`, and a socket or a port without its flag
`{error, eperm}`. Without `--allow-run`, kernel uses its own DNS
client, because the native resolver is a port program.

| System | The sandbox |
|---|---|
| Linux | yes: seccomp (system calls) and Landlock (paths, Linux 5.13 and later) |
| OpenBSD | the paths only (`unveil()`: `--allow-read`, `--allow-write`, and the programs of `--allow-run`); sockets and ports are not limited, because OpenBSD stops ERTS under `pledge()` |
| macOS, Windows, FreeBSD, NetBSD | no: the flags are ignored |

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
