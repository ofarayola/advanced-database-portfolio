"""
migrate_to_mongo.py
CarePoint Specialist Clinic - Portfolio 4 (NoSQL with MongoDB)

Reads the relational CarePoint data from PostgreSQL (schema "clinic") and
reshapes it into a document model in MongoDB (database "carepoint").

Collections created:
  branches   (3)       small reference collection
  lab_tests  (10)      small reference collection
  doctors    (~42)     department + home branch embedded
  drugs      (20)      stock for all 3 branches embedded as an array
  patients   (~20,000) HMO registration history embedded
  visits     (~60,000) one document per appointment, with consultation,
                       vital signs, lab orders (+ structured results),
                       prescription items, invoice and payments embedded

Usage (PowerShell, from the portfolio-4-nosql folder):
  $env:PGPASSWORD = "your_password"
  python migrate_to_mongo.py

Only the default _id index is created here. Extra indexes are added later
(queries session) so their effect can be measured with explain().
"""

import os
import random
from collections import defaultdict
from datetime import date, datetime
from decimal import Decimal

import psycopg2
from bson.decimal128 import Decimal128
from pymongo import MongoClient

PG = dict(host="localhost", port=5432, dbname="carepoint", user="postgres",
          password=os.environ.get("PGPASSWORD"))
MONGO_URI = "mongodb://localhost:27017"
MONGO_DB = "carepoint"
BATCH = 5000

random.seed(42)   # lab result values are reproducible


# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------
def money(value):
    """NUMERIC money -> Decimal128 (exact, no floating-point rounding)."""
    return Decimal128(Decimal(value)) if value is not None else None


def num(value):
    """NUMERIC measurement (temperature, weight) -> float."""
    return float(value) if value is not None else None


def to_dt(value):
    """MongoDB has no date-only type, so DATE becomes midnight datetime."""
    if isinstance(value, date) and not isinstance(value, datetime):
        return datetime(value.year, value.month, value.day)
    return value


def fetch(cur, sql):
    cur.execute(sql)
    cols = [c.name for c in cur.description]
    return [dict(zip(cols, row)) for row in cur.fetchall()]


def drop_none(d):
    """Leave out empty fields instead of storing null (documents stay lean)."""
    return {k: v for k, v in d.items() if v is not None}


def count_embedded(db, array_path):
    """Count items inside an embedded array across all visit documents."""
    result = list(db.visits.aggregate([
        {"$project": {"n": {"$size": {"$ifNull": [array_path, []]}}}},
        {"$group": {"_id": None, "total": {"$sum": "$n"}}},
    ]))
    return result[0]["total"] if result else 0


def insert_batches(collection, docs):
    for i in range(0, len(docs), BATCH):
        collection.insert_many(docs[i:i + BATCH], ordered=False)


