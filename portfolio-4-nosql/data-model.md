# P4 Data Model: CarePoint in MongoDB

## 1. Goal

To redesign the CarePoint clinic database (Portfolio 1, 18 PostgreSQL tables) as a **document model** in MongoDB, load the same data, and compare the two approaches.

In a relational design, the main question is "how do I remove redundancy?" (normalisation). In a document design, the main question is **"how will the data be read?"** Data that is read together should be stored together.

## 2. Main access patterns (from the P2 queries)

| # | Who | What they need | Read or write |
|---|---|---|---|
| A1 | Front desk | A patient's details and visit history | Read (very frequent) |
| A2 | Doctor | One full visit: vitals, diagnosis, labs, prescription | Read (very frequent) |
| A3 | Doctor | Today's schedule at a branch | Read (frequent) |
| A4 | Lab | Pending lab orders; results for a test type | Read and write |
| A5 | Pharmacy | Stock of a drug at each branch; dispense (reduce stock) | Read and write (concurrent, as in P3) |
| A6 | Billing | Unpaid and part-paid invoices; record a payment | Read and write |
| A7 | Management | Visits, revenue and diagnoses per branch per month | Aggregation |

## 3. Collections

| Collection | Documents | Avg size | Contents |
|---|---|---|---|
| `visits` | 60,000 | ~965 bytes (max ~2 KB) | One per appointment, with consultation, vital signs, lab orders and results, prescription items, invoice and payments **embedded** |
| `patients` | 20,000 | ~244 bytes | Patient details with HMO registration history **embedded** |
| `drugs` | 20 | ~357 bytes | Drug details with stock for all 3 branches **embedded** |
| `doctors` | 42 | ~240 bytes | Doctor details with department and home branch embedded |
| `lab_tests` | 10 | ~86 bytes | Test catalogue and price |
| `branches` | 3 | ~103 bytes | Branch details |

18 tables became 6 collections. Junction and child tables (`prescription_item`, `lab_order`, `vital_signs`, `payment`, `hmo_mapping`, `drug_stock`) became **arrays inside their parent document**.

## 4. Example `visits` document (shortened)

```json
{
  "_id": 2,
  "patient": { "patient_id": 7713, "hospital_no": "CP-007713", "full_name": "..." },
  "doctor":  { "doctor_id": 12, "full_name": "Dr. ...", "specialty": "General Practice" },
  "branch":  { "branch_id": 1, "name": "Ikeja" },
  "start_time": "2025-06-24T15:00:00Z", "end_time": "...", "status": "completed",
  "consultation": {
    "consultation_id": 1, "symptoms": "...", "diagnosis": "Malaria",
    "vital_signs": [ { "nurse": {...}, "temp_celsius": 36.9,
                       "bp": { "systolic": 128, "diastolic": 98 }, "weight_kg": 71.8 } ],
    "lab_orders": [ { "test": { "lab_test_id": 1, "name": "Full Blood Count" },
                      "status": "completed",
                      "result": { "summary": "Normal", "hb_g_dl": 14.6,
                                  "wbc_x10e9_l": 4.2, "platelets_x10e9_l": 218 } } ],
    "prescription": { "prescription_id": 1,
                      "items": [ { "drug_id": 15, "name": "Metronidazole", "quantity": 20 } ] }
  },
  "invoice": { "invoice_id": 1, "total_amount": NumberDecimal("19740.00"), "status": "paid",
               "payments": [ { "payment_id": 1, "amount": NumberDecimal("19740.00"),
                               "method": "hmo" } ] }
}
```

A cancelled or no-show visit simply has **no** `consultation` or `invoice` field. Fields are left out instead of being stored as NULL.

## 5. Embed or reference? Decisions and reasons

| Relationship | Decision | Reason |
|---|---|---|
| Visit → consultation, vitals, lab orders, prescription items, invoice, payments | **Embed** | Always read together (A2), owned by one visit, small and bounded (a visit has a handful of each). One read returns the whole visit instead of joining 8 tables. |
| Patient → visits | **Reference** (`visits.patient.patient_id`) | Unbounded: a patient's visits keep growing for years, and MongoDB has a 16 MB document limit. Visits are also queried on their own (doctor schedules, branch reports). |
| Visit → patient, doctor, branch | **Extended reference**: copy `id` plus the fields always displayed (name, hospital no, specialty) | Lists of visits can show names without a lookup. The full record stays in its own collection. |
| Patient → HMO registrations | **Embed** (`hmo_history` array) | Few per patient (1–3), always shown with the patient, and history is kept with `end_date`, as in P1. |
| Drug → stock per branch | **Embed** (`stock` array, 3 entries) | Fixed size (3 branches). Lets dispensing be **one atomic update on one document** (see section 7). |
| Lab test, branch, doctor catalogues | **Separate collections** | Shared by many visits and changed independently. |

