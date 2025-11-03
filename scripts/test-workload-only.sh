#!/bin/bash
# Standalone workload tester - Tests Step 2: Start Continuous Workload
# This script only runs the pgbench workload without any chaos experiments

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
WORKLOAD_DURATION=${3:-120}  # 2 minutes for testing (vs 10 min default)
NAMESPACE=${4:-default}

# Functions
log() {
  echo -e "${CYAN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✅ $1${NC}"
}

log_warn() {
  echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️  $1${NC}"
}

log_error() {
  echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ❌ $1${NC}"
}

log_section() {
  echo ""
  echo "=========================================="
  echo -e "${BLUE}$1${NC}"
  echo "=========================================="
  echo ""
}

# ============================================================
# Main Execution
# ============================================================

clear
log_section "Testing Continuous Workload (Step 2 Only)"

echo "Configuration:"
echo "  Cluster:            $CLUSTER_NAME"
echo "  Namespace:          $NAMESPACE"
echo "  Database:           $DATABASE"
echo "  Workload Duration:  ${WORKLOAD_DURATION}s"
echo ""

# ============================================================
# Pre-flight checks
# ============================================================
log_section "Pre-flight Checks"

log "Checking cluster exists..."
if ! kubectl get cluster $CLUSTER_NAME -n $NAMESPACE &>/dev/null; then
  log_error "Cluster '$CLUSTER_NAME' not found in namespace '$NAMESPACE'"
  exit 1
fi
log_success "Cluster found"

