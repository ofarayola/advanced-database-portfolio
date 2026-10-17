# Portfolio 5 – Distributed and Cloud Database Exercise

**Module:** MIT 8103 Advanced Database Systems · **Case study:** CarePoint Specialist Clinic (Ikeja = branch 1, Lekki = 2, Yaba = 3)
**Tools:** MongoDB 9.0.2, mongosh 2.12, Python 3.13 (pymongo) on Windows · **Replica set:** `rs0`

## 1. Overview

CarePoint has three branches that all depend on one clinical database. If that database stops, no branch can record a consultation, dispense a drug or take a payment. This portfolio builds and tests a **distributed** version of the P4 MongoDB database, with evidence for each topic named in the brief:

| Brief topic | What I did | Section |
|---|---|---|
| Replication | 3-node replica set; data written once and copied to every node | 4 |
| Availability | Stopped and crashed the primary while writing continuously; measured the downtime | 5 |
| Consistency | Write concerns `w: 1` / `majority` / `3`; behaviour with one and two nodes down | 6 |
| Transactions | Multi-document transaction for dispensing (the gap left open in P4) | 7 |
| Sharding | Shard-key design and trade-offs for CarePoint (discussion) | 8 |
| Cloud deployment | CAP analysis, deployment design and security (discussion) | 9 |

**Why no Docker:** the brief accepts a "discussion or setup" and lists configuration files as evidence. Three `mongod` processes on one PC behave the same way as three containers (same elections, replication and write concerns), and need no extra installation. The limits of this choice are in section 11.

## 2. Folder contents

| File | Purpose |
|---|---|
| `config/node1.conf`, `node2.conf`, `node3.conf` | Configuration of each replica set member (port, data folder, log file, `replSetName: rs0`, memory cap) |
| `copy_to_replicaset.py` | Copies the P4 `carepoint` database (with validator and indexes) into the replica set and checks every node |
| `logs/elections.txt` | Election messages from the node logs |
| `screenshots/` | Evidence (section 12) |

## 3. Setup

```powershell
# data folders OUTSIDE the repository
New-Item -ItemType Directory -Force -Path C:\data\rs0\node1, C:\data\rs0\node2, C:\data\rs0\node3, C:\data\rs0\logs

# one window per node
& "C:\Program Files\MongoDB\Server\9.0\bin\mongod.exe" --config config\node1.conf   # port 27018
& "C:\Program Files\MongoDB\Server\9.0\bin\mongod.exe" --config config\node2.conf   # port 27019
& "C:\Program Files\MongoDB\Server\9.0\bin\mongod.exe" --config config\node3.conf   # port 27020
```

```javascript
// mongosh --port 27018
rs.initiate({ _id: "rs0", members: [
  { _id: 0, host: "127.0.0.1:27018" },
  { _id: 1, host: "127.0.0.1:27019" },
  { _id: 2, host: "127.0.0.1:27020" } ] })
```

Each config file caps the storage cache at 0.25 GB (`cacheSizeGB`) because three servers share one PC. Applications connect to the **set**, not to a single server, so the driver always finds the current primary:

```
mongodb://127.0.0.1:27018,127.0.0.1:27019,127.0.0.1:27020/carepoint?replicaSet=rs0
```

**Result:** the three nodes held an election. 27018 became **PRIMARY**, and 27019 and 27020 became **SECONDARY**, all with `health: 1`.

## 4. Replication

`copy_to_replicaset.py` wrote the P4 data **only to the primary**, then asked each node directly how many documents it held:

| Collection | 27018 | 27019 | 27020 |
|---|---|---|---|
| branches | 3 | 3 | 3 |
| doctors | 42 | 42 | 42 |
| drugs | 20 | 20 | 20 |
| lab_tests | 10 | 10 | 10 |
| patients | 20,000 | 20,000 | 20,000 |
| visits (with P4 validator) | 60,000 | 60,000 | 60,000 |

- Drug 3 at Ikeja was **4054** on the replica set, the P4 value, so this is the same data.
- A test record written on the primary was read back from secondary 27019. `rs.printSecondaryReplicationInfo()` showed both secondaries **0 secs behind the primary**.
- A write sent directly to the secondary was refused: `MongoServerError[NotWritablePrimary]: not primary`. **One node accepts writes; the others are read-only copies.**

## 5. Availability: failover tests

A loop wrote one record every 0.5 s (60 writes) through the replica-set connection, while I stopped the primary.

