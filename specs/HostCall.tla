------------------------------- MODULE HostCall -------------------------------
(*****************************************************************************)
(* A call of the VM to a binding of the Worker (a planned host call of       *)
(* wasm_host, as the "sql" and "wasm" calls of worker.js), for a binding     *)
(* with an effect that is not idempotent: send() of the email binding.       *)
(*                                                                           *)
(* A caller (an Erlang process) gets a request (Trigger), sends the call to  *)
(* the host with a new id (Call), and waits for the reply with that id. The  *)
(* host takes the call (Take) and the provider sends the email (Send) or     *)
(* refuses it (Reject). The reply can come after the timeout of the caller:  *)
(* then the VM drops it. At the timeout, a caller tries again (Retry) or     *)
(* gives the result "unknown".                                               *)
(*                                                                           *)
(* A snapshot of VM 1 (worker.js, makeSnapshot) makes VM 2: a copy of the    *)
(* state of the callers, with a new host that has no calls and no replies.   *)
(* Both VMs then run. Guard is the condition of the snapshot:                *)
(*   "none":     any moment;                                                 *)
(*   "inflight": no call at the host, no reply, no caller that waits (what   *)
(*               the host can see, as the sqlPending of worker.js);          *)
(*   "all":      also no caller between its request and its call.            *)
(*                                                                           *)
(* What TLC finds (HostCall.cfg is the first line):                          *)
(*   Retry = FALSE, Guard = "all": no error.                                 *)
(*   Retry = TRUE: AtMostOnce fails. The email went, the reply came after    *)
(*     the timeout, and the call ran again: two emails.                      *)
(*   Guard = "inflight": AtMostOnce fails. A request came to VM 1, the       *)
(*     snapshot copied the caller before its call, and each VM sent it.      *)
(*   Guard = "none": WaitHasCall fails. VM 2 waits for a call that only the  *)
(*     host of VM 1 has: it gets no reply, only its timeout.                 *)
(*****************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Callers, MaxTries, Retry, Guard

VMs == {1, 2}
States == {"idle", "start", "wait", "ok", "failed", "unknown"}
Ids == Callers \X (1..MaxTries)

VARIABLES
    pc,         \* pc[v][c]: the state of caller c in VM v
    tries,      \* tries[v][c]: the calls of c in VM v (the last id)
    live,       \* live[v]: VM v runs
    toHost,     \* toHost[v]: the ids of the calls that the host did not take
    inflight,   \* inflight[v]: the ids of the calls at the provider
    toVM,       \* toVM[v]: the replies [id, res] that VM v did not take
    sent,       \* sent[c]: the emails of c that the provider sent
    triggered,  \* triggered[c]: the request of c came (to one VM, one time)
    snapped     \* the snapshot was made

vars == <<pc, tries, live, toHost, inflight, toVM, sent, triggered, snapped>>

TypeOK ==
    /\ pc \in [VMs -> [Callers -> States]]
    /\ tries \in [VMs -> [Callers -> 0..MaxTries]]
    /\ live \in [VMs -> BOOLEAN]
    /\ toHost \in [VMs -> SUBSET Ids]
    /\ inflight \in [VMs -> SUBSET Ids]
    /\ toVM \in [VMs -> SUBSET [id : Ids, res : {"ok", "rejected"}]]
    /\ sent \in [Callers -> 0..(2 * MaxTries)]
    /\ triggered \in [Callers -> BOOLEAN]
    /\ snapped \in BOOLEAN

Init ==
    /\ pc = [v \in VMs |-> [c \in Callers |-> "idle"]]
    /\ tries = [v \in VMs |-> [c \in Callers |-> 0]]
    /\ live = [v \in VMs |-> v = 1]
    /\ toHost = [v \in VMs |-> {}]
    /\ inflight = [v \in VMs |-> {}]
    /\ toVM = [v \in VMs |-> {}]
    /\ sent = [c \in Callers |-> 0]
    /\ triggered = [c \in Callers |-> FALSE]
    /\ snapped = FALSE

SetPc(v, c, s) == pc' = [pc EXCEPT ![v][c] = s]

\* The request of c comes to one VM that runs.
Trigger(v, c) ==
    /\ live[v] /\ ~triggered[c] /\ pc[v][c] = "idle"
    /\ SetPc(v, c, "start")
    /\ triggered' = [triggered EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<tries, live, toHost, inflight, toVM, sent, snapped>>

\* wasm_host_server:send_host/2 with a new id; the caller waits.
Call(v, c) ==
    /\ live[v] /\ pc[v][c] = "start" /\ tries[v][c] < MaxTries
    /\ SetPc(v, c, "wait")
    /\ tries' = [tries EXCEPT ![v][c] = @ + 1]
    /\ toHost' = [toHost EXCEPT ![v] = @ \cup {<<c, tries[v][c] + 1>>}]
    /\ UNCHANGED <<live, inflight, toVM, sent, triggered, snapped>>

\* onsend of worker.js: the call of the binding starts.
Take(v, id) ==
    /\ live[v] /\ id \in toHost[v]
    /\ toHost' = [toHost EXCEPT ![v] = @ \ {id}]
    /\ inflight' = [inflight EXCEPT ![v] = @ \cup {id}]
    /\ UNCHANGED <<pc, tries, live, toVM, sent, triggered, snapped>>

\* The provider sends the email, and the host gives the reply to the VM.
Send(v, id) ==
    /\ live[v] /\ id \in inflight[v]
    /\ sent' = [sent EXCEPT ![id[1]] = @ + 1]
    /\ inflight' = [inflight EXCEPT ![v] = @ \ {id}]
    /\ toVM' = [toVM EXCEPT ![v] = @ \cup {[id |-> id, res |-> "ok"]}]
    /\ UNCHANGED <<pc, tries, live, toHost, triggered, snapped>>

\* The provider refuses the email (an unverified sender, for example).
Reject(v, id) ==
    /\ live[v] /\ id \in inflight[v]
    /\ inflight' = [inflight EXCEPT ![v] = @ \ {id}]
    /\ toVM' = [toVM EXCEPT ![v] = @ \cup {[id |-> id, res |-> "rejected"]}]
    /\ UNCHANGED <<pc, tries, live, toHost, sent, triggered, snapped>>

\* wasm_host_server routes the reply by its id; a late reply is dropped.
Deliver(v, r) ==
    LET c == r.id[1] IN
    /\ live[v] /\ r \in toVM[v]
    /\ toVM' = [toVM EXCEPT ![v] = @ \ {r}]
    /\ IF pc[v][c] = "wait" /\ r.id[2] = tries[v][c]
         THEN SetPc(v, c, IF r.res = "ok" THEN "ok" ELSE "failed")
         ELSE UNCHANGED pc
    /\ UNCHANGED <<tries, live, toHost, inflight, sent, triggered, snapped>>

\* The timeout of the receive: the caller does not know if the email went.
Timeout(v, c) ==
    /\ live[v] /\ pc[v][c] = "wait"
    /\ SetPc(v, c, IF Retry /\ tries[v][c] < MaxTries THEN "start" ELSE "unknown")
    /\ UNCHANGED <<tries, live, toHost, inflight, toVM, sent, triggered, snapped>>

Quiet(v) ==
    /\ toHost[v] = {} /\ inflight[v] = {} /\ toVM[v] = {}
    /\ \A c \in Callers : pc[v][c] # "wait"

GuardOK(v) ==
    CASE Guard = "none" -> TRUE
      [] Guard = "inflight" -> Quiet(v)
      [] Guard = "all" -> Quiet(v) /\ \A c \in Callers : pc[v][c] # "start"

\* The snapshot of VM 1 starts VM 2: the same callers, a new host.
Snapshot ==
    /\ ~snapped /\ GuardOK(1)
    /\ snapped' = TRUE
    /\ live' = [live EXCEPT ![2] = TRUE]
    /\ pc' = [pc EXCEPT ![2] = pc[1]]
    /\ tries' = [tries EXCEPT ![2] = tries[1]]
    /\ UNCHANGED <<toHost, inflight, toVM, sent, triggered>>

Next ==
    \/ Snapshot
    \/ \E v \in VMs, c \in Callers : Trigger(v, c) \/ Call(v, c) \/ Timeout(v, c)
    \/ \E v \in VMs, id \in Ids : Take(v, id) \/ Send(v, id) \/ Reject(v, id)
    \/ \E v \in VMs : \E r \in toVM[v] : Deliver(v, r)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* The properties.                                                           *)

\* An email of one request goes out at most one time.
AtMostOnce == \A c \in Callers : sent[c] <= 1

\* "ok" is true, and "failed" is true: then no email went.
OkMeansSent == \A v \in VMs, c \in Callers : pc[v][c] = "ok" => sent[c] >= 1
FailedMeansNotSent == \A v \in VMs, c \in Callers : pc[v][c] = "failed" => sent[c] = 0

\* A caller that waits has its call or its reply in its own VM, so the reply
\* can come before the timeout.
WaitHasCall ==
    \A v \in VMs, c \in Callers :
        pc[v][c] = "wait" =>
            LET id == <<c, tries[v][c]>> IN
            \/ id \in toHost[v] \/ id \in inflight[v]
            \/ \E r \in toVM[v] : r.id = id
=============================================================================
