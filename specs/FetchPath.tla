------------------------------ MODULE FetchPath ------------------------------
(*****************************************************************************)
(* HTTP of the VM through fetch() of the host (worker.js, tcpConnect, and    *)
(* wasm_host_fetch.erl).                                                     *)
(*                                                                           *)
(* An app (an Erlang process) connects to a host on port 80 (plain HTTP),    *)
(* port 443 (TLS), or another port (plain HTTP, TLS, or another protocol,    *)
(* "tcp"). The host chooses the route from the port, the rule of BEAM_FETCH  *)
(* for the host and the port, and the trust store (Route): it cannot see the *)
(* protocol. With no BEAM_FETCH ("default"), port 80 goes through fetch(),   *)
(* and port 443 too when the trust store of the VM holds the CA of the VM    *)
(* (trusted: the build had --cacerts). A rule with no port ("host": host,    *)
(* *.domain, or * ) gives the same ports. A rule that names the port         *)
(* ("port": host:8080) also gives another port. A person names another port  *)
(* only for HTTP, or for TLS in a build with --cacerts (Connect). The host   *)
(* joins the socket of the app to a connection of the server of the VM: the  *)
(* app sees an open connection. Each other connection uses connect().        *)
(*                                                                           *)
(* connect() of Cloudflare fails for a host behind Cloudflare, and also for  *)
(* a host that is down: the error is the same. So the host compares the      *)
(* addresses of the name with the ranges of Cloudflare. For HTTP or TLS to a *)
(* host of Cloudflare, it joins the socket to the server (Fallback). Else    *)
(* the app gets econnrefused (Refuse).                                       *)
(*                                                                           *)
(* The server signs with a CA of the VM. A VM that boots in the global scope *)
(* (Boot = "global") has zero random bytes until the event "restored" of the *)
(* host, which comes before the first request. At that event, the VM makes   *)
(* its CA again. With SyncReseed, the pump does it in the same step as the   *)
(* reseed, before the next event; else a message to another process does it *)
(* later.                                                                    *)
(*                                                                           *)
(* The app sends one request, with a host name of its own (the Host header,  *)
(* or the SNI of TLS). The server gives it to the host (Call), and the host  *)
(* calls fetch() (Fetch) with the URL of UrlFrom: the host of the connect    *)
(* ("connect"), or the name of the request ("claimed"). At the timeout, the  *)
(* server closes the connection; with Retry, it calls again first. An        *)
(* upgrade (WebSocket) does not go to fetch(): the server opens a tunnel,    *)
(* a connect() of its own to the host of the connect. With Direct, the host  *)
(* gives that connect() no route through fetch(). With Guard, a snapshot     *)
(* waits for the sockets and the calls (inFlight() of worker.js). The model  *)
(* checks both kinds of boot, each kind of rule, and both trust stores.      *)
(*                                                                           *)
(* What TLC finds (FetchPath.cfg is the first line):                         *)
(*   SyncReseed, UrlFrom = "connect", Retry = FALSE, CheckTrust, CheckPort,  *)
(*     Direct, Guard: no error.                                              *)
(*   SyncReseed = FALSE: StrongCAAtHandshake fails. The request came after   *)
(*     "restored", and the handshake used the CA of the zero random bytes.   *)
(*   UrlFrom = "claimed": FetchIsConnectedHost fails. The app connected to a *)
(*     host of BEAM_CONNECT, and fetch() went to the name in its request.   *)
(*   Retry = TRUE: AtMostOnce fails. fetch() ran, the reply came late, and  *)
(*     the server called again: two requests to the host.                   *)
(*   CheckTrust = FALSE: TlsOnlyWithTrust fails. A rule of BEAM_FETCH sent   *)
(*     port 443 to the server with no CA in the store ("*:443" with no       *)
(*     --cacerts), and the app cannot trust its certificate.                 *)
(*   CheckPort = FALSE: TcpNeverFetch fails (TLC finds TlsOnlyWithTrust      *)
(*     first). A rule with no port ("*") sent another port to the server: a  *)
(*     connection of a database, which the server cannot speak, or TLS with  *)
(*     no CA in the store.                                                   *)
(*   Direct = FALSE: NoLoop fails. The connect() of the tunnel came back to *)
(*     the server of the VM.                                                 *)
(*   Guard = FALSE: NoSnapshotInFlight fails. The snapshot copied a VM with  *)
(*     a call that only the host of this VM has.                            *)
(*****************************************************************************)
EXTENDS Naturals

CONSTANTS SyncReseed, UrlFrom, Retry, CheckTrust, CheckPort, Direct, Guard

