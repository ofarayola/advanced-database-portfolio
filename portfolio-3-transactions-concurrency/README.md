# Portfolio 3 – Transactions and Concurrency

**Module:** MIT 8103 Advanced Database Systems · **Case study:** CarePoint Specialist Clinic (Ikeja = branch 1, Lekki = 2, Yaba = 3)
**DBMS:** PostgreSQL 18 · **Database:** `carepoint` · **Schema:** `clinic`

## 1. Overview

CarePoint has pharmacists dispensing drugs and cashiers taking payments at the same time, often on the same records. This portfolio shows, with live evidence, how PostgreSQL keeps that work correct:

- **ACID transactions:** COMMIT, ROLLBACK and SAVEPOINT on a real clinical workflow (consultation → prescription → invoice → stock).
- **Concurrency anomalies:** lost update, non-repeatable read, deadlock and write skew, each reproduced with two concurrent sessions.
- **Fixes and their trade-offs:** atomic updates, pessimistic locking (`SELECT … FOR UPDATE`), REPEATABLE READ, SERIALIZABLE, lock ordering and database triggers.

Every demo was run by hand in **two psql terminals** side by side in VS Code:

- Terminal **A = Ada** (pharmacist or cashier 1), terminal **B = Bayo** (pharmacist or cashier 2).
- Both prompts were set with `\set PROMPT1 'A%x=> '`, so `*` shows an open transaction and `!` shows a failed one.

## 2. How to reproduce

1. Build the database from Portfolio 1 (`schema.sql`) and load the Portfolio 2 data (`generate_data.py`).
2. Open two terminals and connect to the database in each:
   ```powershell
   psql -U postgres -d carepoint
   ```
3. In each terminal, set the prompt (`'A%x=> '` in A, `'B%x=> '` in B).
4. Open a demo file and run its numbered steps **in order, switching terminals as labelled** (`[A1]`, `[B1]` …). The timing between sessions is what creates each anomaly, so the files are step guides, not scripts to run in one go.
5. `demo9-invoice-trigger.sql`: run only the setup section with `\i` (functions and triggers). Its tests at the bottom are run step by step.

## 3. Folder contents

| File | Purpose |
|---|---|
| `demo1-commit.sql` | Multi-step clinical transaction committed atomically; isolation of uncommitted work |
| `demo2-rollback.sql` | Error mid-transaction → whole transaction rolled back; sequence gaps |
| `demo3-savepoint.sql` | Partial rollback with SAVEPOINT |
| `demo4-lost-update.sql` | Lost update under READ COMMITTED |
| `demo5a-atomic-update.sql` | Fix 1: atomic `SET qty = qty - n` |
| `demo5b-for-update.sql` | Fix 2: pessimistic lock `SELECT … FOR UPDATE` |
| `demo5c-repeatable-read.sql` | Fix 3: REPEATABLE READ → serialization error → retry |
| `demo6-nonrepeatable-read.sql` | Non-repeatable read: READ COMMITTED vs REPEATABLE READ |
| `demo7-deadlock.sql` | Deadlock and the lock-ordering fix |
| `demo8-write-skew.sql` | Write skew (double payment): REPEATABLE READ vs SERIALIZABLE |
| `demo9-invoice-trigger.sql` | Triggers: keep `invoice.status` in sync and block overpayment |
| `screenshots/` | Evidence for every demo (listed in section 4) |

## 4. Results summary

Stock values refer to **drug 3 (Artemether/Lumefantrine) at Ikeja (branch 1)** unless stated.

