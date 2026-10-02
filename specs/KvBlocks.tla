------------------------------- MODULE KvBlocks -------------------------------
(*****************************************************************************)
(* The blocks of a SQLite file in Deno KV (KvStore of                         *)
(* priv/wasm_host/deno/deno.js, and the host files of worker.js).            *)
(*                                                                           *)
(* The key "m" holds the version of the database. A commit is one atomic     *)
(* operation with a check of "m": it writes block n of the new version with  *)
(* p, the version of the block before it, and it drops the version before    *)
(* that one (drop). So a block keeps its last two versions.                  *)
(*                                                                           *)
(* A transaction reads one version, its snapshot. A read of block n at       *)
(* version V is two list operations, not one atomic step:                    *)
(*   1. the newest block at or before V (found);                             *)
(*   2. the first block after V (newer). When newer.p is not found.v, a      *)
(*      later commit dropped a block of V: the read fails ("gone").          *)
(*                                                                           *)
(* The model has one block, writers that commit, and readers that hold an   *)
(* old snapshot while the writers commit. Data is the version that wrote it. *)
(*****************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Writers, Readers, MaxVersion

None == [v |-> 0, p |-> 0]   \* no block: the data is zeros

VARIABLES
    mver,      \* the version of the database (key "m")
    store,     \* the versions of the block in the store: [v, p]
    written,   \* each version that wrote the block (also the dropped ones)
    wpc, wsnap, wcache,
    rpc, rsnap, rfound, rresult

vars == <<mver, store, written, wpc, wsnap, wcache, rpc, rsnap, rfound, rresult>>

Max(S) == CHOOSE x \in S : \A y \in S : y <= x
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

\* The data of the block at version V: the last write at or before V.
Latest(V) == LET w == {x \in written : x <= V} IN IF w = {} THEN 0 ELSE Max(w)

\* Step 1 of a read: the newest block at or before V.
Found(V) == LET b == {x \in store : x.v <= V} IN
            IF b = {} THEN None ELSE CHOOSE x \in b : x.v = Max({y.v : y \in b})

\* Step 2 of a read: the first block after V, if one exists.
Newer(V) == {x \in store : x.v > V}
FirstNewer(V) == CHOOSE x \in Newer(V) : x.v = Min({y.v : y \in Newer(V)})

\* The result of a read: the data, or "gone".
Read(V, found) ==
    IF Newer(V) /= {} /\ FirstNewer(V).p /= found.v
    THEN [gone |-> TRUE, v |-> 0]
    ELSE [gone |-> FALSE, v |-> found.v]

Init ==
    /\ mver = 0 /\ store = {} /\ written = {}
    /\ wpc = [w \in Writers |-> "idle"]
    /\ wsnap = [w \in Writers |-> 0]
    /\ wcache = [w \in Writers |-> None]
    /\ rpc = [r \in Readers |-> "idle"]
    /\ rsnap = [r \in Readers |-> 0]
    /\ rfound = [r \in Readers |-> None]
    /\ rresult = [r \in Readers |-> [gone |-> FALSE, v |-> 0]]

\* A writer reads its snapshot, and the block into its cache (a write of a
\* block reads it first). A read that fails aborts the transaction.
WBegin(w) ==
    /\ wpc[w] = "idle"
    /\ LET r == Read(mver, Found(mver)) IN
         IF r.gone
         THEN UNCHANGED <<wpc, wsnap, wcache>>
         ELSE /\ wpc' = [wpc EXCEPT ![w] = "ready"]
              /\ wsnap' = [wsnap EXCEPT ![w] = mver]
              /\ wcache' = [wcache EXCEPT ![w] = Found(mver)]
    /\ UNCHANGED <<mver, store, written, rpc, rsnap, rfound, rresult>>

\* The commit: one atomic operation with the check of "m". It writes the
\* block (prev = the cached version, drop = the version before it), or a
\* commit of other blocks only changes the version.
WCommit(w, writesBlock) ==
    /\ wpc[w] = "ready"
    /\ mver < MaxVersion
    /\ IF mver = wsnap[w]
       THEN LET new == mver + 1
                old == wcache[w]
            IN /\ mver' = new
               /\ IF writesBlock
                  THEN /\ store' = {x \in store : old.p = 0 \/ x.v /= old.p}
                                   \cup {[v |-> new, p |-> old.v]}
                       /\ written' = written \cup {new}
                  ELSE UNCHANGED <<store, written>>
       ELSE UNCHANGED <<mver, store, written>>   \* SQLITE_BUSY: nothing changes
    /\ wpc' = [wpc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<wsnap, wcache, rpc, rsnap, rfound, rresult>>

RBegin(r) ==
    /\ rpc[r] = "idle"
    /\ rpc' = [rpc EXCEPT ![r] = "begun"]
    /\ rsnap' = [rsnap EXCEPT ![r] = mver]
    /\ UNCHANGED <<mver, store, written, wpc, wsnap, wcache, rfound, rresult>>

RList1(r) ==
    /\ rpc[r] = "begun"
    /\ rpc' = [rpc EXCEPT ![r] = "listed"]
    /\ rfound' = [rfound EXCEPT ![r] = Found(rsnap[r])]
    /\ UNCHANGED <<mver, store, written, wpc, wsnap, wcache, rsnap, rresult>>

RList2(r) ==
    /\ rpc[r] = "listed"
    /\ rpc' = [rpc EXCEPT ![r] = "done"]
    /\ rresult' = [rresult EXCEPT ![r] = Read(rsnap[r], rfound[r])]
    /\ UNCHANGED <<mver, store, written, wpc, wsnap, wcache, rsnap, rfound>>

\* A reader keeps its snapshot for more reads, or starts again.
RAgain(r) ==
    /\ rpc[r] = "done"
    /\ \/ rpc' = [rpc EXCEPT ![r] = "begun"]
       \/ rpc' = [rpc EXCEPT ![r] = "idle"]
    /\ UNCHANGED <<mver, store, written, wpc, wsnap, wcache, rsnap, rfound, rresult>>

Next ==
    \/ \E w \in Writers : WBegin(w) \/ \E b \in BOOLEAN : WCommit(w, b)
    \/ \E r \in Readers : RBegin(r) \/ RList1(r) \/ RList2(r) \/ RAgain(r)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* A read gives the data of its version, or it fails. It never gives the
\* data of another version.
ReadsAreRight ==
    \A r \in Readers : rpc[r] = "done" /\ ~rresult[r].gone
                         => rresult[r].v = Latest(rsnap[r])

\* Each block in the store names the version of the block before it.
PrevIsRight == \A x \in store : x.p = Latest(x.v - 1)

\* A block keeps its last two versions.
TwoVersions == Cardinality(store) <= 2

\* The newest version in the store is the data of the database.
NewestIsLatest == store /= {} => Max({x.v : x \in store}) = Latest(mver)

TypeOK ==
    /\ mver \in 0..MaxVersion
    /\ written \subseteq 1..MaxVersion
    /\ \A x \in store : x.v \in written
=============================================================================
