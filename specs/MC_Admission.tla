---------------------------- MODULE MC_Admission ----------------------------
(* The model of MC_Admission.cfg: three visitors, and two of them have one *)
(* address. The tickets are numbers, so they have an order, as in SQL.     *)
EXTENDS Admission

MCVisitors == {1, 2, 3}
MCAddress == [v \in MCVisitors |-> IF v = 3 THEN "a2" ELSE "a1"]
=============================================================================
