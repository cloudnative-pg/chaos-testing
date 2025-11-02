#!/bin/bash
# End-to-end CNPG chaos test orchestrator
# Implements complete E2E workflow: init -> workload -> chaos -> verify

set -e

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME=${1:-pg-eu}
DATABASE=${2:-app}
CHAOS_EXPERIMENT=${3:-cnpg-primary-with-workload}
WORKLOAD_DURATION=${4:-600}  # 10 minutes
SCALE_FACTOR=${5:-50}
NAMESPACE=${6:-default}

# Directories
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Logging
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/e2e-test-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR"

# Functions
log() {
  echo -e "${CYAN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
  echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✅ $1${NC}" | tee -a "$LOG_FILE"
}

log_warn() {
  echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️  $1${NC}" | tee -a "$LOG_FILE"
}

log_error() {
  echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ❌ $1${NC}" | tee -a "$LOG_FILE"
}

log_section() {
  echo "" | tee -a "$LOG_FILE"
  echo "==========================================" | tee -a "$LOG_FILE"
  echo -e "${BLUE}$1${NC}" | tee -a "$LOG_FILE"
  echo "==========================================" | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
}

# Cleanup function
cleanup() {
  log_section "Cleanup"
  
  # Stop port-forwarding if running
  pkill -f "port-forward.*prometheus" 2>/dev/null || true
  
  # Clean up temporary test pods
  kubectl delete pod -l app=chaos-test-temp --force --grace-period=0 2>/dev/null || true
  
  log_success "Cleanup completed"
}

trap cleanup EXIT

# ============================================================
# Main Execution
# ============================================================

clear
log_section "CNPG E2E Chaos Testing - Full Workflow"

echo "Configuration:" | tee -a "$LOG_FILE"
echo "  Cluster:            $CLUSTER_NAME" | tee -a "$LOG_FILE"
echo "  Namespace:          $NAMESPACE" | tee -a "$LOG_FILE"
echo "  Database:           $DATABASE" | tee -a "$LOG_FILE"
echo "  Chaos Experiment:   $CHAOS_EXPERIMENT" | tee -a "$LOG_FILE"
echo "  Workload Duration:  ${WORKLOAD_DURATION}s" | tee -a "$LOG_FILE"
echo "  Scale Factor:       $SCALE_FACTOR" | tee -a "$LOG_FILE"
echo "  Log File:           $LOG_FILE" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# ============================================================
# Step 0: Pre-flight checks
# ============================================================
log_section "Step 0: Pre-flight Checks"

log "Checking cluster exists..."
if ! kubectl get cluster $CLUSTER_NAME -n $NAMESPACE &>/dev/null; then
  log_error "Cluster '$CLUSTER_NAME' not found in namespace '$NAMESPACE'"
  exit 1
fi
log_success "Cluster found"

log "Checking Prometheus is running..."
if ! kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus &>/dev/null; then
  log_warn "Prometheus service not found - metrics validation may fail"
else
  log_success "Prometheus found"
fi

log "Checking Litmus ChaosEngine CRD..."
if ! kubectl get crd chaosengines.litmuschaos.io &>/dev/null; then
  log_error "Litmus ChaosEngine CRD not found - install Litmus first"
  exit 1
fi
log_success "Litmus CRD found"

log "Checking experiment file exists..."
EXPERIMENT_FILE="$ROOT_DIR/experiments/${CHAOS_EXPERIMENT}.yaml"
if [ ! -f "$EXPERIMENT_FILE" ]; then
  log_error "Experiment file not found: $EXPERIMENT_FILE"
  exit 1
fi
log_success "Experiment file found"

# ============================================================
# Step 1: Initialize test data
# ============================================================
log_section "Step 1: Initialize Test Data"

log "Checking if test data already exists..."

