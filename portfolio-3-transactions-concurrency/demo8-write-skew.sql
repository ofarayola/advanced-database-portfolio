-- =====================================================================
-- Demo 8: Write skew - REPEATABLE READ vs SERIALIZABLE
-- CarePoint Specialist Clinic - Portfolio 3 (Transactions & Concurrency)
-- Tables: clinic.invoice, clinic.payment
-- Run in TWO psql terminals (A = Ada, cashier 1; B = Bayo, cashier 2).
-- Prompt set with \set PROMPT1 'A%x=> ' so '*' = inside a transaction.
--
-- Scenario: two cashiers each check the balance on invoice 11 and each
-- record the full payment. They INSERT DIFFERENT rows, so there is no
-- row conflict. The rule they break spans many rows:
-- "total payments must not exceed the invoice total".
-- Date run: 2026-10-09
-- =====================================================================

-- Find an unpaid invoice with no payments
SELECT invoice_id, total_amount
FROM clinic.invoice i
WHERE status = 'unpaid'
  AND NOT EXISTS (SELECT 1 FROM clinic.payment p
                  WHERE p.invoice_id = i.invoice_id)
ORDER BY invoice_id
LIMIT 1;
-- Result: invoice_id = 11, total_amount = 10750.00


-- =====================================================================
-- PART A: REPEATABLE READ -> double payment is ALLOWED
-- =====================================================================

-- [A1] Terminal A
BEGIN ISOLATION LEVEL REPEATABLE READ;

-- [A2] Terminal A: Ada checks the balance
SELECT i.total_amount
       - COALESCE((SELECT SUM(amount) FROM clinic.payment
                   WHERE invoice_id = 11), 0) AS balance
FROM clinic.invoice i WHERE invoice_id = 11;
-- Result: 10750.00

-- [B1] Terminal B
BEGIN ISOLATION LEVEL REPEATABLE READ;

-- [B2] Terminal B: Bayo checks the balance
SELECT i.total_amount
       - COALESCE((SELECT SUM(amount) FROM clinic.payment
                   WHERE invoice_id = 11), 0) AS balance
FROM clinic.invoice i WHERE invoice_id = 11;
-- Result: 10750.00

-- [A3] Terminal A: Ada records a cash payment
INSERT INTO clinic.payment (invoice_id, amount, method)
VALUES (11, 10750, 'cash');
-- INSERT 0 1

-- [B3] Terminal B: Bayo records a transfer payment
INSERT INTO clinic.payment (invoice_id, amount, method)
VALUES (11, 10750, 'transfer');
-- INSERT 0 1

-- [A4] Terminal A
COMMIT;
-- COMMIT

-- [B4] Terminal B
COMMIT;
-- COMMIT  (no error - PostgreSQL did not detect any problem)

-- [A5] Terminal A: check the payments
SELECT payment_id, amount, method, paid_at
FROM clinic.payment WHERE invoice_id = 11;
-- Result: 2 rows
--   39542 | 10750.00 | cash     | 2026-10-09 16:08:24.699207
--   39543 | 10750.00 | transfer | 2026-10-09 16:08:42.629424
-- 21,500 collected on a 10,750 invoice -> patient charged twice.
-- This is WRITE SKEW.

-- Evidence: screenshots/p3-demo8a-write-skew.png

-- Cleanup before Part B
DELETE FROM clinic.payment WHERE invoice_id = 11;
-- DELETE 2

-- Why REPEATABLE READ missed it:
-- Each cashier worked from a consistent snapshot, and they wrote
-- DIFFERENT rows, so there was no update conflict to detect. In Demo 5c
-- both sessions updated the SAME stock row, which REPEATABLE READ does
-- catch. Here the conflict is between what one transaction READ and
-- what the other WROTE, and REPEATABLE READ does not track reads.


-- =====================================================================
-- PART B: SERIALIZABLE -> double payment is BLOCKED
-- =====================================================================

-- [A1] Terminal A
BEGIN ISOLATION LEVEL SERIALIZABLE;

-- [A2] Terminal A: balance
SELECT i.total_amount
       - COALESCE((SELECT SUM(amount) FROM clinic.payment
                   WHERE invoice_id = 11), 0) AS balance
