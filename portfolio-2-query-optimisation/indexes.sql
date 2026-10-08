-- =====================================================================
-- CarePoint Clinic - Portfolio 2: Indexes
-- Each index targets a specific query from queries.sql.
-- Run:  psql -U postgres -d carepoint -f portfolio-2-query-optimisation/indexes.sql
-- Undo: see the DROP statements at the bottom.
-- =====================================================================
SET search_path TO clinic;

-- Q1 Patient history: find a patient's appointments without scanning all 60,000.
-- Foreign keys are NOT indexed automatically in PostgreSQL.
CREATE INDEX IF NOT EXISTS idx_appointment_patient
    ON appointment (patient_id);

-- Q2 Branch schedule: composite index - equality column (branch_id) first,
-- range column (start_time) second. Only usable once DATE() is removed (q2_rewrite.sql).
CREATE INDEX IF NOT EXISTS idx_appointment_branch_start
    ON appointment (branch_id, start_time);

-- Q3 Monthly revenue: TEST index. Q3 needs ~36% of invoices, so I expect the
-- planner to ignore this index and keep the sequential scan.
CREATE INDEX IF NOT EXISTS idx_invoice_issued_at
    ON invoice (issued_at);

-- Q5 Pending labs: PARTIAL index - only the ~100 rows still waiting for a result
-- are stored, not all 33,000. Small, fast, and cheap to maintain.
CREATE INDEX IF NOT EXISTS idx_lab_order_pending
    ON lab_order (consultation_id)
    WHERE status IN ('ordered', 'sample_collected');

-- Q6 Outstanding balances: (a) foreign key used by the payment join,
-- (b) partial index on the 20% of invoices that are not fully paid.
CREATE INDEX IF NOT EXISTS idx_payment_invoice
    ON payment (invoice_id);
CREATE INDEX IF NOT EXISTS idx_invoice_unpaid
    ON invoice (invoice_id)
    WHERE status IN ('unpaid', 'part_paid');

-- Q8 High BP alerts: recent vital signs only.
CREATE INDEX IF NOT EXISTS idx_vitals_recorded_at
    ON vital_signs (recorded_at);

-- Q8 also joins vital_signs -> consultation; index the foreign key.
CREATE INDEX IF NOT EXISTS idx_vitals_consultation
    ON vital_signs (consultation_id);

-- Refresh statistics so the planner knows about the new indexes and data.
ANALYZE;

-- List what was created, with sizes
SELECT indexname, pg_size_pretty(pg_relation_size(('clinic.' || indexname)::regclass)) AS size
FROM pg_indexes
WHERE schemaname = 'clinic' AND indexname LIKE 'idx_%'
ORDER BY indexname;

-- ---------------------------------------------------------------------
-- UNDO (run these to go back to the baseline):
-- DROP INDEX IF EXISTS idx_appointment_patient, idx_appointment_branch_start,
--   idx_invoice_issued_at, idx_lab_order_pending, idx_payment_invoice,
--   idx_invoice_unpaid, idx_vitals_recorded_at, idx_vitals_consultation;
-- ---------------------------------------------------------------------
