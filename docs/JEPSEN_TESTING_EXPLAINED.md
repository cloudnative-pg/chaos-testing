# Understanding Jepsen Testing for CloudNativePG

**Date**: October 30, 2025  
**Context**: Your mentor's recommendation to use "Jepsen tests"

---

## What is Jepsen?

**Jepsen** is a **distributed systems testing framework** created by Kyle Kingsbury (aphyr) that specializes in finding **data consistency bugs** in distributed databases, queues, and consensus systems.

### Website
- Main site: https://jepsen.io/
- GitHub: https://github.com/jepsen-io/jepsen
- PostgreSQL Analysis: https://jepsen.io/analyses/postgresql-12.3

---

## What Makes Jepsen Different from Your Current Testing?

### Your Current Approach (Litmus + pgbench + probes)

```
┌─────────────────────────────────────┐
│   Litmus Chaos Engineering          │
│   - Delete pods                     │
│   - Cause network partitions        │
│   - Test infrastructure resilience  │
│                                     │
│   cmdProbe:                         │
│   - Run SQL queries                 │
│   - Check if writes succeed         │
│   - Verify reads work               │
│                                     │
│   promProbe:                        │
│   - Monitor metrics                 │
│   - Track replication lag           │
└─────────────────────────────────────┘
```

**Tests:** "Can the database stay available during failures?"

### Jepsen Approach

```
┌─────────────────────────────────────┐
│   Jepsen Testing                    │
│   - Cause network partitions        │
│   - Generate random transactions    │
│   - Build transaction dependency    │
│     graph                           │
│   - Search for consistency         │
│     violations (anomalies)          │
│                                     │
│   Checks for:                       │
│   - Lost writes                     │
│   - Dirty reads                     │
│   - Write skew                      │
│   - Serializability violations      │
│   - Isolation level correctness     │
└─────────────────────────────────────┘
```

**Tests:** "Does the database maintain **ACID guarantees** and **isolation levels** correctly during failures?"

---

## Why Jepsen Found Bugs in PostgreSQL (That No One Else Found)

### The PostgreSQL 12.3 Bug

In 2020, Jepsen found a **serializability violation** in PostgreSQL that had existed for **9 years** (since version 9.1):

**The Bug:**
- PostgreSQL claimed to provide "SERIALIZABLE" isolation
- But under concurrent INSERT + UPDATE operations, transactions could exhibit **G2-item anomaly** (anti-dependency cycles)
- Each transaction failed to observe the other's writes
- This violates serializability!

**Why It Wasn't Found Before:**
1. **Hand-written tests** only checked specific scenarios
2. **PostgreSQL's own test suite** used carefully crafted examples
3. **Martin Kleppmann's Hermitage** tested known patterns

**Why Jepsen Found It:**
- **Generative testing**: Randomly generated thousands of transaction patterns
- **Elle checker**: Built transaction dependency graphs automatically
- **Property-based**: Proved violations mathematically, not just by example

---

## What Jepsen Tests For

### Consistency Anomalies

| Anomaly | What It Means | Example |
|---------|---------------|---------|
| **G0 (Dirty Write)** | Overwriting uncommitted data | T1 writes X, T2 overwrites X before T1 commits |
| **G1a (Aborted Read)** | Reading uncommitted data that gets rolled back | T1 writes X, T2 reads X, T1 aborts |
| **G1c (Cyclic Information Flow)** | Transactions see inconsistent snapshots | T1 → T2 → T3 → T1 (cycle!) |
| **G2-item (Write Skew)** | Two transactions each miss the other's writes | T1 reads A writes B, T2 reads B writes A |

### Isolation Levels

Jepsen verifies that databases **actually provide** the isolation they claim:

- **Read Uncommitted**: Prevents dirty writes (G0)
- **Read Committed**: Prevents aborted reads (G1a, G1b)
- **Repeatable Read**: Prevents read skew (G-single, G2-item)
- **Serializable**: Prevents all anomalies (equivalent to serial execution)

---

## How Jepsen Works

### 1. Generate Random Transactions

```clojure
; Example: List-append workload
{:type :invoke, :f :read, :value nil, :key 42}
{:type :invoke, :f :append, :value 5, :key 42}
{:type :ok, :f :read, :value [1 2 5], :key 42}
```

### 2. Inject Failures

