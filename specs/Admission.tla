------------------------------ MODULE Admission ------------------------------
(*****************************************************************************)
(* The registry of the instances (admit/2 and sweep/0 of                      *)
(* priv/wasm_host/worker/durable.js). admit/2 has no await, so one call is   *)
(* one step of the Durable Object.                                           *)
(*                                                                           *)
(* A visitor has a ticket and an address. The registry gives the visitor    *)
(* its running instance, a new instance, a place in the queue, or a limit. *)
(* A visitor that did not ask again for Stale ticks left the queue. The    *)
(* rows of the instances past their time stay until a sweep.               *)
(*****************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Visitors,     \* the tickets
    Address,      \* Address[v]: the address of visitor v
    Max,          \* BEAM_INSTANCES
    PerAddress,   \* BEAM_INSTANCES_PER_IP
    TTL,          \* BEAM_INSTANCE_TTL, in ticks
    Budget,       \* BEAM_INSTANCE_HOURS of one day, in ticks
    Stale,        \* a visitor that did not ask for this time left the queue
    MaxTime

VARIABLES
    now,
    instances,    \* the rows: [t |-> ticket, a |-> address, exp |-> end]
    waiting,      \* the queue: [t, a, since, seen]
    used,         \* the time of the instances of the day
    overtaken     \* an admission took the place of an earlier visitor

vars == <<now, instances, waiting, used, overtaken>>

Live(t) == {i \in instances : i.exp > t}
Before(w, x) == w.since < x.since \/ (w.since = x.since /\ w.t < x.t)

Init ==
    /\ now = 0 /\ instances = {} /\ waiting = {} /\ used = 0
    /\ overtaken = FALSE

\* admit(ticket, address), as in durable.js, step by step.
Admit(v) ==
    LET a == Address[v]
        queue == {w \in waiting : w.seen >= now - Stale}   \* the late ones left
        live == Live(now)
        free == Max - Cardinality(live)
        old == {w \in queue : w.t = v}
        since == IF old = {} THEN now ELSE (CHOOSE w \in old : TRUE).since
        me == [t |-> v, a |-> a, since |-> since, seen |-> now]
        queue1 == {w \in queue : w.t /= v} \cup {me}
        position == Cardinality({w \in queue1 : Before(w, me)}) + 1
    IN
    /\ now < MaxTime
    /\ IF \E i \in live : i.t = v                                    \* running
       THEN waiting' = queue /\ UNCHANGED <<instances, used, overtaken>>
       ELSE IF Cardinality({i \in live : i.a = a}) >= PerAddress     \* limit: address
            THEN waiting' = queue /\ UNCHANGED <<instances, used, overtaken>>
       ELSE IF used + TTL > Budget                                   \* limit: day
            THEN waiting' = queue /\ UNCHANGED <<instances, used, overtaken>>
       ELSE IF Cardinality({w \in queue : w.a = a /\ w.t /= v}) >= PerAddress
            THEN waiting' = queue /\ UNCHANGED <<instances, used, overtaken>>
       ELSE IF position > free                                       \* a place in the queue
            THEN waiting' = queue1 /\ UNCHANGED <<instances, used, overtaken>>
       ELSE /\ instances' = instances \cup {[t |-> v, a |-> a, exp |-> now + TTL]}
            /\ waiting' = queue1 \ {me}
            /\ used' = used + TTL
            \* The visitors before this one in the queue still have places.
            /\ overtaken' = (overtaken \/ position - 1 > free - 1)
    /\ UNCHANGED now

Tick == now < MaxTime /\ now' = now + 1 /\ UNCHANGED <<instances, waiting, used, overtaken>>

\* sweep(): the rows of the instances past their time go.
Sweep ==
    /\ \E i \in instances : i.exp <= now
    /\ instances' = Live(now)
    /\ UNCHANGED <<now, waiting, used, overtaken>>

Next == Tick \/ Sweep \/ \E v \in Visitors : Admit(v)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
AtMostMax == Cardinality(Live(now)) <= Max

AtMostPerAddress == \A a \in {Address[v] : v \in Visitors} :
                      Cardinality({i \in Live(now) : i.a = a}) <= PerAddress

OneForEachTicket == \A i, j \in Live(now) : i.t = j.t => i = j

WithinBudget == used <= Budget

NoOvertake == ~overtaken

\* An address has at most PerAddress rows in the queue.
QueuePerAddress == \A a \in {Address[v] : v \in Visitors} :
                     Cardinality({w \in waiting : w.a = a}) <= PerAddress

\* The queue holds one row for each ticket.
QueueRows == \A w, x \in waiting : w.t = x.t => w = x
=============================================================================
