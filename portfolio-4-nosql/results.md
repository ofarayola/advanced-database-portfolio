# P4 Results: Queries and Indexes in MongoDB

**Data:** 60,000 `visits` documents (57.9 MB, average 965 bytes) and 20,000 `patients` documents (4.9 MB), migrated from the P2 PostgreSQL database.
**Tools:** MongoDB 9.0, mongosh 2.12, `explain("executionStats")`.
**Method:** each query was run 3 times before and 3 times after indexing, and the **median** time is reported (same method as P2). Raw output: `explain-results.txt`.

## 1. Correctness: same answers as PostgreSQL

The 8 business questions from P2 were rewritten for the document model in `queries.js`. Output: `query-results.txt`.

| Query | Question | MongoDB rows | Same result as P2 SQL? |
|---|---|---|---|
| Q1 | Visit history for CP-011210 | 12 | Yes |
| Q2 | Lekki schedule, 13 Oct 2026 | 22 | Yes |
| Q3 | Monthly revenue per branch, 2025 | 36 | Yes (e.g. Ikeja, Jan 2025: 482 invoices, ₦10,361,380) |
| Q4 | Top 10 drugs since Oct 2025 | 10 | Yes (Paracetamol: 48,444 units, 2,288 times) |
| Q5 | Outstanding lab orders | 106 | Yes |
| Q6 | Top 20 outstanding balances | 20 | Yes (ties at ₦100,000 may appear in a different order) |
| Q7 | Doctor ranking per branch, 2025 | 126 | Yes (`$setWindowFields` + `$rank` = `RANK() OVER`) |
| Q8 | Systolic ≥ 160 in last 90 days (top 20) | 20 | Yes |
| Q9 | FBC results with Hb < 10 g/dL per branch | 3 | Not possible in P2: the result was a single TEXT value |
| Q10 | Patient profile via `$lookup` | 1 | Uses a join, because visits are referenced, not embedded |

Getting identical answers from both systems confirms the migration preserved the data, and that each query was translated correctly.

## 2. Before and after indexing

| Query | Plan before | Docs examined before → after | Returned | Median ms before → after | Plan after |
|---|---|---|---|---|---|
| Q1 | SORT > COLLSCAN | 60,000 → **12** | 12 | 110 → **1** | FETCH > IXSCAN |
| Q2 | SORT > COLLSCAN | 60,000 → **22** | 22 | 122 → **1** | FETCH > IXSCAN |
| Q3 | GROUP > COLLSCAN | 60,000 → 60,000 | 36 groups | 164 → 163 | GROUP > COLLSCAN (no index created) |
| Q5 | COLLSCAN | 60,000 → **89** | 89 | 115 → **2** | FETCH > IXSCAN (multikey) |
| Q6 | COLLSCAN | 60,000 → 8,360 | 8,360 | 155 → 106 | FETCH > IXSCAN |
| Q8 | COLLSCAN | 60,000 → **1,104** | 1,104 | 106 → **11** | FETCH > IXSCAN (multikey compound) |
| Q10 | COLLSCAN + NestedLoopJoin | 80,000 → **112** | 1 | 109 → **2** | EXPRESS_IXSCAN + `$lookup` using `ix_visit_patient_id` |

For aggregation queries, "returned" means the visit documents passed on from the first `$match` stage.

## 3. Indexes created

| Index | Fields | Supports | Size |
|---|---|---|---|
| `ix_visit_patient_time` | `patient.hospital_no`, `start_time` (desc) | Q1: equality + sort | 1.26 MB |
| `ix_visit_branch_time` | `branch.branch_id`, `start_time` | Q2: equality + range + sort | 0.73 MB |
| `ix_visit_lab_status` | `consultation.lab_orders.status` | Q5 (multikey: one key per lab order) | 0.27 MB |
| `ix_visit_invoice_status` | `invoice.status` | Q6 | 0.29 MB |
| `ix_visit_bp_time` | `consultation.vital_signs.bp.systolic`, `…recorded_at` | Q8 (multikey compound) | 0.66 MB |
| `ix_visit_patient_id` | `patient.patient_id` | Q10 (`$lookup` foreign field) | 0.41 MB |
| `ux_patient_hospital_no` | `patients.hospital_no` (unique) | Q10 `$match`; also stops duplicate hospital numbers | 0.25 MB |

