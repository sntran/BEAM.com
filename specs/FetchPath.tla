------------------------------ MODULE FetchPath ------------------------------
(*****************************************************************************)
(* HTTP of the VM through fetch() of the host, for a host that connect() of  *)
(* Cloudflare cannot reach (worker.js, tcpConnect, and wasm_host_fetch.erl). *)
(*                                                                           *)
(* An app (an Erlang process) connects to a host on port 443. connect() of   *)
(* the Worker fails for a host behind Cloudflare, and also for a host that   *)
(* is down: the error is the same. So the host resolves the name and         *)
(* compares the addresses with the ranges of Cloudflare (Classify). For a    *)
(* host of Cloudflare, it joins the socket of the app to a connection of the *)
(* TLS server of the VM (Fallback): the app sees an open connection. Else    *)
(* the app gets econnrefused (Refuse).                                       *)
(*                                                                           *)
(* The TLS server signs with a CA of the VM that the trust store of the VM   *)
(* holds. A VM that boots in the global scope (Boot = "global") has zero     *)
(* random bytes until the event "restored" of the host, which comes before   *)
(* the first request. At that event, the VM makes its CA again. With         *)
(* SyncReseed, the pump does it in the same step as the reseed, before the   *)
(* next event; else a message to another process does it later.             *)
(*                                                                           *)
(* The app sends one request on the connection, with a host name of its own  *)
(* (the Host header, or the SNI of TLS). The TLS server gives it to the host *)
(* (Call), and the host calls fetch() (Fetch) with the URL of UrlFrom: the   *)
(* host of the connect ("connect"), or the name of the request ("claimed").  *)
(* At the timeout, the server closes the connection; with Retry, it calls   *)
(* again first. With Guard, a snapshot waits for the sockets and the calls   *)
(* (busy() of worker.js). The model checks both kinds of boot.              *)
(*                                                                           *)
(* What TLC finds (FetchPath.cfg is the first line):                         *)
(*   SyncReseed, UrlFrom = "connect", Retry = FALSE, Guard: no error.        *)
(*   SyncReseed = FALSE: StrongCAAtHandshake fails. The request came after   *)
(*     "restored", and the handshake used the CA of the zero random bytes.   *)
(*   UrlFrom = "claimed": FetchIsConnectedHost fails. The app connected to a *)
(*     host of BEAM_CONNECT, and fetch() went to the name in its request.   *)
(*   Retry = TRUE: AtMostOnce fails. fetch() ran, the reply came late, and  *)
(*     the server called again: two requests to the host.                   *)
(*   Guard = FALSE: NoSnapshotInFlight fails. The snapshot copied a VM with  *)
(*     a call that only the host of this VM has.                            *)
(*****************************************************************************)
EXTENDS Naturals

CONSTANTS SyncReseed, UrlFrom, Retry, Guard

Kinds == {"cloudflare", "down", "up"}  \* the host that the app connects to
Names == {"connected", "other"}        \* the name in the request of the app

VARIABLES
    boot,      \* the boot of the VM: "global" (a snapshot) or "request"
    rng,       \* the random bytes of the VM: "zero" or "fresh"
    ca,        \* the CA of the TLS server: made with "weak" or "strong" bytes
    regen,     \* a new CA waits in the mailbox of another process
    restored,  \* the pump took the event "restored"
    target,    \* the host of the connect of the app ("none" before it)
    conn,      \* the connection of the app: none, connecting, refused, direct, fallback, closed
    handshake, \* the CA of the TLS handshake of the fallback ("none" before it)
    claimed,   \* the name in the request of the app
    app,       \* the request: none, sent, wait, ok, unknown
    calls,     \* the calls of the server to the host, in flight
    fetched,   \* the fetch() calls that ran, as the names of their URLs
    snapshot,  \* the host made a snapshot of the VM
    snapOpen   \* at the snapshot, a socket of the fallback or a call was open

vars == <<boot, rng, ca, regen, restored, target, conn, handshake, claimed, app, calls, fetched,
          snapshot, snapOpen>>

TypeOK ==
    /\ boot \in {"global", "request"}
    /\ rng \in {"zero", "fresh"}
    /\ ca \in {"weak", "strong"}
    /\ regen \in BOOLEAN
    /\ restored \in BOOLEAN
    /\ target \in Kinds \cup {"none"}
    /\ conn \in {"none", "connecting", "refused", "direct", "fallback", "closed"}
    /\ handshake \in {"none", "weak", "strong"}
    /\ claimed \in Names
    /\ app \in {"none", "sent", "wait", "ok", "unknown"}
    /\ calls \in 0..2
    /\ fetched \in 0..2
    /\ snapshot \in BOOLEAN
    /\ snapOpen \in BOOLEAN

