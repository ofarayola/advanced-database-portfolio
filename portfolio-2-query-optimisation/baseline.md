# Baseline (before optimisation)

Measured on PostgreSQL 18 with no extra indexes (only those created automatically by
primary keys and UNIQUE constraints). Data: 20,000 patients, 60,000 appointments,
41,576 invoices (see generate_data.py).
Time = median of 3 consecutive runs (see plans/before-timings.txt).
Buffers = 8 KB data pages read (see plans/before.txt).

| Query | Largest scan in the plan | Rows read → returned | Buffers | Median (ms) |
|---|---|---|---|---|
| Q1 Patient history | Seq Scan on appointment | 60,000 → 12 | 592 | 6.58 |
| Q2 Branch schedule | Seq Scan on appointment | 60,000 → 22 (59,978 removed) | 620 | 3.17 |
| Q3 Monthly revenue | Seq Scan on invoice + appointment | 41,576 → 15,103 invoices (36%) | 914 | 26.08 |
| Q4 Top drugs | Seq Scan on prescription + prescription_item | 35,369 → 12,993 prescriptions (37%) | 638 | 18.24 |
| Q5 Pending labs | Seq Scan on lab_order | 33,487 → 106 (33,381 removed) | 1,251 | 4.56 |
| Q6 Outstanding balances | Seq Scan on invoice, payment, patient | 41,576 → 8,360 invoices (20%) | 919 | 31.03 |
| Q7 Doctor ranking | Bitmap Index Scan on uq_doctor_slot (skip scan) | 19,984 index entries → 15,103 | 784 | 11.03 |
| Q8 High BP alerts | Seq Scan on vital_signs + consultation | 45,745 → 1,142 (44,603 removed) | 7,727 | 13.70 |

## Observations

### Measuring reliably
- Single runs were unreliable: Q1 took 6.6 ms in one run and 25.5 ms in another, because
  of other activity on my PC and a "cold" first run (planning time 10 ms instead of 2 ms).
- Across all runs the plans and Buffers stayed identical. Only the time changed.
- Three consecutive runs agreed closely (e.g. Q1: 6.39, 6.69, 6.58 ms), so I use the
  median of 3 for time and Buffers as the stable measure of how much work each query does.

### Where the time goes
- The three slowest queries are Q6 (31.0 ms), Q3 (26.1 ms) and Q4 (18.2 ms). All three
  aggregate thousands of rows (8,000–19,000), so most of their time is spent hashing,
  sorting and summing, not on finding rows.
- The fastest-looking queries, Q1 (6.6 ms), Q2 (3.2 ms) and Q5 (4.6 ms), are actually the
  most wasteful. Each reads tens of thousands of rows to return 12, 22 or 106, i.e. it
  throws away over 99.6% of what it reads.

### Causes found in the plans
- **Foreign keys are not indexed automatically.** PostgreSQL indexes primary keys and
  UNIQUE columns, but not foreign keys. Q1 finds the patient instantly through
  patient_hospital_no_key, then scans all 60,000 appointments because
  appointment.patient_id has no index.
- **A function on a column blocks index use.** Q2 filters on DATE(start_time). Even if
  start_time were indexed, wrapping it in DATE() means the index could not be used.
  This needs a query rewrite, not just an index.
- **Low selectivity makes indexes less useful.** Q3 and Q4 need about 36–37% of their
  tables. Reading a third of a table through an index means jumping around the disk, so
  a sequential scan is usually cheaper. I expect little or no gain from indexing them.
- **High selectivity makes indexes very useful.** Q5 needs 0.3% of lab orders and Q8
  needs 2.5% of vital signs. These are strong candidates; Q5 suits a partial index,
  since the pending rows are a tiny, frequently queried subset.
- **Existing constraints already help.** Q7 uses the uq_doctor_slot index from
  Portfolio 1, even though it filters only on start_time, the index's second column.
  This is PostgreSQL 18's B-tree skip scan (Index Searches: 44, about one per doctor).
- **Repeated index lookups add up.** Q8 has the most Buffers (7,727): after filtering
  vital_signs it looks up appointment and patient 1,142 times each by primary key.

### Predictions to test after optimisation
| Query | Planned change | Expected result |
|---|---|---|
| Q1 | Index on appointment(patient_id) | Large reduction in Buffers and time |
| Q2 | Rewrite DATE() as a range, plus index on (branch_id, start_time) | Large reduction |
| Q3 | Test an index on invoice(issued_at) | Little or no gain (low selectivity) |
| Q4 | None planned | No change |
| Q5 | Partial index on lab_order where the test is still pending | Large reduction |
| Q6 | Index on payment(invoice_id), partial index on unpaid invoices | Moderate gain |
| Q7 | None needed (already uses uq_doctor_slot) | No change |
| Q8 | Index on vital_signs(recorded_at) | Moderate gain |