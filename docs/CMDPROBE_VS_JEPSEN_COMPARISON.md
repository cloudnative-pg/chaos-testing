# cmdProbe vs Jepsen: What Can Each Tool Do?

**Date**: October 30, 2025  
**Context**: Understanding testing capabilities

---

## Quick Answer: What's the Difference?

| Aspect | cmdProbe (Litmus) | Jepsen |
|--------|-------------------|---------|
| **Purpose** | "Can I perform this operation?" | "Is the data consistent?" |
| **Approach** | Test individual operations | Analyze transaction histories |
| **Output** | Pass/Fail per operation | Dependency graph + anomalies |
| **Validation** | Immediate (did this work?) | Historical (was everything correct?) |

---

## Test Capability Matrix

### ✅ = Can Do  |  ⚠️ = Partially  |  ❌ = Cannot Do

| Test Type | cmdProbe | Jepsen | Example |
|-----------|----------|--------|---------|
| **Availability Testing** |
| Can I write data during chaos? | ✅ | ✅ | INSERT INTO table VALUES (...) |
| Can I read data during chaos? | ✅ | ✅ | SELECT * FROM table |
| Does the database respond to queries? | ✅ | ✅ | SELECT 1 |
| How many operations succeed vs fail? | ✅ | ✅ | 95% success rate |
| **Consistency Testing** |
| Do all replicas have the same data? | ⚠️ | ✅ | Replica A has [1,2,3], Replica B has [1,2] |
| Did any writes get lost? | ⚠️ | ✅ | Wrote X, but can't find it later |
| Can two transactions read inconsistent data? | ❌ | ✅ | T1 sees X=1, T2 sees X=2, but X was only written once |
| Are there dependency cycles? | ❌ | ✅ | T1→T2→T3→T1 (impossible in serial execution) |
| **Isolation Testing** |
| Does SERIALIZABLE prevent write skew? | ❌ | ✅ | T1 reads A writes B, T2 reads B writes A |
| Can I read uncommitted data? | ⚠️ | ✅ | Dirty read detection |
| Do transactions see each other's writes? | ⚠️ | ✅ | T1 writes X, T2 should/shouldn't see it |
| Are isolation levels correct? | ❌ | ✅ | "Repeatable Read" actually provides Snapshot Isolation |
| **Replication Testing** |
| Do replicas eventually converge? | ⚠️ | ✅ | After chaos, all replicas have same data |
| Is replication lag acceptable? | ✅ | ✅ | Lag < 5 seconds |
| Can replicas diverge permanently? | ❌ | ✅ | Replica A has different data than B forever |
| Does failover preserve all writes? | ⚠️ | ✅ | After primary→replica promotion, no data lost |
| **Correctness Testing** |
| Do writes persist after commit? | ⚠️ | ✅ | INSERT committed but missing after recovery |
| Are there duplicate writes? | ⚠️ | ✅ | Same record appears twice |
| Is data corrupted? | ⚠️ | ✅ | Data values changed unexpectedly |
| Are invariants maintained? | ❌ | ✅ | Sum(accounts) should always = $1000 |

---

## Detailed Breakdown

### 1. Availability Testing (Both Can Do)

#### cmdProbe Approach:
```yaml
# Test: Can I write during chaos?
- name: test-write-availability
  type: cmdProbe
  mode: Continuous
  runProperties:
    interval: "30"
  cmdProbe/inputs:
    command: "psql -c 'INSERT INTO test VALUES (1)'"
    comparator:
      criteria: "contains"
      value: "INSERT 0 1"
```

**Output:**
```
Probe ran 10 times
✅ 8 succeeded
❌ 2 failed
→ 80% availability during chaos
```

#### Jepsen Approach:
```clojure
; Test: Record all write attempts
(def history
  [{:type :invoke, :f :write, :value 1}
   {:type :ok,     :f :write, :value 1}
   {:type :invoke, :f :write, :value 2}
   {:type :fail,   :f :write, :value 2}
   ...])

; Analyze: What succeeded vs failed?
(availability-rate history) ;=> 0.8 (80%)
```

**Both give you:** "80% of writes succeeded during chaos"

---

