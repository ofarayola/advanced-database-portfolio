# Portfolio 2 — Query Processing and Optimisation

**Case study:** CarePoint Specialist Clinic · **DBMS:** PostgreSQL 18 · **Schema:** `clinic` (from Portfolio 1)

## Summary

I loaded realistic volumes of clinic data (20,000 patients, 60,000 appointments), wrote
8 queries used by real clinic roles, measured their execution plans, then added targeted
indexes and rewrote one query. The best results were **Q1 17× faster** (indexing a foreign
key) and **Q2 20× faster** (rewriting a date filter so the index could be used). Two indexes
gave no benefit, and one query I never targeted got faster, which shows why every change
must be measured rather than assumed.

## Files

| File | Purpose |
|---|---|
| `generate_data.py` | Python (Faker + psycopg2) generator: ~380,000 rows across 18 tables, fixed seed for reproducibility |
| `queries.sql` | The 8 business queries (Q2 updated to the optimised version) |
| `query-results.txt` | Output of the 8 queries |
| `explain_plans.sql` | The same 8 queries with `EXPLAIN (ANALYZE, BUFFERS)`, run before and after indexing |
| `baseline.md` | Before: plans, Buffers, median times, observations and predictions |
| `indexes.sql` | 8 indexes, each with the reason it was created (and DROP statements to undo) |
| `q2_rewrite.sql` | Q2 original vs rewritten, plus a check that both return the same rows |
| `results.md` | After: before/after comparison, predictions vs reality, lessons |
| `plans/` | Raw evidence: `before.txt`, `after.txt`, timing runs, `q2-rewrite.txt`, `index-usage.txt` |
| `screenshots/` | Key evidence images |

## How to reproduce

Requires the Portfolio 1 schema (`portfolio-1-database-design/schema.sql`).

```powershell
$env:PGPASSWORD = "your_password"

# 1. Load the large dataset (replaces any existing data)
python portfolio-2-query-optimisation/generate_data.py

# 2. Baseline: run the plans with NO extra indexes
psql -U postgres -d carepoint -f portfolio-2-query-optimisation/explain_plans.sql > plans/before.txt

# 3. Add the indexes, then run the same plans again
psql -U postgres -d carepoint -f portfolio-2-query-optimisation/indexes.sql
psql -U postgres -d carepoint -f portfolio-2-query-optimisation/explain_plans.sql > plans/after.txt

# 4. Q2 rewrite experiment
psql -U postgres -d carepoint -f portfolio-2-query-optimisation/q2_rewrite.sql
```
To return to the baseline, run the DROP INDEX statements at the bottom of `indexes.sql`.

## Method

1. **Realistic data volume.** With only a few rows every query runs in under 1 ms, so
   optimisation cannot be observed. The generator respects every Portfolio 1 constraint
   (no double-booking, systolic > diastolic, one active HMO per patient).
2. **Real queries.** Each query answers a question a specific clinic role asks daily:
   front desk, laboratory, pharmacy, billing, management and clinicians.
3. **Fair comparison.** The same `explain_plans.sql` file was run before and after, on the
   same data, with a warm-up run first.
4. **Two measures.** Time is the median of 3 runs, because single runs varied up to 4×
   (Q1: 6.6 ms vs 25.5 ms). Buffers (data pages read) stayed identical across runs, making
   them the more reliable measure of work.
5. **Predict, then test.** I wrote down the expected outcome for each query before
   indexing, then compared it with the measured result.

## Queries

| # | Role | Question | SQL features |
|---|---|---|---|
| Q1 | Front desk / doctor | Full visit history for one patient | 5-table join, LEFT JOIN |
| Q2 | Front desk | One branch's bookings for one day | Date range, join |
| Q3 | Management | Monthly revenue per branch | GROUP BY, date_trunc, SUM |
| Q4 | Pharmacy | Top 10 drugs, last 12 months | Aggregation, LIMIT |
| Q5 | Laboratory | Tests still awaiting results | Status filter, 5 joins |
| Q6 | Billing | Top 20 outstanding balances | LEFT JOIN, COALESCE |
| Q7 | Management | Doctor workload ranking per branch | Window function (RANK OVER) |
| Q8 | Clinical | High blood pressure, last 90 days | Range filter, ORDER BY |

## Headline results

| Query | Change | Before → after (ms) | Buffers | Result |
|---|---|---|---|---|
| Q1 | Index on foreign key `appointment.patient_id` | 6.58 → 0.38 | 592 → 99 | **17× faster** |
| Q2 | Composite index **+ query rewrite** | 3.17 → 0.16 | 620 → 92 | **20× faster** (index alone: 31% *slower*) |
| Q5 | Partial index (16 kB) on pending lab orders | 4.56 → 1.55 | 1,251 → 1,051 | **2.9× faster** |
| Q6 | Partial index on unpaid invoices | 31.03 → 24.01 | 919 → 945 | 23% faster |
| Q7 | None (used Q2's index) | 11.03 → 9.46 | 784 → 630 | 14% faster, unplanned |
| Q8 | Index on `recorded_at` | 13.70 → 11.39 | 7,727 → 7,736 | 17% faster |
| Q3, Q4 | Test index / none | no meaningful change | — | As predicted |

Full comparison, plan analysis and predictions vs reality: **[results.md](results.md)**.
Baseline analysis: **[baseline.md](baseline.md)**.

## Key findings

1. **PostgreSQL does not index foreign keys automatically.** Primary keys and UNIQUE
   columns get an index; foreign keys do not. Indexing `appointment.patient_id` was the
   simplest change and gave one of the biggest gains.
2. **A function on a column hides it from the index.** `DATE(start_time) = '2026-10-13'`
   prevented the composite index from using `start_time`, so it fetched 20,150 rows and the
   query got *slower*. Rewriting it as `start_time >= '2026-10-13' AND start_time < '2026-10-14'`
   fetched exactly 22 rows. An EXCEPT check proved both return identical results.
3. **Selectivity decides whether an index helps.** Queries returning under 0.5% of a table
   (Q1, Q2, Q5) gained most. Q3 and Q4 need about a third of their tables, and indexing
   made no difference.
4. **Partial indexes are small and effective for hot subsets.** The pending-lab index is
   16 kB (vs 600–1,400 kB for the others) and made Q5 nearly 3× faster.
5. **The optimiser chooses, not the developer.** It ignored two of my indexes (a hash join
   was cheaper) and used the Q2 index to speed up Q7 through PostgreSQL 18's **B-tree skip
   scan**: 5 index searches over 3 branches instead of 44 over 42 doctors.
6. **Usage statistics need interpreting.** The two unused indexes showed 10 "uses" in
   `pg_stat_user_indexes`. A planning-only EXPLAIN proved these were the planner reading index
   endpoints to estimate join costs, not real use. The execution plan is the reliable evidence.

## Evidence

| Screenshot | Shows |
|---|---|
| `screenshots/p2-data-loaded.png` | 60,000 appointments loaded, by status |
| `screenshots/p2-q1-before-after.png` | Q1: Seq Scan before, index scan after |
| `screenshots/p2-q2-rewrite.png` | Q2 rewritten plan: both index columns used, 0.159 ms, identical results |
| `screenshots/p2-index-usage.png` | `pg_stat_user_indexes` output |

## What I would do next

- **Drop** `idx_payment_invoice` and `idx_vitals_consultation`, since they cost disk space and
  write time without helping these queries.
- Check write overhead: time a batch of 1,000 appointment INSERTs with and without the new
  indexes to quantify the cost of each index.
- For Q3 and Q4, which scan large portions of data, consider a **materialized view**
  of monthly totals refreshed nightly, rather than an index.