-- =====================================================================
-- Demo 2: ROLLBACK - insufficient stock cancels the whole transaction
-- Portfolio 3 - Transactions and Concurrency
-- Session A = Pharmacist Ada, Session B = Pharmacist Bayo
-- Run interactively in two psql sessions (prompt shows A*=> inside a
-- transaction and A!=> after an error). Expected results are in comments.
-- =====================================================================
-- Starting state (after Demo 1):
--   drug_stock branch 1, drug 3 (Artemether/Lumefantrine) = 4264
--   consultation 41569 has no prescription; invoice 41569 = 20000.00 / paid

-- ---------------------------------------------------------------------
-- PART A: Automatic rollback after a constraint violation
-- ---------------------------------------------------------------------

-- [A] Start the transaction and create the prescription
-- [A] BEGIN;
-- [A] INSERT INTO prescription (consultation_id) VALUES (41569) RETURNING prescription_id;
--     -> 35372
-- [A] INSERT INTO prescription_item (prescription_id, drug_id, quantity, dosage_instructions)
--     VALUES (35372, 3, 5000, 'Bulk order - error');
--     -> INSERT 0 1   (prompt: A*=>)

-- [B] Isolation check while A's transaction is still open
-- [B] SELECT count(*) FROM prescription WHERE consultation_id = 41569;
--     -> 0   (B cannot see A's uncommitted prescription: no dirty read)

-- [A] Try to dispense 5000 tablets when only 4264 are in stock
-- [A] UPDATE drug_stock SET quantity_on_hand = quantity_on_hand - 5000
--     WHERE branch_id = 1 AND drug_id = 3;
--     -> ERROR:  new row for relation "drug_stock" violates check constraint
--                "chk_stock_not_negative"
--        DETAIL: Failing row contains (1, 3, -736, 100).
--     (prompt changes to A!=> : the transaction has failed)

-- [A] Any further command in the failed transaction is refused
-- [A] UPDATE invoice SET total_amount = total_amount + 1000000 WHERE invoice_id = 41569;
--     -> ERROR:  current transaction is aborted, commands ignored until end
--                of transaction block

-- [A] End the failed transaction
-- [A] ROLLBACK;
--     (prompt returns to A=>)

-- [A] Prove nothing was kept, not even the steps that had succeeded
-- [A] SELECT quantity_on_hand FROM drug_stock WHERE branch_id = 1 AND drug_id = 3;
--     -> 4264              (stock unchanged)
-- [A] SELECT count(*) FROM prescription WHERE consultation_id = 41569;
--     -> 0                 (prescription insert undone)
-- [A] SELECT count(*) FROM prescription_item WHERE prescription_id = 35372;
--     -> 0                 (item insert undone)
-- [A] SELECT total_amount, status FROM invoice WHERE invoice_id = 41569;
--     -> 20000.00 | paid   (invoice unchanged)

-- ---------------------------------------------------------------------
-- PART B: Manual rollback - the pharmacist cancels a transaction herself
-- ---------------------------------------------------------------------
-- [A] BEGIN;
-- [A] UPDATE drug_stock SET quantity_on_hand = quantity_on_hand - 10
--     WHERE branch_id = 1 AND drug_id = 3;
-- [A] SELECT quantity_on_hand FROM drug_stock WHERE branch_id = 1 AND drug_id = 3;
--     -> 4254   (A sees her own uncommitted change)
-- [A] ROLLBACK;
-- [A] SELECT quantity_on_hand FROM drug_stock WHERE branch_id = 1 AND drug_id = 3;
--     -> 4264   (change discarded)

-- ---------------------------------------------------------------------
-- What this demonstrates
-- ---------------------------------------------------------------------
-- 1. ATOMICITY: the prescription and item inserts succeeded, but because a
--    later statement in the same transaction failed, ROLLBACK removed them
--    as well. All or nothing.
-- 2. CONSISTENCY: the CHECK constraint chk_stock_not_negative (from Portfolio 1)
--    stopped stock going below zero; the transaction mechanism made sure no
--    partial data was left behind.
-- 3. After an error PostgreSQL refuses all further commands in that
--    transaction, so a half-finished transaction cannot be committed by mistake.
-- 4. ISOLATION: Session B saw 0 prescriptions for 41569 while A was mid-
--    transaction, so there was no dirty read.
-- 5. SEQUENCE GAP: this run received prescription_id 35372, not 35371, because
--    35371 had been used by an earlier, abandoned transaction that was rolled back.
--    Sequences are not transactional: a value is never handed back, so PostgreSQL
--    never gives two users the same ID, at the cost of occasional gaps in numbering.
--    The 35372 used here was also discarded by this rollback, so the next
--    prescription (Demo 3) received 35373.
-- =====================================================================