### 2. Data Loss Detection (Jepsen Wins)

#### cmdProbe Approach (⚠️ Partial):
```yaml
# Test: Did specific write persist?
- name: check-write-persisted
  type: cmdProbe
  mode: EOT
  cmdProbe/inputs:
    command: |
      COUNT=$(psql -tAc "SELECT count(*) FROM test WHERE id = 123")
      if [ "$COUNT" = "1" ]; then
        echo "FOUND"
      else
        echo "MISSING"
      fi
    comparator:
      value: "FOUND"
```

**Limitation:** You can only check for writes you explicitly track!

#### Jepsen Approach (✅ Complete):
```clojure
; Jepsen records ALL operations
(def history
  [{:type :invoke, :f :write, :value 1}
   {:type :ok,     :f :write, :value 1}
   {:type :invoke, :f :write, :value 2}
   {:type :ok,     :f :write, :value 2}
   {:type :invoke, :f :read,  :value nil}
   {:type :ok,     :f :read,  :value [1]}]) ; ← Missing value 2!

; Elle detects: Write 2 was acknowledged but not visible
(elle/check history) 
;=> {:valid? false
;    :anomaly-types [:lost-write]
;    :lost [{:type :write, :value 2}]}
```

**Jepsen automatically detects:** "Write 2 succeeded but disappeared!"

---

### 3. Isolation Level Violations (Jepsen Only)

#### cmdProbe Approach (❌ Cannot Do):
```yaml
# You CANNOT test this with cmdProbe:
# "Does SERIALIZABLE prevent write skew?"

# You would need to:
# 1. Start transaction T1
# 2. Start transaction T2
# 3. T1 reads A, writes B
# 4. T2 reads B, writes A
# 5. Both commit
# 6. Check if both succeeded (should fail under SERIALIZABLE)

# Problem: cmdProbe runs ONE command at a time
# It cannot coordinate multiple concurrent transactions
```

#### Jepsen Approach (✅ Can Do):
```clojure
; Jepsen generates concurrent transactions
(defn write-skew-test []
  (let [t1 (future 
             (jdbc/with-db-transaction [conn db]
               (jdbc/query conn ["SELECT * FROM accounts WHERE id = 1"])
               (jdbc/execute! conn ["UPDATE accounts SET balance = 100 WHERE id = 2"])))
        t2 (future
             (jdbc/with-db-transaction [conn db]
               (jdbc/query conn ["SELECT * FROM accounts WHERE id = 2"])
               (jdbc/execute! conn ["UPDATE accounts SET balance = 100 WHERE id = 1"])))]
    [@t1 @t2]))

; Elle analyzes the history
(def history
  [{:index 0, :type :invoke, :f :txn, :value [[:r 1 nil] [:w 2 100]]}
   {:index 1, :type :invoke, :f :txn, :value [[:r 2 nil] [:w 1 100]]}
   {:index 2, :type :ok,     :f :txn, :value [[:r 1 10]  [:w 2 100]]}
   {:index 3, :type :ok,     :f :txn, :value [[:r 2 10]  [:w 1 100]]}])

; Detects: G2-item (write skew) under SERIALIZABLE!
(elle/check history)
;=> {:valid? false
;    :anomaly-types [:G2-item]
;    :anomalies [{:type :G2-item, :cycle [t1 t2 t1]}]}
```

**Result:** "SERIALIZABLE is broken - allows write skew!"

---

### 4. Replica Consistency (Both Can Do, Jepsen Better)

#### cmdProbe Approach (⚠️ Manual):
```yaml
# Test: Do all replicas match?
- name: check-replica-consistency
  type: cmdProbe
  mode: EOT
  cmdProbe/inputs:
    command: |
      PRIMARY=$(kubectl exec pg-eu-1 -- psql -tAc "SELECT count(*) FROM test")
      REPLICA1=$(kubectl exec pg-eu-2 -- psql -tAc "SELECT count(*) FROM test")
      REPLICA2=$(kubectl exec pg-eu-3 -- psql -tAc "SELECT count(*) FROM test")
      
      if [ "$PRIMARY" = "$REPLICA1" ] && [ "$PRIMARY" = "$REPLICA2" ]; then
        echo "CONSISTENT: $PRIMARY rows on all replicas"
      else
        echo "DIVERGED: P=$PRIMARY R1=$REPLICA1 R2=$REPLICA2"
        exit 1
      fi
```

