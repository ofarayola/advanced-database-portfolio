# Results (after optimisation)

Same 8 queries (explain_plans.sql), same data, PostgreSQL 18.
Time = median of 3 runs (plans/after-timings.txt), except the rewritten Q2, which is
a single run (plans/q2-rewrite.txt). Buffers = 8 KB data pages read (plans/after.txt).

## 1. Before vs after

| Query | Index / change | Before (ms) | After (ms) | Change | Buffers before → after | Verdict |
|---|---|---|---|---|---|---|
| Q1 Patient history | idx_appointment_patient | 6.58 | 0.38 | 94% faster (17×) | 592 → 99 | Big win |
| Q2 Branch schedule (original) | idx_appointment_branch_start | 3.17 | 4.15 | 31% slower | 620 → 681 | Worse: DATE() blocks the index |
| Q2 Branch schedule (rewritten) | Index + range condition | 3.17 | 0.16 | 95% faster (20×) | 620 → 92 | Big win |
| Q3 Monthly revenue | idx_invoice_issued_at | 26.08 | 24.52 | −6% (noise) | 914 → 943 | No real gain |
| Q4 Top drugs | none | 18.24 | 17.59 | −4% (noise) | 638 → 638 | Unchanged |
| Q5 Pending labs | idx_lab_order_pending (partial) | 4.56 | 1.55 | 66% faster (2.9×) | 1,251 → 1,051 | Big win |
| Q6 Outstanding balances | idx_invoice_unpaid (partial) | 31.03 | 24.01 | 23% faster | 919 → 945 | Moderate |
| Q7 Doctor ranking | none (benefited from Q2's index) | 11.03 | 9.46 | 14% faster | 784 → 630 | Unplanned gain |
| Q8 High BP alerts | idx_vitals_recorded_at | 13.70 | 11.39 | 17% faster | 7,727 → 7,736 | Moderate |

## 2. Indexes created

| Index | Target | Type | Size | Used by the executor? |
|---|---|---|---|---|
| idx_appointment_patient | Q1 | B-tree on foreign key | 872 kB | Yes (Q1) |
| idx_appointment_branch_start | Q2 | Composite (branch_id, start_time) | 1,424 kB | Yes (Q2, and Q7 unplanned) |
| idx_invoice_issued_at | Q3 | B-tree (test) | 608 kB | Yes, but no benefit |
| idx_lab_order_pending | Q5 | Partial (pending tests only) | 16 kB | Yes (Q5) |
| idx_payment_invoice | Q6 | B-tree on foreign key | 888 kB | No |
| idx_invoice_unpaid | Q6 | Partial (unpaid/part-paid only) | 200 kB | Yes (Q6) |
| idx_vitals_recorded_at | Q8 | B-tree | 640 kB | Yes (Q8) |
| idx_vitals_consultation | Q8 | B-tree on foreign key | 1,000 kB | No |

The partial index idx_lab_order_pending is 16 kB, about 1/50th the size of the normal
indexes, because it stores only the ~100 lab orders still waiting for a result.

## 3. What changed in the plans

- **Q1:** `Seq Scan on appointment` (60,000 rows) became `Bitmap Index Scan on
  idx_appointment_patient` (12 rows). Indexing the foreign key removed the full scan.
- **Q2 original:** the index was used only for `branch_id = 2`, fetching 20,150 rows,
  then `date(start_time)` removed 20,128 of them. Wrapping start_time in DATE() stopped
  the index from using its second column, so the query got slower than the plain scan.
- **Q2 rewritten:** `start_time >= '2026-10-13' AND start_time < '2026-10-14'` let the
  index use both columns (`Index Cond: branch_id = 2 AND start_time >= … AND < …`).
  It fetched exactly 22 rows and `Rows Removed by Filter` disappeared. An EXCEPT check
  confirmed both versions return identical rows (rows_that_differ = 0).
- **Q3:** PostgreSQL 18 chose a Bitmap Index Scan on idx_invoice_issued_at, but the
  query still needs 15,103 of 41,576 invoices (36%). Buffers went up slightly and time
  did not change meaningfully.
- **Q5:** `Seq Scan on lab_order` (33,381 rows removed) became an `Index Scan using
  idx_lab_order_pending` that reads only the 106 pending orders. The remaining cost
  is 106 primary-key lookups each into consultation, appointment and patient.
- **Q6:** idx_invoice_unpaid replaced the filtered scan of invoices, saving the work of
  discarding 33,216 paid invoices. idx_payment_invoice was ignored: the plan still reads
  all 39,541 payments once into a hash table, which is cheaper than 8,360 index lookups.
- **Q7:** the planner switched from uq_doctor_slot (skip scan, 44 index searches, one
  per doctor) to idx_appointment_branch_start (skip scan, 5 index searches, because
  branch_id has only 3 values). An index built for Q2 improved Q7.
- **Q8:** idx_vitals_recorded_at cut the vital-sign rows examined from 45,745 to 4,114.
  Total Buffers barely changed because 6,852 of the 7,736 come from 1,142 primary-key
  lookups each into appointment and patient, which the index does not affect.

## 4. Predictions vs reality

| Query | Prediction (baseline.md) | Reality | Why |
|---|---|---|---|
| Q1 | Large gain | 17× faster | Indexing the foreign key replaced a scan of 60,000 rows with a lookup of 12 |
| Q2 | Large gain | Slower with the index alone (4.15 ms); 20× faster once rewritten (0.16 ms) | DATE(start_time) blocked the index's second column; the rewrite was essential |
| Q3 | Index ignored, no gain | Index used, but no gain | Reading 36% of a table through an index saves nothing over a sequential scan |
| Q4 | No change | No change | No index was added |
| Q5 | Large gain | 2.9× faster | The 16 kB partial index holds only the ~100 pending rows |
| Q6 | Moderate gain via both indexes | Gain from one index only | A hash join over all payments was cheaper than 8,360 lookups via idx_payment_invoice |
| Q7 | No change | 14% faster | Skip scan over 3 branches (5 searches) instead of 42 doctors (44 searches) |
| Q8 | Moderate gain | 17% faster | Fewer vital-sign rows examined, but repeated primary-key lookups still dominate |

## 5. Unused indexes and a lesson about statistics

The execution plans show that idx_payment_invoice (Q6) and idx_vitals_consultation (Q8)
were never used: the planner chose hash joins that read payment and consultation in full.

I expected pg_stat_user_indexes to show 0 uses for them, but it showed 10 each
(see plans/index-usage.txt). To find out why, I reset the statistics and ran a plain
EXPLAIN (planning only, no execution): idx_payment_invoice went from 0 to 2.
When the planner costs a join, it reads the first and last entries of a relevant index
to estimate the range of values. I ran explain_plans.sql 5 times: 5 × 2 reads = 10.

Lesson: idx_scan counts every touch of an index, including the planner's estimates.
The execution plan is the reliable evidence of whether an index actually helped a query.

Both indexes still cost disk space (888 kB and 1,000 kB) and must be updated on every
INSERT, UPDATE and DELETE while giving no benefit to these queries. In production I would
drop them, or keep them only if another query or a foreign-key DELETE check needed them.

## 6. Key lessons

1. **Index foreign keys used in lookups.** PostgreSQL does not do this automatically,
   and it gave the biggest gain for the simplest change (Q1: 17× faster).
2. **Write queries the index can use.** Wrapping a column in a function (DATE(), LOWER())
   hides it from the index. For Q2 the rewrite mattered more than the index itself.
3. **Indexes help selective queries, not bulk ones.** Q1, Q2 and Q5 return under 0.5% of
   their rows and gained most; Q3 and Q4 need about a third of their tables and gained nothing.
4. **Partial indexes suit small, frequently queried subsets.** idx_lab_order_pending is
   16 kB yet made Q5 nearly 3× faster.
5. **The planner decides, not me.** It ignored two of my indexes and used another for a
   query I never targeted (Q7). The only way to know is to measure.
6. **Measure work as well as time.** Buffers stayed stable across runs while times varied,
   so they were the more reliable evidence. Usage statistics also need interpreting.
7. **Indexes are not free.** The 8 indexes add about 5.6 MB and slow down every write;
   each one should earn its place.