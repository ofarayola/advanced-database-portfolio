-- =====================================================================
-- Demo 6: Non-repeatable read (READ COMMITTED vs REPEATABLE READ)
-- CarePoint Specialist Clinic - Portfolio 3
-- Scenario: Pharmacist Ada checks stock of drug 3 (Artemether/Lumefantrine)
-- at Ikeja (branch 1) twice in one transaction, while Bayo dispenses 15.
-- Run in TWO psql terminals (A = Ada, B = Bayo) in the numbered order.
-- =====================================================================

-- ---------------------------------------------------------------------
-- PART A: READ COMMITTED (PostgreSQL default)
-- ---------------------------------------------------------------------

-- [A1] Terminal A
BEGIN;
SELECT quantity_on_hand FROM clinic.drug_stock
WHERE branch_id = 1 AND drug_id = 3;          -- result: 4154

-- [B1] Terminal B
BEGIN;
UPDATE clinic.drug_stock
SET quantity_on_hand = quantity_on_hand - 15
WHERE branch_id = 1 AND drug_id = 3;
COMMIT;                                        -- stock now 4139

-- [A2] Terminal A: same query, same transaction
SELECT quantity_on_hand FROM clinic.drug_stock
WHERE branch_id = 1 AND drug_id = 3;          -- result: 4139  (changed!)
COMMIT;

-- Observation: under READ COMMITTED every statement takes a fresh
-- snapshot, so Ada's second read sees Bayo's committed change.
-- This is a NON-REPEATABLE READ. Evidence: p3-demo6a-nonrepeatable-read.png

-- ---------------------------------------------------------------------
-- PART B: REPEATABLE READ
-- ---------------------------------------------------------------------

-- [A1] Terminal A
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT quantity_on_hand FROM clinic.drug_stock
WHERE branch_id = 1 AND drug_id = 3;          -- result: 4139

-- [B1] Terminal B
BEGIN;
UPDATE clinic.drug_stock
SET quantity_on_hand = quantity_on_hand - 15
WHERE branch_id = 1 AND drug_id = 3;
COMMIT;
SELECT quantity_on_hand FROM clinic.drug_stock
WHERE branch_id = 1 AND drug_id = 3;          -- Bayo sees 4124

-- [A2] Terminal A: same query, same transaction
SELECT quantity_on_hand FROM clinic.drug_stock
WHERE branch_id = 1 AND drug_id = 3;          -- result: still 4139
COMMIT;

-- [A3] Terminal A: new transaction
SELECT quantity_on_hand FROM clinic.drug_stock
WHERE branch_id = 1 AND drug_id = 3;          -- result: 4124

-- Observation: under REPEATABLE READ the snapshot is taken at the first
-- statement and kept until COMMIT, so Ada's reads are consistent.
-- Both values (4139 and 4124) existed at the same time as separate row
-- versions (MVCC); each transaction saw the version its snapshot allowed.
-- Evidence: p3-demo6b-repeatable-read.png
--
-- Trade-off: REPEATABLE READ gives a stable view (good for reports and
-- stock audits), but if Ada had tried to UPDATE this row after Bayo's
-- commit she would get a serialization error and need to retry (Demo 5c).
--
-- Stock trail (drug 3, branch 1): 4154 -> 4139 (Part A) -> 4124 (Part B)