# Find any ready pod to check for existing data
CHECK_POD=$(kubectl get pods -l cnpg.io/cluster=$CLUSTER_NAME -n $NAMESPACE --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$CHECK_POD" ]; then
  log_error "No running pods found in cluster $CLUSTER_NAME"
  exit 1
fi

EXISTING_ACCOUNTS=$(timeout 10 kubectl exec -n $NAMESPACE $CHECK_POD -- psql -U postgres -d $DATABASE -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_name = 'pgbench_accounts';" 2>&1 | grep -E '^[0-9]+$' | head -1 || echo "0")

if [ "$EXISTING_ACCOUNTS" -gt 0 ]; then
  log_warn "Test data already exists - skipping initialization"
  log "To reinitialize, run: $SCRIPT_DIR/init-pgbench-testdata.sh"
else
  log "Initializing pgbench test data..."
  bash "$SCRIPT_DIR/init-pgbench-testdata.sh" $CLUSTER_NAME $DATABASE $SCALE_FACTOR $NAMESPACE | tee -a "$LOG_FILE"
  
  if [ ${PIPESTATUS[0]} -eq 0 ]; then
    log_success "Test data initialized"
  else
    log_error "Failed to initialize test data"
    exit 1
  fi
fi

# Verify data
log "Verifying test data..."

# Try replicas first (more reliable), then try primary
VERIFY_POD=$(kubectl get pods -l cnpg.io/cluster=$CLUSTER_NAME,cnpg.io/instanceRole=replica -n $NAMESPACE --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$VERIFY_POD" ]; then
  log "No replica available, trying primary..."
  VERIFY_POD=$(kubectl get pods -l cnpg.io/cluster=$CLUSTER_NAME,cnpg.io/instanceRole=primary -n $NAMESPACE --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi

if [ -z "$VERIFY_POD" ]; then
  log_error "Could not find any running pod in cluster"
  exit 1
fi

log "Using pod: $VERIFY_POD"

# Use pg_class.reltuples for fast estimate (avoids table scan during heavy workload)
ACCOUNT_COUNT=$(timeout 5 kubectl exec -n $NAMESPACE $VERIFY_POD -- psql -U postgres -d $DATABASE -tAc \
  "SELECT reltuples::bigint FROM pg_class WHERE relname='pgbench_accounts';" 2>&1 | grep -E '^[0-9]+$' | head -1 || echo "0")

if [ "$ACCOUNT_COUNT" -gt 0 ]; then
  log_success "Verified: ~$ACCOUNT_COUNT rows in pgbench_accounts (estimate)"
else
  log_warn "Could not verify row count - may be normal if workload is very active"
fi

# ============================================================
# Step 2: Start continuous workload
# ============================================================
log_section "Step 2: Start Continuous Workload"

log "Deploying pgbench workload job..."

# Generate unique job name
JOB_NAME="pgbench-workload-$(date +%s)"

cat <<EOF | kubectl apply -f - | tee -a "$LOG_FILE"
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $NAMESPACE
  labels:
    app: pgbench-workload
    test-id: e2e-$(date +%s)
spec:
  parallelism: 3
  completions: 3
  backoffLimit: 0
  activeDeadlineSeconds: $WORKLOAD_DURATION
  template:
    metadata:
      labels:
        app: pgbench-workload
    spec:
      restartPolicy: Never
      containers:
        - name: pgbench
          image: postgres:16
          env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${CLUSTER_NAME}-credentials
                  key: password
            - name: PGHOST
              value: "${CLUSTER_NAME}-rw"
            - name: PGDATABASE
              value: "$DATABASE"
            - name: PGUSER
              value: "app"
          command: ["/bin/bash"]
          args:
            - -c
            - |
              echo "Workload started at \$(date)"
              sleep \$((RANDOM % 10))  # Stagger start
              pgbench -c 10 -j 2 -T $WORKLOAD_DURATION -P 10 -r || true
              echo "Workload completed at \$(date)"
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
EOF

# Wait for at least one pod to start
log "Waiting for workload pods to start..."
sleep 15

WORKLOAD_PODS=$(kubectl get pods -n $NAMESPACE -l app=pgbench-workload --no-headers 2>/dev/null | wc -l)
if [ "$WORKLOAD_PODS" -gt 0 ]; then
  log_success "$WORKLOAD_PODS workload pod(s) started"
  
  # Show workload pod status
  log "Workload pod status:"
  kubectl get pods -n $NAMESPACE -l app=pgbench-workload | tee -a "$LOG_FILE"
else
  log_error "Failed to start workload pods"
  exit 1
fi

# Verify workload is generating transactions
log "Verifying workload is active (checking transaction rate)..."
sleep 5

# Use any running pod for stats queries (replicas are fine for pg_stat_database)
STATS_POD=$(kubectl get pods -l cnpg.io/cluster=$CLUSTER_NAME -n $NAMESPACE --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$STATS_POD" ]; then
  log_warn "No running pods found, skipping transaction rate check"
else
  # Use shorter timeout and check active backends instead
  ACTIVE_BACKENDS=$(timeout 5 kubectl exec -n $NAMESPACE $STATS_POD -- psql -U postgres -tAc \
    "SELECT count(*) FROM pg_stat_activity WHERE datname = '$DATABASE' AND state = 'active';" 2>&1 | grep -E '^[0-9]+$' | head -1 || echo "0")

  if [ "$ACTIVE_BACKENDS" -gt 0 ]; then
    log_success "Workload is active - $ACTIVE_BACKENDS active connections to $DATABASE"
  else
    log_warn "No active connections detected - workload may not have fully started yet"
  fi
fi

# ============================================================
# Step 3: Execute chaos experiment
# ============================================================
log_section "Step 3: Execute Chaos Experiment"

log "Cleaning up any existing chaos engines..."
kubectl delete chaosengine $CHAOS_EXPERIMENT -n $NAMESPACE 2>/dev/null || true
sleep 5

log "Applying chaos experiment: $CHAOS_EXPERIMENT"
kubectl apply -f "$EXPERIMENT_FILE" | tee -a "$LOG_FILE"

if [ $? -ne 0 ]; then
  log_error "Failed to apply chaos experiment"
  exit 1
fi

log_success "Chaos experiment applied"

# Wait for chaos to start
log "Waiting for chaos to initialize..."
sleep 10

# Monitor chaos status
log "Monitoring chaos experiment progress..."

CHAOS_START=$(date +%s)
MAX_WAIT=600  # 10 minutes max wait

while true; do
  CHAOS_STATUS=$(kubectl get chaosengine $CHAOS_EXPERIMENT -n $NAMESPACE -o jsonpath='{.status.engineStatus}' 2>/dev/null || echo "unknown")
  
  log "Chaos status: $CHAOS_STATUS"
  
  if [ "$CHAOS_STATUS" = "completed" ]; then
    log_success "Chaos experiment completed"
    break
  elif [ "$CHAOS_STATUS" = "stopped" ]; then
    log_error "Chaos experiment stopped unexpectedly"
    break
  fi
  
  # Check timeout
  ELAPSED=$(($(date +%s) - CHAOS_START))
  if [ $ELAPSED -gt $MAX_WAIT ]; then
    log_error "Chaos experiment timeout (${MAX_WAIT}s exceeded)"
    break
  fi
  
  # Show pod status
  log "Current cluster pod status:"
  kubectl get pods -n $NAMESPACE -l cnpg.io/cluster=$CLUSTER_NAME | tee -a "$LOG_FILE"
  
  sleep 30
done

# ============================================================
# Step 4: Wait for workload to complete
# ============================================================
log_section "Step 4: Wait for Workload Completion"

log "Waiting for workload job to complete..."
kubectl wait --for=condition=complete job/$JOB_NAME -n $NAMESPACE --timeout=900s || {
  log_warn "Workload job did not complete successfully (this may be expected during chaos)"
}

# Get workload logs
log "Workload logs (sample from first pod):"
FIRST_WORKLOAD_POD=$(kubectl get pods -n $NAMESPACE -l app=pgbench-workload -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$FIRST_WORKLOAD_POD" ]; then
  kubectl logs $FIRST_WORKLOAD_POD -n $NAMESPACE --tail=50 | tee -a "$LOG_FILE"
fi

# ============================================================
# Step 5: Verify data consistency
# ============================================================
log_section "Step 5: Data Consistency Verification"

# Wait a bit for cluster to stabilize
log "Waiting 30s for cluster to stabilize..."
sleep 30

log "Running data consistency checks..."
bash "$SCRIPT_DIR/verify-data-consistency.sh" $CLUSTER_NAME $DATABASE $NAMESPACE | tee -a "$LOG_FILE"

CONSISTENCY_RESULT=${PIPESTATUS[0]}

if [ $CONSISTENCY_RESULT -eq 0 ]; then
  log_success "Data consistency verification passed"
else
  log_error "Data consistency verification failed"
fi

# ============================================================
# Step 6: Get chaos results
# ============================================================
log_section "Step 6: Chaos Experiment Results"

log "Fetching chaos results..."
if [ -f "$SCRIPT_DIR/get-chaos-results.sh" ]; then
  bash "$SCRIPT_DIR/get-chaos-results.sh" | tee -a "$LOG_FILE"
else
  log_warn "get-chaos-results.sh not found, showing basic results..."
  kubectl get chaosresult -n $NAMESPACE | tee -a "$LOG_FILE"
  
  CHAOS_RESULT=$(kubectl get chaosresult -n $NAMESPACE -l chaosUID=$(kubectl get chaosengine $CHAOS_EXPERIMENT -n $NAMESPACE -o jsonpath='{.status.uid}') -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  
  if [ -n "$CHAOS_RESULT" ]; then
    log "Chaos result details:"
    kubectl describe chaosresult $CHAOS_RESULT -n $NAMESPACE | tee -a "$LOG_FILE"
  fi
fi

# ============================================================
# Step 7: Generate metrics report
# ============================================================
log_section "Step 7: Metrics Report"

log "Generating final metrics report..."

kubectl run temp-report-$$  --rm -i --restart=Never \
  --image=postgres:16 \
  --namespace=$NAMESPACE \
  --env="PGPASSWORD=$PASSWORD" \
  --command -- \
  psql -h ${CLUSTER_NAME}-rw -U app -d $DATABASE <<EOF | tee -a "$LOG_FILE"

SELECT '=== Database Statistics ===' as report;

SELECT 
  'Total Accounts' as metric,
  count(*)::text as value
FROM pgbench_accounts
UNION ALL
SELECT 
  'Total History Records',
  count(*)::text
FROM pgbench_history
UNION ALL
SELECT
  'Transactions Committed',
  xact_commit::text
FROM pg_stat_database WHERE datname = '$DATABASE'
UNION ALL
SELECT
  'Transactions Rolled Back',
  xact_rollback::text
FROM pg_stat_database WHERE datname = '$DATABASE'
UNION ALL
SELECT
  'Rows Inserted',
  tup_inserted::text
FROM pg_stat_database WHERE datname = '$DATABASE'
UNION ALL
SELECT
  'Rows Fetched',
  tup_fetched::text
FROM pg_stat_database WHERE datname = '$DATABASE';

SELECT '=== Replication Status ===' as report;

SELECT
  application_name,
  state,
  sync_state,
  COALESCE(EXTRACT(EPOCH FROM replay_lag)::int, 0) || 's' as replay_lag
FROM pg_stat_replication;

EOF

# ============================================================
# Step 8: Summary and recommendations
# ============================================================
log_section "Test Summary"

echo "" | tee -a "$LOG_FILE"
echo "Test Execution Summary:" | tee -a "$LOG_FILE"
echo "  Start Time:         $(date -d @$CHAOS_START 2>/dev/null || date)" | tee -a "$LOG_FILE"
echo "  End Time:           $(date)" | tee -a "$LOG_FILE"
echo "  Duration:           $(($(date +%s) - CHAOS_START))s" | tee -a "$LOG_FILE"
echo "  Cluster:            $CLUSTER_NAME" | tee -a "$LOG_FILE"
echo "  Chaos Experiment:   $CHAOS_EXPERIMENT" | tee -a "$LOG_FILE"
echo "  Workload Job:       $JOB_NAME" | tee -a "$LOG_FILE"
echo "  Log File:           $LOG_FILE" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Results:" | tee -a "$LOG_FILE"
echo "  Chaos Status:       $CHAOS_STATUS" | tee -a "$LOG_FILE"
echo "  Consistency Check:  $([ $CONSISTENCY_RESULT -eq 0 ] && echo '✅ PASSED' || echo '❌ FAILED')" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Next Steps:" | tee -a "$LOG_FILE"
echo "  1. Review logs:     cat $LOG_FILE" | tee -a "$LOG_FILE"
echo "  2. Check Grafana:   kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-grafana 3000:80" | tee -a "$LOG_FILE"
echo "  3. Query Prometheus: kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090" | tee -a "$LOG_FILE"
echo "  4. Clean up:        kubectl delete job $JOB_NAME -n $NAMESPACE" | tee -a "$LOG_FILE"
echo "  5. Rerun test:      $0 $@" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

if [ $CONSISTENCY_RESULT -eq 0 ] && [ "$CHAOS_STATUS" = "completed" ]; then
  log_success "🎉 E2E CHAOS TEST COMPLETED SUCCESSFULLY!"
  exit 0
else
  log_error "E2E test completed with errors - review logs for details"
  exit 1
fi