\* The CA of init/1 of the server: from the random bytes at the boot.
Init ==
    /\ boot \in {"global", "request"}
    /\ rng = IF boot = "global" THEN "zero" ELSE "fresh"
    /\ ca = IF boot = "global" THEN "weak" ELSE "strong"
    /\ regen = FALSE
    /\ restored = (boot # "global")
    /\ target = "none"
    /\ conn = "none"
    /\ handshake = "none"
    /\ claimed \in Names
    /\ app = "none"
    /\ calls = 0
    /\ fetched = 0
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
    /\ UNCHANGED <<boot, target, conn, handshake, claimed, app, calls, fetched, snapshot, snapOpen>>

\* The other process makes the CA, at a moment of its own.
Regen ==
    /\ regen
    /\ regen' = FALSE
    /\ ca' = IF rng = "fresh" THEN "strong" ELSE "weak"
    /\ UNCHANGED <<boot, rng, restored, target, conn, handshake, claimed, app, calls, fetched, snapshot, snapOpen>>

\* A request of a client runs the app, after the event "restored": the
\* events of the request come after it. The app connects to a host.
Connect(k) ==
    /\ restored /\ conn = "none"
    /\ target' = k
    /\ conn' = "connecting"
    /\ UNCHANGED <<boot, rng, ca, regen, restored, handshake, claimed, app, calls, fetched, snapshot, snapOpen>>

\* connect() of the Worker: a host that is up opens; the others fail.
Open ==
    /\ conn = "connecting" /\ target = "up"
    /\ conn' = "direct"
    /\ UNCHANGED <<boot, rng, ca, regen, restored, target, handshake, claimed, app, calls, fetched, snapshot, snapOpen>>

\* The failure of connect(): the addresses of the name tell the two cases.
Refuse ==
    /\ conn = "connecting" /\ target = "down"
    /\ conn' = "refused"
    /\ UNCHANGED <<boot, rng, ca, regen, restored, target, handshake, claimed, app, calls, fetched, snapshot, snapOpen>>

Fallback ==
    /\ conn = "connecting" /\ target = "cloudflare"
    /\ conn' = "fallback"
    /\ UNCHANGED <<boot, rng, ca, regen, restored, target, handshake, claimed, app, calls, fetched, snapshot, snapOpen>>

\* The TLS handshake of the app with the server of the VM, then the request.
Handshake ==
    /\ conn = "fallback" /\ handshake = "none"
    /\ handshake' = ca
    /\ app' = "sent"
    /\ UNCHANGED <<boot, rng, ca, regen, restored, target, conn, claimed, calls, fetched, snapshot, snapOpen>>

\* The server gives the request to the host, and waits for the reply.
Call ==
    /\ conn = "fallback" /\ app = "sent"
    /\ app' = "wait"
    /\ calls' = calls + 1
    /\ UNCHANGED <<boot, rng, ca, regen, restored, target, conn, handshake, claimed, fetched, snapshot, snapOpen>>

\* The host calls fetch() with the URL of UrlFrom.
Fetch ==
    /\ calls > 0
    /\ calls' = calls - 1
    /\ fetched' = fetched + 1
    /\ UNCHANGED <<boot, rng, ca, regen, restored, target, conn, handshake, claimed, app, snapshot, snapOpen>>

FetchedName == IF UrlFrom = "connect" THEN "connected" ELSE claimed

\* The reply: the response goes to the app, and it can close the connection.
Reply ==
    /\ app = "wait" /\ fetched > 0 /\ calls = 0
    /\ app' = "ok"
    /\ conn' = "closed"
    /\ UNCHANGED <<boot, rng, ca, regen, restored, target, handshake, claimed, calls, fetched, snapshot, snapOpen>>

\* The timeout of the server: no reply yet (the call can still run).
Timeout ==
    /\ app = "wait"
    /\ IF Retry /\ fetched + calls < 2
         THEN app' = "sent" /\ UNCHANGED conn
         ELSE app' = "unknown" /\ conn' = "closed"
    /\ UNCHANGED <<boot, rng, ca, regen, restored, target, handshake, claimed, calls, fetched, snapshot, snapOpen>>

\* busy() of worker.js: a snapshot waits while a socket is open (the sockets
\* of the fallback are in tcps) or a fetch() runs.
Open1 == conn \in {"connecting", "direct", "fallback"} \/ calls > 0
Snapshot ==
    /\ ~snapshot
    /\ Guard => ~Open1
    /\ snapshot' = TRUE
    /\ snapOpen' = (conn = "fallback" \/ calls > 0)
    /\ UNCHANGED <<boot, rng, ca, regen, restored, target, conn, handshake, claimed, app, calls, fetched>>

Next ==
    \/ Restore \/ Regen
    \/ \E k \in Kinds : Connect(k)
    \/ Open \/ Refuse \/ Fallback
    \/ Handshake \/ Call \/ Fetch \/ Reply \/ Timeout
    \/ Snapshot

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* The properties.                                                           *)

\* The fallback is only for a host of Cloudflare: a host that is down gets
\* econnrefused, as before.
FallbackOnlyForCloudflare == conn = "fallback" => target = "cloudflare"
DownIsRefused == (target = "down" /\ conn # "connecting" /\ conn # "none") => conn = "refused"

\* The handshake never uses a CA of the zero random bytes.
StrongCAAtHandshake == handshake # "weak"

\* fetch() goes to the host of the connect (the one that BEAM_CONNECT
\* allowed), not to a name that the app wrote in its request.
FetchIsConnectedHost == fetched > 0 => FetchedName = "connected"

\* One request of the app: at most one fetch().
AtMostOnce == fetched + calls <= 1

\* No snapshot while a socket of the fallback is open, or a fetch() runs.
NoSnapshotInFlight == ~snapOpen
=============================================================================
