# Reflection Notes — MIT 8103 Portfolio

## Week 1 (5–7 Oct 2026): Portfolio 1 — Database Design and Modelling

### Design choices
- **Case study:** CarePoint Specialist Clinic (3 branches in Lagos). Chose a clinic because
  appointments and drug stock create real concurrency problems (P3), lab results vary in
  structure (P4, NoSQL), and multiple branches suit replication/sharding (P5).
- **branch_id on appointment:** At first I planned to derive the branch through
  doctor → department → branch. I added branch_id because consultants rotate between
  branches, so the doctor's home department does not show where an appointment happens.
- **uses_hmo — column vs view:** I first wanted a uses_hmo TRUE/FALSE column on patient.
  I realised it duplicates what hmo_mapping already records, so the two could disagree.
  I replaced it with a view (patient_hmo_status) that calculates it, so it is always correct.
- **Blood pressure as two columns:** "120/80" in one field breaks 1NF and can't be compared
  or averaged, so I used bp_systolic and bp_diastolic.
- **vital_signs as its own table, with nurse_id:** vitals can be taken more than once per
  visit and are recorded by nurses, which also gives the nurse table a real role.
- **HMO history:** hmo_mapping has enrollee_no, start_date and end_date so a change of HMO
  keeps the old record.
- **Junction tables** for the M:N relationships: prescription_item, drug_stock, lab_order.

### Schema decisions (B4)
- **Named every constraint** (e.g. chk_temp, uq_doctor_slot) so error messages show
  exactly which business rule was broken.
- **Partial unique index for "one active HMO per patient":** a normal UNIQUE on patient_id
  would stop a patient from ever having a past HMO record. Adding WHERE end_date IS NULL
  applies the rule only to the current registration.
- **UNIQUE on consultation.appointment_id and prescription.consultation_id** turns a
  one-to-many foreign key into a one-to-one relationship.
- **ON DELETE RESTRICT vs CASCADE:** medical records (patients, appointments,
  consultations) use RESTRICT so they can never be deleted by accident.
  prescription_item and vital_signs use CASCADE because they mean nothing without
  their parent record.
- **UNIQUE (doctor_id, start_time)** prevents double-booking a doctor's slot.
- **CHECK constraints** enforce clinical and business rules in the database itself
  (temperature 30–45 °C, systolic > diastolic, stock never negative, payment > 0,
  a completed lab test must have a result), not just in application code.
- **Table creation order:** parent tables (branch, department) are created before the
  tables that reference them; otherwise the foreign keys fail.
- **DROP SCHEMA ... CASCADE at the top** makes the script re-runnable, so I can fix
  mistakes and rebuild the whole database in one step.

### Testing decisions (B5)
- **Realistic sample data:** 3 branches, 5 patients, 4 doctors, 6 appointments covering
  every status (completed, scheduled, cancelled, no_show), and a doctor rotating to
  another branch, to show the branch_id design decision in real data.
- **Re-runnable test data:** sample-data.sql starts with TRUNCATE ... RESTART IDENTITY
  CASCADE, so IDs always restart at 1 and the tests can refer to fixed IDs.
- **Two kinds of test:** 16 negative tests (bad data that must be rejected) and
  3 positive tests (correct behaviour that must succeed): the view updating when an HMO
  ends, the partial index allowing a new HMO after the old one ends, and CASCADE
  removing prescription items.
- **Saved output as evidence:** ran the tests with psql -a and redirected the output to
  test-results.txt, so each statement appears next to the error it produced.

### Normalisation (B6)
- Worked from an unnormalised spreadsheet-style "visit record" to 3NF: split the drug
  list (1NF), moved drug and visit details out of the composite-key table (2NF), then
  separated patient, doctor, department, branch and HMO (3NF). Checked BCNF.
- Moved diagnosis from appointment to consultation, because cancelled and no-show
  appointments have no diagnosis. This also separates booking from clinical record.
- While writing it I found two real redundancies I had not noticed before:
  invoice.patient_id (derivable via appointment) and invoice.status (derivable from
  payments). I kept both as documented trade-offs and plan to control them in P3.
- Explained why branch_id on appointment is NOT redundant (doctor rotation), and why
  uses_hmo was rejected in favour of a view.

### Challenges and how I solved them
- **psql not recognised:** PostgreSQL's bin folder wasn't on PATH. Added it to the user
  Path variable; learned that terminals must be reopened to pick up the change.
  Ran schema.sql from the VS Code terminal with psql -f once the Path fix worked.
