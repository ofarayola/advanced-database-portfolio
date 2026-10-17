"""
copy_to_replicaset.py
CarePoint Specialist Clinic - Portfolio 5 (Distributed databases)

Copies the P4 "carepoint" database from the single MongoDB server
(port 27017) into the 3-node replica set rs0 (ports 27018-27020),
including each collection's validation rules and indexes.

The data is written ONCE, to the primary. Replication copies it to the
two secondaries automatically - the script then checks that every node
holds the same number of documents.

Usage (PowerShell, from the portfolio-5-distributed-cloud folder,
with all three nodes running and rs.initiate() already done):
  python copy_to_replicaset.py
"""

import time

from pymongo import MongoClient, ReadPreference

SOURCE_URI = "mongodb://localhost:27017"
RS_URI = "mongodb://127.0.0.1:27018,127.0.0.1:27019,127.0.0.1:27020/?replicaSet=rs0"
NODES = ["127.0.0.1:27018", "127.0.0.1:27019", "127.0.0.1:27020"]
DB = "carepoint"
BATCH = 5000

src = MongoClient(SOURCE_URI)[DB]
rs_client = MongoClient(RS_URI)
dst = rs_client[DB]

rs_client.admin.command("ping")   # connect first, so the driver discovers which node is primary
print("Replica set primary:", rs_client.primary)   # (host, port) of the current primary

for name in sorted(src.list_collection_names()):
    if name.startswith("system.") or name == "demo_counter":
        continue

    # 1. re-create the collection with the same options (e.g. the P4 validator)
    info = src.command("listCollections", filter={"name": name})["cursor"]["firstBatch"][0]
    options = info.get("options", {})
    dst.drop_collection(name)
    dst.create_collection(name, **options)

    # 2. copy the documents in batches (written to the primary only)
    batch, copied = [], 0
    for doc in src[name].find():
        batch.append(doc)
        if len(batch) == BATCH:
            dst[name].insert_many(batch)
            copied += len(batch)
            batch = []
    if batch:
        dst[name].insert_many(batch)
        copied += len(batch)

    # 3. re-create the P4 indexes
    for idx in src[name].list_indexes():
        if idx["name"] == "_id_":
            continue
        dst[name].create_index(list(idx["key"].items()), name=idx["name"],
                               unique=idx.get("unique", False))

    print(f"  {name:<10} copied {copied:>6} documents"
          + (" (with validator)" if "validator" in options else ""))

# 4. verification: ask EACH node directly how many documents it holds
time.sleep(3)   # give the secondaries a moment to apply the last writes
print("\nDocuments on each node (written once to the primary, replicated to the others):")
print(f"  {'collection':<10} " + "  ".join(f"{n:>17}" for n in NODES))
for name in ["branches", "doctors", "drugs", "lab_tests", "patients", "visits"]:
    counts = []
    for node in NODES:
        c = MongoClient(f"mongodb://{node}/?directConnection=true",
                        read_preference=ReadPreference.SECONDARY_PREFERRED)
        counts.append(c[DB][name].count_documents({}))
        c.close()
    flag = "OK" if len(set(counts)) == 1 else "DIFFERENT"
    print(f"  {name:<10} " + "  ".join(f"{n:>17}" for n in counts) + f"  {flag}")

drug3 = dst.drugs.find_one({"_id": 3}, {"stock": {"$elemMatch": {"branch_id": 1}}})
print("\nDrug 3 at Ikeja on the replica set:", drug3["stock"][0]["quantity_on_hand"])