**Output:**
```
✅ CONSISTENT: 1000 rows on all replicas
```

**Limitation:** Only checks row counts, not actual data values!

#### Jepsen Approach (✅ Comprehensive):
```clojure
; Jepsen tracks writes to each replica
(def history
  [{:type :ok, :f :write, :value 1, :node :n1}
   {:type :ok, :f :write, :value 2, :node :n1}
   {:type :ok, :f :read,  :value [1 2], :node :n1} ; Primary sees both
   {:type :ok, :f :read,  :value [1],   :node :n2} ; Replica missing value 2!
   {:type :ok, :f :read,  :value [1 2], :node :n3}])

; Checks: Do all nodes eventually converge?
(convergence/check history)
;=> {:valid? false
;    :diverged-nodes #{:n2}
;    :missing-values {2 [:n2]}}
```

**Result:** "Replica n2 permanently missing value 2!"

---

### 5. Transaction Dependency Analysis (Jepsen Only)

#### cmdProbe Approach (❌ Impossible):
```yaml
# You CANNOT do this with cmdProbe:
# "Build a transaction dependency graph and find cycles"

# This requires:
# 1. Recording all transaction operations
# 2. Inferring read-from and write-write relationships
# 3. Searching for cycles in the graph
# 4. Classifying anomalies (G0, G1, G2, etc.)

# cmdProbe just runs commands - it doesn't build graphs!
```

#### Jepsen Approach (✅ Core Feature):
```clojure
; Example history
(def history
  [{:index 0, :type :ok, :f :txn, :value [[:r :x 1] [:w :y 2]]}  ; T1
   {:index 1, :type :ok, :f :txn, :value [[:r :y 2] [:w :z 3]]}  ; T2
   {:index 2, :type :ok, :f :txn, :value [[:r :z 3] [:w :x 4]]}]) ; T3

; Elle builds dependency graph
(def graph
  {:nodes #{0 1 2}
   :edges {0 {:rw #{1}}    ; T1 --rw--> T2 (T2 reads T1's write to y)
           1 {:rw #{2}}    ; T2 --rw--> T3 (T3 reads T2's write to z)
           2 {:rw #{0}}}}) ; T3 --rw--> T1 (T1 reads T3's write to x) ← CYCLE!

; Finds cycles
(scc/strongly-connected-components graph)
;=> [[0 1 2]] ; All three form a cycle

; Classifies anomaly
(elle/check history)
;=> {:valid? false
;    :anomaly-types [:G1c] ; Cyclic information flow
;    :cycle [0 1 2 0]}
```

**Visual:**
```
     T1 (read x=4, write y=2)
      ↓ rw (T2 reads y=2)
     T2 (read y=2, write z=3)
      ↓ rw (T3 reads z=3)
     T3 (read z=3, write x=4)
      ↓ rw (T1 reads x=4)
     T1 ← CYCLE! This is impossible in serial execution!
```

---

## When to Use Each Tool

### Use cmdProbe When You Need:

✅ **Operational validation**
- "Can users still perform operations during failures?"
- "What's the availability percentage?"
- "How fast does failover happen?"

✅ **Simple checks**
- "Does this row exist?"
- "Is the table non-empty?"
- "Can I connect to the database?"

✅ **End-to-end testing**
- "Can my application write data?"
- "Do API calls succeed?"
- "Are services responding?"

**Example Use Cases:**
1. Validate 95% of writes succeed during pod deletion
2. Check that reads return results within 500ms
3. Verify database accepts connections after failover
4. Test that specific test data persists

### Use Jepsen When You Need:

✅ **Correctness validation**
- "Are ACID guarantees maintained?"
- "Do isolation levels work correctly?"
- "Is there any data loss or corruption?"

✅ **Consistency proofs**
- "Do all replicas converge?"
- "Are there any anomalies in transaction histories?"
- "Is serializability actually serializable?"

