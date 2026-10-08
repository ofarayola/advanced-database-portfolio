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

### Challenges
- **"Import psycopg2 could not be resolved" (Pylance):** VS Code was checking a different
  Python installation from the one pip had installed the libraries into. I confirmed the
  libraries worked with python -c "import psycopg2" and selected the matching interpreter
  in VS Code. Lesson: a PC can have several Pythons, and the editor, pip and the terminal
  must all use the same one.

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