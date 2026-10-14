// =====================================================================
// queries.js - CarePoint Specialist Clinic, Portfolio 4 (MongoDB)
// The SAME 8 business questions as Portfolio 2 (queries.sql), answered on
// the document model, plus 2 MongoDB-specific queries (Q9, Q10).
//
// Run from PowerShell in the portfolio-4-nosql folder:
//   mongosh carepoint --quiet queries.js > query-results.txt
// =====================================================================

// ---- helper: print one result row per line, with readable dates/money --
function fmt(v) {
  if (v instanceof Date) return v.toISOString().slice(0, 16).replace("T", " ");
  if (v && v._bsontype === "Decimal128") return Number(v.toString());
  if (Array.isArray(v)) return v.map(fmt);
  if (v && typeof v === "object") {
    const out = {};
    for (const k of Object.keys(v)) out[k] = fmt(v[k]);
    return out;
  }
  return v;
}
function show(title, rows) {
  print("\n=== " + title + " ===");
  rows.forEach(r => print(JSON.stringify(fmt(r))));
  print("(" + rows.length + " rows)");
}

// ---------------------------------------------------------------------
// Q1  Front desk: a patient's visit history (newest first)
// SQL: 5-table join patient-appointment-doctor-branch-consultation
// Mongo: one collection; patient, doctor and branch names are embedded
// ---------------------------------------------------------------------
show("Q1 Visit history for CP-011210",
  db.visits.find(
    { "patient.hospital_no": "CP-011210" },
    { _id: 0, "patient.full_name": 1, start_time: 1, "branch.name": 1,
      "doctor.full_name": 1, status: 1, "consultation.diagnosis": 1 }
  ).sort({ start_time: -1 }).toArray());

// ---------------------------------------------------------------------
// Q2  Front desk: Lekki (branch 2) schedule for 13 Oct 2026
// SQL: range on start_time (the P2 rewrite) + joins to doctor, patient
// ---------------------------------------------------------------------
show("Q2 Lekki schedule 2026-10-13",
  db.visits.find(
    { "branch.branch_id": 2,
      start_time: { $gte: ISODate("2026-10-13T00:00:00Z"),
                    $lt:  ISODate("2026-10-14T00:00:00Z") } },
    { _id: 0, start_time: 1, end_time: 1, "doctor.full_name": 1,
      "patient.full_name": 1, status: 1 }
  ).sort({ start_time: 1 }).toArray());

// ---------------------------------------------------------------------
// Q3  Management: monthly revenue per branch in 2025
// SQL: invoice JOIN appointment JOIN branch, GROUP BY branch, month
// ---------------------------------------------------------------------
show("Q3 Monthly revenue per branch, 2025",
  db.visits.aggregate([
    { $match: { "invoice.issued_at": { $gte: ISODate("2025-01-01T00:00:00Z"),
                                       $lt:  ISODate("2026-01-01T00:00:00Z") } } },
    { $group: {
        _id: { branch: "$branch.name",
               month: { $dateToString: { format: "%Y-%m", date: "$invoice.issued_at" } } },
        invoices: { $sum: 1 },
        revenue:  { $sum: "$invoice.total_amount" } } },
    { $sort: { "_id.branch": 1, "_id.month": 1 } },
    { $project: { _id: 0, branch: "$_id.branch", month: "$_id.month", invoices: 1, revenue: 1 } }
  ]).toArray());

// ---------------------------------------------------------------------
// Q4  Pharmacy: top 10 drugs by units prescribed since 1 Oct 2025
// SQL: prescription_item JOIN prescription JOIN drug, GROUP BY drug
// Mongo: $unwind the embedded items array (one row per item)
// ---------------------------------------------------------------------
show("Q4 Top 10 drugs since 2025-10-01",
  db.visits.aggregate([
    { $match: { "consultation.prescription.issued_at": { $gte: ISODate("2025-10-01T00:00:00Z") } } },
    { $unwind: "$consultation.prescription.items" },
    { $group: {
        _id: { name: "$consultation.prescription.items.name",
               strength: "$consultation.prescription.items.strength" },
        units: { $sum: "$consultation.prescription.items.quantity" },
        times_prescribed: { $sum: 1 } } },
    { $sort: { units: -1 } },
    { $limit: 10 },
    { $project: { _id: 0, name: "$_id.name", strength: "$_id.strength", units: 1, times_prescribed: 1 } }
  ]).toArray());

// ---------------------------------------------------------------------
// Q5  Lab: outstanding lab orders (oldest first)
// SQL: lab_order JOIN lab_test JOIN consultation JOIN appointment JOIN patient
// Mongo: match visits that contain an outstanding order, unwind, filter again
// ---------------------------------------------------------------------
show("Q5 Outstanding lab orders",
  db.visits.aggregate([
    { $match: { "consultation.lab_orders.status": { $in: ["ordered", "sample_collected"] } } },
    { $unwind: "$consultation.lab_orders" },
    { $match: { "consultation.lab_orders.status": { $in: ["ordered", "sample_collected"] } } },
    { $sort: { "consultation.created_at": 1 } },
    { $project: { _id: 0,
        lab_order_id: "$consultation.lab_orders.lab_order_id",
        test: "$consultation.lab_orders.test.name",
        patient: "$patient.full_name",
        ordered_at: "$consultation.created_at" } }
  ]).toArray());

