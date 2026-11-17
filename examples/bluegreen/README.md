# Blue-green upgrade of one beam.com file (a spike)

This spike replaces a running program with a new file of the same
program. The state of the program stays, and no request fails: the new
server gets the listening socket of the old server itself, so the
connections in the accept queue stay (see
[The handover of the socket](#the-handover-of-the-socket)).
[`bluegreen.erl`](bluegreen.erl) is a small HTTP server. It counts its
requests, and it is also its own load client.

```sh
beam.com examples/bluegreen/bluegreen.erl -o bluegreen.com
./bluegreen.com serve 8080 &               # version 1
./bluegreen.com wait 8080                  # "count 1 version 1 upgrades 0"
./bluegreen.com upgrade 8080 /path/v2.com  # "upgrade to version 2"
./bluegreen.com load 8080 3                # versions [2]
./bluegreen.com stop 8080
```

[`check.sh`](check.sh) does it all from end to end. It builds versions
1, 2 and 3, makes an upgrade from version 1 to version 2 under load, and
then tries three upgrades that the server must refuse. Its load is
`load PORT N 2`: after N requests, more requests follow until version 2
answers (at most 60 s more), so the switch is inside the load also on a
fast machine.

```sh
examples/bluegreen/check.sh build/beam.com
```

`tests/run.sh` runs it on Linux. On the other Unix systems, it runs it
as a probe: it shows the result, but a failure does not stop CI.

## The steps of an upgrade

1. **Check.** The server starts the new file as a peer node (the `peer`
   module of OTP, in erl mode), and calls `migrate/1` of the new code
   with its state. The server refuses the upgrade when the file does not
   start, or when `migrate/1` refuses the state. The server goes on, and
   the request gets the reason.
2. **Listen.** The new file starts as its own process
   (`serve PORT HANDOFF`). It connects to the Unix socket `HANDOFF.sock`
   of the old server, and gets the descriptor of the listening socket.
   It does not accept yet.
3. **Hand off.** The acceptor of the old server stops and closes its
   copy of the socket. The old server waits for its open requests, and writes its state to
   the file `HANDOFF` (a write and a rename). In this time, the new
   connections wait in the queue of the socket.
4. **Take over.** The new server reads the state, calls its own
   `migrate/1`, and starts to accept. The old server stops.

## The handover of the socket

The old server sends the descriptor of its listening socket over a Unix
socket, with `beam_com_fd:send/2`. The new server receives it with
`beam_com_fd:recv/2`, and opens a listener on it with
`gen_tcp:listen(0, [{fd, Fd} | Options])`: port 0, and no `ip` or
`ifaddr` option, because the socket is already bound. The two processes
then have one socket. When the old server closes its copy, the socket
stays open, and its queue stays. The new server accepts each connection
of that queue.

Only the acceptor closes the listener of the old server. When another
process closes it during an accept, the accept can get a connection
and then fail with `{error, einval}`: `prim_inet` reads the options of
the listener after the accept, and it closes the new connection. The
client gets a reset, and the acceptor stops. So the acceptor accepts
with a timeout of 100 ms, and looks for a stop message between two
accepts. One CI run on Linux x86_64 had this failure, and a test of
300 runs had it in 98 runs before the change and in 0 runs after.

`beam_com_fd` is a module of `beam.com` (`src/beam_com_reload/`), with a
static NIF (`c_src/fd/beam_com_fd.c`). The `socket` module of OTP can
send a descriptor (`SCM_RIGHTS`), but the build of OTP for `beam.com`
does not have it (`--disable-esock`), and `gen_tcp` cannot send one.

Before, the new server opened its own listener on the same port, with
`SO_REUSEPORT`. When the old listener closed, Linux reset the
connections in its queue: one run of 5000 requests had one
`econnreset`, and two CI runs on Linux aarch64 had one in 2000. Linux
5.14 and later can move these connections to the other listener
(`sysctl net.ipv4.tcp_migrate_req=1`), but that is a setting of the
host, not of the program.

## Why the peer node only does the check

A peer node cannot live after the node that started it. The peer node
stops (`erlang:halt/0`) when its control channel closes: the standard
I/O (end of input), the TCP connection, or the distribution (the
monitor of the origin). So the new version cannot be a peer node that
stays after the old one stops.

But a peer node is a good place for the check. It runs the new file with
the real state, in its own OS process, and the old server does not
change. A file that does not start, or a new state format that the new
code cannot read, never gets traffic.

## Results

These results are from the method with `SO_REUSEPORT`, before the
handover of the socket. Local, Linux x86_64 (4 CPUs), with the
`beam.com` of CI:

- 13 runs of 3000 requests, one after the other, with an upgrade in the
  middle: no failed request. The counts stay in order, so no state was
  lost. The slowest request took 12 to 27 ms (the pause of step 3).
- A full run of `check.sh` takes about 6 seconds.
- The server refuses an upgrade to a version whose `migrate/1` refuses
  the state (`{unknown_state, ...}`), to a file that is not executable
  (`{cannot_start, eacces}`), and to a file that does not exist
  (`{cannot_start, enoent}`). After each refusal, the old version
  serves, and a later upgrade works.
- One run of 5000 requests had one failed request: `econnreset`. This is
  the reset of the accept queue of Linux (see the limits). The counts
  stayed in order.
- 10 runs of 5000 requests in a network namespace (Linux 6.18), 5 with
  `net.ipv4.tcp_migrate_req=0` and 5 with `=1`: no failed request. The
  slowest request took 14 to 26 ms. A reset is rare, so these runs do not
  show the effect of `tcp_migrate_req`.

The probes of CI (2000 requests):

| System | Result | Versions | Slowest |
|---|---|---|---|
| macOS arm64 | 2000 ok, 0 failed | [1,2] | 33 ms |
| macOS x86_64 | 2000 ok, 0 failed | [1,2] | 22 ms |
| OpenBSD 7.3 | 2000 ok, 0 failed | [1,2] | 45 ms |
| FreeBSD | 2000 ok, 0 failed | [1] | |
| NetBSD | did not run | | |

On FreeBSD, the load stopped before the switch. On NetBSD, `sh` cannot
start an APE file, and the run with the APE loader did not run the probe. The probes now run 5000
requests, and `sh` starts `check.sh` with `RUNNER` for each APE file.

## Limits

- **Unix only.** The new server starts with `nohup`, and
  `beam_com_fd` gives `{error, enotsup}` on Windows. Windows is not done.
- **The path of the Unix socket** is `HANDOFF.sock`, next to the new
  file. A Unix socket path has at most 104 bytes on macOS and the BSDs,
  and 108 bytes on Linux. With a longer path, the server refuses the
  upgrade.
- **macOS and the BSDs**: CI runs the check there as a probe, to get the
  result.
- **The state** is in one process here. A real program must collect the
  state of all its processes (for an ETS table, `ets:tab2list/1`), and
  must stop its writes during step 3.
- **Long connections** (WebSocket) do not move to the new server. They
  stay with the old server until they close, or they must open again.
- **No authentication.** `/upgrade` starts the file that a client names.
  The server listens only on the loopback address for this reason.

## Next steps

- The probes on FreeBSD and NetBSD, with the longer load.
- The state over the distribution, in place of a file.
- The same steps for a release with a supervision tree, with the
  `sys` calls of OTP to collect the state of each process.
