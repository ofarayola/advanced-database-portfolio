# Advanced Database Systems Portfolio — CarePoint Specialist Clinic

**Student:** Farayola Oluwadamilola · **Student ID:** 301900517
**Course:** MIT 8103 Advanced Database Systems · Master of Information Technology
**Institution:** Miva Open University · **Session:** 2026/2027, First Semester

---

## Case study

**CarePoint Specialist Clinic** is a simulated outpatient clinic with three branches
in Lagos (Ikeja, Lekki and Yaba), offering consultations, laboratory tests and a pharmacy.

| | |
|---|---|
| **Nature of the business** | Multi-branch outpatient healthcare provider |
| **Users of the database** | Front-desk staff, doctors, nurses, lab scientists, pharmacists, billing officers, patients |
| **Major data stored** | Patients, HMO registrations, doctors, nurses, departments, branches, appointments, consultations, vital signs, lab tests and results, prescriptions, drugs and stock, invoices and payments |
| **Key operations** | Register patients, book/cancel appointments, record vitals and diagnoses, order lab tests and record results, issue prescriptions and reduce stock, bill and receive payments (including HMO), retrieve a patient's history |

**Why this case study:** appointment slots and drug stock create real concurrency problems
(Portfolio 3), lab results and clinical notes vary in structure, which suits NoSQL
(Portfolio 4), and three branches give a natural reason for replication and sharding
(Portfolio 5).

---

## Portfolio progress

| # | Portfolio | Status | Key evidence |
|---|---|---|---|
| 1 | [Database Design and Modelling](portfolio-1-database-design/) | ✅ Complete | ER diagram (18 tables), schema with named constraints, normalisation UNF→3NF/BCNF, 16 constraint tests passed |
| 2 | [Query Processing and Optimisation](portfolio-2-query-optimisation/) | ✅ Complete |  8 queries, before/after EXPLAIN ANALYZE; Q1 17× and Q2 20× faster; partial indexes; PostgreSQL 18 skip scan observed |
| 3 | [Transactions and Concurrency](portfolio-3-transactions-concurrency/) | ⏳ In Progress | — |
| 4 | [NoSQL and Advanced Data Models](portfolio-4-nosql/) | ⬜ Not started | — |
| 5 | [Distributed and Cloud Database](portfolio-5-distributed-cloud/) | ⬜ Not started | — |

---

## Technologies

| Tool | Version | Used for |
|---|---|---|
| PostgreSQL | 18 | Relational database (Portfolios 1–3) |
| pgAdmin 4 | — | Database administration and screenshots |
| MongoDB Community Server | 9.0 | Document database (Portfolio 4) |
| mongosh | 2.12 | MongoDB shell |
| Python | 3.13 | Data generation (Faker), database scripts |
| dbdiagram.io | — | ER diagram |
| Git / GitHub | 2.54 | Version control |

---

## Repository structure

```
advanced-database-portfolio/
├── portfolio-1-database-design/          ER diagram, schema, tests, normalisation
├── portfolio-2-query-optimisation/       Queries, execution plans, indexing
├── portfolio-3-transactions-concurrency/ Transactions, isolation, locking
├── portfolio-4-nosql/                    MongoDB model and queries
├── portfolio-5-distributed-cloud/        Replication, sharding, deployment
├── reflection-notes.md                   Running log of decisions, challenges and AI use
└── README.md                             This file
```

---

## How to run

**Prerequisites:** PostgreSQL 18 with a database named `carepoint`.

```powershell
# Portfolio 1: build the schema, load sample data, run constraint tests
psql -U postgres -d carepoint -f portfolio-1-database-design/schema.sql
psql -U postgres -d carepoint -f portfolio-1-database-design/sample-data.sql
psql -U postgres -d carepoint -a -f portfolio-1-database-design/test-constraints.sql
```

Each portfolio folder has its own README with full instructions.

---

## Reflection

Design decisions, challenges and lessons are recorded as I go in
[reflection-notes.md](reflection-notes.md). A summary reflection will be added
here when all portfolios are complete.

---

## AI use declaration

- **Tool used:** Claude (Anthropic).
- **What it was used for:** planning the portfolio, explaining concepts, troubleshooting
  software setup (PATH and OpenSSL errors), reviewing my entity design, and helping draft
  SQL scripts and documentation structure.
- **How I reviewed and verified the output:** I ran every script myself in PostgreSQL,
  checked each constraint against my business rules, confirmed results through the test
  output and pgAdmin, made my own design decisions (for example, replacing a stored
  `uses_hmo` column with a view), and rewrote the documentation in my own words.
  I can explain every file in this repository.

A dated log of AI use is kept in [reflection-notes.md](reflection-notes.md#ai-use-log).

---

## References

- PostgreSQL Global Development Group (2025) *PostgreSQL 18 Documentation*. Available at: https://www.postgresql.org/docs/18/
- MongoDB Inc. (2025) *MongoDB Manual*. Available at: https://www.mongodb.com/docs/manual/
- Elmasri, R. and Navathe, S.B. (2016) *Fundamentals of Database Systems*. 7th edn. Pearson.
- dbdiagram.io (2025) *DBML documentation*. Available at: https://dbml.dbdiagram.io/docs/