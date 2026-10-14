// =====================================================================
// explain.js - CarePoint Specialist Clinic, Portfolio 4 (MongoDB)
// Measures 7 queries BEFORE and AFTER adding indexes, using
// explain("executionStats") - the MongoDB equivalent of P2's
// EXPLAIN (ANALYZE, BUFFERS). Each query runs 3 times; the median time
// is reported (same method as P2).
//
// Run from PowerShell in the portfolio-4-nosql folder:
//   mongosh carepoint --quiet explain.js > explain-results.txt
// Re-runnable: it drops the extra indexes first.
// =====================================================================

// ---- the queries being measured (same filters as queries.js) ----------
const LAB_OPEN = { $in: ["ordered", "sample_collected"] };
const tests = [
  { id: "Q1", desc: "patient visit history",
    run: () => db.visits.find({ "patient.hospital_no": "CP-011210" }).sort({ start_time: -1 }) },
  { id: "Q2", desc: "branch schedule for one day",
    run: () => db.visits.find({ "branch.branch_id": 2,
        start_time: { $gte: ISODate("2026-10-13T00:00:00Z"), $lt: ISODate("2026-10-14T00:00:00Z") } })
      .sort({ start_time: 1 }) },
  { id: "Q3", desc: "2025 revenue (reads ~1/3 of visits)",
    pipeline: [
      { $match: { "invoice.issued_at": { $gte: ISODate("2025-01-01T00:00:00Z"), $lt: ISODate("2026-01-01T00:00:00Z") } } },
      { $group: { _id: { b: "$branch.name", m: { $dateToString: { format: "%Y-%m", date: "$invoice.issued_at" } } },
                  revenue: { $sum: "$invoice.total_amount" } } } ] },
  { id: "Q5", desc: "outstanding lab orders",
    pipeline: [
      { $match: { "consultation.lab_orders.status": LAB_OPEN } },
      { $unwind: "$consultation.lab_orders" },
      { $match: { "consultation.lab_orders.status": LAB_OPEN } } ] },
  { id: "Q6", desc: "unpaid / part-paid invoices",
    pipeline: [
      { $match: { "invoice.status": { $in: ["unpaid", "part_paid"] } } },
      { $project: { paid: { $sum: "$invoice.payments.amount" }, total: "$invoice.total_amount" } } ] },
  { id: "Q8", desc: "systolic >= 160 in last 90 days",
    pipeline: [
      { $match: { "consultation.vital_signs": { $elemMatch: {
          "bp.systolic": { $gte: 160 }, recorded_at: { $gte: ISODate("2026-07-10T00:00:00Z") } } } } } ] },
  { id: "Q10", desc: "patient profile with $lookup", coll: "patients",
    pipeline: [
      { $match: { hospital_no: "CP-011210" } },
      { $lookup: { from: "visits", localField: "_id", foreignField: "patient.patient_id", as: "visits" } } ] },
];

// ---- helpers --------------------------------------------------------------
function collect(obj, key, out) {            // gather every value of `key` in a nested object
  if (Array.isArray(obj)) obj.forEach(x => collect(x, key, out));
  else if (obj && typeof obj === "object") {
    for (const k of Object.keys(obj)) {
      if (k === key && typeof obj[k] === "string") out.push(obj[k]);
      else collect(obj[k], key, out);
    }
  }
  return out;
}

