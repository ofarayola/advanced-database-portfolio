-- =====================================================================
-- CarePoint Clinic - Sample data (valid rows)
-- Re-runnable: clears all data and resets IDs to 1 each time.
-- =====================================================================
SET search_path TO clinic;

TRUNCATE branch, patient, hmo_provider, lab_test, drug RESTART IDENTITY CASCADE;

-- Branches (IDs 1-3)
INSERT INTO branch (name, address, phone) VALUES
 ('Ikeja', '12 Allen Avenue, Ikeja, Lagos',      '0801 000 0001'),
 ('Lekki', '5 Admiralty Way, Lekki Phase 1, Lagos', '0801 000 0002'),
 ('Yaba',  '40 Herbert Macaulay Way, Yaba, Lagos', '0801 000 0003');

-- Departments (IDs 1-5)
INSERT INTO department (branch_id, name) VALUES
 (1, 'General Medicine'),   -- 1
 (1, 'Cardiology'),         -- 2
 (2, 'General Medicine'),   -- 3
 (2, 'Paediatrics'),        -- 4
 (3, 'General Medicine');   -- 5

-- Doctors (IDs 1-4)
INSERT INTO doctor (department_id, full_name, specialty, licence_no, phone, email) VALUES
 (1, 'Dr. Adebayo Okafor', 'General Practice', 'MDCN-10234', '0802 111 0001', 'a.okafor@carepoint.ng'),
 (2, 'Dr. Chioma Eze',     'Cardiology',       'MDCN-10567', '0802 111 0002', 'c.eze@carepoint.ng'),
 (4, 'Dr. Ibrahim Musa',   'Paediatrics',      'MDCN-10891', '0802 111 0003', 'i.musa@carepoint.ng'),
 (5, 'Dr. Funke Adeyemi',  'General Practice', 'MDCN-11024', '0802 111 0004', 'f.adeyemi@carepoint.ng');

-- Nurses (IDs 1-3)
INSERT INTO nurse (department_id, full_name, specialty, licence_no, phone, email) VALUES
 (1, 'Nurse Grace Okon',    'General',    'NMCN-20011', '0803 222 0001', 'g.okon@carepoint.ng'),
 (2, 'Nurse Bisi Lawal',    'Cardiac',    'NMCN-20045', '0803 222 0002', 'b.lawal@carepoint.ng'),
 (4, 'Nurse Amaka Obi',     'Paediatric', 'NMCN-20078', '0803 222 0003', 'a.obi@carepoint.ng');

-- Patients (IDs 1-5)
INSERT INTO patient (hospital_no, full_name, date_of_birth, gender, phone, address, next_of_kin) VALUES
 ('CP-0001', 'Adaeze Nwosu',     '1988-04-12', 'F', '0805 333 0001', 'Surulere, Lagos', 'Emeka Nwosu'),
 ('CP-0002', 'Tunde Bakare',     '1965-09-30', 'M', '0805 333 0002', 'Ikeja GRA, Lagos', 'Kemi Bakare'),
 ('CP-0003', 'Zainab Bello',     '1995-01-22', 'F', '0805 333 0003', 'Ajah, Lagos', 'Musa Bello'),
 ('CP-0004', 'Chidi Okeke',      '2019-06-05', 'M', '0805 333 0004', 'Lekki, Lagos', 'Ngozi Okeke'),
 ('CP-0005', 'Folake Johnson',   '1978-11-15', 'F', '0805 333 0005', 'Yaba, Lagos', 'David Johnson');

-- HMO providers (IDs 1-3)
INSERT INTO hmo_provider (provider_name, phone, email) VALUES
 ('Hygeia HMO',          '0700 000 1111', 'care@hygeia.example'),
 ('AXA Mansard Health',  '0700 000 2222', 'care@axa.example'),
 ('Reliance HMO',        '0700 000 3333', 'care@reliance.example');

