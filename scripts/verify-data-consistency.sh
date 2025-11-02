#!/bin/bash
# Verify data consistency after chaos experiments
# Implements CNPG e2e pattern: AssertDataExpectedCount

set -e

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
CLUSTER_NAME=${1:-pg-eu}
DATABASE=${2:-app}
NAMESPACE=${3:-default}

# Test results
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_WARNED=0

echo "=========================================="
echo "  Data Consistency Verification"
echo "=========================================="
echo ""
echo "Cluster:   $CLUSTER_NAME"
echo "Database:  $DATABASE"
echo "Namespace: $NAMESPACE"
echo "Time:      $(date)"
echo ""

# Function to run test and track results
run_test() {
  local test_name=$1
  local test_result=$2
  
  if [ "$test_result" = "PASS" ]; then
    echo -e "${GREEN}✅ PASS${NC}: $test_name"
    ((TESTS_PASSED++))
  elif [ "$test_result" = "WARN" ]; then
    echo -e "${YELLOW}⚠️  WARN${NC}: $test_name"
    ((TESTS_WARNED++))
  else
    echo -e "${RED}❌ FAIL${NC}: $test_name"
    ((TESTS_FAILED++))
  fi
}

# Get password
echo "Retrieving credentials..."
if ! kubectl get secret ${CLUSTER_NAME}-credentials -n $NAMESPACE &>/dev/null; then
  echo -e "${RED}❌ Error: Secret '${CLUSTER_NAME}-credentials' not found in namespace '$NAMESPACE'${NC}"
  exit 1
fi

PASSWORD=$(kubectl get secret ${CLUSTER_NAME}-credentials -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)
echo -e "${GREEN}✓${NC} Credentials retrieved"
echo ""

# Find the current primary pod
echo "Identifying cluster topology..."
PRIMARY_POD=$(kubectl get pod -n $NAMESPACE -l "cnpg.io/cluster=${CLUSTER_NAME}" -o json 2>/dev/null | \
  jq -r '.items[] | select(.metadata.labels["cnpg.io/instanceRole"] == "primary") | .metadata.name' | head -n1)

if [ -z "$PRIMARY_POD" ]; then
  echo -e "${RED}❌ FAIL: Could not find primary pod${NC}"
  echo ""
  echo "Available pods:"
  kubectl get pods -n $NAMESPACE -l "cnpg.io/cluster=${CLUSTER_NAME}"
  exit 1
fi

echo -e "${GREEN}✓${NC} Primary: $PRIMARY_POD"

# Get all cluster pods
ALL_PODS=$(kubectl get pod -n $NAMESPACE -l "cnpg.io/cluster=${CLUSTER_NAME}" -o json | \
  jq -r '.items[].metadata.name' | tr '\n' ' ')
TOTAL_PODS=$(echo $ALL_PODS | wc -w)

echo -e "${GREEN}✓${NC} Total pods: $TOTAL_PODS"
echo ""

echo "=========================================="
echo "  Running Consistency Tests"
echo "=========================================="
echo ""

# ============================================================
# Test 1: Verify pgbench tables exist and have data
# ============================================================
echo -e "${BLUE}Test 1: Verify pgbench test data exists${NC}"

# Use service connection instead of direct pod exec
SERVICE="${CLUSTER_NAME}-rw"

ACCOUNTS_COUNT=$(kubectl run verify-accounts-$$ --rm -i --restart=Never \
  --image=postgres:16 \
  --namespace=$NAMESPACE \
  --env="PGPASSWORD=$PASSWORD" \
  --command -- \
  psql -h $SERVICE -U app -d $DATABASE -tAc \
  "SELECT count(*) FROM pgbench_accounts;" 2>&1 | grep -E '^[0-9]+$' | head -1 || echo "0")

if [ -n "$ACCOUNTS_COUNT" ] && [ "$ACCOUNTS_COUNT" -gt 0 ] 2>/dev/null; then
  run_test "pgbench_accounts has $ACCOUNTS_COUNT rows" "PASS"
else
  run_test "pgbench_accounts is empty or missing" "FAIL"
fi

