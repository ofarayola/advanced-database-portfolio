# Baseline (before optimisation)

Measured on PostgreSQL 18, second run (warm cache). Data: 20,000 patients,
60,000 appointments, 41,576 invoices (see generate_data.py).

| Query | Largest scan in the plan | Rows read → returned | Execution time (ms) |
|---|---|---|---|
| Q1 Patient history | Seq Scan on appointment | 60,000 → 12 | 6.62 |
| Q2 Branch schedule | Seq Scan on appointment | 60,000 → 22 (59,978 removed) | 3.27 |
| Q3 Monthly revenue | Seq Scan on invoice + appointment | 41,576 → 15,103 invoices (36%) | 23.48 |
| Q4 Top drugs | Seq Scan on prescription + prescription_item | 35,369 → 12,993 prescriptions (37%) | 15.77 |
| Q5 Pending labs | Seq Scan on lab_order | 33,487 → 106 (33,381 removed) | 4.39 |
| Q6 Outstanding balances | Seq Scan on invoice, payment, patient | 41,576 → 8,360 invoices (20%) | 23.50 |
| Q7 Doctor ranking | Bitmap Index Scan on uq_doctor_slot (skip scan) | 19,984 index entries → 15,103 | 10.01 |
| Q8 High BP alerts | Seq Scan on vital_signs + consultation | 45,745 → 1,142 (44,603 removed) | 11.05 |

## Observations
- PostgreSQL automatically indexes primary keys and UNIQUE columns, but not foreign keys.
  So Q1 finds the patient by index, then scans every appointment to find their 12 visits.
- Q2 wraps start_time in DATE(), which stops any index on start_time from being used.
- Q3 and Q4 need about a third of their tables. For that much data a sequential scan
  is usually cheaper than an index, so I expect indexing to help little there.
- Q5 needs only 0.3% of lab orders, a good candidate for a partial index.
- Q7 already uses the uq_doctor_slot index even though it filters only on start_time,
  the second column. This is PostgreSQL 18's B-tree skip scan (Index Searches: 44,
  about one per doctor). The constraint from Portfolio 1 is already helping here.