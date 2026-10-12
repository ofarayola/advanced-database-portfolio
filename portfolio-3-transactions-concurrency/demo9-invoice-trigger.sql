-- =====================================================================
-- Demo 9: Triggers that keep invoice.status in sync and block
--         overpayment (the P1 trade-off control)
-- CarePoint Specialist Clinic - Portfolio 3 (Transactions & Concurrency)
-- Tables: clinic.payment (trigger source), clinic.invoice (target)
--
-- Why: P1 stored invoice.status as a column for fast reads, and I noted
-- the risk that it could drift from the real payment total. Demo 8
-- proved it: invoice 11 was fully paid but still 'unpaid'. These
-- triggers make the database enforce the rule itself, so it does not
-- depend on every application remembering to do it.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Helper: recalculate one invoice's status from its payments
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clinic.refresh_invoice_status(p_invoice_id INT)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    UPDATE clinic.invoice i
    SET status = CASE
            WHEN s.paid = 0              THEN 'unpaid'
            WHEN s.paid < i.total_amount THEN 'part_paid'
            ELSE 'paid'
        END
    FROM (SELECT COALESCE(SUM(amount), 0) AS paid
          FROM clinic.payment
          WHERE invoice_id = p_invoice_id) AS s
    WHERE i.invoice_id = p_invoice_id;
END;
$$;

-- ---------------------------------------------------------------------
-- 2. AFTER trigger function: refresh status when payments change
--    INSERT -> new invoice; DELETE -> old invoice; UPDATE -> both
--    (in case a payment was moved to a different invoice)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clinic.fn_sync_invoice_status()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        PERFORM clinic.refresh_invoice_status(NEW.invoice_id);
    END IF;
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM clinic.refresh_invoice_status(OLD.invoice_id);
    END IF;
    RETURN NULL;   -- return value is ignored for AFTER triggers
END;
$$;

-- ---------------------------------------------------------------------
-- 3. BEFORE trigger function: block overpayment
--    Step 1 locks the invoice row (FOR UPDATE), so a second cashier
--    paying the same invoice WAITS here until the first commits.
--    Step 2 then sums the payments in a new statement, which (under
--    READ COMMITTED) sees the first cashier's committed payment.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clinic.fn_check_payment()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_total NUMERIC(12,2);
    v_paid  NUMERIC(12,2);
BEGIN
    SELECT total_amount INTO v_total
    FROM clinic.invoice
    WHERE invoice_id = NEW.invoice_id
    FOR UPDATE;

    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM clinic.payment
    WHERE invoice_id = NEW.invoice_id
      AND payment_id <> NEW.payment_id;   -- exclude this row on UPDATE

    IF v_paid + NEW.amount > v_total THEN
        RAISE EXCEPTION 'Overpayment on invoice %: total %, already paid %, new payment %',
            NEW.invoice_id, v_total, v_paid, NEW.amount
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------
-- 4. Attach the triggers to clinic.payment
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_payment_check ON clinic.payment;
CREATE TRIGGER trg_payment_check
BEFORE INSERT OR UPDATE OF amount, invoice_id ON clinic.payment
FOR EACH ROW EXECUTE FUNCTION clinic.fn_check_payment();

DROP TRIGGER IF EXISTS trg_payment_sync_status ON clinic.payment;
CREATE TRIGGER trg_payment_sync_status
AFTER INSERT OR UPDATE OR DELETE ON clinic.payment
FOR EACH ROW EXECUTE FUNCTION clinic.fn_sync_invoice_status();

-- Confirm the triggers exist
SELECT tgname AS trigger_name
FROM pg_trigger
WHERE tgrelid = 'clinic.payment'::regclass AND NOT tgisinternal
ORDER BY tgname;

-- =====================================================================
-- TESTS AND RESULTS (run 2026-10-12)
-- Setup output: CREATE FUNCTION x3, CREATE TRIGGER x2;
-- triggers listed: trg_payment_check, trg_payment_sync_status
-- Evidence: screenshots/p3-demo9-setup.png
-- =====================================================================

-- ---------------------------------------------------------------------
-- TEST A: Find and fix existing drift
-- Triggers only fire on NEW changes, so old data must be checked once.
-- ---------------------------------------------------------------------
-- Audit: invoices whose status does not match their payments
SELECT i.invoice_id, i.total_amount, i.status,
       COALESCE(SUM(p.amount), 0) AS paid
FROM clinic.invoice i
LEFT JOIN clinic.payment p USING (invoice_id)
GROUP BY i.invoice_id
HAVING i.status <> CASE
         WHEN COALESCE(SUM(p.amount), 0) = 0              THEN 'unpaid'
         WHEN COALESCE(SUM(p.amount), 0) < i.total_amount THEN 'part_paid'
         ELSE 'paid' END;
