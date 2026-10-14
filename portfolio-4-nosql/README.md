# Portfolio 4 – NoSQL with MongoDB

**Module:** MIT 8103 Advanced Database Systems · **Case study:** CarePoint Specialist Clinic (Ikeja = branch 1, Lekki = 2, Yaba = 3)
**Tools:** MongoDB 9.0.2, mongosh 2.12, Python 3.13 (pymongo, psycopg2) · **Database:** `carepoint`

## 1. Overview

Portfolios 1–3 built CarePoint as a normalised PostgreSQL database with 18 tables. This portfolio redesigns the same clinic as a **document model** in MongoDB, migrates the real P2 data into it, and compares the two approaches using evidence:

1. **Design:** 18 tables become 6 collections, with each embed-or-reference decision justified by how the data is read.
2. **Migration:** a Python script copies 60,000 visits and 20,000 patients from PostgreSQL and checks every count.
3. **Queries:** the **same 8 business questions as P2** give identical answers, plus 2 queries that only the document model can answer this way.
4. **Indexes:** `explain("executionStats")` before and after indexing, using the same method as P2.
5. **Concurrency:** P3's lost update repeated 10,000 times in MongoDB, then fixed with an atomic `$inc`.
6. **Integrity:** P1's CHECK constraints re-created with `$jsonSchema` validation, along with the clearest limitation (no foreign keys).

## 2. Folder contents

| File | Purpose |
|---|---|
| `data-model.md` | Design: access patterns, collections, embed vs reference, flexible lab results, consistency, data types |
| `migrate_to_mongo.py` | PostgreSQL → MongoDB migration with count verification |
| `queries.js` | Q1–Q8 (same questions as P2) + Q9 (polymorphic lab results) + Q10 (`$lookup`) |
| `query-results.txt` | Output of `queries.js` |
| `explain.js` | Before/after index measurements (3 runs, median) |
| `explain-results.txt` | Output of `explain.js` |
| `results.md` | Index results, findings and PostgreSQL vs MongoDB comparison |
| `atomic-dispense.js` | Demo A: lost update vs atomic `$inc`, and a conditional dispense |
| `validation.js` | Demo B: `$jsonSchema` rules, audit and 7 tests |
| `screenshots/` | Evidence (listed in section 9) |

## 3. How to reproduce

All commands run in PowerShell from this folder. PostgreSQL (P1/P2 database) and MongoDB must both be running.

```powershell
pip install pymongo psycopg2-binary
$env:PGPASSWORD = "your_password"
python migrate_to_mongo.py                                   # 1. migrate and verify
mongosh carepoint --quiet queries.js  > query-results.txt    # 2. queries
mongosh carepoint --quiet explain.js  > explain-results.txt  # 3. index measurements
mongosh carepoint --quiet validation.js                      # 4. validation (re-runnable)
```

`atomic-dispense.js` is a step guide, because it needs two mongosh windows running at the same time.

## 4. Design summary (full detail in `data-model.md`)

| Collection | Docs | Avg size | Main decision |
|---|---|---|---|
| `visits` | 60,000 | 965 B | Consultation, vitals, lab orders and results, prescription items, invoice and payments **embedded**: always read together, small and bounded |
| `patients` | 20,000 | 244 B | HMO history **embedded**; visits **referenced**, because they grow without limit |
| `drugs` | 20 | 357 B | Stock for 3 branches **embedded**, so a dispense updates one document atomically |
| `doctors`, `lab_tests`, `branches` | 42 / 10 / 3 | — | Small reference collections |

- **Extended references:** each visit copies the patient's, doctor's and branch's id plus their display names, so visit lists need no joins. The cost is duplicated names, which must be updated if they change.
- **Polymorphic lab results:** each test type has its own result fields (e.g. `hb_g_dl` for a Full Blood Count, `hdl`/`ldl` for a Lipid Profile). In P1 every result was a single TEXT value.
- **Money** is stored as `Decimal128` (exact, like `NUMERIC`), never as a floating-point double.
- The average visit size I measured (57.9 MB ÷ 60,000 = **965 bytes**) matched the estimate in the design.

## 5. Migration

| Check | PostgreSQL | MongoDB | |
|---|---|---|---|
| Patients | 20,000 | 20,000 | OK |
| Appointments → visits | 60,000 | 60,000 | OK |
| Consultations (embedded) | 41,576 | 41,576 | OK |
| Invoices (embedded) | 41,576 | 41,576 | OK |
| Lab orders (embedded arrays) | 33,487 | 33,487 | OK |
| Payments (embedded arrays) | 39,544 | 39,544 | OK |