✅ **Finding subtle bugs**
- "Can concurrent transactions violate invariants?"
- "Are there race conditions in replication?"
- "Does the system allow impossible orderings?"

**Example Use Cases:**
1. Prove SERIALIZABLE prevents write skew (it didn't in PostgreSQL 12.3!)
2. Detect lost writes during network partitions
3. Find replica divergence issues
4. Verify replication doesn't create cycles

---

## Hybrid Approach: Best of Both Worlds

### Your Current Setup (Good!)
```yaml
# cmdProbe: Operational validation
- name: continuous-write-probe
  cmdProbe/inputs:
    command: "psql -c 'INSERT ...'"
  → Tests: "Can I write right now?"

# promProbe: Infrastructure validation  
- name: replication-lag
  promProbe/inputs:
    query: "cnpg_pg_replication_lag"
  → Tests: "Is replication working?"
```

### Add Jepsen-Style Validation
```yaml
# cmdProbe: Consistency check (Jepsen-inspired)
- name: verify-no-data-loss
  type: cmdProbe
  mode: EOT
  cmdProbe/inputs:
    command: |
      # Save write count before chaos
      BEFORE=$(cat /tmp/writes_before)
      
      # Count writes after chaos
      AFTER=$(psql -tAc "SELECT count(*) FROM test")
      
      # Check for loss
      if [ $AFTER -lt $BEFORE ]; then
        echo "LOST: $((BEFORE - AFTER)) writes"
        exit 1
      else
        echo "SAFE: All $AFTER writes present"
      fi

- name: verify-replica-convergence
  type: cmdProbe
  mode: EOT
  cmdProbe/inputs:
    command: |
      # Wait for replication to settle
      sleep 10
      
      # Get checksums from all replicas
      PRIMARY_SUM=$(kubectl exec pg-eu-1 -- psql -tAc "SELECT sum(aid) FROM pgbench_accounts")
      REPLICA1_SUM=$(kubectl exec pg-eu-2 -- psql -tAc "SELECT sum(aid) FROM pgbench_accounts")
      REPLICA2_SUM=$(kubectl exec pg-eu-3 -- psql -tAc "SELECT sum(aid) FROM pgbench_accounts")
      
      # Compare
      if [ "$PRIMARY_SUM" = "$REPLICA1_SUM" ] && [ "$PRIMARY_SUM" = "$REPLICA2_SUM" ]; then
        echo "CONVERGED: checksum=$PRIMARY_SUM"
      else
        echo "DIVERGED: P=$PRIMARY_SUM R1=$REPLICA1_SUM R2=$REPLICA2_SUM"
        exit 1
      fi
```

---

## Summary: Which Tool for Your Tests?

| Your Question | Tool to Use | Why |
|---------------|-------------|-----|
| "Can I write during chaos?" | **cmdProbe** ✅ | Simple availability test |
| "Did any writes get lost?" | **Jepsen** or **cmdProbe+tracking** | Need to track all writes |
| "Do replicas converge?" | **cmdProbe** (basic) or **Jepsen** (thorough) | Both can check, Jepsen catches more |
| "Is SERIALIZABLE correct?" | **Jepsen only** ❌ | Requires dependency analysis |
| "What's the success rate?" | **Both** ✅ | cmdProbe simpler for this |
| "Are there any anomalies?" | **Jepsen only** ❌ | Requires graph analysis |
| "How fast is failover?" | **cmdProbe** ✅ | Operational metric |
| "Can transactions violate invariants?" | **Jepsen only** ❌ | Needs transaction tracking |

---

## Recommendation

**For CloudNativePG chaos testing:**

1. **Keep your cmdProbe tests** ← Perfect for availability/operations
2. **Add consistency cmdProbes** ← Check replicas match, no data loss
3. **Learn about Jepsen** ← Understand what it can find
4. **Use full Jepsen if:**
   - You're developing CloudNativePG itself (not just using it)
   - You suspect serializability bugs
   - You need to publish correctness claims
   - Your mentor insists on deep correctness validation

**Your cmdProbes are doing their job!** They're testing availability and basic operations, which is exactly what they're designed for. Jepsen would add *correctness* testing on top of that.