// ---------------------------------------------------------------------
// Q6  Billing: 20 largest outstanding balances
// SQL: invoice JOIN patient LEFT JOIN payment, GROUP BY invoice
// Mongo: payments are inside the invoice, so "paid" is a $sum over an
//        embedded array - no join and no GROUP BY needed
// ---------------------------------------------------------------------
show("Q6 Top 20 outstanding balances",
  db.visits.aggregate([
    { $match: { "invoice.status": { $in: ["unpaid", "part_paid"] } } },
    { $project: { _id: 0,
        invoice_id: "$invoice.invoice_id",
        hospital_no: "$patient.hospital_no",
        full_name: "$patient.full_name",
        total_amount: "$invoice.total_amount",
        paid: { $sum: "$invoice.payments.amount" } } },
    { $addFields: { balance: { $subtract: ["$total_amount", "$paid"] } } },
    { $sort: { balance: -1, invoice_id: 1 } },
    { $limit: 20 }
  ]).toArray());

// ---------------------------------------------------------------------
// Q7  Management: doctors ranked by completed consultations per branch, 2025
// SQL: GROUP BY + RANK() OVER (PARTITION BY branch ORDER BY count DESC)
// Mongo: $group + $setWindowFields with $rank (the window-function equivalent)
// ---------------------------------------------------------------------
show("Q7 Doctor ranking per branch, 2025",
  db.visits.aggregate([
    { $match: { status: "completed",
                start_time: { $gte: ISODate("2025-01-01T00:00:00Z"),
                              $lt:  ISODate("2026-01-01T00:00:00Z") } } },
    { $group: { _id: { branch: "$branch.name", doctor: "$doctor.full_name" },
                consultations: { $sum: 1 } } },
    { $setWindowFields: {
        partitionBy: "$_id.branch",
        sortBy: { consultations: -1 },
        output: { rank_in_branch: { $rank: {} } } } },
    { $sort: { "_id.branch": 1, rank_in_branch: 1, "_id.doctor": 1 } },
    { $project: { _id: 0, branch: "$_id.branch", doctor: "$_id.doctor",
                  consultations: 1, rank_in_branch: 1 } }
  ]).toArray());

// ---------------------------------------------------------------------
// Q8  Clinical alert: highest systolic BP (>= 160) in the 90 days to 8 Oct 2026
// SQL: vital_signs JOIN consultation JOIN appointment JOIN patient, LIMIT 20
// ---------------------------------------------------------------------
show("Q8 Severe hypertension readings (top 20)",
  db.visits.aggregate([
    { $match: { "consultation.vital_signs": { $elemMatch: {
        "bp.systolic": { $gte: 160 },
        recorded_at: { $gte: ISODate("2026-07-10T00:00:00Z") } } } } },
    { $unwind: "$consultation.vital_signs" },
    { $match: { "consultation.vital_signs.bp.systolic": { $gte: 160 },
                "consultation.vital_signs.recorded_at": { $gte: ISODate("2026-07-10T00:00:00Z") } } },
    { $sort: { "consultation.vital_signs.bp.systolic": -1, "consultation.vital_signs.recorded_at": -1 } },
    { $limit: 20 },
    { $project: { _id: 0,
        hospital_no: "$patient.hospital_no", full_name: "$patient.full_name",
        bp_systolic: "$consultation.vital_signs.bp.systolic",
        bp_diastolic: "$consultation.vital_signs.bp.diastolic",
        recorded_at: "$consultation.vital_signs.recorded_at" } }
  ]).toArray());

// =====================================================================
// MongoDB-specific queries (not possible in the same way in P2)
// =====================================================================

// ---------------------------------------------------------------------
// Q9  Lab: Full Blood Counts with low haemoglobin (Hb < 10 g/dL)
// Queries a field that exists ONLY in FBC results (polymorphic results).
// In PostgreSQL the result is a single TEXT value, so this was impossible.
// ---------------------------------------------------------------------
show("Q9 FBC results with Hb < 10 g/dL, per branch",
  db.visits.aggregate([
    { $match: { "consultation.lab_orders": { $elemMatch: {
        "test.lab_test_id": 1, "result.hb_g_dl": { $lt: 10 } } } } },
    { $unwind: "$consultation.lab_orders" },
    { $match: { "consultation.lab_orders.test.lab_test_id": 1,
                "consultation.lab_orders.result.hb_g_dl": { $lt: 10 } } },
    { $group: { _id: "$branch.name",
                low_hb_results: { $sum: 1 },
                lowest_hb: { $min: "$consultation.lab_orders.result.hb_g_dl" },
                average_hb: { $avg: "$consultation.lab_orders.result.hb_g_dl" } } },
    { $sort: { _id: 1 } },
    { $project: { _id: 0, branch: "$_id", low_hb_results: 1, lowest_hb: 1,
                  average_hb: { $round: ["$average_hb", 1] } } }
  ]).toArray());

// ---------------------------------------------------------------------
// Q10 Front desk: patient profile with current HMO and visit summary
// Uses $lookup (MongoDB's left outer join) from patients to visits,
// because visits are REFERENCED, not embedded, in the patient document.
// ---------------------------------------------------------------------
show("Q10 Patient profile with $lookup (CP-011210)",
  db.patients.aggregate([
    { $match: { hospital_no: "CP-011210" } },
    { $lookup: { from: "visits", localField: "_id",
                 foreignField: "patient.patient_id", as: "visits" } },
    { $project: { _id: 0, hospital_no: 1, full_name: 1, gender: 1,
        current_hmo: { $filter: { input: { $ifNull: ["$hmo_history", []] }, as: "h",
                                  cond: { $not: ["$$h.end_date"] } } },
        total_visits: { $size: "$visits" },
        completed_visits: { $size: { $filter: { input: "$visits", as: "v",
                                     cond: { $eq: ["$$v.status", "completed"] } } } },
        last_visit: { $max: "$visits.start_time" } } }
  ]).toArray());