| # | Demo | What happened | Evidence |
|---|---|---|---|
| 1 | COMMIT | Consultation, prescription, invoice and stock change saved together (consultation/invoice 41573, prescription 35370). Bayo could not see Ada's work until COMMIT. Stock 4288 → 4264 | `p3-demo1-isolation.png`, `p3-demo1-after-commit.png` |
| 2 | ROLLBACK | An error mid-transaction put the session in a failed state (`!`); ROLLBACK undid every step (consultation 41569, prescription 35372). Sequence values used were **not** returned, leaving ID gaps | `p3-demo2-isolation.png`, `p3-demo2-error.png`, `p3-demo2-after-rollback.png`, `p3-demo2-manual-rollback.png` |
| 3 | SAVEPOINT | Rolled back only the faulty step and kept the rest (consultation 41532, prescription 35373) | `p3-demo3-savepoint.png`, `p3-demo3-final.png` |
| 4 | Lost update | Bayo read stock before Ada committed and wrote back a value based on that stale read. Stock ended at **4244 instead of 4234**: 10 units vanished from the records with **no error** | `p3-demo4-lost-update.png` |
| 5a | Atomic update | `quantity_on_hand = quantity_on_hand - n` → correct result (4214) | `p3-demo5a-correct.png` |
| 5b | `FOR UPDATE` | Bayo's read waited for Ada's lock, then saw the committed value → correct (4184) | `p3-demo5b-correct.png` |
| 5c | REPEATABLE READ | Same order of events as Demo 4, but Bayo got `could not serialize access due to concurrent update`; retry → correct (4154) | `p3-demo5c-serialization-error.png` |
| 6A | Non-repeatable read | READ COMMITTED: Ada read **4154, then 4139** in the same transaction after Bayo committed | `p3-demo6a-nonrepeatable-read.png` |
| 6B | Snapshot | REPEATABLE READ: Ada kept reading **4139** while Bayo had committed 4124; she saw 4124 only after her COMMIT | `p3-demo6b-repeatable-read.png` |
| 7A | Deadlock | Ada locked drug 3 then drug 1; Bayo locked drug 1 then drug 3. PostgreSQL detected the cycle and aborted Bayo (`ERROR: deadlock detected`); all of his work was undone | `p3-demo7a-deadlock.png` |
| 7B | Lock ordering | Both updated in ascending `drug_id` order: Bayo briefly waited, no deadlock, both saved (drug 1 = 3345, drug 3 = 4074) | `p3-demo7b-lock-ordering.png` |
| 8A | Write skew | REPEATABLE READ: two cashiers each saw a balance of 10,750 on invoice 11 and each inserted a full payment (39542 cash, 39543 transfer). Both committed, so **₦21,500 was collected on a ₦10,750 invoice** | `p3-demo8a-write-skew.png` |
| 8B | SERIALIZABLE | Same steps: Bayo's COMMIT failed with `could not serialize access due to read/write dependencies among transactions`; retry showed balance 0.00, so only 1 payment (39544) | `p3-demo8b-serializable.png` |
| 9 | Triggers | Audit found invoice 11 `unpaid` despite full payment; fixed. Status then updated automatically (`part_paid` → `paid` → `part_paid` on refund); overpayment rejected; Demo 8's double payment **blocked at plain READ COMMITTED** (invoice 31, 1 payment: 39549) | `p3-demo9-setup.png`, `p3-demo9a-audit-fix.png`, `p3-demo9b-status-sync.png`, `p3-demo9c-overpayment.png`, `p3-demo9d-concurrent-blocked.png` |

Full drug 3 stock trail: 4288 → 4264 (D1) → 4254 → 4244 (D4, lost update) → 4214 (5a) → 4184 (5b) → 4154 (5c) → 4139 (6A) → 4124 (6B) → 4094 → 4074 (D7).

## 5. Anomalies by isolation level (PostgreSQL, as observed)

| Anomaly | READ COMMITTED (default) | REPEATABLE READ | SERIALIZABLE |
|---|---|---|---|
| Dirty read | Not possible: PostgreSQL never shows uncommitted data (Demos 1–2) | Not possible | Not possible |
| Non-repeatable read | **Occurs** (Demo 6A) | Prevented: snapshot (Demo 6B) | Prevented |
| Lost update (read–modify–write) | **Occurs** silently (Demo 4) | Prevented: error + retry (Demo 5c) | Prevented: error + retry |
| Write skew (rule across several rows) | **Occurs** | **Occurs** (Demo 8A) | Prevented: error + retry (Demo 8B) |
| Deadlock | Can occur at any level; detected and one transaction aborted (Demo 7A) | Can occur | Can occur |

**Key finding:** Demo 4 and Demo 5c ran **the same steps in the same order** with opposite outcomes. Only the isolation level changed. The same pattern repeats one level higher with Demo 8A vs 8B. Choosing an isolation level is a correctness decision, not a performance setting to ignore.

## 6. Comparison of fixes

