-- =====================================================================
-- CarePoint Specialist Clinic - Relational Schema (PostgreSQL)
-- MIT 8103 Advanced Database Systems - Portfolio 1
-- Run: psql -U postgres -d carepoint -f portfolio-1-database-design/schema.sql
-- =====================================================================

-- Start fresh each time the script runs (deletes the old clinic schema)
DROP SCHEMA IF EXISTS clinic CASCADE;
CREATE SCHEMA clinic;
SET search_path TO clinic;

-- ---------------------------------------------------------------------
-- 1. ORGANISATION
-- ---------------------------------------------------------------------
CREATE TABLE branch (
    branch_id   SERIAL PRIMARY KEY,
    name        VARCHAR(50)  NOT NULL UNIQUE,
    address     VARCHAR(200) NOT NULL,
    phone       VARCHAR(20)
);

CREATE TABLE department (
    department_id SERIAL PRIMARY KEY,
    branch_id     INT NOT NULL REFERENCES branch(branch_id) ON DELETE RESTRICT,
    name          VARCHAR(50) NOT NULL,
    CONSTRAINT uq_department_per_branch UNIQUE (branch_id, name)
);

CREATE TABLE doctor (
    doctor_id     SERIAL PRIMARY KEY,
    department_id INT NOT NULL REFERENCES department(department_id) ON DELETE RESTRICT,
    full_name     VARCHAR(100) NOT NULL,
    specialty     VARCHAR(50),
    licence_no    VARCHAR(30)  NOT NULL UNIQUE,
    phone         VARCHAR(20),
    email         VARCHAR(100) UNIQUE
);

CREATE TABLE nurse (
    nurse_id      SERIAL PRIMARY KEY,
    department_id INT NOT NULL REFERENCES department(department_id) ON DELETE RESTRICT,
    full_name     VARCHAR(100) NOT NULL,
    specialty     VARCHAR(50),
    licence_no    VARCHAR(30)  NOT NULL UNIQUE,
    phone         VARCHAR(20),
    email         VARCHAR(100) UNIQUE
);

-- ---------------------------------------------------------------------
-- 2. PATIENTS AND HMO
-- ---------------------------------------------------------------------
CREATE TABLE patient (
    patient_id    SERIAL PRIMARY KEY,
    hospital_no   VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL,
    date_of_birth DATE NOT NULL,
    gender        CHAR(1),
    phone         VARCHAR(20),
    address       VARCHAR(200),
    next_of_kin   VARCHAR(100),
    CONSTRAINT chk_patient_gender CHECK (gender IN ('M', 'F')),
    CONSTRAINT chk_patient_dob    CHECK (date_of_birth <= CURRENT_DATE)
);

CREATE TABLE hmo_provider (
    hmo_id        SERIAL PRIMARY KEY,
    provider_name VARCHAR(100) NOT NULL UNIQUE,
    phone         VARCHAR(20),
    email         VARCHAR(100)
);

CREATE TABLE hmo_mapping (
    register_id SERIAL PRIMARY KEY,
    hmo_id      INT NOT NULL REFERENCES hmo_provider(hmo_id) ON DELETE RESTRICT,
    patient_id  INT NOT NULL REFERENCES patient(patient_id)  ON DELETE RESTRICT,
    enrollee_no VARCHAR(30) NOT NULL,
    start_date  DATE NOT NULL DEFAULT CURRENT_DATE,
    end_date    DATE,                                   -- NULL = currently active
    CONSTRAINT uq_hmo_enrollee     UNIQUE (hmo_id, enrollee_no),
    CONSTRAINT chk_hmo_dates       CHECK (end_date IS NULL OR end_date > start_date)
);

-- Business rule: a patient can have only ONE active HMO (end_date IS NULL).
-- A partial unique index applies the UNIQUE rule only to rows matching the WHERE.
CREATE UNIQUE INDEX uq_one_active_hmo_per_patient
    ON hmo_mapping (patient_id)
    WHERE end_date IS NULL;

-- ---------------------------------------------------------------------
-- 3. CLINICAL
-- ---------------------------------------------------------------------
CREATE TABLE appointment (
    appointment_id SERIAL PRIMARY KEY,
    patient_id     INT NOT NULL REFERENCES patient(patient_id) ON DELETE RESTRICT,
    doctor_id      INT NOT NULL REFERENCES doctor(doctor_id)   ON DELETE RESTRICT,
    branch_id      INT NOT NULL REFERENCES branch(branch_id)   ON DELETE RESTRICT,
    start_time     TIMESTAMP NOT NULL,
    end_time       TIMESTAMP NOT NULL,
    status         VARCHAR(15) NOT NULL DEFAULT 'scheduled',
    CONSTRAINT chk_appt_status CHECK (status IN ('scheduled', 'completed', 'cancelled', 'no_show')),
    CONSTRAINT chk_appt_time   CHECK (end_time > start_time),
    CONSTRAINT uq_doctor_slot  UNIQUE (doctor_id, start_time)   -- no double-booking
);

