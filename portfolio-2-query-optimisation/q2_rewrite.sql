-- =====================================================================
-- CarePoint Clinic - Portfolio 2: Query rewrite for Q2
-- Same result, but the date filter is written as a RANGE on the raw column,
-- so the index on (branch_id, start_time) can be used.
-- DATE(start_time) = '2026-10-13'  becomes
-- start_time >= '2026-10-13' AND start_time < '2026-10-14'
-- =====================================================================
SET search_path TO clinic;

-- A) ORIGINAL Q2 (with indexes in place) - DATE() still blocks the index
EXPLAIN (ANALYZE, BUFFERS)
SELECT a.start_time, a.end_time, d.full_name AS doctor, p.full_name AS patient, a.status
FROM appointment a
JOIN doctor d  ON d.doctor_id  = a.doctor_id
JOIN patient p ON p.patient_id = a.patient_id
WHERE a.branch_id = 2
  AND DATE(a.start_time) = '2026-10-13'
ORDER BY a.start_time;

-- B) REWRITTEN Q2 - sargable range condition
EXPLAIN (ANALYZE, BUFFERS)
SELECT a.start_time, a.end_time, d.full_name AS doctor, p.full_name AS patient, a.status
FROM appointment a
JOIN doctor d  ON d.doctor_id  = a.doctor_id
JOIN patient p ON p.patient_id = a.patient_id
WHERE a.branch_id = 2
  AND a.start_time >= '2026-10-13' AND a.start_time < '2026-10-14'
ORDER BY a.start_time;

-- C) Proof both versions return the same rows (expect 0)
SELECT count(*) AS rows_that_differ FROM (
  (SELECT appointment_id FROM appointment
   WHERE branch_id = 2 AND DATE(start_time) = '2026-10-13'
   EXCEPT
   SELECT appointment_id FROM appointment
   WHERE branch_id = 2 AND start_time >= '2026-10-13' AND start_time < '2026-10-14')
  UNION ALL
  (SELECT appointment_id FROM appointment
   WHERE branch_id = 2 AND start_time >= '2026-10-13' AND start_time < '2026-10-14'
   EXCEPT
   SELECT appointment_id FROM appointment
   WHERE branch_id = 2 AND DATE(start_time) = '2026-10-13')
) diff;
