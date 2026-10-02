# Blue-green upgrade of one beam.com file (a spike)

This spike replaces a running program with a new file of the same
program. No request fails, and the state of the program stays.
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
then tries three upgrades that the server must refuse:

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
   (`serve PORT HANDOFF`). It listens on the same port, with
   `SO_REUSEPORT`, but it does not accept yet.
3. **Hand off.** The old server closes its listener. It waits for its
   open requests, and writes its state to the file `HANDOFF` (a write
   and a rename). In this time, the new connections wait in the queue of
   the new listener.
4. **Take over.** The new server reads the state, calls its own
   `migrate/1`, and starts to accept. The old server stops.

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

Local, Linux x86_64 (4 CPUs), with the `beam.com` of CI:

- 13 runs of 3000 requests, one after the other, with an upgrade in the
  middle: no failed request. The counts stay in order, so no state was
  lost. The slowest request took 12 to 27 ms (the pause of step 3).
- A full run of `check.sh` takes about 6 seconds.
- The server refuses an upgrade to a version whose `migrate/1` refuses
  the state (`{unknown_state, ...}`), to a file that is not executable
  (`{cannot_start, eacces}`), and to a file that does not exist
  (`{cannot_start, enoent}`). After each refusal, the old version
  serves, and a later upgrade works.

## Limits

- **Unix only.** The new server starts with `nohup`, and `SO_REUSEPORT`
  of Windows is different. Windows is not done.
- **Linux.** When a listener with `SO_REUSEPORT` closes, Linux resets the
  connections in its accept queue. The acceptor of the old server keeps
  that queue short, and the runs had no failure, but the risk is not
  zero. Linux 5.14 and later can move these connections to the other
  listener (`sysctl net.ipv4.tcp_migrate_req=1`).
- **macOS and the BSDs** have other rules for `SO_REUSEPORT`. CI runs the
  check there as a probe, to get the result.
- **The state** is in one process here. A real program must collect the
  state of all its processes (for an ETS table, `ets:tab2list/1`), and
  must stop its writes during step 3.
- **Long connections** (WebSocket) do not move to the new server. They
  stay with the old server until they close, or they must open again.
- **No authentication.** `/upgrade` starts the file that a client names.
  The server listens only on the loopback address for this reason.

## Next steps

- The results of the probes on macOS and the BSDs.
- The state over the distribution, in place of a file.
- The same steps for a release with a supervision tree, with the
  `sys` calls of OTP to collect the state of each process.