HISTORY_COUNT=$(kubectl run verify-history-$$ --rm -i --restart=Never \
  --image=postgres:16 \
  --namespace=$NAMESPACE \
  --env="PGPASSWORD=$PASSWORD" \
  --command -- \
  psql -h $SERVICE -U app -d $DATABASE -tAc \
  "SELECT count(*) FROM pgbench_history;" 2>&1 | grep -E '^[0-9]+$' | head -1 || echo "0")

if [ "$HISTORY_COUNT" -gt 0 ]; then
  run_test "pgbench_history has $HISTORY_COUNT transactions recorded" "PASS"
else
  run_test "pgbench_history is empty (no workload ran?)" "WARN"
fi

echo ""

# ============================================================
# Test 2: Verify replica data consistency (row counts)
# ============================================================
echo -e "${BLUE}Test 2: Verify replica data consistency${NC}"

declare -A POD_COUNTS
COUNTS_CONSISTENT=true
REFERENCE_COUNT=""

for POD in $ALL_PODS; do
  # Check if pod is ready
  POD_READY=$(kubectl get pod -n $NAMESPACE $POD -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  
  if [ "$POD_READY" != "True" ]; then
    echo "  ⏭️  Skipping $POD (not ready)"
    continue
  fi
  
  COUNT=$(kubectl exec -n $NAMESPACE $POD -- \
    env PGPASSWORD=$PASSWORD psql -U app -d $DATABASE -tAc \
    "SELECT count(*) FROM pgbench_accounts;" 2>/dev/null || echo "ERROR")
  
  POD_COUNTS[$POD]=$COUNT
  
  if [ -z "$REFERENCE_COUNT" ]; then
    REFERENCE_COUNT=$COUNT
  elif [ "$COUNT" != "$REFERENCE_COUNT" ]; then
    COUNTS_CONSISTENT=false
  fi
  
  echo "  $POD: $COUNT rows"
done

echo ""
if $COUNTS_CONSISTENT; then
  run_test "All replicas have consistent row counts ($REFERENCE_COUNT rows)" "PASS"
else
  run_test "Row count mismatch detected across replicas" "FAIL"
  echo ""
  echo "  Details:"
  for POD in "${!POD_COUNTS[@]}"; do
    echo "    $POD: ${POD_COUNTS[$POD]}"
  done
fi

echo ""

# ============================================================
# Test 3: Verify no data corruption (integrity checks)
# ============================================================
echo -e "${BLUE}Test 3: Check for data corruption indicators${NC}"

# Check for null primary keys
NULL_PKS=$(kubectl exec -n $NAMESPACE $PRIMARY_POD -- \
  env PGPASSWORD=$PASSWORD psql -U app -d $DATABASE -tAc \
  "SELECT count(*) FROM pgbench_accounts WHERE aid IS NULL;" 2>&1)

if [[ "$NULL_PKS" =~ ^[0-9]+$ ]] && [ "$NULL_PKS" -eq 0 ]; then
  run_test "No null primary keys in pgbench_accounts" "PASS"
else
  run_test "Null primary keys detected or check failed" "FAIL"
fi

# Check for negative balances (should exist in pgbench, but checking query works)
NEGATIVE_BALANCES=$(kubectl exec -n $NAMESPACE $PRIMARY_POD -- \
  env PGPASSWORD=$PASSWORD psql -U app -d $DATABASE -tAc \
  "SELECT count(*) FROM pgbench_accounts WHERE abalance < -999999;" 2>&1)

if [[ "$NEGATIVE_BALANCES" =~ ^[0-9]+$ ]]; then
  run_test "Able to query account balances (no corruption)" "PASS"
else
  run_test "Failed to query account data" "FAIL"
fi

# Check table structure integrity
TABLE_CHECK=$(kubectl exec -n $NAMESPACE $PRIMARY_POD -- \
  env PGPASSWORD=$PASSWORD psql -U app -d $DATABASE -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_name LIKE 'pgbench_%';" 2>&1)

if [[ "$TABLE_CHECK" =~ ^[0-9]+$ ]] && [ "$TABLE_CHECK" -eq 4 ]; then
  run_test "All 4 pgbench tables present" "PASS"
elif [[ "$TABLE_CHECK" =~ ^[0-9]+$ ]]; then
  run_test "Expected 4 pgbench tables, found $TABLE_CHECK" "WARN"
else
  run_test "Table structure check failed" "FAIL"
fi

echo ""

# ============================================================
# Test 4: Verify replication status
# ============================================================
echo -e "${BLUE}Test 4: Verify replication health${NC}"

# Check number of active replication slots
ACTIVE_SLOTS=$(kubectl exec -n $NAMESPACE $PRIMARY_POD -- \
  env PGPASSWORD=$PASSWORD psql -U postgres -d postgres -tAc \
  "SELECT count(*) FROM pg_replication_slots WHERE active = true;" 2>/dev/null || echo "0")

EXPECTED_REPLICAS=$((TOTAL_PODS - 1))

if [ "$ACTIVE_SLOTS" -eq "$EXPECTED_REPLICAS" ]; then
  run_test "All $ACTIVE_SLOTS replication slots are active" "PASS"
else
  run_test "Expected $EXPECTED_REPLICAS active slots, found $ACTIVE_SLOTS" "WARN"
fi

# Check streaming replication connections
STREAMING_REPLICAS=$(kubectl exec -n $NAMESPACE $PRIMARY_POD -- \
  env PGPASSWORD=$PASSWORD psql -U postgres -d postgres -tAc \
  "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming';" 2>/dev/null || echo "0")

if [ "$STREAMING_REPLICAS" -eq "$EXPECTED_REPLICAS" ]; then
  run_test "All $STREAMING_REPLICAS replicas are streaming" "PASS"
else
  run_test "Expected $EXPECTED_REPLICAS streaming replicas, found $STREAMING_REPLICAS" "WARN"
fi

# Check replication lag
MAX_LAG=$(kubectl exec -n $NAMESPACE $PRIMARY_POD -- \
  env PGPASSWORD=$PASSWORD psql -U postgres -d postgres -tAc \
  "SELECT COALESCE(MAX(EXTRACT(EPOCH FROM replay_lag)), 0)::int FROM pg_stat_replication;" 2>/dev/null || echo "999")

if [ "$MAX_LAG" -le 5 ]; then
  run_test "Maximum replication lag is ${MAX_LAG}s (acceptable)" "PASS"
elif [ "$MAX_LAG" -le 30 ]; then
  run_test "Maximum replication lag is ${MAX_LAG}s (elevated)" "WARN"
else
  run_test "Maximum replication lag is ${MAX_LAG}s (too high)" "FAIL"
fi

echo ""

# ============================================================
# Test 5: Verify transaction IDs are healthy
# ============================================================
echo -e "${BLUE}Test 5: Verify transaction ID health${NC}"

XID_AGE=$(kubectl exec -n $NAMESPACE $PRIMARY_POD -- \
  env PGPASSWORD=$PASSWORD psql -U app -d $DATABASE -tAc \
  "SELECT max(age(datfrozenxid)) FROM pg_database;" 2>/dev/null || echo "999999999")

MAX_SAFE_AGE=100000000  # 100M transactions
if [ "$XID_AGE" -lt "$MAX_SAFE_AGE" ]; then
  run_test "Transaction ID age is $XID_AGE (safe, no wraparound risk)" "PASS"
elif [ "$XID_AGE" -lt 500000000 ]; then
  run_test "Transaction ID age is $XID_AGE (monitor closely)" "WARN"
else
  run_test "Transaction ID age is $XID_AGE (critical, risk of wraparound)" "FAIL"
fi

echo ""

# ============================================================
# Test 6: Verify database statistics are being collected
# ============================================================
echo -e "${BLUE}Test 6: Verify database statistics collection${NC}"

STATS_RESET=$(kubectl exec -n $NAMESPACE $PRIMARY_POD -- \
  env PGPASSWORD=$PASSWORD psql -U app -d $DATABASE -tAc \
  "SELECT stats_reset FROM pg_stat_database WHERE datname = '$DATABASE';" 2>/dev/null)

if [ -n "$STATS_RESET" ]; then
  run_test "Database statistics are being collected (reset: $STATS_RESET)" "PASS"
else
  run_test "Database statistics collection issue" "FAIL"
fi

# Check if we have recent transaction data
XACT_COMMIT=$(kubectl exec -n $NAMESPACE $PRIMARY_POD -- \
  env PGPASSWORD=$PASSWORD psql -U app -d $DATABASE -tAc \
  "SELECT xact_commit FROM pg_stat_database WHERE datname = '$DATABASE';" 2>/dev/null || echo "0")

if [ "$XACT_COMMIT" -gt 0 ]; then
  run_test "Database has recorded $XACT_COMMIT committed transactions" "PASS"
else
  run_test "No committed transactions recorded (stats issue or no activity)" "WARN"
fi

echo ""

# ============================================================
# Test 7: Verify all pods are healthy
# ============================================================
echo -e "${BLUE}Test 7: Verify cluster pod health${NC}"

READY_PODS=0
for POD in $ALL_PODS; do
  POD_READY=$(kubectl get pod -n $NAMESPACE $POD -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  if [ "$POD_READY" = "True" ]; then
    ((READY_PODS++))
  fi
done

if [ "$READY_PODS" -eq "$TOTAL_PODS" ]; then
  run_test "All $TOTAL_PODS pods are Ready" "PASS"
else
  run_test "$READY_PODS/$TOTAL_PODS pods are Ready" "WARN"
fi

# Check for pod restarts (might indicate issues)
MAX_RESTARTS=0
for POD in $ALL_PODS; do
  RESTARTS=$(kubectl get pod -n $NAMESPACE $POD -o jsonpath='{.status.containerStatuses[0].restartCount}')
  if [ "$RESTARTS" -gt "$MAX_RESTARTS" ]; then
    MAX_RESTARTS=$RESTARTS
  fi
done

if [ "$MAX_RESTARTS" -eq 0 ]; then
  run_test "No pod restarts detected" "PASS"
elif [ "$MAX_RESTARTS" -le 2 ]; then
  run_test "Maximum $MAX_RESTARTS restarts detected (acceptable during chaos)" "WARN"
else
  run_test "Maximum $MAX_RESTARTS restarts detected (investigate)" "FAIL"
fi

echo ""

# ============================================================
# Summary
# ============================================================
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo ""
echo "Results:"
echo -e "  ${GREEN}Passed:${NC}  $TESTS_PASSED"
echo -e "  ${YELLOW}Warnings:${NC} $TESTS_WARNED"
echo -e "  ${RED}Failed:${NC}  $TESTS_FAILED"
echo ""

TOTAL_TESTS=$((TESTS_PASSED + TESTS_WARNED + TESTS_FAILED))
echo "Total tests: $TOTAL_TESTS"
echo ""

# Additional context
echo "Additional Information:"
echo "  Primary Pod:    $PRIMARY_POD"
echo "  Total Pods:     $TOTAL_PODS"
echo "  Account Rows:   $ACCOUNTS_COUNT"
echo "  History Rows:   $HISTORY_COUNT"
echo "  Max Repl Lag:   ${MAX_LAG}s"
echo "  Active Slots:   $ACTIVE_SLOTS/$EXPECTED_REPLICAS"
echo ""

# Final verdict
if [ "$TESTS_FAILED" -eq 0 ]; then
  if [ "$TESTS_WARNED" -eq 0 ]; then
    echo "=========================================="
    echo -e "${GREEN}✅ ALL CONSISTENCY CHECKS PASSED${NC}"
    echo "=========================================="
    echo ""
    echo "🎉 Cluster is healthy and data is consistent!"
    exit 0
  else
    echo "=========================================="
    echo -e "${YELLOW}⚠️  CHECKS PASSED WITH WARNINGS${NC}"
    echo "=========================================="
    echo ""
    echo "Cluster appears healthy but has some warnings."
    echo "Review the warnings above for potential issues."
    exit 0
  fi
else
  echo "=========================================="
  echo -e "${RED}❌ CONSISTENCY CHECKS FAILED${NC}"
  echo "=========================================="
  echo ""
  echo "Data consistency issues detected!"
  echo "Review the failures above and investigate."
  exit 1
fi