- **mongosh OpenSSL error:** the OPENSSL_CONF environment variable pointed to openssl.exe
  instead of a config file, and no config file existed. Deleting the variable fixed it.
  Lesson: one program's environment settings can break another.
- **Git didn't upload my empty folders:** Git tracks files, not folders, so I added a
  placeholder README.md in each portfolio folder.
- **ERD layout:** TableGroup boxes overlapped with 18 tables, so I removed them and
  arranged the tables in horizontal bands by area (organisation, patients/HMO, clinical,
  pharmacy, billing). I re-exported the final image after noticing a row was still
  highlighted from being selected.
- **Showing the view in the ERD:** the free dbdiagram plan has no sticky notes. I learned
  that views are usually left out of ERDs because they store no data, so I explain the
  view in the README instead.
- **Push failed ("Could not resolve host: github.com"):** my internet dropped. The commit
  was still saved locally and pushed once I was back online. Committing (local) and pushing
  (remote) are separate steps, similar to how a replica keeps working during a network
  partition and syncs later (P5).
- **schema.sql ran first time:** 18 tables, 1 view and the partial unique index were
  created with no errors. Creating tables in dependency order (parents before children)
  avoided foreign-key errors, and DROP SCHEMA ... CASCADE means I can safely re-run
  the script after any change. Verified with a count of tables in information_schema
  and a pgAdmin screenshot (screenshots/b4-tables-created.png).
- **Constraint tests:** all 16 violations were rejected by the expected named
  constraint, and all 3 positive tests succeeded (see test-results.txt).
- **Positive tests change the data:** after running the tests once, patient 1's HMO had
  ended and prescription 2 was deleted, so I learned to re-run sample-data.sql before
  repeating the tests.
- **Typing the password every time:** set $env:PGPASSWORD for the terminal session so
  psql could run scripts without prompting, including when output is redirected to a file.

### Documentation
- Wrote the P1 README (files, how to run, ERD, normalisation, trade-offs, constraint-to-test
  table, evidence) and the main repository README (case study, portfolio progress table,
  technologies, AI-use declaration) so an assessor can follow the work from the front page.

### Lessons learned
- Planning entities and cardinality before drawing saves rework.
- Storing the same fact twice (redundancy) risks inconsistency; derive it when you can,
  and document it as a trade-off when you choose not to.
- Business rules belong in the database (constraints), not only in the application,
  because every program that touches the data must then obey them.
- In constraint testing, an ERROR is the *desired* result: it proves the rule works.
  Testing what should succeed matters too, so the rules are not too strict.
- Small, frequent commits create a clear history of how the design evolved.

## Week 2 (8 Oct 2026): Portfolio 2 — Query Processing and Optimisation

### Data generation
- Wrote a Python generator (Faker + psycopg2) to load ~20,000 patients and ~60,000
  appointments, plus ~41,600 consultations, ~33,500 lab orders, ~53,000 prescription
  items and ~41,600 invoices. Small data can't show optimisation: every query runs in
  under 1 ms with or without indexes.
- Made the data realistic so query plans behave as they would in a real clinic: some
  doctors busier than others, 10% branch rotation, appointments only Monday–Saturday
  08:00–16:00, diagnoses linked to matching lab tests and drugs, 40% of patients on an HMO.
- The generator respects every P1 constraint (no double-booking, systolic > diastolic,
  one active HMO per patient), which confirmed my schema rules work with realistic
  volumes too.
- Used random.seed(42) so the data, and therefore my timings, can be reproduced.
- Inserted rows in batches with execute_values (5,000 per round trip) instead of one
  INSERT per row, and ran ANALYZE afterwards so the query planner has up-to-date statistics.
- Learned to reset SERIAL sequences with setval() after inserting explicit IDs; otherwise
  the next normal INSERT would try to reuse ID 1.
- Loaded successfully: appointment statuses add up to 60,000
  (screenshots/p2-data-loaded.png).
- Noticed that uq_doctor_slot already created an index on (doctor_id, start_time), so a
  doctor's schedule query is fast before I add any index. Constraints create indexes as
  a side effect, which I need to account for in my analysis.

### Queries and baseline (P2)
- Wrote 8 queries based on real clinic roles (front desk, lab, pharmacy, billing,
  management), including multi-table joins, aggregation and a window function (RANK).
- Kept the EXPLAIN versions in a separate file so the before and after runs use
  exactly the same queries, and ran each twice so the timing isn't distorted by a cold cache.
