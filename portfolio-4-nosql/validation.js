// =====================================================================
// validation.js - CarePoint Specialist Clinic, Portfolio 4 (MongoDB)
// Demo B: $jsonSchema validation - MongoDB's version of the P1 CHECK
// constraints.
//
// Can be run as a whole (re-runnable):
//   mongosh carepoint --quiet validation.js > validation-results.txt
// Results in the comments are from my interactive run on 14 Oct 2026.
// =====================================================================

// ---------------------------------------------------------------------
// 1. The rules
// ---------------------------------------------------------------------
var visitRules = {
  $jsonSchema: {
    bsonType: "object",
    required: ["patient", "doctor", "branch", "start_time", "end_time", "status"],
    properties: {
      patient: { bsonType: "object", required: ["patient_id", "hospital_no", "full_name"],
                 properties: { hospital_no: { bsonType: "string", pattern: "^CP-[0-9]{6}$" } } },
      doctor:  { bsonType: "object", required: ["doctor_id", "full_name"] },
      branch:  { bsonType: "object", required: ["branch_id", "name"],
                 properties: { branch_id: { enum: [1, 2, 3] } } },
      start_time: { bsonType: "date" },
      end_time:   { bsonType: "date" },
      status: { enum: ["scheduled", "completed", "cancelled", "no_show"] },          // chk_appt_status
      consultation: { bsonType: "object", properties: {
        vital_signs: { bsonType: "array", items: { bsonType: "object",
          required: ["bp"],
          properties: {
            temp_celsius: { bsonType: "number", minimum: 30, maximum: 45 },         // chk_temp
            weight_kg:    { bsonType: "number", minimum: 0, exclusiveMinimum: true }, // chk_weight
            bp: { bsonType: "object", required: ["systolic", "diastolic"] } } } },
        lab_orders: { bsonType: "array", items: { bsonType: "object", required: ["test", "status"],
          properties: { status: { enum: ["ordered", "sample_collected", "completed", "cancelled"] } } } },
        prescription: { bsonType: "object", properties: {
          items: { bsonType: "array", items: { bsonType: "object", required: ["drug_id", "quantity"],
            properties: { quantity: { bsonType: "number", minimum: 1 } } } } } } } },  // chk_item_qty
      invoice: { bsonType: "object", required: ["invoice_id", "total_amount", "status", "payments"],
        properties: {
          total_amount: { bsonType: "decimal", minimum: 0 },                        // chk_invoice_total
          status: { enum: ["unpaid", "part_paid", "paid"] },                         // chk_invoice_status
          payments: { bsonType: "array", items: { bsonType: "object", required: ["amount", "method"],
            properties: {
              amount: { bsonType: "decimal", minimum: 0, exclusiveMinimum: true },  // chk_payment_amount
              method: { enum: ["cash", "card", "transfer", "hmo"] } } } } } }       // chk_payment_method
    }
  },
  // Rules that compare two fields cannot be written in $jsonSchema,
  // so they use $expr (aggregation expressions).
  $expr: { $and: [
    { $gt: ["$end_time", "$start_time"] },                                          // chk_appt_time
    { $allElementsTrue: [ { $map: {                                                 // chk_bp
        input: { $ifNull: ["$consultation.vital_signs", []] }, as: "v",
        in: { $gt: ["$$v.bp.systolic", "$$v.bp.diastolic"] } } } ] }
  ] }
};

// ---------------------------------------------------------------------
// 2. Audit existing data BEFORE switching the rules on
// ---------------------------------------------------------------------
print("Existing visits breaking the rules: " + db.visits.countDocuments({ $nor: [visitRules] }));
// Result: 0 - all 60,000 migrated visits already obey the rules, because
// PostgreSQL's CHECK constraints enforced them at source.

// ---------------------------------------------------------------------
// 3. Switch the rules on
// ---------------------------------------------------------------------
printjson(db.runCommand({ collMod: "visits", validator: visitRules,
                          validationLevel: "strict", validationAction: "error" }));
// Result: { ok: 1 }
print("validationLevel: " + db.getCollectionInfos({ name: "visits" })[0].options.validationLevel);
// Result: strict  (every insert AND update is checked)
// Evidence: screenshots/p4-demoB-audit-enable.png, p4-final-checks.png