| Test | How the primary was stopped | Writes OK | Time with no writes possible | New primary |
|---|---|---|---|---|
| Clean shutdown | Ctrl+C on 27018 | **60 / 60** | **< 1 s** (switch between writes 8 and 9, both at 14:46:00 UTC) | 27019 |
| Secondary stopped | Ctrl+C on 27018 (by then a secondary) | **60 / 60** | **0 s** | 27019 (unchanged) |
| **Crash** | `Stop-Process -Force` on 27019 (no warning) | **55 / 60** | **13.0 s** (write 15 → write 21 at 14:59:52.463 UTC; writes 16–20 failed) | 27020 |

The crash downtime was measured from the data itself, using the `at` time each write saved and `$setWindowFields` / `$shift` to find the biggest gap between saved writes:

```
{ i: 21, at: ISODate('2026-10-16T14:59:52.463Z'), gap_seconds: 13.022, writes_missing_before_this: 5 }
{ i: 22, ...                                       gap_seconds: 1.099,  writes_missing_before_this: 0 }
```

**Why the two failovers differ:**
- **Clean shutdown:** the old primary stepped down itself and handed over to an up-to-date secondary. The driver retried the one write caught in the switch automatically (*retryable writes*), so the application saw **no error at all**.
- **Crash:** nothing told the other nodes. They waited **10 s** without a heartbeat (`electionTimeoutMillis`, the default), then held an election (about 1 s), then the client had to find the new primary (1–2 s, see the 1.1 s gap at write 22). That adds up to about 13 s.

**Recovery:** each stopped node was restarted with the same command. It rejoined as a **SECONDARY** (it did not take back the primary role), copied the writes it had missed, and showed 0 s lag. No manual repair was needed and no committed data was lost.

**Meaning for CarePoint:** a planned restart (maintenance) causes no interruption. An unplanned server crash stops all three branches from saving for about **13 seconds**, after which the system recovers by itself.

## 6. Consistency: write concerns and the CAP theorem

The write concern `w` sets how many nodes must confirm a write before the client is told "OK".

| Step | Nodes running | Write | Result |
|---|---|---|---|
| 10a | 3 | `w: 1`, `w: "majority"`, `w: 3` | All acknowledged |
| 10b | 2 | `w: "majority"` | Acknowledged (2 of 3 is a majority) |
| 10b | 2 | `w: 3, wtimeout: 3000` | **`WriteConcernTimeout`**, yet `n: 1` and the document **was saved** |
| 10c | 1 | Any write | **Refused.** The last node stepped down to SECONDARY; **no primary existed** |
| 10c | 1 | Read | **Worked** (reads still possible) |
| 10d | 3 (restarted) | — | Healed by itself: one PRIMARY, all healthy |