## 6. Flexible lab results (why a document model helps here)

In PostgreSQL, every result is a single TEXT column (`result_value`: "Normal", "Positive" …), because each test has different fields. A Full Blood Count has Hb, WBC and platelets; a Lipid Profile has four cholesterol values; a Chest X-ray has a text report and an image reference. A relational design would need either one table per test type or an Entity–Attribute–Value table, and both are awkward to query.

In MongoDB, each `result` sub-document has **its own shape** (polymorphic pattern), and the values can still be queried directly, for example "all FBCs with Hb below 10":

| Test | Result fields |
|---|---|
| Full Blood Count | `hb_g_dl`, `wbc_x10e9_l`, `platelets_x10e9_l` |
| Malaria Parasite | `parasites_seen`, plus `density_per_ul` and `species` only if positive |
| Lipid Profile | `total_chol`, `hdl`, `ldl`, `triglycerides` |
| Fasting Blood Sugar / HbA1c | `glucose_mmol_l` / `hba1c_percent` |
| Urinalysis | `protein`, `glucose`, `leukocytes`, `nitrite` (dipstick text) |
| Widal | `o_titre`, `h_titre` |
| Liver / Kidney function | `alt_u_l`, `ast_u_l`, `bilirubin_umol_l` / `urea_mmol_l`, `creatinine_umol_l`, `sodium_mmol_l`, `potassium_mmol_l` |
| Chest X-Ray | `findings` (text), `image_ref` |

**Honesty note:** the P2 generator only produced a summary word for each result. The migration keeps that word as `result.summary` and **simulates** the detailed values (`random.seed(42)`), choosing values in the normal range when the summary is "Normal" or "Negative" and in the abnormal range otherwise. Pending orders have no `result` field at all.

## 7. Consistency: what changes compared with PostgreSQL

| Topic | PostgreSQL (P1 and P3) | MongoDB design |
|---|---|---|
| Atomicity | Multi-table transactions (Demo 1: prescription + stock + invoice) | **A single-document write is always atomic.** Embedding a visit's parts makes most clinical writes single-document. Multi-document transactions exist but need a replica set (P5). |
| Dispensing (P3 lost update) | `UPDATE … SET qty = qty - n` with a CHECK constraint | One atomic update with a condition: `updateOne({_id: 3, stock: {$elemMatch: {branch_id: 1, quantity_on_hand: {$gte: 20}}}}, {$inc: {"stock.$.quantity_on_hand": -20}})`. No read-then-write, so no lost update. |
| Invoice status (P1 trade-off, P3 Demo 9) | Stored column kept correct by a trigger | Status and payments are in the **same document**, so both are updated in one atomic `updateOne`. |
| Constraints | CHECK, FOREIGN KEY, UNIQUE in the schema | `$jsonSchema` validation and unique indexes are possible, but there are **no foreign keys**. The application must keep references valid. |
| Duplicated data | Avoided by normalisation | Deliberate: patient and doctor names are copied into visits. If a patient changes their name, `updateMany` must also update their visits. Accepted because names rarely change and are read on every visit list. |

## 8. Data types

- **Money:** stored as `Decimal128` (`NumberDecimal("19740.00")`), not as a double, so ₦ amounts never pick up floating-point rounding errors. This matches PostgreSQL `NUMERIC(12,2)`.
- **Dates:** BSON has no date-only type, so `date_of_birth` and the HMO dates are stored as midnight UTC datetimes.
- **IDs:** the PostgreSQL primary keys are kept as `_id` (integers instead of ObjectIds), so every document can be matched to its source row for verification and comparison.

## 9. Migration

`migrate_to_mongo.py` reads all tables from PostgreSQL (psycopg2), groups the child rows by their parent id, builds the documents in Python, and inserts them in batches of 5,000 (pymongo `insert_many`).

The script is re-runnable: it drops the collections first. At the end it checks that MongoDB holds the same number of patients, visits, consultations, invoices, lab orders and payments as PostgreSQL.

Only the default `_id` index is created during migration. Further indexes are added in the queries session, so their effect can be measured with `explain()`, as in P2.