- Network partitions
- Process crashes
- Clock skew
- Slow networks

### 3. Build Dependency Graph

```
Transaction T1: read(A)=1, write(B)=2
Transaction T2: read(B)=2, write(C)=3
Transaction T3: read(C)=3, write(A)=4

T1 --rw--> T2 --rw--> T3 --rw--> T1  ← CYCLE! Not serializable!
```

### 4. Search for Anomalies

Jepsen's **Elle** checker searches for:
- Cycles in the dependency graph
- Missing writes
- Inconsistent reads
- Isolation violations

---

## Should You Use Jepsen for CloudNativePG Testing?

### Current Testing (What You Have)

**✅ Good for:**
- **Availability testing**: Does the database stay up?
- **Failover testing**: How fast does primary switch to replica?
- **Operational resilience**: Can applications continue working?
- **Infrastructure validation**: Are pods/services healthy?

**❌ NOT testing:**
- Data consistency during partitions
- Transaction isolation correctness
- Write visibility across replicas
- Serializability guarantees

### Adding Jepsen (What Your Mentor Wants)

**✅ Good for:**
- **Correctness testing**: Are ACID guarantees maintained?
- **Isolation level validation**: Does SERIALIZABLE really mean serializable?
- **Replication consistency**: Do all replicas converge correctly?
- **Edge case discovery**: Find bugs no one thought to test

**❌ Challenges:**
- Complex setup (Clojure-based framework)
- Requires understanding of consistency models
- Longer test execution times
- Steep learning curve

---

## Recommendation: Hybrid Approach

### Phase 1: Keep What You Have (Current)
```
Litmus Chaos + cmdProbe + promProbe + pgbench
```
This is **perfect for operational testing**:
- ✅ Tests real-world failure scenarios
- ✅ Validates application-level operations
- ✅ Measures recovery times
- ✅ Simple and focused

### Phase 2: Add Jepsen-Style Consistency Checks

You don't need the full Jepsen framework. Instead, add **consistency validation** to your existing tests:

#### Option A: Enhanced cmdProbe (Easy)

Add probes that check for consistency violations:

```yaml
# Check: Do all replicas have the same data?
- name: replica-consistency-check
  type: cmdProbe
  mode: EOT
  cmdProbe/inputs:
    command: |
      PRIMARY_DATA=$(kubectl exec pg-eu-1 -- psql -U postgres -d app -tAc "SELECT count(*), sum(aid) FROM pgbench_accounts")
      for POD in pg-eu-2 pg-eu-3; do
        REPLICA_DATA=$(kubectl exec $POD -- psql -U postgres -d app -tAc "SELECT count(*), sum(aid) FROM pgbench_accounts")
        if [ "$PRIMARY_DATA" != "$REPLICA_DATA" ]; then
          echo "MISMATCH: $POD differs from primary"
          exit 1
        fi
      done
      echo "CONSISTENT"
    comparator:
      type: string
      criteria: "contains"
      value: "CONSISTENT"
```

#### Option B: Transaction Verification Test (Medium)

Create a test that tracks transaction IDs and verifies visibility:

```bash
#!/bin/bash
# Test: Do writes become visible on all replicas?

# 1. Insert with known transaction ID
TXID=$(kubectl exec pg-eu-1 -- psql -U postgres -d app -tAc \
  "BEGIN; INSERT INTO test_table VALUES ('marker', txid_current()); COMMIT; SELECT txid_current();")

# 2. Wait for replication
sleep 2

# 3. Verify on all replicas
for POD in pg-eu-2 pg-eu-3; do
  FOUND=$(kubectl exec $POD -- psql -U postgres -d app -tAc \
    "SELECT COUNT(*) FROM test_table WHERE value = 'marker'")
  
  if [ "$FOUND" != "1" ]; then
    echo "ERROR: Transaction $TXID not visible on $POD"
    exit 1
  fi
done

echo "SUCCESS: Transaction $TXID visible on all replicas"
```

#### Option C: Full Jepsen Integration (Advanced)

Use Jepsen's [Elle library](https://github.com/jepsen-io/elle) to analyze your transaction histories:

1. **Record transactions** during chaos:
   ```
   {txid: 1001, ops: [{read, key:42, value:[1,2]}, {append, key:42, value:3}]}
   {txid: 1002, ops: [{read, key:42, value:[1,2,3]}, {append, key:43, value:5}]}
   ```