**Findings:**
1. **An error does not always mean "nothing was saved".** The `w: 3` write timed out but was stored on the primary. A write-concern error means "I cannot confirm this is as safe as you asked", not "this was rolled back".
2. **"Saved" does not always mean "safe".** In step 10c, the write "only one node left" reported an error but **was** saved on node 3 alone, before it stepped down. It survived only because node 3 won the next election. If another node had won, MongoDB would have **rolled it back**, because a majority never confirmed it. **Only `w: "majority"` writes are guaranteed to survive a failover.** CarePoint should use it for every clinical and billing write (it is MongoDB's default).
3. **MongoDB chose consistency over availability (CP).** With only one node visible, node 3 could not tell whether the others had crashed or were cut off by a network split and possibly electing their own primary. To prevent two primaries accepting conflicting writes (*split brain*), it stopped accepting writes while still serving reads. This is the **CP** choice in the CAP theorem: during a partition, the minority side loses write availability so the data stays consistent.
4. **Typos in my commands:** `wtiwtimeout` in 10a was not recognised but made no difference because all 3 nodes were up. In 10b, the misspelled `writeConwriteConcern` was ignored, so the default write concern (`majority`) applied. I left these in the evidence rather than hiding them.

**PACELC view:** even without a partition there is a trade-off between **latency and consistency**. `w: "majority"` waits for a second node; reading from a secondary is faster and spreads load, but may return slightly old data. For CarePoint: clinical and billing writes use `majority`. Reports (P2 Q3, Q7) could read from a secondary, but stock checks before dispensing must read from the primary.

## 7. Multi-document transaction (closing the P4 gap)

In P4, dispensing changed the `drugs` document atomically, but recording the dispense in the `visits` document was a **second** document, which could not be included. Multi-document transactions **require a replica set**.

| Test | What happened | Result |
|---|---|---|
| Transaction left open too long | Both updates succeeded (`1 | 1`), but I spent over 60 s checking another window before committing | **`NoSuchTransaction … has been aborted`**. MongoDB aborts transactions open longer than 60 s (`transactionLifetimeLimitSeconds`). Stock stayed 4054 and the visit had no `dispensed` field: **nothing was saved** |
| Successful dispense (patient Nathaniel Olawale, 10 tablets) | Stock −10 and visit marked `dispensed: { by: "Pharmacist Ada" }` in one transaction | Before commit, another session read **4054**. After `COMMITTED`, it read **4044**. Both changes appeared at the same moment |
| Failing dispense (visit 38541, Philip Chukwu, 5,000 tablets) | Visit update succeeded (`visit update: 1`), stock update matched nothing (`stock update: 0`), so the code called `abortTransaction()` | Visit has **no `dispensed` field** (the successful update was undone); stock still **4044** |

**Comparison with P3 (PostgreSQL):** the behaviour matches `BEGIN … COMMIT / ROLLBACK`: atomic, and invisible to others until commit. Two differences:
- PostgreSQL keeps a forgotten transaction open indefinitely (my Demo 7 `A*=>` prompt). MongoDB **aborts it after 60 s**, which protects other users but means a transaction must be short.
- In PostgreSQL a failed CHECK raised an error automatically. In MongoDB the update simply matched 0 documents, so **the application had to check `modifiedCount` and abort itself**.

**Design note:** because P4 embedded the stock inside the drug document, most writes need no transaction. Transactions are needed only where a business action spans documents (dispensing and recording it). MongoDB's guidance is the same: use them where needed, not for everything.

## 8. Sharding: design discussion

Sharding splits one collection across several replica sets (*shards*) by a **shard key**. A router (`mongos`) sends each query to the shard(s) holding the data. Unlike replication, it adds **capacity**, not copies.

### 8.1 Does CarePoint need sharding now? No.

- The `visits` data is **57.9 MB** for 60,000 visits (P4). The generated data covers about two years, so roughly **30,000 visits per year ≈ 29 MB per year**.
- A single replica set handles that comfortably for decades.
- Sharding would add at least 3 config servers, routers and a second replica set: more cost and complexity with no benefit at this size.
- **Replication (availability) is CarePoint's real need; sharding is not.**

### 8.2 If CarePoint grew into a national network (e.g. 200 branches)

| Shard key on `visits` | Distribution | Q1: patient history | Q2: branch schedule | Problems |
|---|---|---|---|---|
| `{ "branch.branch_id": 1 }` | By branch | Scatter to all shards (unless branch known) | **Targeted** (one shard) | Low cardinality (only 3 values today); a busy branch becomes a *hot shard*; chunks can't split below one branch |
| `{ "patient.patient_id": "hashed" }` | Even spread | **Targeted** | Scatter-gather to every shard | No locality: a branch's data is everywhere |
| **`{ "branch.branch_id": 1, "patient.patient_id": 1 }`** | By branch, then patient | Targeted when the branch is known; otherwise scatter | **Targeted** | Must pair with **zone sharding** (branches in a region pinned to a shard in that region) to keep data near users |

**Recommendation:** the compound key, with **zones by region** (e.g. Lagos branches on a Lagos-area shard). Most daily work (schedules, stock, billing) happens within one branch, so those queries stay on one shard, and a patient's records stay together within their branch.

- **Not sharded:** `drugs`, `branches`, `doctors` and `lab_tests` are tiny reference collections; they stay unsharded on one shard.
- **Patient history across branches** (P1's doctor-rotation case) would become a scatter-gather query. That's acceptable because it's infrequent compared with branch-local work.

## 9. Cloud deployment and CAP: design discussion

### 9.1 Proposed deployment

- **Managed database service** (e.g. MongoDB Atlas, or a managed PostgreSQL service for the relational system of record) running a **3-node replica set across 3 availability zones** in one region. A zone failure then behaves like my crash test: automatic failover in seconds.
- **Region choice:** as close to Lagos as possible, to reduce latency for the three branches. Availability of cloud regions in or near Nigeria changes over time, so the current options would need to be checked before deployment.
- **Data protection:** patient records are sensitive health data. The **Nigeria Data Protection Act 2023** applies, including its rules on transferring personal data outside Nigeria, so the hosting region and provider must be approved for that.
- **Backups:** continuous backups with point-in-time restore. Replication is *not* a backup: a mistaken `deleteMany` is replicated to every node within milliseconds.

### 9.2 Where CarePoint sits on CAP, and the branch-connectivity risk

- My tests show MongoDB with `w: "majority"` is **CP**. In the cloud, a **branch that loses its internet connection** is on the minority side of a partition: it cannot reach the primary, so it cannot save anything.
- For a clinic in Lagos, where connectivity can be unreliable, this is the biggest real-world risk. Options:
  - a backup internet link per branch (the simplest);
  - a read-only local copy so staff can still *view* records during an outage;
  - an offline queue for non-critical writes that syncs later. That would trade consistency for availability (AP behaviour) and would need conflict rules, so it is unsuitable for stock and billing.
- **My recommendation:** keep CP for stock and billing (correctness matters more than availability, as P3 showed), and give each branch a second internet connection.

### 9.3 Security (fixing what my local setup lacks)

My setup printed: *"Access control is not enabled for the database."* That's acceptable for a local exercise, never for patient data. A production deployment needs:
- authentication with role-based users (e.g. pharmacists can update stock but not delete visits);
- `keyFile` or x.509 authentication between replica set members;
- TLS for all connections;
- `bindIp` limited to the application network (my config uses `127.0.0.1`);
- encryption at rest and audit logging.

## 10. PostgreSQL comparison

| Feature | PostgreSQL (P1–P3 system of record) | MongoDB replica set (P5) |
|---|---|---|
| Replication | Streaming replication to standbys | Built in (replica set) |
| Automatic failover | Needs an extra tool (e.g. Patroni) or a managed service | Built in (elections) |
| "Confirmed by a replica" | `synchronous_commit` + synchronous standbys | `w: "majority"` |
| Multi-statement transactions | Always available | Need a replica set; 60 s limit |
| Horizontal scaling | Extensions (e.g. Citus) or partitioning | Built-in sharding |

## 11. Limitations

- **All three nodes ran on one PC.** There was no real network latency, and one machine failing would stop all three. A real deployment puts each node on a separate server or availability zone.
- **Network partitions were simulated by stopping processes**, not by cutting a network link between running nodes.
- **The crash was simulated** with `Stop-Process -Force`, not a power failure (a real power cut could also lose unflushed disk writes).
- **Timings are from one run each** on a small local setup; a production cluster would differ.
- **Sharding and cloud deployment are design discussions**, not implemented (the brief allows "discussion or setup").
- **No authentication** on the local replica set (section 9.3).

## 12. Evidence

| Screenshot | Shows |
|---|---|
| `p5-rs-initiated.png` | `rs.initiate` and the first election (27018 PRIMARY) |
| `p5-data-replicated.png` | Same document counts on all 3 nodes; drug 3 = 4054 |
| `p5-replication-primary.png` | Write on the primary; both secondaries 0 s behind |
| `p5-replication-secondary.png` | Read from a secondary; write refused (`not primary`) |
| `p5-failover-clean.png` | Clean shutdown: 60/60 writes, primary 27018 → 27019 |
| `p5-failover-crash.png`, `p5-crash-downtime.png` | Crash: 55/60 writes, 13.0 s gap |
| `p5-node2-rejoined.png` | Crashed node back as SECONDARY, 0 s behind |
| `p5-write-concern.png` | `w: 3` timeout with one node down, document still saved |
| `p5-no-majority.png`, `p5-healed.png` | Writes refused with one node left; recovery |
| `p5-consistency-docs.png` | The 6 documents, including the non-majority write that survived |
| `p5-transaction-timeout.png` | Transaction aborted after 60 s; nothing saved |
| `p5-transaction-commit.png` | 4054 before, 4044 after commit |
| `p5-transaction-abort.png` | Failed dispense: visit change undone, stock unchanged |

## 13. References

- MongoDB, Inc. (n.d.) *Replication*. Available at: https://www.mongodb.com/docs/manual/replication/ (Accessed: 17 October 2026)
- MongoDB, Inc. (n.d.) *Replica Set Elections*. Available at: https://www.mongodb.com/docs/manual/core/replica-set-elections/ (Accessed: 17 October 2026)
- MongoDB, Inc. (n.d.) *Write Concern*. Available at: https://www.mongodb.com/docs/manual/reference/write-concern/ (Accessed: 17 October 2026)
- MongoDB, Inc. (n.d.) *Transactions*. Available at: https://www.mongodb.com/docs/manual/core/transactions/ (Accessed: 17 October 2026)
- MongoDB, Inc. (n.d.) *Sharding* and *Choose a Shard Key*. Available at: https://www.mongodb.com/docs/manual/sharding/ (Accessed: 17 October 2026)
- Brewer, E. (2012) 'CAP twelve years later: how the "rules" have changed', *Computer*, 45(2), pp. 23–29.
- Abadi, D. (2012) 'Consistency tradeoffs in modern distributed database system design: CAP is only part of the story', *Computer*, 45(2), pp. 37–42.
- Federal Republic of Nigeria (2023) *Nigeria Data Protection Act, 2023*.

## 14. AI use

AI assistance (Claude) was used to plan the P5 approach against the brief, write the node configuration files and the copy script, and give me step-by-step commands for each demo. I ran every step myself across five terminal windows, captured the evidence, and the figures in this README (13.0 s crash downtime, 55/60 writes, the surviving non-majority write, 4054 → 4044) come from my own outputs. See the AI use log in `reflection-notes.md`.