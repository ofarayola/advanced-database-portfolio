"""
CarePoint Specialist Clinic - large test data generator (Portfolio 2)

Fills the clinic schema with realistic volumes so query plans and indexes
show measurable differences:
  ~20,000 patients, ~60,000 appointments, ~40,000 consultations, plus
  vitals, lab orders, prescriptions, invoices and payments.

Run from the repo root:
    python portfolio-2-query-optimisation/generate_data.py

WARNING: this deletes all existing data in the clinic schema first.
"""

import os
import random
import getpass
from datetime import date, datetime, timedelta

import psycopg2
from psycopg2.extras import execute_values
from faker import Faker

# ---------------------------------------------------------------------
# 0. Settings
# ---------------------------------------------------------------------
NUM_PATIENTS = 20_000
NUM_APPOINTMENTS = 60_000
START_DATE = date(2024, 1, 1)      # first appointment date
END_DATE = date(2026, 12, 31)      # last appointment date
TODAY = date(2026, 10, 8)          # appointments after this are "scheduled"

random.seed(42)                    # same "random" data every run (reproducible)
fake = Faker("en_NG")              # Nigerian-style names
Faker.seed(42)

DB = dict(
    dbname="carepoint",
    user="postgres",
    host=os.environ.get("PGHOST", "localhost"),
    password=os.environ.get("PGPASSWORD") or getpass.getpass("PostgreSQL password: "),
)


def phone():
    return f"080{random.randint(0, 9)} {random.randint(100, 999)} {random.randint(1000, 9999)}"


def insert(cur, table, columns, rows):
    """Insert many rows at once (much faster than one INSERT per row)."""
    sql = f"INSERT INTO {table} ({', '.join(columns)}) VALUES %s"
    execute_values(cur, sql, rows, page_size=5000)
    print(f"  {table:<18} {len(rows):>7,} rows")


# ---------------------------------------------------------------------
# 1. Reference data: branches, departments, staff, HMOs, tests, drugs
# ---------------------------------------------------------------------
def build_reference():
    branches = [
        (1, "Ikeja", "12 Allen Avenue, Ikeja, Lagos", "0801 000 0001"),
        (2, "Lekki", "5 Admiralty Way, Lekki Phase 1, Lagos", "0801 000 0002"),
        (3, "Yaba", "40 Herbert Macaulay Way, Yaba, Lagos", "0801 000 0003"),
    ]
    dept_names = ["General Medicine", "Cardiology", "Paediatrics", "Obstetrics & Gynaecology"]
    specialty = {"General Medicine": "General Practice", "Cardiology": "Cardiology",
                 "Paediatrics": "Paediatrics", "Obstetrics & Gynaecology": "O&G"}

    departments, dept_branch, dept_name = [], {}, {}
    did = 0
    for b in branches:
        for name in dept_names:
            did += 1
            departments.append((did, b[0], name))
            dept_branch[did] = b[0]
            dept_name[did] = name

    # Doctors: General Medicine is busiest, so it gets more doctors
    doctors, doctor_branch = [], {}
    doc_id = 0
    for d_id, b_id, name in departments:
        count = 5 if name == "General Medicine" else 3
        for _ in range(count):
            doc_id += 1
            doctors.append((doc_id, d_id, "Dr. " + fake.name(), specialty[name],
                            f"MDCN-{10000 + doc_id}", phone(),
                            f"doctor{doc_id}@carepoint.ng"))
            doctor_branch[doc_id] = b_id

    nurses, nurses_by_branch = [], {1: [], 2: [], 3: []}
    n_id = 0
    for d_id, b_id, name in departments:
        for _ in range(4):
            n_id += 1
            nurses.append((n_id, d_id, "Nurse " + fake.name(), name,
                           f"NMCN-{20000 + n_id}", phone(), f"nurse{n_id}@carepoint.ng"))
            nurses_by_branch[b_id].append(n_id)

    hmos = [
        (1, "Hygeia HMO", "0700 000 1111", "care@hygeia.example"),
        (2, "AXA Mansard Health", "0700 000 2222", "care@axa.example"),
        (3, "Reliance HMO", "0700 000 3333", "care@reliance.example"),
        (4, "Leadway Health", "0700 000 4444", "care@leadway.example"),
        (5, "Avon HMO", "0700 000 5555", "care@avon.example"),
        (6, "NHIA (Government)", "0700 000 6666", "care@nhia.example"),
    ]

    lab_tests = [
        (1, "Full Blood Count", "Blood", 8000), (2, "Malaria Parasite (MP)", "Blood", 3500),
        (3, "Lipid Profile", "Blood", 12000), (4, "Fasting Blood Sugar", "Blood", 3000),
        (5, "HbA1c", "Blood", 9000), (6, "Urinalysis", "Urine", 2500),
        (7, "Widal Test", "Blood", 3000), (8, "Liver Function Test", "Blood", 11000),
        (9, "Kidney Function (E/U/Cr)", "Blood", 10000), (10, "Chest X-Ray", "Imaging", 15000),
    ]

    drugs = [
        (1, "Paracetamol", "tablet", "500mg", 50), (2, "Amlodipine", "tablet", "5mg", 120),
        (3, "Artemether/Lumefantrine", "tablet", "20/120mg", 200), (4, "Amoxicillin", "capsule", "500mg", 80),
        (5, "Metformin", "tablet", "500mg", 60), (6, "Lisinopril", "tablet", "10mg", 150),
        (7, "Ibuprofen", "tablet", "400mg", 40), (8, "Ciprofloxacin", "tablet", "500mg", 120),
        (9, "Omeprazole", "capsule", "20mg", 90), (10, "Vitamin C", "tablet", "100mg", 20),
        (11, "Folic Acid", "tablet", "5mg", 15), (12, "Ferrous Sulphate", "tablet", "200mg", 25),
        (13, "Salbutamol", "inhaler", "100mcg", 2500), (14, "Cetirizine", "tablet", "10mg", 35),
        (15, "Metronidazole", "tablet", "400mg", 45), (16, "Losartan", "tablet", "50mg", 180),
        (17, "ORS", "sachet", "20.5g", 100), (18, "Zinc", "tablet", "20mg", 30),
        (19, "Ceftriaxone", "injection", "1g", 1500), (20, "Diclofenac", "tablet", "50mg", 40),
    ]
    return (branches, departments, dept_branch, dept_name, doctors, doctor_branch,
            nurses, nurses_by_branch, hmos, lab_tests, drugs)