| Fix | Demo | How it works | Strengths | Costs / limits |
|---|---|---|---|---|
| Atomic update | 5a | Database reads and writes in one statement | Simplest; no waiting; works at READ COMMITTED | Only when the new value can be computed in one SQL statement |
| `SELECT … FOR UPDATE` | 5b | Pessimistic: lock the row before reading it | Never needs a retry; easy to reason about | Other sessions wait; risk of deadlock if lock order differs |
| REPEATABLE READ | 5c | Optimistic: detect conflicting update to the same row | No blocking on reads; stable snapshot for reports | App must catch error 40001 and retry; misses write skew |
| SERIALIZABLE (SSI) | 8B | Tracks reads and writes; aborts if no serial order exists | Strongest guarantee; catches write skew | More aborts; every transaction must retry on 40001 |
| Lock ordering | 7B | All code locks rows in the same order (ascending `drug_id`) | Prevents deadlocks with no extra cost | A coding rule: every developer must follow it |
| Trigger + `FOR UPDATE` | 9 | Database enforces the rule and serialises payments per invoice | Works at the default level for **every** application; keeps `invoice.status` correct | Hidden logic must be documented; small cost per insert; same-invoice payments queue |

## 7. Recommendations for CarePoint

| Operation | Recommended approach | Reason |
|---|---|---|
| Dispensing (stock deduction) | Atomic update + the existing `chk_stock_not_negative` CHECK, at READ COMMITTED; sort prescription items by `drug_id` | Correct, fast, no retries, no deadlocks (Demos 5a, 7B) |
| Recording payments | `trg_payment_check` + `trg_payment_sync_status` triggers | Stops overpayment and keeps status correct whatever app is used (Demo 9) |
| End-of-day stock and revenue reports | REPEATABLE READ (read-only) | All figures come from one consistent snapshot (Demo 6B) |
| Complex multi-row rules without a trigger | SERIALIZABLE with a retry loop | Catches write skew (Demo 8B) |
| All application code | Short transactions; retry on SQLSTATE `40001` (serialization) and `40P01` (deadlock) | Aborts are normal under concurrency, not bugs |

## 8. Link to Portfolio 1 design

In P1, `invoice.status` was stored as a column (a small denormalisation) for fast "unpaid invoices" queries, with the risk noted that it could drift from the real payment total. Demo 8 proved the risk: invoice 11 was fully paid but still `unpaid`. Demo 9 adds the promised control: the triggers keep the column correct on every INSERT, UPDATE and DELETE of a payment, and a one-off audit query found and fixed the single existing mismatch.

## 9. Limitations

- Demos used two manual sessions; real clinic load (many concurrent users) was not simulated, so throughput costs of SERIALIZABLE and locking were not measured.
- Retry logic is described and performed by hand, not implemented in application code.
- The status trigger does not recalculate if `invoice.total_amount` is changed; a second trigger on `clinic.invoice` would be needed.
- Rejected or rolled-back inserts still consume sequence values, so IDs have gaps (Demos 2, 8 and 9). This is expected; IDs should not be used as gap-free receipt numbers.
- In my first Demo 7 attempt I forgot Ada's COMMIT, so Part B did not prove the fix; I re-ran Part B cleanly (documented in `demo7-deadlock.sql`).

## 10. References

- PostgreSQL Global Development Group (2025) *PostgreSQL 18 Documentation*, Chapter 13: Concurrency Control. Available at: https://www.postgresql.org/docs/18/mvcc.html
- PostgreSQL Global Development Group (2025) *PostgreSQL 18 Documentation*, Chapter 41: PL/pgSQL – Trigger Functions. Available at: https://www.postgresql.org/docs/18/plpgsql-trigger.html
- Berenson, H., Bernstein, P., Gray, J., Melton, J., O'Neil, E. and O'Neil, P. (1995) 'A critique of ANSI SQL isolation levels', *Proceedings of ACM SIGMOD*, pp. 1–10.
- Ports, D.R.K. and Grittner, K. (2012) 'Serializable Snapshot Isolation in PostgreSQL', *Proceedings of the VLDB Endowment*, 5(12), pp. 1850–1861.
- Elmasri, R. and Navathe, S.B. (2016) *Fundamentals of Database Systems*. 7th edn. Pearson.

## 11. AI use

AI assistance (Claude) was used to plan the demo sequence, draft SQL step guides and explain errors. I ran every demo myself, checked each value against my own stock and payment trail, captured the screenshots, and corrected the scripts with my real results. See the AI use log in `reflection-notes.md`.
