----------------------------- MODULE SendWindow -----------------------------
(*****************************************************************************)
(* The send window of a socket (wasm_tcp and tcpSend of worker.js). The     *)
(* owner sends data. wasm_tcp counts the bytes that the host holds          *)
(* (inflight), and a send waits while inflight is Win or more. The host    *)
(* gives the data to the peer, which takes the sends in order. The host    *)
(* counts the bytes that the peer took (took), and tells wasm_tcp with      *)
(* tcp_sent after each Ack bytes or more. The messages go in order.        *)
(*                                                                           *)
(* The model checks that a send never waits with nothing that can end the  *)
(* wait (NoStall), that the host holds less than Win + MaxSend bytes        *)
(* (Bounded), and that all the sends end (AllSent).                        *)
(*****************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    Win,      \* SEND_WINDOW of wasm_tcp
    Ack,      \* ACK_BYTES of worker.js
    MaxSend,  \* the largest send
    Total     \* the count of sends of the owner

ASSUME Ack <= Win /\ MaxSend >= 1

VARIABLES
    count,     \* the sends that the owner started
    waiting,   \* the size of the send that waits, or 0
    inflight,  \* wasm_tcp: the bytes that the host holds
    pending,   \* the host: the sends that the peer did not take yet
    took,      \* the host: the bytes that the peer took, not in tcp_sent
    acks       \* the tcp_sent messages to wasm_tcp

vars == <<count, waiting, inflight, pending, took, acks>>

RECURSIVE Sum(_)
Sum(s) == IF s = <<>> THEN 0 ELSE Head(s) + Sum(Tail(s))

Init ==
    /\ count = 0 /\ waiting = 0 /\ inflight = 0
    /\ pending = <<>> /\ took = 0 /\ acks = <<>>

\* handle_call({send, Data}): the data goes to the host, or the send waits.
Send(n) ==
    /\ count < Total /\ waiting = 0
    /\ count' = count + 1
    /\ IF inflight >= Win
          THEN /\ waiting' = n
               /\ UNCHANGED <<inflight, pending>>
          ELSE /\ inflight' = inflight + n
               /\ pending' = Append(pending, n)
               /\ UNCHANGED waiting
    /\ UNCHANGED <<took, acks>>

\* The peer takes the oldest send (the write of the stream, the write of
\* the socket); tcpSend gives tcp_sent at Ack bytes or more.
Take ==
    /\ pending /= <<>>
    /\ pending' = Tail(pending)
    /\ LET t == took + Head(pending) IN
          IF t >= Ack
             THEN /\ acks' = Append(acks, t) /\ took' = 0
             ELSE /\ took' = t /\ UNCHANGED acks
    /\ UNCHANGED <<count, waiting, inflight>>

\* tcp_sent in wasm_tcp: inflight goes down, and drain/1 sends the send that
\* waits when inflight is below Win.
Sent ==
    /\ acks /= <<>>
    /\ acks' = Tail(acks)
    /\ LET f == inflight - Head(acks) IN
          IF waiting > 0 /\ f < Win
             THEN /\ inflight' = f + waiting
                  /\ pending' = Append(pending, waiting)
                  /\ waiting' = 0
             ELSE /\ inflight' = f
                  /\ UNCHANGED <<pending, waiting>>
    /\ UNCHANGED <<count, took>>

Next == (\E n \in 1..MaxSend : Send(n)) \/ Take \/ Sent

Spec == Init /\ [][Next]_vars /\ WF_vars(\E n \in 1..MaxSend : Send(n)) /\ WF_vars(Take) /\ WF_vars(Sent)

TypeOK ==
    /\ count \in 0..Total
    /\ waiting \in 0..MaxSend
    /\ inflight \in Nat /\ took \in Nat

\* wasm_tcp counts each byte that the host holds, or that a tcp_sent on
\* its way gives back.
Counted == inflight = Sum(pending) + took + Sum(acks)

\* A send that waits always has a tcp_sent to come.
NoStall == waiting > 0 => (pending /= <<>> \/ acks /= <<>>)

\* The host holds less than Win + MaxSend bytes of the socket.
Bounded == Sum(pending) + took < Win + MaxSend

\* All the sends end: none waits, and the owner sent Total.
AllSent == <>[](count = Total /\ waiting = 0)
=============================================================================