# ---------------------------------------------------------------------
# 2. Patients and HMO registrations
# ---------------------------------------------------------------------
def build_patients():
    patients = []
    for pid in range(1, NUM_PATIENTS + 1):
        gender = random.choice("MF")
        name = fake.name_male() if gender == "M" else fake.name_female()
        dob = date(1940, 1, 1) + timedelta(days=random.randint(0, 30_500))   # ~1940-2023
        patients.append((pid, f"CP-{pid:06d}", name, dob, gender, phone(),
                         random.choice(["Surulere", "Ikeja", "Yaba", "Lekki", "Ajah",
                                        "Ikorodu", "Festac", "Gbagada", "Maryland", "Ikoyi"]) + ", Lagos",
                         fake.name()))

    mappings, rid = [], 0
    for pid in range(1, NUM_PATIENTS + 1):
        if random.random() < 0.40:                     # 40% of patients use an HMO
            hmo = random.randint(1, 6)
            if random.random() < 0.15:                 # some changed HMO: keep the old one as history
                rid += 1
                old = random.choice([h for h in range(1, 7) if h != hmo])
                mappings.append((rid, old, pid, f"H{old}-{pid:06d}-A", date(2021, 1, 1), date(2023, 12, 31)))
            rid += 1
            mappings.append((rid, hmo, pid, f"H{hmo}-{pid:06d}-B", date(2024, 1, 1), None))
    return patients, mappings


# ---------------------------------------------------------------------
# 3. Appointments (no doctor double-booked: uq_doctor_slot)
# ---------------------------------------------------------------------
def build_appointments(doctors, doctor_branch):
    days = (END_DATE - START_DATE).days
    doctor_ids = [d[0] for d in doctors]
    # some doctors are busier than others (more realistic, and skews the data)
    weights = [random.uniform(0.5, 2.0) for _ in doctor_ids]
    used_slots = set()
    appts = []
    aid = 0
    while aid < NUM_APPOINTMENTS:
        doc = random.choices(doctor_ids, weights)[0]
        day = START_DATE + timedelta(days=random.randint(0, days))
        if day.weekday() == 6:                         # clinic closed on Sundays
            continue
        slot = random.randint(0, 15)                   # 16 half-hour slots, 08:00-16:00
        start = datetime(day.year, day.month, day.day, 8) + timedelta(minutes=30 * slot)
        if (doc, start) in used_slots:                 # slot taken: try again
            continue
        used_slots.add((doc, start))
        aid += 1
        branch = doctor_branch[doc]
        if random.random() < 0.10:                     # 10% rotation to another branch
            branch = random.choice([b for b in (1, 2, 3) if b != branch])
        if day > TODAY:
            status = "scheduled"
        else:
            status = random.choices(["completed", "cancelled", "no_show"], [0.75, 0.10, 0.15])[0]
        patient = random.randint(1, NUM_PATIENTS)
        appts.append((aid, patient, doc, branch, start, start + timedelta(minutes=30), status))
    return appts