# ---------------------------------------------------------------------
# Structured lab results
# In PostgreSQL every result is one TEXT value ("Normal", "Positive"...).
# Real results have a different shape for every test, which is where a
# document model is useful. The PostgreSQL value is kept as "summary" and
# the detailed values are simulated so they agree with it
# (normal summary -> values in the normal range).
# ---------------------------------------------------------------------
def lab_result(test_id, summary):
    normal = summary in ("Normal", "Negative")
    r = random.uniform
    if test_id == 1:   # Full Blood Count
        return {"hb_g_dl": round(r(12, 16) if normal else r(7, 11), 1),
                "wbc_x10e9_l": round(r(4, 11) if normal else r(11.5, 20), 1),
                "platelets_x10e9_l": int(r(150, 400) if normal else r(60, 140))}
    if test_id == 2:   # Malaria Parasite
        seen = not normal
        res = {"parasites_seen": seen}
        if seen:
            res["density_per_ul"] = int(r(500, 50000))
            res["species"] = "P. falciparum"
        return res
    if test_id == 3:   # Lipid Profile (mmol/L)
        return {"total_chol": round(r(3.5, 5.1) if normal else r(5.5, 7.5), 1),
                "hdl": round(r(1.0, 1.8) if normal else r(0.6, 0.95), 2),
                "ldl": round(r(1.8, 3.0) if normal else r(3.4, 5.0), 1),
                "triglycerides": round(r(0.6, 1.6) if normal else r(1.8, 3.5), 1)}
    if test_id == 4:   # Fasting Blood Sugar
        return {"glucose_mmol_l": round(r(3.9, 5.5) if normal else r(7.0, 14.0), 1)}
    if test_id == 5:   # HbA1c
        return {"hba1c_percent": round(r(4.5, 5.6) if normal else r(6.5, 10.5), 1)}
    if test_id == 6:   # Urinalysis (dipstick)
        bad = "+" if not normal else "negative"
        return {"protein": random.choice([bad, "negative"]),
                "glucose": "negative",
                "leukocytes": bad, "nitrite": random.choice([bad, "negative"])}
    if test_id == 7:   # Widal
        titre = random.choice(["1:40", "1:80"]) if normal else random.choice(["1:160", "1:320"])
        return {"o_titre": titre, "h_titre": random.choice(["1:40", "1:80", titre])}
    if test_id == 8:   # Liver Function Test
        return {"alt_u_l": int(r(7, 40) if normal else r(60, 200)),
                "ast_u_l": int(r(8, 40) if normal else r(55, 180)),
                "bilirubin_umol_l": round(r(3, 20) if normal else r(25, 60), 1)}
    if test_id == 9:   # Kidney Function
        return {"urea_mmol_l": round(r(2.5, 7.1) if normal else r(8, 20), 1),
                "creatinine_umol_l": int(r(60, 110) if normal else r(130, 400)),
                "sodium_mmol_l": int(r(135, 145)),
                "potassium_mmol_l": round(r(3.5, 5.0) if normal else r(5.3, 6.5), 1)}
    if test_id == 10:  # Chest X-Ray (report text + image reference, no numbers)
        return {"findings": "No active lung lesion" if normal
                else random.choice(["Right lower lobe consolidation",
                                    "Cardiomegaly", "Bilateral hilar prominence"]),
                "image_ref": f"xray/{random.randint(100000, 999999)}.dcm"}
    return {}


# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------
def main():
    pg = psycopg2.connect(**PG)
    cur = pg.cursor()
    cur.execute("SET search_path TO clinic")

    client = MongoClient(MONGO_URI)
    db = client[MONGO_DB]
    for name in ["branches", "lab_tests", "doctors", "drugs", "patients", "visits"]:
        db[name].drop()          # re-runnable, like DROP SCHEMA ... CASCADE

    # --- reference data --------------------------------------------------
    branches = {b["branch_id"]: b for b in fetch(cur, "SELECT * FROM branch")}
    db.branches.insert_many([
        {"_id": b["branch_id"], "name": b["name"], "address": b["address"],
         "phone": b["phone"]} for b in branches.values()])

    tests = {t["lab_test_id"]: t for t in fetch(cur, "SELECT * FROM lab_test")}
    db.lab_tests.insert_many([
        {"_id": t["lab_test_id"], "name": t["name"], "sample_type": t["sample_type"],
         "price": money(t["price"])} for t in tests.values()])

    depts = {d["department_id"]: d for d in fetch(cur, "SELECT * FROM department")}

    doctors = {d["doctor_id"]: d for d in fetch(cur, "SELECT * FROM doctor")}
    db.doctors.insert_many([drop_none({
        "_id": d["doctor_id"], "full_name": d["full_name"], "specialty": d["specialty"],
        "licence_no": d["licence_no"], "phone": d["phone"], "email": d["email"],
        "department": depts[d["department_id"]]["name"],
        "home_branch": {"branch_id": depts[d["department_id"]]["branch_id"],
                        "name": branches[depts[d["department_id"]]["branch_id"]]["name"]},
    }) for d in doctors.values()])

    nurses = {n["nurse_id"]: n for n in fetch(cur, "SELECT nurse_id, full_name FROM nurse")}

    # --- drugs with embedded stock --------------------------------------
    stock = defaultdict(list)
    for s in fetch(cur, "SELECT * FROM drug_stock ORDER BY branch_id"):
        stock[s["drug_id"]].append({
            "branch_id": s["branch_id"], "branch": branches[s["branch_id"]]["name"],
            "quantity_on_hand": s["quantity_on_hand"], "reorder_level": s["reorder_level"]})
    drugs = {d["drug_id"]: d for d in fetch(cur, "SELECT * FROM drug")}
    db.drugs.insert_many([{
        "_id": d["drug_id"], "name": d["name"], "form": d["form"],
        "strength": d["strength"], "unit_price": money(d["unit_price"]),
        "stock": stock[d["drug_id"]]} for d in drugs.values()])
    print(f"reference data: {len(branches)} branches, {len(tests)} lab tests, "
          f"{len(doctors)} doctors, {len(drugs)} drugs")

    # --- patients with embedded HMO history -----------------------------
    hmos = {h["hmo_id"]: h["provider_name"] for h in fetch(cur, "SELECT * FROM hmo_provider")}
    hmo_hist = defaultdict(list)
    for m in fetch(cur, "SELECT * FROM hmo_mapping ORDER BY start_date"):
        hmo_hist[m["patient_id"]].append(drop_none({
            "hmo_id": m["hmo_id"], "provider": hmos[m["hmo_id"]],
            "enrollee_no": m["enrollee_no"], "start_date": to_dt(m["start_date"]),
            "end_date": to_dt(m["end_date"])}))

    patient_docs, patients = [], {}
    for p in fetch(cur, "SELECT * FROM patient ORDER BY patient_id"):
        patients[p["patient_id"]] = p
        doc = drop_none({
            "_id": p["patient_id"], "hospital_no": p["hospital_no"],
            "full_name": p["full_name"], "date_of_birth": to_dt(p["date_of_birth"]),
            "gender": p["gender"], "phone": p["phone"], "address": p["address"],
            "next_of_kin": p["next_of_kin"]})
        if hmo_hist[p["patient_id"]]:
            doc["hmo_history"] = hmo_hist[p["patient_id"]]
        patient_docs.append(doc)
    insert_batches(db.patients, patient_docs)
    print(f"patients: {len(patient_docs)}")

    # --- child rows of a visit, grouped by parent id --------------------
    vitals = defaultdict(list)
    for v in fetch(cur, "SELECT * FROM vital_signs ORDER BY recorded_at"):
        vitals[v["consultation_id"]].append(drop_none({
            "nurse": {"nurse_id": v["nurse_id"],
                      "full_name": nurses[v["nurse_id"]]["full_name"]},
            "temp_celsius": num(v["temp_celsius"]),
            "bp": {"systolic": v["bp_systolic"], "diastolic": v["bp_diastolic"]},
            "weight_kg": num(v["weight_kg"]), "recorded_at": v["recorded_at"]}))

    labs = defaultdict(list)
    for o in fetch(cur, "SELECT * FROM lab_order ORDER BY lab_order_id"):
        t = tests[o["lab_test_id"]]
        lab = drop_none({
            "lab_order_id": o["lab_order_id"],
            "test": {"lab_test_id": t["lab_test_id"], "name": t["name"],
                     "sample_type": t["sample_type"]},
            "price": money(t["price"]), "status": o["status"],
            "result_date": o["result_date"]})
        if o["status"] == "completed":
            lab["result"] = {"summary": o["result_value"],
                             **lab_result(o["lab_test_id"], o["result_value"])}
        labs[o["consultation_id"]].append(lab)

    items = defaultdict(list)
    for i in fetch(cur, "SELECT * FROM prescription_item ORDER BY prescription_id, drug_id"):
        d = drugs[i["drug_id"]]
        items[i["prescription_id"]].append(drop_none({
            "drug_id": d["drug_id"], "name": d["name"], "strength": d["strength"],
            "quantity": i["quantity"], "dosage_instructions": i["dosage_instructions"]}))
    prescriptions = {p["consultation_id"]: p for p in fetch(cur, "SELECT * FROM prescription")}
    consultations = {c["appointment_id"]: c for c in fetch(cur, "SELECT * FROM consultation")}

    payments = defaultdict(list)
    for p in fetch(cur, "SELECT * FROM payment ORDER BY paid_at"):
        payments[p["invoice_id"]].append({
            "payment_id": p["payment_id"], "amount": money(p["amount"]),
            "method": p["method"], "paid_at": p["paid_at"]})
    invoices = {i["appointment_id"]: i for i in fetch(cur, "SELECT * FROM invoice")}

    # --- visits ---------------------------------------------------------
    visit_docs = []
    for a in fetch(cur, "SELECT * FROM appointment ORDER BY appointment_id"):
        p, d = patients[a["patient_id"]], doctors[a["doctor_id"]]
        doc = {
            "_id": a["appointment_id"],
            # extended references: copy the fields that are always displayed
            "patient": {"patient_id": p["patient_id"], "hospital_no": p["hospital_no"],
                        "full_name": p["full_name"]},
            "doctor": {"doctor_id": d["doctor_id"], "full_name": d["full_name"],
                       "specialty": d["specialty"]},
            "branch": {"branch_id": a["branch_id"], "name": branches[a["branch_id"]]["name"]},
            "start_time": a["start_time"], "end_time": a["end_time"],
            "status": a["status"],
        }
        c = consultations.get(a["appointment_id"])
        if c:
            cons = drop_none({"consultation_id": c["consultation_id"],
                              "symptoms": c["symptoms"], "diagnosis": c["diagnosis"],
                              "notes": c["notes"], "created_at": c["created_at"]})
            if vitals[c["consultation_id"]]:
                cons["vital_signs"] = vitals[c["consultation_id"]]
            if labs[c["consultation_id"]]:
                cons["lab_orders"] = labs[c["consultation_id"]]
            rx = prescriptions.get(c["consultation_id"])
            if rx:
                cons["prescription"] = {"prescription_id": rx["prescription_id"],
                                        "issued_at": rx["issued_at"],
                                        "items": items[rx["prescription_id"]]}
            doc["consultation"] = cons
        inv = invoices.get(a["appointment_id"])
        if inv:
            doc["invoice"] = {"invoice_id": inv["invoice_id"],
                              "issued_at": inv["issued_at"],
                              "total_amount": money(inv["total_amount"]),
                              "status": inv["status"],
                              "payments": payments[inv["invoice_id"]]}
        visit_docs.append(doc)
    insert_batches(db.visits, visit_docs)
    print(f"visits: {len(visit_docs)}")

    # --- verification: counts must match PostgreSQL ----------------------
    print("\nVerification (PostgreSQL vs MongoDB)")
    checks = [
        ("patients",      "SELECT count(*) FROM patient",
         db.patients.count_documents({})),
        ("appointments",  "SELECT count(*) FROM appointment",
         db.visits.count_documents({})),
        ("consultations", "SELECT count(*) FROM consultation",
         db.visits.count_documents({"consultation": {"$exists": True}})),
        ("invoices",      "SELECT count(*) FROM invoice",
         db.visits.count_documents({"invoice": {"$exists": True}})),
        ("lab orders",    "SELECT count(*) FROM lab_order",
         count_embedded(db, "$consultation.lab_orders")),
        ("payments",      "SELECT count(*) FROM payment",
         count_embedded(db, "$invoice.payments")),
    ]
    for label, sql, mongo_count in checks:
        cur.execute(sql)
        pg_count = cur.fetchone()[0]
        flag = "OK" if pg_count == mongo_count else "MISMATCH"
        print(f"  {label:<14} postgres={pg_count:>6}  mongo={mongo_count:>6}  {flag}")

    cur.close()
    pg.close()
    client.close()


if __name__ == "__main__":
    main()