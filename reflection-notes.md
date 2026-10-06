# Reflection Notes — MIT 8103 Portfolio

## Week 1 (5–6 Oct 2026): Setup, case study, entities, ERD, schema

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

### Challenges and how I solved them
- **mongosh OpenSSL error:** the OPENSSL_CONF environment variable pointed to openssl.exe
  instead of a config file, and no config file existed. Deleting the variable fixed it.
  Lesson: one program's environment settings can break another.
- **Git didn't upload my empty folders:** Git tracks files, not folders, so I added a
  placeholder README.md in each portfolio folder.
- **ERD layout:** TableGroup boxes overlapped with 18 tables, so I used coloured table
  headers instead and arranged tables in a grid with appointment as the central hub.
- **Showing the view in the ERD:** the free dbdiagram plan has no sticky notes. I learned
  that views are usually left out of ERDs because they store no data, so I explain the
  view in the README instead.
- **Push failed ("Could not resolve host: github.com"):** my internet dropped. The commit
  was still saved locally and pushed once I was back online. Committing (local) and pushing
  (remote) are separate steps, similar to how a replica keeps working during a network
  partition and syncs later (P5).
- Created schema.sql. Named every constraint so error messages show which rule failed.
  Used a partial unique index for "one active HMO per patient" because a normal UNIQUE
  would block a patient from ever having a past HMO record.

### Lessons learned
- Planning entities and cardinality before drawing saves rework.
- Storing the same fact twice (redundancy) risks inconsistency; derive it when you can.
- Business rules belong in the database (constraints), not only in the application,
  because every program that touches the data must then obey them.
- Small, frequent commits create a clear history of how the design evolved.

## AI use log
| Date | Tool | What I used it for | How I checked or changed it |
|---|---|---|---|
| 5 Oct | Claude (Anthropic) | Planning the portfolio roadmap; setup steps for PostgreSQL, MongoDB, Git | Followed the steps myself and fixed the errors that came up |
| 5 Oct | Claude | Troubleshooting the PATH and OpenSSL errors | Ran the diagnostic commands and confirmed the fixes worked |
| 5–6 Oct | Claude | Reviewing my entity list; feedback on my additions (nurse, vital_signs, HMO) | Chose which suggestions to accept; replaced uses_hmo with a view after weighing the trade-off |
| 6 Oct | Claude | DBML syntax and ERD layout for dbdiagram.io | Checked the diagram's cardinalities against my entities.md |