Kinds == {"cloudflare", "down", "up"}  \* the host that the app connects to
Ports == {"http", "https", "other"}    \* port 80, port 443, another port
Protos == {"plain", "tls", "tcp"}      \* plain HTTP, TLS, another protocol
\* The rule of BEAM_FETCH for the host and the port of the connect: no
\* BEAM_FETCH, no rule (or an empty BEAM_FETCH), a rule with no port, a rule
\* that names the port.
Rules == {"default", "none", "host", "port"}
Names == {"connected", "other"}        \* the name in the request of the app

VARIABLES
    boot,      \* the boot of the VM: "global" (a snapshot) or "request"
    rule,      \* the rule of BEAM_FETCH for the connect (Rules)
    trusted,   \* the trust store of the VM holds the CA of the VM
    rng,       \* the random bytes of the VM: "zero" or "fresh"
    ca,        \* the CA of the server: made with "weak" or "strong" bytes
    regen,     \* a new CA waits in the mailbox of another process
    restored,  \* the pump took the event "restored"
    target,    \* the host of the connect of the app ("none" before it)
    port,      \* the port of the connect
    proto,     \* the protocol of the app on the connection
    conn,      \* the connection of the app: none, connecting, refused, direct, fetch, closed
    handshake, \* the CA of the TLS handshake with the server ("none" before it, "plain" with no TLS)
    claimed,   \* the name in the request of the app
    upgrade,   \* the request of the app is an upgrade (WebSocket)
    app,       \* the request: none, sent, wait, ok, error, unknown
    calls,     \* the calls of the server to the host, in flight
    fetched,   \* the fetch() calls that ran
    tunnel,    \* the tunnel of an upgrade: none, connecting, open, failed, loop
    snapshot,  \* the host made a snapshot of the VM
    snapOpen   \* at the snapshot, a socket of the server, a tunnel or a call was open

vars == <<boot, rule, trusted, rng, ca, regen, restored, target, port, proto, conn, handshake,
          claimed, upgrade, app, calls, fetched, tunnel, snapshot, snapOpen>>

TypeOK ==
    /\ boot \in {"global", "request"}
    /\ rule \in Rules
    /\ trusted \in BOOLEAN
    /\ rng \in {"zero", "fresh"}
    /\ ca \in {"weak", "strong"}
    /\ regen \in BOOLEAN
    /\ restored \in BOOLEAN
    /\ target \in Kinds \cup {"none"}
    /\ port \in Ports \cup {"none"}
    /\ proto \in Protos \cup {"none"}
    /\ conn \in {"none", "connecting", "refused", "direct", "fetch", "closed"}
    /\ handshake \in {"none", "plain", "weak", "strong"}
    /\ claimed \in Names
    /\ upgrade \in BOOLEAN
    /\ app \in {"none", "sent", "wait", "ok", "error", "unknown"}
    /\ calls \in 0..2
    /\ fetched \in 0..2
    /\ tunnel \in {"none", "connecting", "open", "failed", "loop"}
    /\ snapshot \in BOOLEAN
    /\ snapOpen \in BOOLEAN