FROM clinic.invoice i WHERE invoice_id = 11;
-- Result: 10750.00

-- [B1] Terminal B
BEGIN ISOLATION LEVEL SERIALIZABLE;

-- [B2] Terminal B: balance
SELECT i.total_amount
       - COALESCE((SELECT SUM(amount) FROM clinic.payment
                   WHERE invoice_id = 11), 0) AS balance
FROM clinic.invoice i WHERE invoice_id = 11;
-- Result: 10750.00

-- [A3] Terminal A
INSERT INTO clinic.payment (invoice_id, amount, method)
VALUES (11, 10750, 'cash');
-- INSERT 0 1

-- [B3] Terminal B
INSERT INTO clinic.payment (invoice_id, amount, method)
VALUES (11, 10750, 'transfer');
-- INSERT 0 1  (no error yet)

-- [A4] Terminal A: first committer wins
COMMIT;
-- COMMIT

-- [B4] Terminal B
COMMIT;
-- ERROR:  could not serialize access due to read/write dependencies
--         among transactions
-- DETAIL: Reason code: Canceled on identification as a pivot,
--         during commit attempt.
-- HINT:   The transaction might succeed if retried.
--
-- The failed COMMIT ended the transaction by itself: the prompt went
-- back to B=> (no '*' or '!'), so no ROLLBACK was needed.

-- [B5] Terminal B: RETRY the whole transaction, as the HINT suggests
BEGIN ISOLATION LEVEL SERIALIZABLE;

SELECT i.total_amount
       - COALESCE((SELECT SUM(amount) FROM clinic.payment
                   WHERE invoice_id = 11), 0) AS balance
FROM clinic.invoice i WHERE invoice_id = 11;
-- Result: 0.00 -> invoice already paid, so Bayo does NOT insert

COMMIT;
-- COMMIT

-- [B6] Terminal B: check the payments
SELECT payment_id, amount, method, paid_at
FROM clinic.payment WHERE invoice_id = 11;
-- Result: 1 row only
--   39544 | 10750.00 | cash | 2026-10-09 16:15:07.309275
--
-- Note: the ID is 39544, not 39542. IDs 39542 and 39543 were used by
-- the Part A payments I deleted, and Bayo's failed transfer in Part B
-- also took a sequence value. Sequences are never rolled back (same
-- behaviour as the ID gaps in Demo 2).

-- Evidence: screenshots/p3-demo8b-serializable.png


-- =====================================================================
-- Remaining problem (to be fixed by the trigger in Demo 9)
-- =====================================================================
SELECT invoice_id, total_amount, status
FROM clinic.invoice WHERE invoice_id = 11;
-- status is still 'unpaid' although the invoice is fully paid,
-- because nothing updates invoice.status when a payment is recorded.


-- =====================================================================
-- Observations
-- =====================================================================
-- 1. Write skew is harder to see than a lost update. No row was
--    overwritten and no error appeared in Part A. The data broke a
--    business rule that covers several rows (the sum of payments).
--
-- 2. SERIALIZABLE in PostgreSQL uses Serializable Snapshot Isolation
--    (SSI). It records what each transaction READ (predicate locks),
--    as well as what it wrote. Ada's insert changed the rows Bayo had
--    read, and Bayo's insert changed the rows Ada had read. No serial
--    order (Ada then Bayo, or Bayo then Ada) could produce both
--    payments, so PostgreSQL aborted one transaction at COMMIT.
--
-- 3. Same steps, different isolation level, opposite outcome - the
--    same pattern as Demo 4 vs Demo 5c, one level higher:
--      READ COMMITTED  -> misses lost update        (Demo 4)
--      REPEATABLE READ -> catches lost update (5c), misses write skew (8A)
--      SERIALIZABLE    -> catches write skew        (8B)
--
-- 4. Trade-off: SERIALIZABLE gives the strongest guarantee, but more
--    transactions fail and the application MUST catch the error
--    (SQLSTATE 40001) and retry the whole transaction, re-reading the
--    data each time. For CarePoint I would use SERIALIZABLE for payment
--    recording, where correctness matters more than speed, and keep
--    READ COMMITTED for ordinary lookups such as appointment lists.
-- =====================================================================