-- HMO registrations
-- Patient 1: active Hygeia. Patient 2: past AXA (ended) + active Reliance. Patients 3-5: none.
INSERT INTO hmo_mapping (hmo_id, patient_id, enrollee_no, start_date, end_date) VALUES
 (1, 1, 'HYG-100234', '2025-01-01', NULL),
 (2, 2, 'AXA-55021',  '2023-03-01', '2025-02-28'),
 (3, 2, 'REL-77810',  '2025-03-01', NULL);

-- Appointments (IDs 1-6)
INSERT INTO appointment (patient_id, doctor_id, branch_id, start_time, end_time, status) VALUES
 (1, 1, 1, '2026-10-05 09:00', '2026-10-05 09:30', 'completed'),
 (2, 2, 1, '2026-10-05 10:00', '2026-10-05 10:30', 'completed'),
 (3, 2, 2, '2026-10-07 09:00', '2026-10-07 09:30', 'scheduled'),  -- Dr. Eze rotating to Lekki
 (4, 3, 2, '2026-10-08 11:00', '2026-10-08 11:30', 'scheduled'),
 (5, 4, 3, '2026-10-03 14:00', '2026-10-03 14:30', 'no_show'),
 (1, 1, 1, '2026-10-12 09:00', '2026-10-12 09:30', 'cancelled');

-- Consultations (only for completed appointments)
INSERT INTO consultation (appointment_id, symptoms, diagnosis, notes) VALUES
 (1, 'Fever, headache for 2 days', 'Suspected malaria', 'Ordered MP test'),
 (2, 'Occasional chest tightness', 'Hypertension',      'Start Amlodipine; lipid profile');

-- Vital signs
INSERT INTO vital_signs (consultation_id, nurse_id, temp_celsius, bp_systolic, bp_diastolic, weight_kg) VALUES
 (1, 1, 38.2, 118, 76, 64.0),
 (2, 2, 36.8, 152, 96, 88.5),
 (2, 2, 36.8, 148, 94, 88.5);   -- BP re-checked during same visit (1:N)

-- Lab tests (IDs 1-3) and orders
INSERT INTO lab_test (name, sample_type, price) VALUES
 ('Full Blood Count',        'Blood', 8000.00),
 ('Malaria Parasite (MP)',   'Blood', 3500.00),
 ('Lipid Profile',           'Blood', 12000.00);

INSERT INTO lab_order (consultation_id, lab_test_id, status, result_value, result_date) VALUES
 (1, 2, 'completed', 'Positive (+)', '2026-10-05 11:00'),
 (2, 3, 'ordered',   NULL,           NULL);

-- Drugs (IDs 1-4) and stock per branch
INSERT INTO drug (name, form, strength, unit_price) VALUES
 ('Paracetamol',               'tablet',  '500mg',     50.00),
 ('Amlodipine',                'tablet',  '5mg',      120.00),
 ('Artemether/Lumefantrine',   'tablet',  '20/120mg', 200.00),
 ('Amoxicillin',               'capsule', '500mg',     80.00);

INSERT INTO drug_stock (branch_id, drug_id, quantity_on_hand, reorder_level) VALUES
 (1, 1, 500, 100), (1, 2, 200, 50), (1, 3, 150, 50), (1, 4, 300, 50),
 (2, 1, 400, 100), (2, 3, 100, 50),
 (3, 1, 250, 100);

-- Prescriptions (IDs 1-2) and items
INSERT INTO prescription (consultation_id) VALUES (1), (2);

INSERT INTO prescription_item (prescription_id, drug_id, quantity, dosage_instructions) VALUES
 (1, 3, 24, '4 tablets twice daily for 3 days'),
 (1, 1, 10, '2 tablets 3x daily when needed'),
 (2, 2, 30, '1 tablet daily');

-- Billing
INSERT INTO invoice (patient_id, appointment_id, total_amount, status) VALUES
 (1, 1, 25000.00, 'part_paid'),
 (2, 2, 40000.00, 'paid');

INSERT INTO payment (invoice_id, amount, method) VALUES
 (1, 15000.00, 'hmo'),
 (2, 40000.00, 'transfer');

-- Quick check: HMO status view (expect patients 1 and 2 = true, 3-5 = false)
SELECT * FROM patient_hmo_status ORDER BY patient_id;