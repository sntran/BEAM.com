----------------------------- MODULE GreenThreads -----------------------------
(*****************************************************************************)
(* The green threads of the WebAssembly runtime: the mutex and the condition *)
(* variable of c_src/erts_wasm/jspi_pthread.c, on the suspend and the resume *)
(* of wasm/erts/jspi_lib.js.                                                 *)
(*                                                                           *)
(* One thread runs at a time. A thread runs until it suspends. The host     *)
(* runs microtasks in order: a resume (w), or the continuation of a thread  *)
(* (cont). A timer is a macrotask. With Batch, the host runs the callbacks  *)
(* of all the due timers in one task, as runJobs of worker.js does.         *)
(*                                                                           *)
(* Each thread takes the mutex K times. With the mutex, it signals the      *)
(* condition, waits on it (with or without a timeout), or does nothing.     *)
(*                                                                           *)
(* Fix selects the code of the threads and of the host: FALSE is the code   *)
(* before the fix, TRUE is the code after it.                               *)
(*****************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Threads, K, Batch, Fix

NOOP == 99   \* Fix: the resume of a thread whose timer fired does nothing

VARIABLES
    pc, ops, owner, mq, cq, woken, rval,
    running, js, waiters, timer, epoch, resolved, early

vars == <<pc, ops, owner, mq, cq, woken, rval,
          running, js, waiters, timer, epoch, resolved, early>>

None == "none"

Remove(s, t) == SelectSeq(s, LAMBDA x : x /= t)

Init ==
    /\ pc = [t \in Threads |-> "idle"]
    /\ ops = [t \in Threads |-> 0]
    /\ owner = None
    /\ mq = <<>> /\ cq = <<>>
    /\ woken = [t \in Threads |-> FALSE]
    /\ rval = [t \in Threads |-> 0]
    /\ running = None
    \* Each thread starts as a microtask (its entry).
    /\ js \in {s \in [1..Cardinality(Threads) -> {[k |-> "cont", t |-> t, v |-> 0] : t \in Threads}] :
               \A t \in Threads : \E i \in DOMAIN s : s[i].t = t}
    /\ waiters = [t \in Threads |-> 0]
    /\ timer = [t \in Threads |-> 0]
    /\ epoch = [t \in Threads |-> 0]
    /\ resolved = [t \in Threads |-> 0]
    /\ early = {}

-----------------------------------------------------------------------------
\* The host side, as operators on the state of the host:
\* h = [js, waiters, timer, epoch, early].

\* jspi_resume(u).
Resume(h, u) ==
    IF ~Fix THEN
        IF h.waiters[u] /= 0
        THEN [h EXCEPT !.js = Append(@, [k |-> "w", t |-> u, v |-> h.waiters[u]])]
        ELSE [h EXCEPT !.early = @ \cup {u}]
    ELSE
        \* The fix: a resume puts NOOP in place of the waiter.
        IF h.waiters[u] = NOOP THEN h
        ELSE IF h.waiters[u] /= 0
        THEN [h EXCEPT !.js = Append(@, [k |-> "w", t |-> u, v |-> h.waiters[u]]),
                       !.waiters[u] = NOOP]
        ELSE [h EXCEPT !.early = @ \cup {u}]

\* jspi_suspend(t, ms): a resume that came first resolves it at once.
Suspend(h, t, timed) ==
    IF t \in h.early
    THEN [h EXCEPT !.early = @ \ {t}, !.js = Append(@, [k |-> "cont", t |-> t, v |-> 1])]
    ELSE LET e == h.epoch[t] + 1 IN
         [h EXCEPT !.epoch[t] = e, !.waiters[t] = e, !.timer[t] = IF timed THEN e ELSE 0]

\* wake(u) of jspi_pthread.c: woken = 1, then jspi_resume(u).
Host == [js |-> js, waiters |-> waiters, timer |-> timer, epoch |-> epoch, early |-> early]

SetHost(h) ==
    /\ js' = h.js /\ waiters' = h.waiters /\ timer' = h.timer
    /\ epoch' = h.epoch /\ early' = h.early

-----------------------------------------------------------------------------
\* The threads. Only the running thread acts.

Idle(t) ==
    /\ running = t /\ pc[t] = "idle"
    /\ IF ops[t] < K
       THEN pc' = [pc EXCEPT ![t] = "lock"] /\ UNCHANGED running
       ELSE pc' = [pc EXCEPT ![t] = "done"] /\ running' = None
    /\ UNCHANGED <<ops, owner, mq, cq, woken, rval, js, waiters, timer, epoch, resolved, early>>

\* pthread_mutex_lock: take the mutex, or wait in its queue.
Lock(t) ==
    /\ running = t /\ pc[t] \in {"lock", "relock"}
    /\ IF owner = None
       THEN /\ owner' = t
            /\ pc' = [pc EXCEPT ![t] = IF pc[t] = "lock" THEN "crit" ELSE "unlock"]
            /\ UNCHANGED <<mq, running, js, waiters, timer, epoch, early>>
       ELSE /\ mq' = Append(mq, t)
            /\ pc' = [pc EXCEPT ![t] = IF pc[t] = "lock" THEN "lockwait" ELSE "relockwait"]
            /\ running' = None
            /\ SetHost(Suspend(Host, t, FALSE))
            /\ UNCHANGED owner
    /\ UNCHANGED <<ops, cq, woken, rval, resolved>>

\* pthread_mutex_unlock: free the mutex, and wake the first thread of its queue.
Unlock(t) ==
    /\ running = t /\ pc[t] = "unlock"
    /\ owner' = None
    /\ IF mq = <<>>
       THEN UNCHANGED <<mq, woken, js, waiters, timer, epoch, early>>
       ELSE LET u == Head(mq) IN
            /\ mq' = Tail(mq)
            /\ woken' = [woken EXCEPT ![u] = TRUE]
            /\ SetHost(Resume(Host, u))
    /\ ops' = [ops EXCEPT ![t] = @ + 1]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<cq, rval, running, resolved>>

\* With the mutex: pthread_cond_signal.
Signal(t) ==
    /\ running = t /\ pc[t] = "crit"
    /\ IF cq = <<>>
       THEN UNCHANGED <<cq, woken, js, waiters, timer, epoch, early>>
       ELSE LET u == Head(cq) IN
            /\ cq' = Tail(cq)
            /\ woken' = [woken EXCEPT ![u] = TRUE]
            /\ SetHost(Resume(Host, u))
    /\ pc' = [pc EXCEPT ![t] = "unlock"]
    /\ UNCHANGED <<ops, owner, mq, rval, running, resolved>>

\* With the mutex: pthread_cond_wait or pthread_cond_timedwait. The thread
\* goes into the queue of the condition, frees the mutex, and suspends.
Wait(t, timed) ==
    /\ running = t /\ pc[t] = "crit"
    /\ cq' = Append(cq, t)
    /\ owner' = None
    /\ LET freed == IF mq = <<>> THEN Host ELSE Resume(Host, Head(mq))
           w0 == IF mq = <<>> THEN woken ELSE [woken EXCEPT ![Head(mq)] = TRUE]
       IN /\ mq' = IF mq = <<>> THEN mq ELSE Tail(mq)
          /\ woken' = [w0 EXCEPT ![t] = FALSE]
          /\ SetHost(Suspend(freed, t, timed))
    /\ pc' = [pc EXCEPT ![t] = "condwait"]
    /\ running' = None
    /\ UNCHANGED <<ops, rval, resolved>>

\* With the mutex: no change of the condition.
Nothing(t) ==
    /\ running = t /\ pc[t] = "crit"
    /\ pc' = [pc EXCEPT ![t] = "unlock"]
    /\ UNCHANGED <<ops, owner, mq, cq, woken, rval, running, js, waiters, timer, epoch, resolved, early>>

-----------------------------------------------------------------------------
\* The host: a microtask, or a task of timers.

\* A thread continues after its suspend, with the value of the suspend.
Continue(m) ==
    LET t == m.t IN
    /\ running' = t
    /\ rval' = [rval EXCEPT ![t] = m.v]
    /\ CASE pc[t] = "lockwait" -> pc' = [pc EXCEPT ![t] = "lock"] /\ UNCHANGED cq
         [] pc[t] = "relockwait" -> pc' = [pc EXCEPT ![t] = "relock"] /\ UNCHANGED cq
         \* cond_wait: woken from the suspend (before the fix) or from the
         \* flag that wake() sets (the fix). A thread that was not woken
         \* leaves the queue of the condition.
         [] pc[t] = "condwait" ->
               LET signaled == IF Fix THEN woken[t] ELSE m.v = 1 IN
               /\ cq' = IF signaled THEN cq ELSE Remove(cq, t)
               /\ pc' = [pc EXCEPT ![t] = "relock"]
         [] OTHER -> UNCHANGED <<pc, cq>>

Microtask ==
    /\ running = None /\ js /= <<>>
    /\ LET m == Head(js) IN
       IF m.k = "cont"
       THEN /\ js' = Tail(js)
            /\ Continue(m)
            /\ UNCHANGED <<ops, owner, mq, woken, waiters, timer, epoch, resolved, early>>
       ELSE \* The resume function w of the suspend m.v: it clears its
            \* timer, and resolves its promise with 1.
            LET t == m.t
                fresh == resolved[t] < m.v
                js1 == IF fresh THEN Append(Tail(js), [k |-> "cont", t |-> t, v |-> 1]) ELSE Tail(js)
            IN /\ js' = js1
               /\ timer' = [timer EXCEPT ![t] = IF @ = m.v THEN 0 ELSE @]
               \* Before the fix, w also deletes the waiter of the thread.
               /\ waiters' = IF Fix THEN waiters ELSE [waiters EXCEPT ![t] = 0]
               /\ resolved' = [resolved EXCEPT ![t] = IF fresh THEN m.v ELSE @]
               /\ UNCHANGED <<pc, ops, owner, mq, cq, woken, rval, running, epoch, early>>

\* The callback of the timer of thread t (one step of a task of timers).
FireOne(h, rs, t) ==
    LET e == h.timer[t] IN
    [h |-> [h EXCEPT !.timer[t] = 0,
                     !.waiters[t] = IF Fix THEN (IF @ = e THEN NOOP ELSE @) ELSE 0,
                     !.js = IF rs[t] < e THEN Append(@, [k |-> "cont", t |-> t, v |-> 0]) ELSE @],
     rs |-> [rs EXCEPT ![t] = IF @ < e THEN e ELSE @]]

Due == {t \in Threads : timer[t] /= 0}

\* A task of timers: one timer, or (Batch) several in some order.
Timers ==
    /\ running = None /\ js = <<>> /\ Due /= {}
    /\ \E order \in {s \in UNION {[1..n -> Due] : n \in 1..Cardinality(Due)} :
                       \A i, j \in DOMAIN s : i /= j => s[i] /= s[j]} :
         /\ Batch \/ Len(order) = 1
         /\ LET Step[i \in 0..Len(order)] ==
                  IF i = 0 THEN [h |-> Host, rs |-> resolved]
                  ELSE FireOne(Step[i - 1].h, Step[i - 1].rs, order[i])
                last == Step[Len(order)]
            IN /\ SetHost(last.h)
               /\ resolved' = last.rs
    /\ UNCHANGED <<pc, ops, owner, mq, cq, woken, rval, running>>

Next ==
    \/ \E t \in Threads :
         Idle(t) \/ Lock(t) \/ Unlock(t) \/ Signal(t) \/ Nothing(t)
         \/ \E timed \in BOOLEAN : Wait(t, timed)
    \/ Microtask
    \/ Timers

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Only the owner of the mutex is in its critical section.
Mutex == \A t \in Threads : pc[t] \in {"crit", "unlock"} => owner = t

\* The host never resumes a thread that does not wait: else the next
\* suspend of that thread returns at once, while it is still in a queue.
NoEarlyResume == early = {}

\* A thread is in at most one queue, once, and only while it waits there.
QueuesAreRight ==
    /\ \A i, j \in DOMAIN mq : i /= j => mq[i] /= mq[j]
    /\ \A i, j \in DOMAIN cq : i /= j => cq[i] /= cq[j]
    /\ \A i \in DOMAIN mq : pc[mq[i]] \in {"lockwait", "relockwait"}
    /\ \A i \in DOMAIN cq : pc[cq[i]] = "condwait"

\* A thread that waits for the mutex is woken when the mutex is free and
\* no thread runs (no lost wake-up).
NoLostWakeup ==
    (running = None /\ js = <<>> /\ owner = None /\ mq /= <<>>) => Due /= {}
=============================================================================