-- Result: 1 row -> 11 | 10750.00 | unpaid | 10750.00
-- (the invoice paid in Demo 8, before the trigger existed)

SELECT clinic.refresh_invoice_status(11);
SELECT invoice_id, total_amount, status FROM clinic.invoice WHERE invoice_id = 11;
-- Result: 11 | 10750.00 | paid
-- Audit re-run: 0 rows -> all 41,000+ invoices now consistent.
-- Evidence: screenshots/p3-demo9a-audit-fix.png

-- ---------------------------------------------------------------------
-- TEST B: Status updates automatically (invoice 26, total 10400.00)
-- ---------------------------------------------------------------------
INSERT INTO clinic.payment (invoice_id, amount, method) VALUES (26, 4000, 'cash');
SELECT invoice_id, total_amount, status FROM clinic.invoice WHERE invoice_id = 26;
-- Result: part_paid

INSERT INTO clinic.payment (invoice_id, amount, method) VALUES (26, 6400, 'card');
SELECT invoice_id, total_amount, status FROM clinic.invoice WHERE invoice_id = 26;
-- Result: paid

DELETE FROM clinic.payment WHERE invoice_id = 26 AND method = 'card';  -- refund
SELECT invoice_id, total_amount, status FROM clinic.invoice WHERE invoice_id = 26;
-- Result: part_paid (status follows deletes too)
-- Evidence: screenshots/p3-demo9b-status-sync.png

-- ---------------------------------------------------------------------
-- TEST C: Overpayment blocked (invoice 26: 4000 of 10400 paid)
-- ---------------------------------------------------------------------
INSERT INTO clinic.payment (invoice_id, amount, method) VALUES (26, 7000, 'transfer');
-- ERROR:  Overpayment on invoice 26: total 10400.00, already paid 4000.00,
--         new payment 7000.00
-- CONTEXT: PL/pgSQL function fn_check_payment() line 17 at RAISE
-- Evidence: screenshots/p3-demo9c-overpayment.png

-- ---------------------------------------------------------------------
-- TEST D: Demo 8 repeated at plain READ COMMITTED (two terminals)
-- Invoice 31, total 19120.00, no payments
-- ---------------------------------------------------------------------
-- [A1] BEGIN;
-- [A2] INSERT INTO clinic.payment (invoice_id, amount, method)
--      VALUES (31, 19120, 'cash');                    -- INSERT 0 1
-- [B1] BEGIN;
-- [B2] INSERT INTO clinic.payment (invoice_id, amount, method)
--      VALUES (31, 19120, 'transfer');                -- WAITS (invoice locked)
-- [A3] COMMIT;
--      B immediately gets:
--      ERROR: Overpayment on invoice 31: total 19120.00,
--             already paid 19120.00, new payment 19120.00
-- [B3] ROLLBACK;   (prompt was B!=>)
-- [A4] SELECT payment_id, amount, method FROM clinic.payment
--      WHERE invoice_id = 31;
--      Result: 1 row -> 39549 | 19120.00 | cash
-- [A5] SELECT invoice_id, total_amount, status FROM clinic.invoice
--      WHERE invoice_id = 31;
--      Result: paid
-- Evidence: screenshots/p3-demo9d-concurrent-blocked.png

-- =====================================================================
-- Observations
-- =====================================================================
-- 1. The P1 trade-off is now controlled: invoice.status is a stored
--    (denormalised) column for fast reads, but the database keeps it
--    correct on every INSERT, UPDATE and DELETE of a payment. No
--    application code can forget to update it.
--
-- 2. Test D is the same double payment as Demo 8, but it was stopped
--    at READ COMMITTED with no retry logic. The BEFORE trigger's
--    SELECT ... FOR UPDATE on the invoice row makes payments for the
--    same invoice take turns. After Ada committed, Bayo's trigger
--    re-read the payment total in a new statement, saw 19120 already
--    paid, and rejected his payment. This is pessimistic locking
--    (Demo 5b) applied to a write-skew problem.
--
-- 3. Comparison of the two fixes for double payment:
--      SERIALIZABLE (Demo 8B): no extra code in the database, but every
--        payment transaction must run at SERIALIZABLE and the app must
--        catch error 40001 and retry.
--      Trigger + FOR UPDATE (Demo 9D): works at the default level and
--        protects every application, but payments to the SAME invoice
--        queue behind each other (fine for a clinic - one invoice is
--        rarely paid by two cashiers at once).
--
-- 4. Limitations:
--    - Triggers run on every payment, adding a small cost to inserts.
--    - Logic is "hidden" in the database; it must be documented
--      (this file and the P3 README) so developers know it exists.
--    - If invoice.total_amount changes, status is not recalculated;
--      a second trigger on clinic.invoice would be needed.
--    - Rejected payments still consume sequence values (ID gaps), as
--      seen in Demos 2 and 8.
-- =====================================================================