- Main finding: PostgreSQL indexes primary keys and UNIQUE columns automatically, but
  NOT foreign keys. So Q1 finds the patient instantly but then scans all 60,000
  appointments to find their 12 visits.

### P2 wrap-up
- Wrote the P2 README with method, headline results and key findings, so the assessor
  can follow the work without reading every plan.
- If I did P2 again, I would measure write cost (INSERT speed) alongside read speed,
  since every index slows down writes.

### Challenges
- **"Import psycopg2 could not be resolved" (Pylance):** VS Code was checking a different
  Python installation from the one pip had installed the libraries into. I confirmed the
  libraries worked with python -c "import psycopg2" and selected the matching interpreter
  in VS Code. Lesson: a PC can have several Pythons, and the editor, pip and the terminal
  must all use the same one.

## Week 2–3 (9–12 Oct 2026): Portfolio 3 — Transactions and Concurrency

### Session 1 (9 Oct): ACID basics (Demos 1–3)

**What I demonstrated**
- **COMMIT (Demo 1):** dispensing as one transaction (prescription + item + stock + invoice).
  While Ada's transaction was open she saw stock 4264 but Bayo still saw 4288: no dirty read.
  After COMMIT all four changes appeared to Bayo at once.
- **ROLLBACK (Demo 2):** trying to dispense 5000 tablets broke chk_stock_not_negative.
  PostgreSQL then refused every further command until ROLLBACK, and the rollback also
  removed the prescription and item that had been inserted successfully. Atomicity.
- **SAVEPOINT (Demo 3):** rolled back only the failed inhaler line and still committed
  the Paracetamol, so one bad item no longer cancels the whole prescription.

**Things I noticed**
- PostgreSQL never allows dirty reads; READ UNCOMMITTED behaves as READ COMMITTED.
- Sequence values are not rolled back: Demo 2 got prescription 35372 because 35371 had
  been used by an abandoned transaction. Gaps in IDs are normal and safe.
- Bayo's own open transaction saw Ada's change as soon as she committed. In READ COMMITTED
  each statement sees the latest committed data, which leads to non-repeatable reads (Session 2).
- After an UPDATE the row order changed: PostgreSQL's MVCC writes a new row version
  instead of overwriting, which is also what makes isolation possible.