P3 changes carried over correctly: invoice 11 is `paid` with one payment (39544), and drug 3 at Ikeja was 4074, the final value of the P3 stock trail.

## 6. Queries and indexes (full detail in `results.md`)

**Correctness:** Q1–Q8 return the same answers as the P2 SQL queries. For example, Q3 gives Ikeja, January 2025: 482 invoices, ₦10,361,380, identical to PostgreSQL. Q7 uses `$setWindowFields` + `$rank` in place of `RANK() OVER`.

| Query | Docs examined before → after | Median ms before → after | Plan after |
|---|---|---|---|
| Q1 patient history | 60,000 → 12 | 110 → 1 | IXSCAN (no SORT: index order used) |
| Q2 branch schedule | 60,000 → 22 | 122 → 1 | IXSCAN |
| Q3 2025 revenue | 60,000 → 60,000 | 164 → 163 | COLLSCAN (no index: reads ~1/3 of data) |
| Q5 outstanding lab orders | 60,000 → 89 | 115 → 2 | IXSCAN (multikey) |
| Q6 unpaid invoices | 60,000 → 8,360 | 155 → 106 | IXSCAN (low selectivity, small gain) |
| Q8 high blood pressure | 60,000 → 1,104 | 106 → 11 | IXSCAN (multikey compound) |
| Q10 `$lookup` profile | 80,000 → 112 | 109 → 2 | Index on the lookup's foreign field |

The 6 new indexes cost about 3.6 MB, roughly 6% of the `visits` data, and every write must keep them up to date.

## 7. Demo A: Lost update and atomic `$inc` (`atomic-dispense.js`)

Two mongosh windows each removed 1 unit 5,000 times from a practice counter starting at 10,000. The correct final value is 0.

| Method | Final value | Updates lost | Time per window |
|---|---|---|---|
| Read then write (`findOne` + `$set`) | **4,260** | 4,260 (42.6%), with no error shown | ~24.1 s |
| Atomic `$inc` | **0** | 0 | ~7.1 s |

- Every single write in MongoDB is atomic, but the read-then-write pattern still lost updates. Splitting one change into a read and a write leaves a gap between them, exactly as in P3 Demo 4.
- `$inc` does the read and the write in one server operation. It was both correct and about 3.4× faster.
- **Conditional dispense:** `updateOne({ _id: 3, stock: { $elemMatch: { branch_id: 1, quantity_on_hand: { $gte: 20 } } } }, { $inc: … })` dispensed 20 (4074 → 4054). The same update for 5,000 matched **0 documents** and changed nothing.
  - PostgreSQL rejected the same mistake with an **error** (P3 Demo 2, `chk_stock_not_negative`). MongoDB raises **no error**, so the application must check `matchedCount`.

## 8. Demo B: Schema validation (`validation.js`)

An audit first confirmed that **0** of the 60,000 existing visits broke the rules. Validation was then switched on (`validationLevel: strict`).

| Test | P1 constraint | Result |
|---|---|---|
| T1 temperature 50 °C | `chk_temp` | Rejected (`maximum: 45`, `consideredValue: 50`) |
| T2 systolic 80 < diastolic 120 | `chk_bp` | Rejected (`$expr`) |
| T3 status "done" | `chk_appt_status` | Rejected (`enum`) |
| T4 end before start | `chk_appt_time` | Rejected (`$expr`) |
| T5 method "bitcoin" | `chk_payment_method` | Rejected (nested `invoice.payments[0].method`) |
| T6 **update** to status "settled" | `chk_invoice_status` | Rejected: updates are checked too |
| T7 valid visit for non-existent patient 999999 | Foreign key | **Accepted.** MongoDB has no foreign keys |

- `$jsonSchema` error messages give the exact field path, rule and bad value.
- The two cross-field rules were combined into one `$expr`, so T2 and T4 only report "expression did not match". Separate `$expr` clauses would make errors clearer, much like having one named constraint per rule in P1.

## 9. PostgreSQL vs MongoDB: what I found