# ---------------------------------------------------------------------
# 4. Clinical records, pharmacy and billing for completed appointments
# ---------------------------------------------------------------------
DIAGNOSES = [
    ("Fever, headache, body pains", "Malaria"),
    ("Headache, dizziness", "Hypertension"),
    ("Frequent urination, thirst", "Type 2 Diabetes"),
    ("Cough, sore throat", "Upper Respiratory Tract Infection"),
    ("Fever, abdominal pain", "Typhoid Fever"),
    ("Burning urination", "Urinary Tract Infection"),
    ("Heartburn, upper abdominal pain", "Peptic Ulcer Disease"),
    ("Diarrhoea, vomiting", "Gastroenteritis"),
    ("Wheezing, shortness of breath", "Asthma"),
    ("Routine check", "Routine Antenatal Visit"),
    ("Joint pain", "Osteoarthritis"),
    ("Tiredness, pallor", "Anaemia"),
]
# diagnosis -> (likely lab tests, likely drugs)
TREATMENT = {
    "Malaria": ([2, 1], [3, 1]), "Hypertension": ([3, 9], [2, 6, 16]),
    "Type 2 Diabetes": ([4, 5], [5]), "Upper Respiratory Tract Infection": ([1], [4, 14, 1]),
    "Typhoid Fever": ([7, 1], [8, 1]), "Urinary Tract Infection": ([6], [8]),
    "Peptic Ulcer Disease": ([1], [9]), "Gastroenteritis": ([1], [17, 18, 15]),
    "Asthma": ([10], [13]), "Routine Antenatal Visit": ([1, 6], [11, 12]),
    "Osteoarthritis": ([], [7, 20]), "Anaemia": ([1], [12, 11, 10]),
}
CONSULT_FEE = 10_000


def build_clinical(appts, nurses_by_branch, lab_tests, drugs, active_hmo):
    lab_price = {t[0]: t[3] for t in lab_tests}
    drug_price = {d[0]: d[4] for d in drugs}
    consults, vitals, lab_orders, prescriptions, items, invoices, payments = [], [], [], [], [], [], []
    cid = vid = lid = rx = inv = pay = 0

    for aid, patient, doc, branch, start, end, status in appts:
        if status != "completed":
            continue
        cid += 1
        symptoms, diagnosis = random.choice(DIAGNOSES)
        seen = start + timedelta(minutes=5)
        consults.append((cid, aid, symptoms, diagnosis, None, seen))

        # vital signs (sometimes re-checked)
        for _ in range(2 if random.random() < 0.10 else 1):
            vid += 1
            sys_bp = random.randint(95, 185)
            dia_bp = sys_bp - random.randint(30, 60)
            vitals.append((vid, cid, random.choice(nurses_by_branch[branch]),
                           round(random.uniform(35.8, 39.8), 1), sys_bp, dia_bp,
                           round(random.uniform(10, 110), 1), start))

        bill = CONSULT_FEE
        tests, meds = TREATMENT[diagnosis]

        # lab orders
        for t in tests:
            if random.random() < 0.6:
                lid += 1
                recent = start.date() > TODAY - timedelta(days=3)
                if recent:
                    lab_orders.append((lid, cid, t, "ordered", None, None))
                else:
                    result = random.choice(["Normal", "Abnormal - see notes", "Positive", "Negative"])
                    lab_orders.append((lid, cid, t, "completed", result, start + timedelta(hours=random.randint(2, 48))))
                bill += lab_price[t]

        # prescription
        if meds and random.random() < 0.85:
            rx += 1
            prescriptions.append((rx, cid, seen + timedelta(minutes=15)))
            for d in random.sample(meds, k=random.randint(1, len(meds))):
                qty = random.choice([10, 14, 20, 24, 28, 30])
                items.append((rx, d, qty, "As directed by the doctor"))
                bill += drug_price[d] * qty

        # invoice and payment(s)
        inv += 1
        r = random.random()
        inv_status = "paid" if r < 0.80 else ("part_paid" if r < 0.95 else "unpaid")
        invoices.append((inv, patient, aid, end, bill, inv_status))
        if inv_status != "unpaid":
            method = "hmo" if patient in active_hmo else random.choice(["cash", "card", "transfer"])
            amount = bill if inv_status == "paid" else round(bill * random.uniform(0.3, 0.8), 2)
            pay += 1
            payments.append((pay, inv, amount, method, end + timedelta(minutes=random.randint(5, 120))))

    return consults, vitals, lab_orders, prescriptions, items, invoices, payments


