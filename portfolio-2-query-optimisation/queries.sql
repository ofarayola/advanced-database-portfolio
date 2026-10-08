-- =====================================================================
-- CarePoint Clinic - Portfolio 2: Business queries
-- Eight queries that real clinic staff would run every day.
-- Run:  psql -U postgres -d carepoint -f portfolio-2-query-optimisation/queries.sql
-- =====================================================================
SET search_path TO clinic;

-- Q1. PATIENT HISTORY (front desk / doctor)
-- "Show me every visit for patient CP-011210, newest first."
SELECT p.hospital_no, p.full_name, a.start_time, b.name AS branch,
       d.full_name AS doctor, a.status, c.diagnosis
FROM patient p
JOIN appointment a       ON a.patient_id = p.patient_id
JOIN doctor d            ON d.doctor_id  = a.doctor_id
JOIN branch b            ON b.branch_id  = a.branch_id
LEFT JOIN consultation c ON c.appointment_id = a.appointment_id
WHERE p.hospital_no = 'CP-011210'
ORDER BY a.start_time DESC;

-- Q2. BRANCH DAILY SCHEDULE (front desk)
-- "Who is booked at the Lekki branch on 13 Oct 2026?"
SELECT a.start_time, a.end_time, d.full_name AS doctor, p.full_name AS patient, a.status
FROM appointment a
JOIN doctor d  ON d.doctor_id  = a.doctor_id
JOIN patient p ON p.patient_id = a.patient_id
WHERE a.branch_id = 2
  AND DATE(a.start_time) = '2026-10-13'
ORDER BY a.start_time;

-- Q3. MONTHLY REVENUE PER BRANCH (management)
-- "How much did each branch invoice per month in 2025?"
SELECT b.name AS branch, date_trunc('month', i.issued_at)::date AS month,
       count(*) AS invoices, sum(i.total_amount) AS revenue
FROM invoice i
JOIN appointment a ON a.appointment_id = i.appointment_id
JOIN branch b      ON b.branch_id      = a.branch_id
WHERE i.issued_at >= '2025-01-01' AND i.issued_at < '2026-01-01'
GROUP BY b.name, month
ORDER BY b.name, month;

-- Q4. TOP 10 DRUGS IN THE LAST 12 MONTHS (pharmacy restocking)
SELECT dr.name, dr.strength, sum(pi.quantity) AS units, count(*) AS times_prescribed
FROM prescription_item pi
JOIN prescription pr ON pr.prescription_id = pi.prescription_id
JOIN drug dr         ON dr.drug_id         = pi.drug_id
WHERE pr.issued_at >= '2025-10-01'
GROUP BY dr.name, dr.strength
ORDER BY units DESC
LIMIT 10;

-- Q5. PENDING LAB RESULTS (laboratory worklist)
-- "Which tests are still waiting for a result, oldest first?"
SELECT lo.lab_order_id, lt.name AS test, p.full_name AS patient, c.created_at AS ordered_at
FROM lab_order lo
JOIN lab_test lt    ON lt.lab_test_id    = lo.lab_test_id
JOIN consultation c ON c.consultation_id = lo.consultation_id
JOIN appointment a  ON a.appointment_id  = c.appointment_id
JOIN patient p      ON p.patient_id      = a.patient_id
WHERE lo.status IN ('ordered', 'sample_collected')
ORDER BY c.created_at;

-- Q6. OUTSTANDING BALANCES (billing)
-- "Top 20 unpaid or part-paid invoices by amount still owed."
SELECT i.invoice_id, p.hospital_no, p.full_name, i.total_amount,
       COALESCE(sum(pay.amount), 0)                  AS paid,
       i.total_amount - COALESCE(sum(pay.amount), 0) AS balance
FROM invoice i
JOIN patient p        ON p.patient_id   = i.patient_id
LEFT JOIN payment pay ON pay.invoice_id = i.invoice_id
WHERE i.status IN ('unpaid', 'part_paid')
GROUP BY i.invoice_id, p.hospital_no, p.full_name, i.total_amount
ORDER BY balance DESC
LIMIT 20;

-- Q7. DOCTOR WORKLOAD RANKING (management) - uses a WINDOW FUNCTION
-- "Rank doctors within each branch by completed visits in 2025."
SELECT b.name AS branch, d.full_name AS doctor, count(*) AS consultations,
       RANK() OVER (PARTITION BY b.name ORDER BY count(*) DESC) AS rank_in_branch
FROM appointment a
JOIN doctor d ON d.doctor_id = a.doctor_id
JOIN branch b ON b.branch_id = a.branch_id
WHERE a.status = 'completed'
  AND a.start_time >= '2025-01-01' AND a.start_time < '2026-01-01'
GROUP BY b.name, d.full_name
ORDER BY b.name, rank_in_branch;

-- Q8. HIGH BLOOD PRESSURE ALERTS (clinical follow-up)
-- "Patients with systolic BP of 160+ in the last 90 days."
SELECT p.hospital_no, p.full_name, v.bp_systolic, v.bp_diastolic, v.recorded_at
FROM vital_signs v
JOIN consultation c ON c.consultation_id = v.consultation_id
JOIN appointment a  ON a.appointment_id  = c.appointment_id
JOIN patient p      ON p.patient_id      = a.patient_id
WHERE v.bp_systolic >= 160
  AND v.recorded_at >= DATE '2026-10-08' - INTERVAL '90 days'
ORDER BY v.bp_systolic DESC, v.recorded_at DESC
LIMIT 20;
