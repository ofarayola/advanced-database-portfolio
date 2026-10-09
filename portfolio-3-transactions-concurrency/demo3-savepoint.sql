-- =====================================================================
-- Demo 3: SAVEPOINT - undo one failed step, keep the rest, then commit
-- Portfolio 3 - Transactions and Concurrency
-- Session A = Pharmacist Ada. Run interactively in psql.
-- =====================================================================
-- Starting state:
--   drug_stock branch 1: drug 1 (Paracetamol) = 3380, drug 13 (Salbutamol) = 3727
--   invoice 41532 = 18000.00 / paid; consultation 41532 has no prescription

-- [A] BEGIN;
-- [A] INSERT INTO prescription (consultation_id) VALUES (41532) RETURNING prescription_id;
--     -> 35373

-- Part 1: Paracetamol (succeeds)
-- [A] INSERT INTO prescription_item (prescription_id, drug_id, quantity, dosage_instructions)
--     VALUES (35373, 1, 10, '2 tablets 3 times daily');
-- [A] UPDATE drug_stock SET quantity_on_hand = quantity_on_hand - 10
--     WHERE branch_id = 1 AND drug_id = 1;                          -- UPDATE 1

-- Bookmark before the risky step
-- [A] SAVEPOINT before_inhaler;

-- Part 2: Salbutamol, 5000 entered by mistake (fails)
-- [A] INSERT INTO prescription_item (prescription_id, drug_id, quantity, dosage_instructions)
--     VALUES (35373, 13, 5000, '2 puffs when needed');              -- INSERT 0 1
-- [A] UPDATE drug_stock SET quantity_on_hand = quantity_on_hand - 5000
--     WHERE branch_id = 1 AND drug_id = 13;
--     -> ERROR: new row for relation "drug_stock" violates check constraint
--               "chk_stock_not_negative"
--        DETAIL: Failing row contains (1, 13, -1273, 100).
--     (prompt: A!=>)

-- Undo ONLY the work after the savepoint
-- [A] ROLLBACK TO SAVEPOINT before_inhaler;
--     (prompt back to A*=> : the transaction is alive again)
-- [A] SELECT drug_id, quantity FROM prescription_item WHERE prescription_id = 35373;
--     -> 1 | 10      (inhaler row removed, Paracetamol row kept)

-- Bill only what was dispensed (10 x N50 = N500) and commit
-- [A] UPDATE invoice SET total_amount = total_amount + 500, status = 'part_paid'
--     WHERE invoice_id = 41532;
-- [A] COMMIT;

-- Final state
-- [A] SELECT drug_id, quantity_on_hand FROM drug_stock WHERE branch_id = 1 AND drug_id IN (1, 13);
--     -> 13 | 3727   (unchanged)
--         1 | 3370   (3380 - 10)
-- [A] SELECT total_amount, status FROM invoice WHERE invoice_id = 41532;
--     -> 18500.00 | part_paid

-- ---------------------------------------------------------------------
-- What this demonstrates
-- ---------------------------------------------------------------------
-- 1. A SAVEPOINT marks a point inside a transaction. ROLLBACK TO SAVEPOINT undoes
--    only the work after that point; the earlier work stays and the transaction
--    can continue and COMMIT.
-- 2. Compared with Demo 2: a plain ROLLBACK discards everything; a savepoint
--    gives finer control, e.g. drop one problem item and dispense the rest.
-- 3. The constraint chk_stock_not_negative again protected the stock level.
-- 4. MVCC: after the UPDATE, drug 1 is listed after drug 13 because PostgreSQL
--    writes a new row version instead of overwriting the old one. Without
--    ORDER BY, row order is not guaranteed.
-- =====================================================================