function explainOnce(t) {
  let ex;
  if (t.run) ex = t.run().explain("executionStats");
  else ex = db.getCollection(t.coll || "visits").explain("executionStats").aggregate(t.pipeline);
  // find() and fully pushed-down pipelines report at the top level;
  // other pipelines report inside stages[0].$cursor
  const cursor = (ex.stages && ex.stages[0].$cursor) ? ex.stages[0].$cursor : ex;
  const es = cursor.executionStats || {};
  const plan = cursor.queryPlanner ? cursor.queryPlanner.winningPlan : {};
  let stages = collect(plan, "stage", []);
  const strategy = collect(plan, "strategy", []);          // $lookup join method
  // $lookup that is NOT pushed down reports its own stats in a later stage
  let lookupDocs = null;
  if (ex.stages) {
    ex.stages.forEach(s => {
      if (s.$lookup) {
        lookupDocs = s.totalDocsExamined;
        stages.push("$lookup" + (s.indexesUsed && s.indexesUsed.length ? "(IXSCAN " + s.indexesUsed.join(",") + ")" : "(COLLSCAN)"));
      }
    });
  }
  const docs = (es.totalDocsExamined || 0) + (lookupDocs || 0);
  return {
    stages: [...new Set(stages.concat(strategy))].join(" > "),
    keys: es.totalKeysExamined,
    docs: docs,
    returned: es.nReturned,
    ms: es.executionTimeMillis,
  };
}

function measure(phase) {
  print("\n==================== " + phase + " ====================");
  const results = {};
  tests.forEach(t => {
    const runs = [explainOnce(t), explainOnce(t), explainOnce(t)];
    const times = runs.map(r => r.ms).sort((a, b) => a - b);
    const r = runs[2];                                   // stats from the last (warm) run
    r.median_ms = times[1];
    r.times = times.join("/");
    results[t.id] = r;
    print(`${t.id} (${t.desc})`);
    print(`   plan: ${r.stages}`);
    print(`   keys examined: ${r.keys}   docs examined: ${r.docs}   returned: ${r.returned}`);
    print(`   time ms (3 runs): ${r.times}   median: ${r.median_ms}`);
  });
  return results;
}

// ---- 1. start from a clean state (only the default _id indexes) ------------
db.visits.dropIndexes();
db.patients.dropIndexes();
const before = measure("BEFORE (only _id indexes)");

// ---- 2. create indexes (one per access pattern) ----------------------------
print("\n==================== CREATING INDEXES ====================");
const created = [
  db.visits.createIndex({ "patient.hospital_no": 1, start_time: -1 }, { name: "ix_visit_patient_time" }),      // Q1: equality + sort
  db.visits.createIndex({ "branch.branch_id": 1, start_time: 1 },     { name: "ix_visit_branch_time" }),       // Q2: equality + range + sort
  db.visits.createIndex({ "consultation.lab_orders.status": 1 },      { name: "ix_visit_lab_status" }),        // Q5: multikey (array)
  db.visits.createIndex({ "invoice.status": 1 },                      { name: "ix_visit_invoice_status" }),    // Q6
  db.visits.createIndex({ "consultation.vital_signs.bp.systolic": 1,
                          "consultation.vital_signs.recorded_at": 1 }, { name: "ix_visit_bp_time" }),          // Q8: multikey compound
  db.visits.createIndex({ "patient.patient_id": 1 },                  { name: "ix_visit_patient_id" }),        // Q10: $lookup foreignField
  db.patients.createIndex({ hospital_no: 1 }, { name: "ux_patient_hospital_no", unique: true }),               // Q10: $match
];
created.forEach(n => print("created " + n));
// No index for Q3: it reads about a third of all visits, so a full scan is
// expected to stay the best plan (same finding as P2).

const after = measure("AFTER");

// ---- 3. summary table -----------------------------------------------------------
print("\n==================== SUMMARY ====================");
print("Query | docs examined before -> after | returned | median ms before -> after | plan after");
tests.forEach(t => {
  const b = before[t.id], a = after[t.id];
  print(`${t.id} | ${b.docs} -> ${a.docs} | ${a.returned} | ${b.median_ms} -> ${a.median_ms} | ${a.stages}`);
});

print("\nIndex sizes (bytes) - the storage cost of each index:");
["visits", "patients"].forEach(c => {
  const s = db.getCollection(c).aggregate([{ $collStats: { storageStats: {} } }]).next().storageStats;
  print(c + ": data " + s.size + " bytes, " + s.count + " documents");
  printjson(s.indexSizes);
});