| Aspect | PostgreSQL (P1–P3) | MongoDB (P4) |
|---|---|---|
| Design approach | Normalise to remove redundancy | Shape documents around how they are read; accept some duplication |
| Reading one visit | Join up to 8 tables | One document |
| Analytics (revenue, rankings) | Short, natural SQL | Longer pipelines, same answers |
| Varying data (lab results) | Single TEXT column, not queryable | Different fields per test, fully queryable (Q9) |
| Joins | Normal and well optimised | `$lookup` exists but needs an index (109 → 2 ms) |
| Atomicity | Multi-table transactions (P3) | Single-document by default; multi-document transactions need a replica set (P5) |
| Integrity rules | CHECK + FOREIGN KEY + triggers | `$jsonSchema` + `$expr`; **no foreign keys** |
| Impossible operation (over-dispense) | Error | 0 documents matched, no error |
| Schema changes | `ALTER TABLE` | Add fields freely; validation is optional |

**Conclusion for CarePoint:** I would not replace PostgreSQL. Billing, stock and referential integrity depend on constraints, foreign keys and multi-table transactions, which PostgreSQL enforces natively. MongoDB is a strong fit for the parts with variable structure and whole-record reads: lab results, and a patient's full visit record for the doctor's screen. A realistic design would use both, with PostgreSQL as the system of record. That raises the problem seen in this portfolio: after Demo A, MongoDB holds 4054 for drug 3 while PostgreSQL still holds 4074. Two copies need a process to keep them in sync.

## 10. Limitations

- **Simulated lab values.** P2 stored only a summary word per result. The detailed values were generated (`random.seed(42)`) to agree with that word.
- **Generator quirks visible in the data:** some visits have two vital-sign records at the same minute with very different weights (e.g. visit 2: 49.8 kg and 71.8 kg), and summary words do not always suit the test (a Full Blood Count marked "Negative"). Validation cannot catch the first, because it is a business rule across two array items.
- **No foreign keys:** reference integrity depends on the application (T7).
- **Single server:** multi-document transactions, replication and sharding were not tested. They are the subject of P5.
- **Security:** MongoDB warned at startup that access control is not enabled. That's acceptable on a local practice install, but a real clinic database must require authentication (P5).
- **Duplicated names:** a patient name change would need `updateMany` across their visits.

## 11. Screenshots

| File | Shows |
|---|---|
| `p4-migration.png` | Migration output with all six checks OK |
| `p4-visit-document.png` | Visit 2: one document replacing 8 tables |
| `p4-p3-carryover.png` | Invoice 11 `paid` and drug 3 = 4074 after migration |
| `p4-lab-results.png` | Lipid Profile with its own result fields |
| `p4-query-results.png`, `p4-q9-q10.png` | Query output |
| `p4-explain-summary.png` | Before/after index summary |
| `p4-demoA1-lost-update.png` | Read-then-write: 4,260 lost |
| `p4-demoA2-atomic-inc.png` | `$inc`: 0 lost |
| `p4-demoA3-conditional.png` | Dispense 20 succeeds, 5,000 refused |
| `p4-demoB-audit-enable.png`, `p4-final-checks.png` | Audit = 0, validation strict, drug 3 = 4054 |
| `p4-demoB-t1-temp.png` … `p4-demoB-t7-no-fk.png` | Validation tests T1–T7 |

## 12. References

- MongoDB, Inc. (n.d.) *MongoDB Manual: Data Modeling* (embedding vs references, extended reference and polymorphic patterns). Available at: https://www.mongodb.com/docs/manual/data-modeling/ (Accessed: 14 October 2026)
- MongoDB, Inc. (n.d.) *MongoDB Manual: Schema Validation*. Available at: https://www.mongodb.com/docs/manual/core/schema-validation/ (Accessed: 14 October 2026)
- MongoDB, Inc. (n.d.) *MongoDB Manual: Atomicity and Transactions*. Available at: https://www.mongodb.com/docs/manual/core/write-operations-atomicity/ (Accessed: 14 October 2026)
- MongoDB, Inc. (n.d.) *MongoDB Manual: Explain Results*. Available at: https://www.mongodb.com/docs/manual/reference/explain-results/ (Accessed: 14 October 2026)
- Sadalage, P.J. and Fowler, M. (2012) *NoSQL Distilled*. Addison-Wesley.

## 13. AI use

AI assistance (Claude) was used to draft the data model, the migration script, the queries, the measurement script and the demo steps. I ran everything myself, checked each result against PostgreSQL and against my P3 stock and payment trail, captured the evidence, and wrote the findings from my own outputs. See the AI use log in `reflection-notes.md`.