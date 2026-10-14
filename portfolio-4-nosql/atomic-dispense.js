// =====================================================================
// atomic-dispense.js - CarePoint Specialist Clinic, Portfolio 4 (MongoDB)
// Demo A: P3's lost update replayed in MongoDB, and the atomic fix.
//
// This is a STEP GUIDE, not a script to run in one go: Parts 1 and 2 need
// TWO mongosh windows running at the same time.
//   Window A = Ada, Window B = Bayo   (both: mongosh carepoint)
// Results below are from my run on 14 Oct 2026 (MongoDB 9.0.2, mongosh 2.12).
// =====================================================================


// ---------------------------------------------------------------------
// PART 1 - Read-then-write from two sessions -> LOST UPDATES
// (same pattern as P3 Demo 4, repeated 10,000 times)
// ---------------------------------------------------------------------
// [A] practice counter, so real stock is not damaged
db.demo_counter.drop()
db.demo_counter.insertOne({ _id: "stock", qty: 10000 })

// [A and B at the same time] 5,000 x (read qty, then write qty - 1)
var t = Date.now(); for (let i = 0; i < 5000; i++) { const q = db.demo_counter.findOne({ _id: "stock" }).qty; db.demo_counter.updateOne({ _id: "stock" }, { $set: { qty: q - 1 } }); } print("done in " + (Date.now() - t) + " ms")
// A: done in 24146 ms     B: done in 24106 ms   (the loops fully overlapped)

// [A]
db.demo_counter.findOne()
// Result: { _id: 'stock', qty: 4260 }
// Correct answer: 10000 - 5000 - 5000 = 0
// -> 4,260 of 10,000 decrements LOST (42.6%), with NO error in either window.
// Evidence: screenshots/p4-demoA1-lost-update.png
//
// Why: each document write is atomic, but the read and the write are two
// separate operations. Between Ada's findOne and her updateOne, Bayo wrote
// a new value, which Ada then overwrote with a value based on her old read.
// Note: my first paste in each window was cut off / had a typo (__id); it
// matched no document and changed nothing.


// ---------------------------------------------------------------------
// PART 2 - Atomic $inc from two sessions -> NO lost updates
// (same idea as P3 Demo 5a: SET qty = qty - 1)
// ---------------------------------------------------------------------
// [A] reset
db.demo_counter.updateOne({ _id: "stock" }, { $set: { qty: 10000 } })

// [A and B at the same time] 5,000 x $inc -1
var t = Date.now(); for (let i = 0; i < 5000; i++) { db.demo_counter.updateOne({ _id: "stock" }, { $inc: { qty: -1 } }); } print("done in " + (Date.now() - t) + " ms")
// A: done in 7249 ms     B: done in 6922 ms

// [A]
db.demo_counter.findOne()
// Result: { _id: 'stock', qty: 0 }  -> exactly correct, 0 updates lost.
// Evidence: screenshots/p4-demoA2-atomic-inc.png
//
// $inc reads and writes inside the server as ONE atomic operation on one
// document, so there is no gap for the other session. It was also about
// 3.4x faster (~7 s vs ~24 s): one round trip per decrement instead of two.

// [A] clean up
db.demo_counter.drop()


// ---------------------------------------------------------------------
// PART 3 - Real dispensing with a stock check (drug 3 at Ikeja)
// The condition and the change are in ONE update, so the check cannot be
// out of date by the time the change is made.
// ---------------------------------------------------------------------
// Before: drug 3 (Artemether/Lumefantrine), Ikeja = 4074
// (the final value of the P3 stock trail, carried over by the migration)

// Dispense 20 - only if at least 20 are in stock
db.drugs.updateOne(
  { _id: 3, stock: { $elemMatch: { branch_id: 1, quantity_on_hand: { $gte: 20 } } } },
  { $inc: { "stock.$.quantity_on_hand": -20 } }
)
// Result: matchedCount: 1, modifiedCount: 1

// Try to dispense 5000 - more than is in stock
db.drugs.updateOne(
  { _id: 3, stock: { $elemMatch: { branch_id: 1, quantity_on_hand: { $gte: 5000 } } } },
  { $inc: { "stock.$.quantity_on_hand": -5000 } }
)
// Result: matchedCount: 0, modifiedCount: 0  -> refused, nothing changed

db.drugs.findOne({ _id: 3 }, { stock: { $elemMatch: { branch_id: 1 } } })
// Result: quantity_on_hand: 4054
// Evidence: screenshots/p4-demoA3-conditional.png, p4-final-checks.png
//
// Comparison with P3 Demo 2: PostgreSQL REJECTED the over-dispense with an
// ERROR (chk_stock_not_negative). MongoDB raises NO error - the update
// simply matches 0 documents. The application must check matchedCount and
// tell the pharmacist. Forgetting that check would fail silently.
//
// Note: MongoDB now holds 4054 while PostgreSQL still holds 4074. The two
// databases are separate copies; nothing keeps them in step after the
// one-off migration.


// =====================================================================
// Observations
// =====================================================================
// 1. Single-document atomicity is not enough on its own. Part 1 used
//    atomic single-document writes and still lost 42.6% of updates,
//    because the application split one logical change into a read and a
//    write. The fix is to send the whole change to the server ($inc).
// 2. Embedding stock for all branches inside the drug document means a
//    dispense touches exactly one document, so it is atomic without a
//    transaction. Recording the prescription in the visit as well would
//    touch a SECOND document; doing both atomically would need a
//    multi-document transaction, which requires a replica set (P5).
// 3. Same lesson as P3, measured at scale: the safest update is the one
//    that does not depend on a value the application read earlier.