**Storage cost:** the six new `visits` indexes take about **3.6 MB**, roughly 6% of the 57.9 MB of data. Every insert or update of a visit must also update these indexes. Multikey indexes add one entry per array element, so a visit with three lab orders adds three keys to `ix_visit_lab_status`.

## 4. Findings

1. **Selective queries gained the most.** Q1 and Q2 went from scanning all 60,000 documents to reading exactly the 12 and 22 they return (110 ms → 1 ms, about 100× faster). This is the same pattern as P2: an index helps most when a query returns a tiny fraction of the data.

2. **The order of fields in a compound index matters (the Equality–Sort–Range rule).** In `ix_visit_patient_time`, the equality field comes first and the sort field second. That's why the "after" plan for Q1 has no SORT stage: the index already returns visits newest first. This is the same idea as the composite indexes in P2.

3. **Q3 did not change, as expected.** It reads about a third of all visits, so a full scan stays cheaper than thousands of index lookups. I deliberately created no index for it. P2 showed the same thing: indexes are not useful for queries that touch a large part of a table.

4. **Q6 improved only modestly (155 → 106 ms).** About 14% of visits are unpaid or part-paid (8,360 documents). The index removes the scan, but most of the time is spent fetching and summing 8,360 documents. A low-selectivity filter limits what an index can do.

5. **Indexes on arrays (multikey) work naturally.** Q5 found 106 outstanding lab orders by reading only **89** visits, because some visits hold two outstanding orders in one document. In P2 the same question needed a five-table join. For Q8, 1,165 index keys were examined to fetch 1,104 visits containing 1,142 qualifying readings: a visit with two qualifying readings has two index keys but is fetched only once.

6. **Joins still exist in MongoDB, and they need indexes even more.** Without an index, Q10's `$lookup` used a NestedLoopJoin, scanning 80,000 documents to build one patient profile. With an index on the foreign field (`patient.patient_id`), the time fell from 109 ms to 2 ms. The patient lookup itself used `EXPRESS_IXSCAN`, a fast path in recent MongoDB versions for an equality match on a unique index.
   - *Note:* the explain output reported 112 documents examined for the `$lookup`, while the patient has 12 visits. The exact way the `$lookup` stage counts examined documents differs between versions, so I report the figure as shown rather than adjusting it.

7. **Embedding removed most joins.** Q1, Q2, Q4, Q5, Q6 and Q8 needed between 2 and 5 joins in PostgreSQL but use a single collection here, because patient, doctor and branch names are copied into each visit (extended references) and child records are embedded. The trade-off is duplicated names that must be kept in step (see `data-model.md`, section 7).

8. **Measurement notes.** The first run after creating an index was sometimes slower (Q1: 17 ms vs 0–1 ms), because the index pages were not yet in memory. Taking the median of three runs avoids reporting this one-off cost. Times below 2 ms are close to the timer's resolution, so for the fast queries the **documents examined** figure is the more reliable measure, just as Buffers was in P2.

## 5. PostgreSQL vs MongoDB for these workloads

| Aspect | PostgreSQL (P2) | MongoDB (P4) |
|---|---|---|
| Single-patient and single-visit reads | Several joins, fast with indexes | One document or one indexed range, no joins |
| Analytical queries (Q3, Q4, Q7) | Natural in SQL (`GROUP BY`, window functions) | Possible with aggregation pipelines, but longer to write |
| Flexible lab results (Q9) | Not queryable (TEXT column) | Queryable per test type |
| Ad-hoc joins (Q10) | Normal and well optimised | Possible (`$lookup`) but the design tries to avoid them |
| Index tool | B-tree, partial indexes, skip scan | B-tree, multikey (array) indexes, compound indexes |