\* The route of a connect to the port pt (fetchFirst of worker.js): through
\* fetch() first, or connect(). Port 443 needs the trust store; with
\* ~CheckTrust, a rule of BEAM_FETCH does not check it. Another port needs a
\* rule that names it; with ~CheckPort, a rule with no port also gives it.
RouteOf(pt) ==
    /\ rule # "none"
    /\ CASE pt = "http" -> TRUE
         [] pt = "https" -> trusted \/ (~CheckTrust /\ rule # "default")
         [] pt = "other" -> rule = "port" \/ (~CheckPort /\ rule = "host")
         [] OTHER -> FALSE
Route == RouteOf(port)

\* The CA of init/1 of the server: from the random bytes at the boot.
Init ==
    /\ boot \in {"global", "request"}
    /\ rule \in Rules
    /\ trusted \in BOOLEAN
    /\ rng = IF boot = "global" THEN "zero" ELSE "fresh"
    /\ ca = IF boot = "global" THEN "weak" ELSE "strong"
    /\ regen = FALSE
    /\ restored = (boot # "global")
    /\ target = "none"
    /\ port = "none"
    /\ proto = "none"
    /\ conn = "none"
    /\ handshake = "none"
    /\ claimed \in Names
    /\ upgrade \in BOOLEAN
    /\ app = "none"
    /\ calls = 0
    /\ fetched = 0
    /\ tunnel = "none"
    /\ snapshot = FALSE
    /\ snapOpen = FALSE

\* The event "restored" (the bytes of the first request): the pump reseeds
\* OpenSSL, and makes the CA again in the same step or in a message.
Restore ==
    /\ ~restored
    /\ restored' = TRUE
    /\ rng' = "fresh"
    /\ IF SyncReseed THEN ca' = "strong" /\ UNCHANGED regen
                     ELSE regen' = TRUE /\ UNCHANGED ca
    /\ UNCHANGED <<boot, rule, trusted, target, port, proto, conn, handshake, claimed, upgrade, app,
                   calls, fetched, tunnel, snapshot, snapOpen>>

\* The other process makes the CA, at a moment of its own.
Regen ==
    /\ regen
    /\ regen' = FALSE
    /\ ca' = IF rng = "fresh" THEN "strong" ELSE "weak"
    /\ UNCHANGED <<boot, rule, trusted, rng, restored, target, port, proto, conn, handshake,
                   claimed, upgrade, app, calls, fetched, tunnel, snapshot, snapOpen>>

\* A request of a client runs the app, after the event "restored": the
\* events of the request come after it. The app connects to a host, and the
\* host chooses the route. Port 80 is plain HTTP, and port 443 is TLS. A
\* rule names another port only for plain HTTP, or for TLS with the trust
\* store (docs/WORKERS.md asks this of the person who writes BEAM_FETCH).
Connect(k, pt, p) ==
    /\ restored /\ conn = "none"
    /\ pt = "http" => p = "plain"
    /\ pt = "https" => p = "tls"
    /\ (pt = "other" /\ rule = "port") => (p = "plain" \/ (p = "tls" /\ trusted))
    /\ target' = k
    /\ port' = pt
    /\ proto' = p
    /\ conn' = IF RouteOf(pt) THEN "fetch" ELSE "connecting"
    /\ UNCHANGED <<boot, rule, trusted, rng, ca, regen, restored, handshake, claimed, upgrade, app,
                   calls, fetched, tunnel, snapshot, snapOpen>>

\* connect() of the Worker: a host that is up opens; the others fail.
Open ==
    /\ conn = "connecting" /\ target = "up"
    /\ conn' = "direct"
    /\ UNCHANGED <<boot, rule, trusted, rng, ca, regen, restored, target, port, proto, handshake,
                   claimed, upgrade, app, calls, fetched, tunnel, snapshot, snapOpen>>

\* The failure of connect(): the addresses of the name tell the two cases.
\* The fallback is only for port 80 and port 443.
Refuse ==
    /\ conn = "connecting" /\ (target = "down" \/ (target = "cloudflare" /\ port = "other"))
    /\ conn' = "refused"
    /\ UNCHANGED <<boot, rule, trusted, rng, ca, regen, restored, target, port, proto, handshake,
                   claimed, upgrade, app, calls, fetched, tunnel, snapshot, snapOpen>>

Fallback ==
    /\ conn = "connecting" /\ target = "cloudflare" /\ port # "other"
    /\ conn' = "fetch"
    /\ UNCHANGED <<boot, rule, trusted, rng, ca, regen, restored, target, port, proto, handshake,
                   claimed, upgrade, app, calls, fetched, tunnel, snapshot, snapOpen>>

\* The TLS handshake of the app with the server (none for plain HTTP), then
\* the request.
Handshake ==
    /\ conn = "fetch" /\ handshake = "none"
    /\ handshake' = IF proto = "tls" THEN ca ELSE "plain"
    /\ app' = "sent"
    /\ UNCHANGED <<boot, rule, trusted, rng, ca, regen, restored, target, port, proto, conn,
                   claimed, upgrade, calls, fetched, tunnel, snapshot, snapOpen>>

\* The server gives the request to the host, and waits for the reply.
Call ==
    /\ conn = "fetch" /\ app = "sent" /\ ~upgrade
    /\ app' = "wait"
    /\ calls' = calls + 1
    /\ UNCHANGED <<boot, rule, trusted, rng, ca, regen, restored, target, port, proto, conn,
                   handshake, claimed, upgrade, fetched, tunnel, snapshot, snapOpen>>

\* The host calls fetch() with the URL of UrlFrom.
Fetch ==
    /\ calls > 0
    /\ calls' = calls - 1
    /\ fetched' = fetched + 1
    /\ UNCHANGED <<boot, rule, trusted, rng, ca, regen, restored, target, port, proto, conn,
                   handshake, claimed, upgrade, app, tunnel, snapshot, snapOpen>>

FetchedName == IF UrlFrom = "connect" THEN "connected" ELSE claimed

\* The reply: the response goes to the app, and it can close the connection.
Reply ==
    /\ app = "wait" /\ tunnel = "none" /\ fetched > 0 /\ calls = 0
    /\ app' = "ok"
    /\ conn' = "closed"
    /\ UNCHANGED <<boot, rule, trusted, rng, ca, regen, restored, target, port, proto, handshake,
                   claimed, upgrade, calls, fetched, tunnel, snapshot, snapOpen>>

\* The timeout of the server: no reply yet (the call can still run).
Timeout ==
    /\ app = "wait" /\ tunnel = "none"
    /\ IF Retry /\ fetched + calls < 2
         THEN app' = "sent" /\ UNCHANGED conn
         ELSE app' = "unknown" /\ conn' = "closed"
    /\ UNCHANGED <<boot, rule, trusted, rng, ca, regen, restored, target, port, proto, handshake,
                   claimed, upgrade, calls, fetched, tunnel, snapshot, snapOpen>>

\* An upgrade: the server connects to the host of the connect itself. With
\* Direct, the host uses connect() for it; else the route of Connect.
Tunnel ==
    /\ conn = "fetch" /\ app = "sent" /\ upgrade /\ tunnel = "none"
    /\ app' = "wait"
    /\ tunnel' = IF ~Direct /\ Route THEN "loop" ELSE "connecting"
    /\ UNCHANGED <<boot, rule, trusted, rng, ca, regen, restored, target, port, proto, conn,
                   handshake, claimed, upgrade, calls, fetched, snapshot, snapOpen>>

\* connect() of the tunnel: the bytes go both ways, or the app gets 502.
TunnelEnd ==
    /\ tunnel = "connecting"
    /\ IF target = "up" THEN tunnel' = "open" /\ app' = "ok"
                        ELSE tunnel' = "failed" /\ app' = "error"
    /\ UNCHANGED <<boot, rule, trusted, rng, ca, regen, restored, target, port, proto, conn,
                   handshake, claimed, upgrade, calls, fetched, snapshot, snapOpen>>

\* The tunnel or the app closes.
TunnelClose ==
    /\ tunnel \in {"open", "failed"} /\ conn = "fetch"
    /\ conn' = "closed"
    /\ UNCHANGED <<boot, rule, trusted, rng, ca, regen, restored, target, port, proto, handshake,
                   claimed, upgrade, app, calls, fetched, tunnel, snapshot, snapOpen>>

\* inFlight() of worker.js: a snapshot waits while a socket is open (the
\* sockets of the server and of a tunnel are in tcps) or a fetch() runs.
\* inFlight() also counts the SQL calls and the operations, modules and
\* instances of WasmHost, which this model does not have.
Busy == conn \in {"connecting", "direct", "fetch"} \/ calls > 0 \/ tunnel \in {"connecting", "open"}
Snapshot ==
    /\ ~snapshot
    /\ Guard => ~Busy
    /\ snapshot' = TRUE
    /\ snapOpen' = (conn = "fetch" \/ calls > 0 \/ tunnel \in {"connecting", "open"})
    /\ UNCHANGED <<boot, rule, trusted, rng, ca, regen, restored, target, port, proto, conn,
                   handshake, claimed, upgrade, app, calls, fetched, tunnel>>

Next ==
    \/ Restore \/ Regen
    \/ \E k \in Kinds, pt \in Ports, p \in Protos : Connect(k, pt, p)
    \/ Open \/ Refuse \/ Fallback
    \/ Handshake \/ Call \/ Fetch \/ Reply \/ Timeout
    \/ Tunnel \/ TunnelEnd \/ TunnelClose
    \/ Snapshot

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* The properties.                                                           *)

\* Another protocol than HTTP never goes to the server: only connect().
TcpNeverFetch == proto = "tcp" => conn # "fetch"

\* With fetch first, port 80, and another port that a rule names, never use
\* connect().
FetchFirst == rule # "none" /\ (port = "http" \/ (port = "other" /\ rule = "port"))
PlainFetchFirst == FetchFirst => conn \notin {"connecting", "direct", "refused"}

\* TLS goes to the server only when the app can trust its CA, or when
\* connect() cannot reach the host (a host of Cloudflare) anyway.
TlsOnlyWithTrust == (conn = "fetch" /\ proto = "tls") => (trusted \/ target = "cloudflare")

\* Off the route of fetch first, only a host of Cloudflare goes to the
\* server, and a host that is down gets econnrefused, as before.
FallbackOnlyForCloudflare == (conn = "fetch" /\ ~Route) => target = "cloudflare"
DownIsRefused ==
    (target = "down" /\ ~Route /\ conn \notin {"none", "connecting"}) => conn = "refused"

\* The handshake never uses a CA of the zero random bytes.
StrongCAAtHandshake == handshake # "weak"

\* fetch() goes to the host of the connect (the one that BEAM_CONNECT
\* allowed), not to a name that the app wrote in its request.
FetchIsConnectedHost == fetched > 0 => FetchedName = "connected"

\* One request of the app: at most one fetch(). An upgrade: none.
AtMostOnce == fetched + calls <= 1
UpgradeNeverFetches == upgrade => fetched + calls = 0

\* The connect() of a tunnel never comes back to the server.
NoLoop == tunnel # "loop"

\* No snapshot while a socket of the server or a tunnel is open, or a
\* fetch() runs.
NoSnapshotInFlight == ~snapOpen
=============================================================================