// ---------------------------------------------------------------------
// 4. Tests
// ---------------------------------------------------------------------
var base = { _id: 900001,
  patient: { patient_id: 1, hospital_no: "CP-000001", full_name: "Test Patient" },
  doctor:  { doctor_id: 1, full_name: "Dr. Test" },
  branch:  { branch_id: 1, name: "Ikeja" },
  start_time: ISODate("2026-10-20T09:00:00Z"), end_time: ISODate("2026-10-20T09:30:00Z"),
  status: "scheduled" };

function expectFail(label, fn) {
  try { fn(); print("UNEXPECTED SUCCESS: " + label); }
  catch (e) { print("REJECTED as expected: " + label + "  (" + e.message + ")"); }
}

expectFail("T1 temperature 50", () =>
  db.visits.insertOne({ ...base, consultation: { vital_signs: [
    { temp_celsius: 50, bp: { systolic: 120, diastolic: 80 } } ] } }));
// Result: rejected. details: $jsonSchema (index 0) -> consultation ->
// vital_signs -> itemIndex 0 -> temp_celsius -> maximum 45, consideredValue 50
// Evidence: p4-demoB-t1-temp.png

expectFail("T2 systolic 80 < diastolic 120", () =>
  db.visits.insertOne({ ...base, consultation: { vital_signs: [
    { temp_celsius: 37, bp: { systolic: 80, diastolic: 120 } } ] } }));
// Result: rejected. details: $expr (index 1), "expression did not match"
// Evidence: p4-demoB-t2-bp.png

expectFail("T3 status 'done'", () =>
  db.visits.insertOne({ ...base, status: "done" }));
// Result: rejected. details: status -> enum, consideredValue 'done'
// Evidence: p4-demoB-t3-status.png

expectFail("T4 end time before start time", () =>
  db.visits.insertOne({ ...base, end_time: ISODate("2026-10-20T08:00:00Z") }));
// Result: rejected. details: $expr (index 1), "expression did not match"
// Evidence: p4-demoB-t4-time.png

expectFail("T5 payment method 'bitcoin'", () =>
  db.visits.insertOne({ ...base, invoice: { invoice_id: 999999,
    total_amount: NumberDecimal("5000"), status: "unpaid",
    payments: [ { amount: NumberDecimal("5000"), method: "bitcoin" } ] } }));
// Result: rejected. details: invoice -> payments -> itemIndex 0 -> method
// -> enum, consideredValue 'bitcoin'
// Evidence: p4-demoB-t5-method.png

expectFail("T6 UPDATE invoice.status to 'settled'", () =>
  db.visits.updateOne({ _id: 2 }, { $set: { "invoice.status": "settled" } }));
// Result: rejected ("Plan executor error during update :: caused by ::
// Document failed validation") - updates are checked, not only inserts.
// Evidence: p4-demoB-t6-update.png

// T7 - a VALID document with a patient that does not exist IS accepted
printjson(db.visits.insertOne({ ...base,
  patient: { patient_id: 999999, hospital_no: "CP-999999", full_name: "Nobody" } }));
printjson(db.visits.deleteOne({ _id: 900001 }));
// Result: inserted, then { acknowledged: true, deletedCount: 1 }
// Evidence: p4-demoB-t7-no-fk.png

// =====================================================================
// Observations
// =====================================================================
// 1. 7 of P1's CHECK constraints were re-created and all behaved the same
//    way: bad inserts AND bad updates were rejected.
// 2. $jsonSchema errors are precise (field path, rule, bad value). The two
//    $expr rules were combined in one $and, so T2 and T4 only report
//    "expression did not match" without saying WHICH rule failed.
//    Improvement: give each cross-field rule its own $expr clause - the
//    MongoDB equivalent of one named constraint per rule in P1.
// 3. T7 is the key difference from P1: there are NO foreign keys. The
//    validator checks the SHAPE of a document, never whether patient
//    999999 exists. The application must keep references valid.
// 4. Validation is optional and added afterwards. The audit (step 2) is
//    essential, because existing documents are not re-checked until they
//    are next updated.