2. **Feed to Elle** for analysis:
   ```bash
   lein run -m elle.core analyze-history transactions.edn
   ```

3. **Get results**:
   ```
   Checked 1000 transactions
   Found 0 anomalies
   Strongest consistency model: serializable
   ```

---

## Practical Next Steps

### Step 1: Understand What You're Testing Now

**Your current tests answer:**
- ✅ Can users read/write during pod deletion?
- ✅ How fast does failover happen?
- ✅ Do metrics show healthy state?

**They DON'T answer:**
- ❌ Are transactions isolated correctly?
- ❌ Do replicas always converge to same state?
- ❌ Are there race conditions in replication?

### Step 2: Add Consistency Checks (Low Hanging Fruit)

Add these cmdProbes to your experiment:

```yaml
# 1. Verify no data loss
- name: check-no-data-loss
  type: cmdProbe
  mode: EOT
  cmdProbe/inputs:
    command: |
      BEFORE=$(cat /tmp/row_count_before)
      AFTER=$(kubectl exec pg-eu-1 -- psql -U postgres -d app -tAc "SELECT count(*) FROM pgbench_accounts")
      if [ "$AFTER" -lt "$BEFORE" ]; then
        echo "DATA LOSS: $BEFORE -> $AFTER"
        exit 1
      fi
      echo "NO LOSS: $AFTER rows"

# 2. Verify eventual consistency
- name: check-replica-convergence
  type: cmdProbe
  mode: EOT
  runProperties:
    probeTimeout: "60"
    interval: "10"
    retry: 6
  cmdProbe/inputs:
    command: ./scripts/verify-all-replicas-match.sh pg-eu app
```

### Step 3: Learn Jepsen Concepts

Read these to understand what your mentor wants:

1. **[Jepsen: PostgreSQL 12.3](https://jepsen.io/analyses/postgresql-12.3)** - See what Jepsen found
2. **[Call Me Maybe: PostgreSQL](https://aphyr.com/posts/282-jepsen-postgres)** - Original Jepsen article
3. **[Consistency Models](https://jepsen.io/consistency)** - What isolation levels mean
4. **[Elle: Inferring Isolation Anomalies](https://github.com/jepsen-io/elle)** - How the checker works

### Step 4: Discuss with Your Mentor

Ask your mentor:

**"What specific consistency problems are you concerned about in CloudNativePG?"**

Options:
- A. **Replication lag divergence**: "Do replicas ever miss committed writes?"
- B. **Isolation violations**: "Does SERIALIZABLE actually work during failover?"
- C. **Split-brain scenarios**: "Can we get two primaries writing different data?"
- D. **Transaction visibility**: "Are committed transactions always visible to subsequent reads?"

Each requires different testing approaches!

---

## Summary

### What cmdProbe Does (Your Question)
**cmdProbe** runs actual commands to verify **application-level operations work**. It tests "can I write/read data?" not "is the data consistent?"

### What Jepsen Does (Your Mentor's Suggestion)
**Jepsen** generates random transactions and mathematically proves **data consistency** is maintained. It tests "are ACID guarantees upheld?" not "does it stay available?"

### What You Should Do
1. **Keep your current Litmus + cmdProbe + promProbe setup** ← This is great for availability testing!
2. **Add consistency checks** (replica matching, transaction visibility)
3. **Learn about consistency models** (read Jepsen articles)
4. **Ask your mentor** what specific consistency problems they're worried about
5. **Consider full Jepsen later** if you need deep consistency validation

---

## Key Takeaway

**Jepsen is NOT a replacement for your current testing.**  
**It's a COMPLEMENTARY approach that tests different properties.**

| Your Current Tests | Jepsen Tests |
|-------------------|--------------|
| Availability | Consistency |
| Failover speed | Isolation correctness |
| Operational resilience | ACID guarantees |
| "Does it work?" | "Is it correct?" |

Both are valuable! CloudNativePG benefits from both types of testing.

---

**Questions to ask your mentor:**
1. "Are you worried about consistency bugs during failover?"
2. "Should I add replica-matching checks to EOT probes?"
3. "Do you want full Jepsen integration or just consistency validation?"
4. "What specific anomalies (G2-item, write skew, etc.) should I test for?"