log "Checking cluster pods are running..."
RUNNING_PODS=$(kubectl get pods -l cnpg.io/cluster=$CLUSTER_NAME -n $NAMESPACE --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
if [ "$RUNNING_PODS" -eq 0 ]; then
  log_error "No running pods found in cluster $CLUSTER_NAME"
  exit 1
fi
log_success "$RUNNING_PODS pod(s) running"

log "Checking if test data exists..."
CHECK_POD=$(kubectl get pods -l cnpg.io/cluster=$CLUSTER_NAME -n $NAMESPACE --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

EXISTING_ACCOUNTS=$(timeout 10 kubectl exec -n $NAMESPACE $CHECK_POD -- psql -U postgres -d $DATABASE -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_name = 'pgbench_accounts';" 2>&1 | grep -E '^[0-9]+$' | head -1 || echo "0")

if [ "$EXISTING_ACCOUNTS" -eq 0 ]; then
  log_error "Test data not found! Run init-pgbench-testdata.sh first"
  echo ""
  echo "Initialize data with:"
  echo "  ./scripts/init-pgbench-testdata.sh $CLUSTER_NAME $DATABASE"
  exit 1
fi
log_success "Test data exists (pgbench_accounts table found)"

# ============================================================
# Start continuous workload
# ============================================================
log_section "Starting Continuous Workload"

log "Deploying pgbench workload job..."

# Generate unique job name
JOB_NAME="pgbench-workload-test-$(date +%s)"

cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $NAMESPACE
  labels:
    app: pgbench-workload
    test-id: workload-test-$(date +%s)
spec:
  parallelism: 3
  completions: 3
  backoffLimit: 0
  activeDeadlineSeconds: $((WORKLOAD_DURATION + 60))
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

if [ $? -ne 0 ]; then
  log_error "Failed to create workload job"
  exit 1
fi

log_success "Job '$JOB_NAME' created"

# Wait for at least one pod to start
log "Waiting for workload pods to start..."
sleep 15

WORKLOAD_PODS=$(kubectl get pods -n $NAMESPACE -l app=pgbench-workload --no-headers 2>/dev/null | wc -l)
if [ "$WORKLOAD_PODS" -gt 0 ]; then
  log_success "$WORKLOAD_PODS workload pod(s) started"
  
  # Show workload pod status
  log "Workload pod status:"
  kubectl get pods -n $NAMESPACE -l app=pgbench-workload
else
  log_error "Failed to start workload pods"
  exit 1
fi

# ============================================================
# Verify workload is active
# ============================================================
log_section "Verifying Workload Activity"

log "Checking database connections..."
sleep 10

STATS_POD=$(kubectl get pods -l cnpg.io/cluster=$CLUSTER_NAME -n $NAMESPACE --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$STATS_POD" ]; then
  log_warn "No running pods found, skipping verification"
else
  # Check active connections
  ACTIVE_BACKENDS=$(timeout 5 kubectl exec -n $NAMESPACE $STATS_POD -- psql -U postgres -tAc \
    "SELECT count(*) FROM pg_stat_activity WHERE datname = '$DATABASE' AND state = 'active';" 2>&1 | grep -E '^[0-9]+$' | head -1 || echo "0")

  if [ "$ACTIVE_BACKENDS" -gt 0 ]; then
    log_success "Workload is active - $ACTIVE_BACKENDS active connections"
  else
    log_warn "No active connections detected yet - workload may be ramping up"
  fi
  
  # Show connection details
  log "Connection details:"
  kubectl exec -n $NAMESPACE $STATS_POD -- psql -U postgres -tAc \
    "SELECT application_name, state, wait_event_type, wait_event FROM pg_stat_activity WHERE datname = '$DATABASE' AND usename = 'app';" 2>/dev/null || true
fi

# ============================================================
# Monitor workload
# ============================================================
log_section "Monitoring Workload Progress"

log "You can monitor the workload with these commands:"
echo ""
echo "  # Watch pod status:"
echo "  watch kubectl get pods -n $NAMESPACE -l app=pgbench-workload"
echo ""
echo "  # View logs from a workload pod:"
echo "  kubectl logs -n $NAMESPACE -l app=pgbench-workload -f"
echo ""
echo "  # Check database activity:"
echo "  kubectl exec -n $NAMESPACE $STATS_POD -- psql -U postgres -c \"SELECT * FROM pg_stat_activity WHERE datname = '$DATABASE';\""
echo ""
echo "  # Check transaction stats:"
echo "  kubectl exec -n $NAMESPACE $STATS_POD -- psql -U postgres -c \"SELECT xact_commit, xact_rollback, tup_inserted, tup_updated FROM pg_stat_database WHERE datname = '$DATABASE';\""
echo ""

log "Workload will run for ${WORKLOAD_DURATION} seconds..."
log "Showing live logs from first pod (Ctrl+C to stop watching):"
echo ""

# Follow logs from first pod
FIRST_POD=$(kubectl get pods -n $NAMESPACE -l app=pgbench-workload -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$FIRST_POD" ]; then
  kubectl logs -n $NAMESPACE $FIRST_POD -f 2>/dev/null || log_warn "Pod not ready yet or already completed"
fi

# ============================================================
# Wait for completion
# ============================================================
log_section "Waiting for Workload Completion"

log "Waiting for job to complete (timeout: $((WORKLOAD_DURATION + 60))s)..."
kubectl wait --for=condition=complete job/$JOB_NAME -n $NAMESPACE --timeout=$((WORKLOAD_DURATION + 60))s || {
  log_warn "Job did not complete in time or failed"
}

# ============================================================
# Results
# ============================================================
log_section "Workload Test Results"

log "Final job status:"
kubectl get job $JOB_NAME -n $NAMESPACE

log ""
log "Pod statuses:"
kubectl get pods -n $NAMESPACE -l app=pgbench-workload

log ""
log "Sample logs from workload pods:"
for pod in $(kubectl get pods -n $NAMESPACE -l app=pgbench-workload -o jsonpath='{.items[*].metadata.name}'); do
  echo ""
  echo "--- Logs from $pod ---"
  kubectl logs $pod -n $NAMESPACE --tail=20 2>/dev/null || echo "Could not get logs"
done

log ""
log_section "Summary"

SUCCEEDED=$(kubectl get job $JOB_NAME -n $NAMESPACE -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
FAILED=$(kubectl get job $JOB_NAME -n $NAMESPACE -o jsonpath='{.status.failed}' 2>/dev/null || echo "0")

echo "Job: $JOB_NAME"
echo "  Succeeded: $SUCCEEDED / 3"
echo "  Failed:    $FAILED / 3"
echo ""

if [ "$SUCCEEDED" -eq 3 ]; then
  log_success "✅ All workload pods completed successfully!"
  echo ""
  echo "Next steps:"
  echo "  1. Clean up: kubectl delete job $JOB_NAME -n $NAMESPACE"
  echo "  2. Run full test: ./scripts/run-e2e-chaos-test.sh"
  exit 0
else
  log_warn "Some workload pods did not complete successfully"
  echo ""
  echo "Troubleshooting:"
  echo "  1. Check pod logs: kubectl logs -n $NAMESPACE -l app=pgbench-workload"
  echo "  2. Check events: kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp'"
  echo "  3. Clean up: kubectl delete job $JOB_NAME -n $NAMESPACE"
  exit 1
fi