# ---------------------------------------------------------------------
# 5. Main: clear old data, insert everything, fix sequences
# ---------------------------------------------------------------------
def main():
    print("Building data in Python...")
    (branches, departments, dept_branch, dept_name, doctors, doctor_branch,
     nurses, nurses_by_branch, hmos, lab_tests, drugs) = build_reference()
    patients, mappings = build_patients()
    active_hmo = {m[2] for m in mappings if m[5] is None}
    appts = build_appointments(doctors, doctor_branch)
    consults, vitals, lab_orders, prescriptions, items, invoices, payments = \
        build_clinical(appts, nurses_by_branch, lab_tests, drugs, active_hmo)
    stock = [(b[0], d[0], random.randint(200, 5000), 100) for b in branches for d in drugs]

    print("Connecting to PostgreSQL...")
    conn = psycopg2.connect(**DB)
    cur = conn.cursor()
    cur.execute("SET search_path TO clinic")
    cur.execute("TRUNCATE branch, patient, hmo_provider, lab_test, drug RESTART IDENTITY CASCADE")

    print("Inserting:")
    insert(cur, "branch", ["branch_id", "name", "address", "phone"], branches)
    insert(cur, "department", ["department_id", "branch_id", "name"], departments)
    insert(cur, "doctor", ["doctor_id", "department_id", "full_name", "specialty", "licence_no", "phone", "email"], doctors)
    insert(cur, "nurse", ["nurse_id", "department_id", "full_name", "specialty", "licence_no", "phone", "email"], nurses)
    insert(cur, "hmo_provider", ["hmo_id", "provider_name", "phone", "email"], hmos)
    insert(cur, "patient", ["patient_id", "hospital_no", "full_name", "date_of_birth", "gender", "phone", "address", "next_of_kin"], patients)
    insert(cur, "hmo_mapping", ["register_id", "hmo_id", "patient_id", "enrollee_no", "start_date", "end_date"], mappings)
    insert(cur, "lab_test", ["lab_test_id", "name", "sample_type", "price"], lab_tests)
    insert(cur, "drug", ["drug_id", "name", "form", "strength", "unit_price"], drugs)
    insert(cur, "drug_stock", ["branch_id", "drug_id", "quantity_on_hand", "reorder_level"], stock)
    insert(cur, "appointment", ["appointment_id", "patient_id", "doctor_id", "branch_id", "start_time", "end_time", "status"], appts)
    insert(cur, "consultation", ["consultation_id", "appointment_id", "symptoms", "diagnosis", "notes", "created_at"], consults)
    insert(cur, "vital_signs", ["vital_signs_id", "consultation_id", "nurse_id", "temp_celsius", "bp_systolic", "bp_diastolic", "weight_kg", "recorded_at"], vitals)
    insert(cur, "lab_order", ["lab_order_id", "consultation_id", "lab_test_id", "status", "result_value", "result_date"], lab_orders)
    insert(cur, "prescription", ["prescription_id", "consultation_id", "issued_at"], prescriptions)
    insert(cur, "prescription_item", ["prescription_id", "drug_id", "quantity", "dosage_instructions"], items)
    insert(cur, "invoice", ["invoice_id", "patient_id", "appointment_id", "issued_at", "total_amount", "status"], invoices)
    insert(cur, "payment", ["payment_id", "invoice_id", "amount", "method", "paid_at"], payments)

    # We supplied the IDs ourselves, so move each SERIAL counter past the highest ID.
    # Otherwise the next normal INSERT would try to reuse ID 1 and fail.
    for table, col in [("branch", "branch_id"), ("department", "department_id"), ("doctor", "doctor_id"),
                       ("nurse", "nurse_id"), ("patient", "patient_id"), ("hmo_provider", "hmo_id"),
                       ("hmo_mapping", "register_id"), ("appointment", "appointment_id"),
                       ("consultation", "consultation_id"), ("vital_signs", "vital_signs_id"),
                       ("lab_test", "lab_test_id"), ("lab_order", "lab_order_id"), ("drug", "drug_id"),
                       ("prescription", "prescription_id"), ("invoice", "invoice_id"), ("payment", "payment_id")]:
        cur.execute(f"SELECT setval(pg_get_serial_sequence('clinic.{table}', '{col}'), (SELECT MAX({col}) FROM {table}))")

    conn.commit()
    cur.execute("ANALYZE")             # refresh statistics so the query planner knows the new table sizes
    conn.commit()
    conn.close()
    print("Done. Data committed and statistics updated.")


if __name__ == "__main__":
    main()
