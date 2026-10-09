-- =====================================================================
-- Demo 7: Deadlock and the lock-ordering fix
-- CarePoint Specialist Clinic - Portfolio 3 (Transactions & Concurrency)
-- Table: clinic.drug_stock (branch 1 = Ikeja; drug 1 and drug 3)
-- Run in TWO psql terminals (A = Ada, B = Bayo) in the numbered order.
-- Prompt set with \set PROMPT1 'A%x=> ' so '*' = inside a transaction,
-- '!' = transaction failed.
-- Starting stock: drug 1 = 3370, drug 3 = 4124
-- =====================================================================

-- Check starting values (either terminal)
SELECT drug_id, quantity_on_hand
FROM clinic.drug_stock
WHERE branch_id = 1 AND drug_id IN (1, 3)
ORDER BY drug_id;


-- =====================================================================
-- PART A: Opposite lock order -> DEADLOCK
-- Ada dispenses drug 3 then drug 1; Bayo dispenses drug 1 then drug 3.
-- =====================================================================

-- [A1] Terminal A
BEGIN;

-- [A2] Terminal A: Ada locks drug 3
UPDATE clinic.drug_stock
SET quantity_on_hand = quantity_on_hand - 10
WHERE branch_id = 1 AND drug_id = 3;

-- [B1] Terminal B
BEGIN;

-- [B2] Terminal B: Bayo locks drug 1
UPDATE clinic.drug_stock
SET quantity_on_hand = quantity_on_hand - 5
WHERE branch_id = 1 AND drug_id = 1;

-- [A3] Terminal A: Ada needs drug 1 -> WAITS for Bayo
UPDATE clinic.drug_stock
SET quantity_on_hand = quantity_on_hand - 5
WHERE branch_id = 1 AND drug_id = 1;

-- [B3] Terminal B: Bayo needs drug 3 -> waits for Ada -> CYCLE
UPDATE clinic.drug_stock
SET quantity_on_hand = quantity_on_hand - 10
WHERE branch_id = 1 AND drug_id = 3;

-- Output in B (after deadlock_timeout, default 1s):
--   ERROR:  deadlock detected
--   DETAIL: Process 87144 waits for ShareLock on transaction 907;
--           blocked by process 4104.
--           Process 4104 waits for ShareLock on transaction 908;
--           blocked by process 87144.
--   CONTEXT: while updating tuple (0,73) in relation "drug_stock"
-- At the same moment Ada's waiting UPDATE completed (UPDATE 1).

-- [B4] Terminal B: prompt showed B!=> (failed transaction)
ROLLBACK;

-- [A4] Terminal A
COMMIT;

-- Evidence: screenshots/p3-demo7a-deadlock.png
--
-- Observation:
-- Each session held one row lock and waited for the other's, so neither
-- could ever proceed. PostgreSQL's deadlock detector found the cycle and
-- aborted ONE transaction (Bayo = the "victim"). ALL of Bayo's work was
-- undone, including his first successful update. Data stayed consistent,
-- but the application would have to retry Bayo's dispensing.
--
-- Note on my first run: I forgot step [A4] COMMIT (the prompt stayed
-- A*=>), so Ada's Part A updates stayed in the same open transaction
-- while I continued with Part B steps. Everything was committed once at
-- the end, giving drug 1 = 3355, drug 3 = 4094. Because Ada was already
-- holding both locks, that attempt did not prove the fix, so I re-ran
-- Part B cleanly below.


-- =====================================================================
-- PART B: Same lock order -> NO deadlock (clean re-run)
-- Rule: always update stock rows in ascending drug_id order
-- (drug 1 first, then drug 3).
-- Starting stock for this run: drug 1 = 3355, drug 3 = 4094
-- =====================================================================

-- [A1] Terminal A
BEGIN;

-- [A2] Terminal A: Ada locks drug 1
UPDATE clinic.drug_stock
SET quantity_on_hand = quantity_on_hand - 5
WHERE branch_id = 1 AND drug_id = 1;

-- [B1] Terminal B
BEGIN;

-- [B2] Terminal B: Bayo also wants drug 1 first -> WAITS for Ada
UPDATE clinic.drug_stock
SET quantity_on_hand = quantity_on_hand - 5
WHERE branch_id = 1 AND drug_id = 1;

-- [A3] Terminal A: Ada locks drug 3 -> succeeds immediately (no cycle)
UPDATE clinic.drug_stock
SET quantity_on_hand = quantity_on_hand - 10
WHERE branch_id = 1 AND drug_id = 3;

-- [A4] Terminal A: releases both locks -> Bayo's waiting UPDATE completes
COMMIT;

-- [B3] Terminal B
UPDATE clinic.drug_stock
SET quantity_on_hand = quantity_on_hand - 10
WHERE branch_id = 1 AND drug_id = 3;

-- [B4] Terminal B
COMMIT;

-- [B5] Terminal B: verify
SELECT drug_id, quantity_on_hand
FROM clinic.drug_stock
WHERE branch_id = 1 AND drug_id IN (1, 3)
ORDER BY drug_id;
-- Result: drug 1 = 3345, drug 3 = 4074  (both transactions saved)

-- Evidence: screenshots/p3-demo7b-lock-ordering.png
--
-- Observed: B's first UPDATE (drug 1) waited until A committed, then
-- continued. A short wait, but no cycle, so no deadlock.
--
-- Observation:
-- Waiting for a lock is normal; a deadlock only happens when waits form
-- a cycle. If every transaction locks rows in the same fixed order, a
-- cycle is impossible. In CarePoint's application code this means:
-- sort the items of a prescription by drug_id before updating stock.
-- Other safeguards: keep transactions short, and catch the deadlock
-- error (SQLSTATE 40P01) and retry the transaction.

-- =====================================================================
-- Stock trail (branch 1):
--   drug 1: 3370 -> 3355 (Part A run) -> 3345 (Part B re-run)
--   drug 3: 4124 -> 4094 (Part A run) -> 4074 (Part B re-run)
-- =====================================================================