**Challenges**
- Setting \set PROMPT1 'A=> ' hid the transaction indicator; 'A%x=> ' shows * and !.
- I typed CLS inside psql, which started an unfinished statement (carepoint-#); \r
  cleared it. \! cls is the psql way to clear the screen.
- A forgotten open transaction caused "there is already a transaction in progress";
  I learned to check the prompt for * before typing BEGIN.

### Session 2 (9 Oct): Concurrency anomalies and fixes (Demos 4–6)

**What I did**
- Reproduced a **lost update** (Demo 4) with two psql sessions: Bayo read the stock
  before Ada committed, then wrote back a value calculated from that old read.
  Stock ended at 4244 instead of 4234, so 10 units of Artemether/Lumefantrine
  disappeared from the records without any error.
- Fixed the same scenario three ways:
  - **5a, atomic update:** `SET quantity_on_hand = quantity_on_hand - n`. The database
    does the read and the write in one step.
  - **5b, `SELECT … FOR UPDATE`** (pessimistic locking): Bayo's session waited until
    Ada committed, then read the correct value.
  - **5c, REPEATABLE READ** (optimistic): Bayo got
    `could not serialize access due to concurrent update`. After ROLLBACK and a retry,
    the result was correct.
- Showed a **non-repeatable read** (Demo 6). Under READ COMMITTED, Ada read 4154 and
  then 4139 inside one transaction. Under REPEATABLE READ, she kept seeing 4139 while
  Bayo had already committed 4124.

**What I learned**
- The most striking result: Demo 4 and Demo 5c had **the same order of events** but
  opposite outcomes. Only the isolation level changed. Under READ COMMITTED the
  conflict went unnoticed and data was lost. Under REPEATABLE READ, PostgreSQL detected
  it and refused. Isolation level is a real correctness decision, not a setting to
  ignore.
- A lost update raises no error, which is what makes it dangerous. Nothing in the
  output warned me. I only caught it because I worked out the expected value by hand.
- The three fixes have different costs. Atomic update is simplest, but it only works
  when the new value can be computed in a single statement. FOR UPDATE is safe but
  makes other sessions wait, which could slow a busy pharmacy. REPEATABLE READ avoids
  waiting, but the application must catch the error and retry.
- MVCC means old and new row versions exist side by side. Each transaction sees the
  version its snapshot allows. That's why Ada and Bayo saw different numbers at the
  same moment, and neither was "wrong".
- For CarePoint, I would use atomic updates (with a CHECK that stock can't go
  negative) for dispensing, and REPEATABLE READ for end-of-day stock reports that
  must be internally consistent.

**Challenges**
- My first Demo 4 attempt ran the steps without real overlap, so no anomaly appeared.
  I learned that the interleaving (read before the other commits, write after) is
  what creates the problem.
- Keeping track of which terminal was inside a transaction. The `A%x=> ` prompt
  (showing `*`) helped a lot.
- Recording a stock trail (4288 → … → 4124) made every result checkable instead of
  guessed.

### Session 3 (9 and 12 Oct): Deadlock, write skew and triggers (Demos 7–9)

**What I did**
- **Demo 7, deadlock:** Ada updated drug 3 then drug 1 while Bayo updated drug 1 then
  drug 3. PostgreSQL detected the cycle after about one second, aborted Bayo
  (`ERROR: deadlock detected`) and undid all of his work. I then showed the fix: when
  both sessions update rows in ascending `drug_id` order, Bayo only waits briefly and
  no deadlock happens (final stock: drug 1 = 3345, drug 3 = 4074).
- **Demo 8, write skew:** two cashiers both saw a balance of ₦10,750 on invoice 11 and
  both recorded a full payment. Under REPEATABLE READ both commits succeeded, so the
  patient paid ₦21,500. Under SERIALIZABLE, Bayo's COMMIT failed with
  `could not serialize access due to read/write dependencies`. His retry showed a
  balance of 0.00, so only one payment was kept.
- **Demo 9, triggers:** I created two triggers on `clinic.payment`. One keeps
  `invoice.status` correct after every insert, update or delete. The other blocks
  overpayment by locking the invoice row first. An audit query found invoice 11 still
  marked `unpaid`, and I fixed it. In the tests, the status changed automatically,
  an overpayment was rejected, and the Demo 8 double payment was blocked even at the
  default READ COMMITTED level.
- Wrote the P3 README with a results table, an isolation-level table, a comparison of
  fixes and recommendations for CarePoint.

**What I learned**
- **Waiting is not the problem; cycles are.** In Demo 7B Bayo still waited, but because
  both sessions locked rows in the same order, a cycle could not form. A simple coding
  rule (sort prescription items by `drug_id`) prevents deadlocks completely.
- **Write skew is harder to spot than a lost update.** Nothing was overwritten and no
  error appeared. Each transaction was correct on its own, but together they broke a
  rule that covers several rows (total payments must not exceed the invoice). That is
  why REPEATABLE READ, which caught the lost update in Demo 5c, missed it.
- **Each isolation level catches one more problem.** READ COMMITTED missed the lost
  update (Demo 4). REPEATABLE READ caught it (5c) but missed write skew (8A).
  SERIALIZABLE caught write skew (8B). Same steps, different level, different outcome.
- **The database can protect the rule itself.** The trigger's `FOR UPDATE` lock made
  payments for the same invoice take turns, so the double payment was stopped without
  SERIALIZABLE and without retry code. It is the Demo 5b idea (pessimistic locking)
  applied to a write-skew problem.
- **Design decisions have consequences later.** In P1 I stored `invoice.status` for
  fast queries and wrote that it could drift. Demo 8 showed it really did drift, and
  Demo 9 added the control I had promised. This connected the design, transaction and
  integrity parts of the module for me.
- **Sequences never go backwards.** Payment IDs 39542 and 39543 (deleted) and the
  failed inserts left gaps, which is why 39544 and 39549 were the next IDs. IDs should
  not be used as gap-free receipt numbers.

**Challenges**
- **I forgot Ada's COMMIT in Demo 7.** The prompt stayed `A*=>`, so her Part A and
  Part B work became one transaction, and Part B did not prove the fix. Final numbers
  were still correct, but the evidence was weak. I re-ran Part B cleanly and recorded
  the mistake in the script. Lesson: check the `*` in the prompt before every step.
- **I typed PowerShell commands inside psql.** The `$env:` and `psql` lines went into
  the query buffer and the prompt changed to `carepoint-#`. I learned that `-#` means
  an unfinished statement and that `\r` clears it.
- **Wrong table name in my notes.** The Demo 6 script referred to `pharmacy_stock`, but
  the real table is `drug_stock`. I fixed it with Find and Replace. Checking names
  against the schema matters even in comments.
- Understanding why a trigger needs two separate statements (lock the invoice first,
  then sum the payments) took some thought. The second statement takes a fresh
  snapshot after the wait, so it can see the other cashier's committed payment.

### P3 overall reflection
Before P3, I thought transactions were just "BEGIN and COMMIT". Running two terminals
side by side showed me that the hard problems only appear when sessions overlap in
time, and that some of them (lost update, write skew) give no error at all. The most
useful habit I built was keeping a running trail of expected values (stock 4288 →
… → 4074, payment IDs). It let me prove each anomaly with numbers instead of
assuming. For a real clinic, I would combine atomic updates, a fixed lock order and
database triggers, and keep SERIALIZABLE with retries for rules that span several
rows.

## AI use log
| Date | Tool | What I used it for | How I checked or changed it |
|---|---|---|---|
| 5 Oct | Claude (Anthropic) | Planning the portfolio roadmap; setup steps for PostgreSQL, MongoDB, Git | Followed the steps myself and fixed the errors that came up |
| 5 Oct | Claude | Troubleshooting the PATH and OpenSSL errors | Ran the diagnostic commands and confirmed the fixes worked |
| 5–6 Oct | Claude | Reviewing my entity list; feedback on my additions (nurse, vital_signs, HMO) | Chose which suggestions to accept; replaced uses_hmo with a view after weighing the trade-off |
| 6 Oct | Claude | DBML syntax and ERD layout for dbdiagram.io | Checked the diagram's cardinalities against my entities.md |
| 6 Oct | Claude | Drafting schema.sql (tables, constraints, partial index, view) | Ran it in PostgreSQL, confirmed 18 tables + 1 view in pgAdmin, and checked each constraint matched my business rules |
| 6 Oct | Claude | Sample data and constraint test scripts | Ran both, checked each error named the expected constraint, reviewed test-results.txt |
| 6–7 Oct | Claude | Structuring the normalisation write-up, P1 README and main README | Checked every functional dependency against my own tables; matched screenshot names to my files; filled in my own details |
| 8 Oct | Claude | Python data generator for P2 | Read each section, ran it, verified row counts and status distribution in psql |
| 8–9 Oct | Claude | Index design, Q2 rewrite, explaining the idx_scan counts, results and README structure | Ran every script, compared all numbers with my own plans, tested the planner-statistics explanation myself |
| 9 Oct | Claude | Designing Demos 1–3 and explaining psql prompts and errors | Ran every step in two sessions, checked each result against the expected values, fixed a wrong ID in my own verification query |
| 9 Oct | Claude | Explaining why my first lost-update attempt (Demo 4) showed no anomaly | Learned the read/write interleaving is what matters; re-ran it myself in two terminals and verified the 10-unit loss by calculation |
| 9 Oct | Claude | Suggesting three fixes for the lost update (Demos 5a–5c) with SQL templates | Ran each fix, checked final stock values against my own trail, and compared the trade-offs in my own words |
| 9 Oct | Claude | Non-repeatable read script (Demo 6) and explanation of MVCC snapshots | Executed both isolation levels, captured screenshots, and confirmed the values (4154→4139 vs 4139 kept) myself |
| 9 Oct | Claude | Checking the schema and correcting the table name in my Demo 6 script | Changed `pharmacy_stock` to `drug_stock` in the file myself |
| 9 Oct | Claude | Deadlock and lock-ordering steps (Demo 7) and reviewing my screenshot | AI spotted that I had skipped Ada's COMMIT, so Part B did not prove the fix; I re-ran Part B myself and documented the mistake |
| 9 Oct | Claude | Explaining why my psql prompt changed to `carepoint-#` | Learned the PowerShell lines had gone into the query buffer; cleared it with `\r` |
| 9 Oct | Claude | Designing the double-payment (write skew) scenario for Demo 8 | Ran both isolation levels, captured the evidence, and checked payment IDs and totals myself |
| 12 Oct | Claude | Trigger functions and test plan for Demo 9 | Ran the setup and all four tests, confirmed each status change and error, and linked the result back to my P1 design trade-off |
| 12 Oct | Claude | Drafting the P3 README from my recorded results | Checked the Demo 1–3 details and screenshot names against my own files before committing |
