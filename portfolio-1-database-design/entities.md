# Portfolio 1 — Entities and Relationships

Case study: CarePoint Specialist Clinic (3 branches in Lagos).

## 1. Entities and attributes

PK = primary key, FK = foreign key.

| # | Entity | Attributes | Notes |
|---|---|---|---|
| 1 | branch | branch_id (PK), name, address, phone | Ikeja, Lekki, Yaba |
| 2 | department | department_id (PK), branch_id (FK), name | e.g. Cardiology at Ikeja |
| 3 | doctor | doctor_id (PK), department_id (FK), full_name, specialty, licence_no, phone, email | licence_no must be unique |
| 4 | nurse | nurse_id (PK), department_id (FK), full_name, specialty, licence_no, phone, email | licence_no must be unique |
| 5 | patient | patient_id (PK), hospital_no, full_name, date_of_birth, gender, phone, address, next_of_kin, uses_hmo | hospital_no must be unique; uses_hmo is TRUE/FALSE, default FALSE |
| 6 | hmo_provider | hmo_id (PK), provider_name, phone, email | e.g. Hygeia, AXA Mansard, Reliance HMO |
| 7 | hmo_mapping | register_id (PK), hmo_id (FK), patient_id (FK), enrollee_no, start_date, end_date | links patients to their HMO; end_date empty = current |
| 8 | appointment | appointment_id (PK), patient_id (FK), doctor_id (FK), branch_id (FK), start_time, end_time, status | status: scheduled, completed, cancelled, no_show |
| 9 | consultation | consultation_id (PK), appointment_id (FK), symptoms, diagnosis, notes, created_at | only created when the patient is actually seen |
| 10 | vital_signs | vital_signs_id (PK), consultation_id (FK), nurse_id (FK), temp_celsius, bp_systolic, bp_diastolic, weight_kg, recorded_at | BP split into two columns (1NF) |
| 11 | prescription | prescription_id (PK), consultation_id (FK), issued_at | |
| 12 | drug | drug_id (PK), name, form, strength, unit_price | e.g. Paracetamol, tablet, 500mg |
| 13 | prescription_item | prescription_id (FK), drug_id (FK), quantity, dosage_instructions | junction table |
| 14 | drug_stock | branch_id (FK), drug_id (FK), quantity_on_hand, reorder_level | junction table: stock per branch |
| 15 | lab_test | lab_test_id (PK), name, sample_type, price | catalogue, e.g. Full Blood Count |
| 16 | lab_order | lab_order_id (PK), consultation_id (FK), lab_test_id (FK), status, result_value, result_date | junction table with extra data |
| 17 | invoice | invoice_id (PK), patient_id (FK), appointment_id (FK), issued_at, total_amount, status | status: unpaid, part_paid, paid |
| 18 | payment | payment_id (PK), invoice_id (FK), amount, method, paid_at | method: cash, card, transfer, HMO |

## 2. Relationships and cardinality

| # | Relationship | Cardinality | Reason |
|---|---|---|---|
| R1 | branch - department | 1:N | A branch has many departments; each department belongs to one branch. |
| R2 | department - doctor | 1:N | A department has many doctors; each doctor has one home department. |
| R3 | department - nurse | 1:N | A department has many nurses; each nurse belongs to one department. |
| R4 | patient - hmo_provider | M:N via hmo_mapping | An HMO covers many patients; a patient can be registered with different HMOs over time. |
| R5 | patient - appointment | 1:N | A patient can book many appointments; each appointment is for one patient. |
| R6 | doctor - appointment | 1:N | A doctor sees many appointments; each appointment is with one doctor. |
| R7 | branch - appointment | 1:N | A branch hosts many appointments; each appointment takes place at one branch. |
| R8 | appointment - consultation | 1:0..1 | An appointment produces at most one consultation, and none if cancelled or a no-show. |
| R9 | consultation - vital_signs | 1:N | Vitals can be taken more than once in a visit (e.g. BP re-checked). |
| R10 | nurse - vital_signs | 1:N | A nurse records many sets of vitals; each set is recorded by one nurse. |
| R11 | consultation - prescription | 1:0..1 | A consultation may lead to one prescription, or none. |
| R12 | prescription - drug | M:N via prescription_item | A prescription lists many drugs; a drug appears on many prescriptions. |
| R13 | branch - drug | M:N via drug_stock | Each branch stocks many drugs, each with its own quantity. |
| R14 | consultation - lab_test | M:N via lab_order | A consultation can order many tests; a test type is ordered in many consultations. |
| R15 | patient - invoice | 1:N | A patient receives many invoices over time; each invoice is for one patient. |
| R16 | appointment - invoice | 1:0..1 | Each visit is billed with at most one invoice. |
| R17 | invoice - payment | 1:N | An invoice can be paid in parts (e.g. part HMO, part cash). |

## 3. Design decisions

1. **branch_id on appointment.** Consultants rotate between branches, so a doctor's home department does not show where a particular appointment happens. The appointment must record its own branch.
2. **uses_hmo on patient (deliberate denormalisation).** This could be derived by checking hmo_mapping, but front-desk staff check it on every visit, so a simple TRUE/FALSE saves a join. Risk: the flag and hmo_mapping could disagree. Control: a trigger (Portfolio 3) will keep them in sync.
3. **hmo_mapping keeps history.** start_date and end_date record when a patient changes HMO, instead of overwriting the old one.
4. **BP stored as two numbers.** "120/80" in one column breaks 1NF and cannot be compared or averaged.
5. **vital_signs is separate from consultation.** Vitals can be taken several times per visit and are recorded by a nurse, not the doctor.
6. **drug_stock is separate from drug.** The same drug has a different quantity at each branch.
7. **lab_order stores the result.** The result belongs to one test for one consultation, not to the test type in general.
8. **payment is separate from invoice.** Patients often pay in parts or through an HMO.

## 4. Business rules

- A doctor cannot have two appointments starting at the same time.
- An appointment's end_time must be after its start_time.
- doctor.licence_no, nurse.licence_no and patient.hospital_no must be unique.
- Temperature must be between 30 and 45 °C; weight must be greater than 0.
- bp_systolic must be greater than bp_diastolic.
- An HMO registration's end_date, if present, must be after its start_date.
- Drug stock can never go below zero.
- A payment amount must be greater than zero.
- A patient with appointments cannot be deleted (the medical record must be kept).