CREATE TABLE consultation (
    consultation_id SERIAL PRIMARY KEY,
    appointment_id  INT NOT NULL UNIQUE                          -- UNIQUE makes it 1:1
                    REFERENCES appointment(appointment_id) ON DELETE RESTRICT,
    symptoms        TEXT,
    diagnosis       TEXT,
    notes           TEXT,
    created_at      TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE vital_signs (
    vital_signs_id  SERIAL PRIMARY KEY,
    consultation_id INT NOT NULL REFERENCES consultation(consultation_id) ON DELETE CASCADE,
    nurse_id        INT NOT NULL REFERENCES nurse(nurse_id) ON DELETE RESTRICT,
    temp_celsius    NUMERIC(4,1),
    bp_systolic     INT,
    bp_diastolic    INT,
    weight_kg       NUMERIC(5,1),
    recorded_at     TIMESTAMP NOT NULL DEFAULT now(),
    CONSTRAINT chk_temp   CHECK (temp_celsius BETWEEN 30 AND 45),
    CONSTRAINT chk_weight CHECK (weight_kg > 0),
    CONSTRAINT chk_bp     CHECK (bp_systolic > bp_diastolic)
);

CREATE TABLE lab_test (
    lab_test_id SERIAL PRIMARY KEY,
    name        VARCHAR(100) NOT NULL UNIQUE,
    sample_type VARCHAR(30),
    price       NUMERIC(10,2) NOT NULL,
    CONSTRAINT chk_lab_price CHECK (price >= 0)
);

CREATE TABLE lab_order (
    lab_order_id    SERIAL PRIMARY KEY,
    consultation_id INT NOT NULL REFERENCES consultation(consultation_id) ON DELETE RESTRICT,
    lab_test_id     INT NOT NULL REFERENCES lab_test(lab_test_id)         ON DELETE RESTRICT,
    status          VARCHAR(20) NOT NULL DEFAULT 'ordered',
    result_value    TEXT,
    result_date     TIMESTAMP,
    CONSTRAINT chk_lab_status CHECK (status IN ('ordered', 'sample_collected', 'completed', 'cancelled')),
    -- a completed test must have a result
    CONSTRAINT chk_lab_result CHECK (status <> 'completed' OR result_value IS NOT NULL)
);

-- ---------------------------------------------------------------------
-- 4. PHARMACY
-- ---------------------------------------------------------------------
CREATE TABLE drug (
    drug_id    SERIAL PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    form       VARCHAR(30),                 -- tablet, syrup, injection...
    strength   VARCHAR(30),                 -- e.g. 500mg
    unit_price NUMERIC(10,2) NOT NULL,
    CONSTRAINT uq_drug       UNIQUE (name, form, strength),
    CONSTRAINT chk_drug_price CHECK (unit_price >= 0)
);

CREATE TABLE prescription (
    prescription_id SERIAL PRIMARY KEY,
    consultation_id INT NOT NULL UNIQUE                          -- 1:1 with consultation
                    REFERENCES consultation(consultation_id) ON DELETE RESTRICT,
    issued_at       TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE prescription_item (                 -- junction: prescription M:N drug
    prescription_id     INT NOT NULL REFERENCES prescription(prescription_id) ON DELETE CASCADE,
    drug_id             INT NOT NULL REFERENCES drug(drug_id) ON DELETE RESTRICT,
    quantity            INT NOT NULL,
    dosage_instructions VARCHAR(200),
    PRIMARY KEY (prescription_id, drug_id),      -- composite primary key
    CONSTRAINT chk_item_qty CHECK (quantity > 0)
);

CREATE TABLE drug_stock (                        -- junction: branch M:N drug
    branch_id        INT NOT NULL REFERENCES branch(branch_id) ON DELETE RESTRICT,
    drug_id          INT NOT NULL REFERENCES drug(drug_id)     ON DELETE RESTRICT,
    quantity_on_hand INT NOT NULL DEFAULT 0,
    reorder_level    INT NOT NULL DEFAULT 10,
    PRIMARY KEY (branch_id, drug_id),
    CONSTRAINT chk_stock_not_negative CHECK (quantity_on_hand >= 0),
    CONSTRAINT chk_reorder_level      CHECK (reorder_level >= 0)
);

-- ---------------------------------------------------------------------
-- 5. BILLING
-- ---------------------------------------------------------------------
CREATE TABLE invoice (
    invoice_id     SERIAL PRIMARY KEY,
    patient_id     INT NOT NULL REFERENCES patient(patient_id) ON DELETE RESTRICT,
    appointment_id INT UNIQUE REFERENCES appointment(appointment_id) ON DELETE RESTRICT,
    issued_at      TIMESTAMP NOT NULL DEFAULT now(),
    total_amount   NUMERIC(12,2) NOT NULL DEFAULT 0,
    status         VARCHAR(10) NOT NULL DEFAULT 'unpaid',
    CONSTRAINT chk_invoice_total  CHECK (total_amount >= 0),
    CONSTRAINT chk_invoice_status CHECK (status IN ('unpaid', 'part_paid', 'paid'))
);

CREATE TABLE payment (
    payment_id SERIAL PRIMARY KEY,
    invoice_id INT NOT NULL REFERENCES invoice(invoice_id) ON DELETE RESTRICT,
    amount     NUMERIC(12,2) NOT NULL,
    method     VARCHAR(10) NOT NULL,
    paid_at    TIMESTAMP NOT NULL DEFAULT now(),
    CONSTRAINT chk_payment_amount CHECK (amount > 0),
    CONSTRAINT chk_payment_method CHECK (method IN ('cash', 'card', 'transfer', 'hmo'))
);

-- ---------------------------------------------------------------------
-- 6. VIEW: HMO status calculated from hmo_mapping (not stored)
-- ---------------------------------------------------------------------
CREATE VIEW patient_hmo_status AS
SELECT p.patient_id,
       p.full_name,
       EXISTS (
           SELECT 1
           FROM hmo_mapping m
           WHERE m.patient_id = p.patient_id
             AND m.end_date IS NULL
       ) AS uses_hmo
FROM patient p;