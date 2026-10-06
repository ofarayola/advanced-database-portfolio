-- =====================================================================
-- CarePoint Clinic - Constraint tests
-- Run AFTER sample-data.sql. Tests 1-16 SHOULD FAIL with an ERROR.
-- Tests P1-P3 SHOULD SUCCEED.
-- =====================================================================
SET search_path TO clinic;

-- ---------- PART A: rules that must REJECT bad data ----------

-- TEST 1: Duplicate hospital number  -> expect: patient_hospital_no_key
INSERT INTO patient (hospital_no, full_name, date_of_birth, gender)
VALUES ('CP-0001', 'Duplicate Person', '1990-01-01', 'F');

-- TEST 2: Invalid gender  -> expect: chk_patient_gender
INSERT INTO patient (hospital_no, full_name, date_of_birth, gender)
VALUES ('CP-0099', 'Test Gender', '1990-01-01', 'X');

-- TEST 3: Duplicate doctor licence number  -> expect: doctor_licence_no_key
INSERT INTO doctor (department_id, full_name, licence_no)
VALUES (1, 'Dr. Copy', 'MDCN-10234');

-- TEST 4: Appointment ends before it starts  -> expect: chk_appt_time
INSERT INTO appointment (patient_id, doctor_id, branch_id, start_time, end_time)
VALUES (3, 1, 1, '2026-10-20 10:00', '2026-10-20 09:30');

-- TEST 5: Double-booking Dr. Okafor at 09:00 on 5 Oct  -> expect: uq_doctor_slot
INSERT INTO appointment (patient_id, doctor_id, branch_id, start_time, end_time)
VALUES (3, 1, 1, '2026-10-05 09:00', '2026-10-05 09:30');

-- TEST 6: Invalid appointment status  -> expect: chk_appt_status
INSERT INTO appointment (patient_id, doctor_id, branch_id, start_time, end_time, status)
VALUES (3, 1, 1, '2026-10-21 10:00', '2026-10-21 10:30', 'pending');

-- TEST 7: Appointment for a patient who doesn't exist  -> expect: appointment_patient_id_fkey
INSERT INTO appointment (patient_id, doctor_id, branch_id, start_time, end_time)
VALUES (999, 1, 1, '2026-10-22 10:00', '2026-10-22 10:30');

-- TEST 8: Delete a patient who has appointments (RESTRICT)  -> expect: foreign key violation
DELETE FROM patient WHERE patient_id = 1;

-- TEST 9: Second consultation for the same appointment (1:1)  -> expect: consultation_appointment_id_key
INSERT INTO consultation (appointment_id, diagnosis) VALUES (1, 'Duplicate visit');

-- TEST 10: Temperature 50 °C  -> expect: chk_temp
INSERT INTO vital_signs (consultation_id, nurse_id, temp_celsius) VALUES (1, 1, 50.0);

-- TEST 11: Systolic lower than diastolic (80/120)  -> expect: chk_bp
INSERT INTO vital_signs (consultation_id, nurse_id, bp_systolic, bp_diastolic) VALUES (1, 1, 80, 120);

-- TEST 12: Lab test marked completed with no result  -> expect: chk_lab_result
INSERT INTO lab_order (consultation_id, lab_test_id, status) VALUES (2, 1, 'completed');

-- TEST 13: Dispense more drugs than in stock (500 - 1000)  -> expect: chk_stock_not_negative
UPDATE drug_stock SET quantity_on_hand = quantity_on_hand - 1000
WHERE branch_id = 1 AND drug_id = 1;

-- TEST 14: Second ACTIVE HMO for patient 1  -> expect: uq_one_active_hmo_per_patient
INSERT INTO hmo_mapping (hmo_id, patient_id, enrollee_no, start_date)
VALUES (2, 1, 'AXA-99999', '2026-10-01');

-- TEST 15: HMO end date before start date  -> expect: chk_hmo_dates
INSERT INTO hmo_mapping (hmo_id, patient_id, enrollee_no, start_date, end_date)
VALUES (1, 3, 'HYG-200001', '2026-05-01', '2026-01-01');

-- TEST 16: Payment of zero  -> expect: chk_payment_amount
INSERT INTO payment (invoice_id, amount, method) VALUES (1, 0, 'cash');

-- ---------- PART B: correct behaviour that must SUCCEED ----------

-- P1: View updates automatically when an HMO ends
SELECT * FROM patient_hmo_status WHERE patient_id = 1;          -- before: uses_hmo = t
UPDATE hmo_mapping SET end_date = '2026-10-06' WHERE register_id = 1;
SELECT * FROM patient_hmo_status WHERE patient_id = 1;          -- after:  uses_hmo = f

-- P2: Partial index allows a NEW active HMO once the old one has ended
INSERT INTO hmo_mapping (hmo_id, patient_id, enrollee_no, start_date)
VALUES (3, 1, 'REL-90001', '2026-10-07');
SELECT register_id, hmo_id, enrollee_no, start_date, end_date
FROM hmo_mapping WHERE patient_id = 1 ORDER BY start_date;      -- history kept: 2 rows

-- P3: ON DELETE CASCADE removes prescription items with their prescription
SELECT count(*) AS items_before FROM prescription_item WHERE prescription_id = 2;  -- 1
DELETE FROM prescription WHERE prescription_id = 2;
SELECT count(*) AS items_after  FROM prescription_item WHERE prescription_id = 2;  -- 0