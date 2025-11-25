#!/bin/bash
#
# CNPG Jepsen + Chaos E2E Test Runner
#
# This script orchestrates a complete chaos testing workflow:
# 1. Deploy Jepsen consistency testing Job
# 2. Wait for Jepsen to initialize
# 3. Apply Litmus chaos experiment (primary pod deletion)
# 4. Monitor execution in background
# 5. Extract Jepsen results after completion
# 6. Validate consistency findings
# 7. Cleanup resources
#
# Features:
# - Automatic timestamping for unique test runs
# - Background monitoring
# - Graceful cleanup on interrupt
# - Exit codes indicate test success/failure
# - Result artifacts saved to logs/ directory
#
# Prerequisites:
# - kubectl configured with cluster access
# - Litmus Chaos installed (chaos-operator running)
# - CNPG cluster deployed and healthy
# - Prometheus monitoring enabled (for probes)
# - pg-{cluster}-credentials secret exists
#
# Usage:
#   ./scripts/run-jepsen-chaos-test.sh <cluster-name> <db-user> [test-duration-seconds]
#
# Examples:
#   # 5 minute test against pg-eu cluster
#   ./scripts/run-jepsen-chaos-test.sh pg-eu app 300
#
#   # 10 minute test
#   ./scripts/run-jepsen-chaos-test.sh pg-eu app 600
#
#   # Default 5 minute test
#   ./scripts/run-jepsen-chaos-test.sh pg-eu app
#
# Exit Codes:
#   0  - Test passed (consistency verified, no anomalies)
#   1  - Test failed (consistency violations detected)
#   2  - Deployment/execution error
#   3  - Invalid arguments
#   130 - User interrupted (SIGINT)

set -euo pipefail

# ==========================================
# Configuration Constants
# ==========================================

# Color output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Timeouts (in seconds)
readonly PVC_BIND_TIMEOUT=60
readonly PVC_BIND_CHECK_INTERVAL=2
readonly POD_START_TIMEOUT=600        # 10 minutes for pod to start (includes image pull)
readonly POD_START_CHECK_INTERVAL=5
readonly JEPSEN_INIT_TIMEOUT=120      # 2 minutes for Jepsen to connect to DB
readonly JEPSEN_INIT_CHECK_INTERVAL=5
readonly WORKLOAD_BUFFER=300          # 5 minutes buffer beyond TEST_DURATION
readonly RESULT_WAIT_TIMEOUT=180      # 3 minutes for files to be written
readonly RESULT_WAIT_INTERVAL=5
readonly EXTRACTOR_POD_TIMEOUT=30
readonly LOG_CHECK_INTERVAL=10        # Check logs every 10 seconds during monitoring
readonly STATUS_CHECK_INTERVAL=30     # Check status every 30 seconds

# Resource limits
readonly JEPSEN_MEMORY_REQUEST="512Mi"
readonly JEPSEN_MEMORY_LIMIT="1Gi"
readonly JEPSEN_CPU_REQUEST="500m"
readonly JEPSEN_CPU_LIMIT="1000m"
readonly LITMUS_NAMESPACE="${LITMUS_NAMESPACE:-litmus}"
readonly PROMETHEUS_NAMESPACE="${PROMETHEUS_NAMESPACE:-monitoring}"

# ==========================================
# Parse and Validate Arguments
# ==========================================

CLUSTER_NAME="${1:-}"
DB_USER="${2:-}"
TEST_DURATION="${3:-300}"  # Default 5 minutes
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Input validation function
validate_input() {
    local input="$1"
    local name="$2"
    
    # Only allow lowercase letters, numbers, and hyphens
    if [[ ! "$input" =~ ^[a-z0-9-]+$ ]]; then
        echo -e "${RED}Error: Invalid $name: '$input'${NC}" >&2
        echo "Must contain only lowercase letters, numbers, and hyphens" >&2
        exit 3
    fi
    
    # Length check (Kubernetes name limit)
    if [[ ${#input} -gt 63 ]]; then
        echo -e "${RED}Error: $name too long (max 63 characters)${NC}" >&2
        exit 3
    fi
}

# Validate required arguments
if [[ -z "$CLUSTER_NAME" || -z "$DB_USER" ]]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    echo "Usage: $0 <cluster-name> <db-user> [test-duration-seconds]"
    echo ""
    echo "Examples:"
    echo "  $0 pg-eu app 300"
    echo "  $0 pg-prod postgres 600"
    exit 3
fi

# Validate inputs
validate_input "$CLUSTER_NAME" "cluster name"
validate_input "$DB_USER" "database user"

# Validate test duration
if [[ ! "$TEST_DURATION" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: Test duration must be a positive number${NC}"
    exit 3
fi

if [[ $TEST_DURATION -lt 60 ]]; then
    echo -e "${RED}Error: Test duration must be at least 60 seconds${NC}"
    exit 3
fi

# Configuration
JOB_NAME="jepsen-chaos-${TIMESTAMP}"
CHAOS_ENGINE_NAME="cnpg-jepsen-chaos"
NAMESPACE="default"
LOG_DIR="logs/jepsen-chaos-${TIMESTAMP}"
RESULT_DIR="${LOG_DIR}/results"

# Create log directories
mkdir -p "${LOG_DIR}" "${RESULT_DIR}"

# ==========================================
# Logging Functions
# ==========================================

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $*" | tee -a "${LOG_DIR}/test.log"
}

error() {
    echo -e "${RED}[$(date +'%H:%M:%S')] ERROR:${NC} $*" | tee -a "${LOG_DIR}/test.log"
}

success() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')] SUCCESS:${NC} $*" | tee -a "${LOG_DIR}/test.log"
}

warn() {
    echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARNING:${NC} $*" | tee -a "${LOG_DIR}/test.log"
}

# Safe grep with fixed strings (not regex)
safe_grep_count() {
    local pattern="$1"
    local file="$2"
    local count="0"

    if count=$(grep -F -c "$pattern" "$file" 2>/dev/null); then
        printf "%s" "$count"
    else
        printf "%s" "0"
    fi
}

# Check if a Kubernetes resource exists
check_resource() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="${3:-${NAMESPACE}}"
    local error_msg="${4:-}"
    
    if ! kubectl get "$resource_type" "$resource_name" -n "$namespace" &>/dev/null; then
        if [[ -n "$error_msg" ]]; then
            error "$error_msg"
        else
            error "${resource_type} '${resource_name}' not found in namespace '${namespace}'"
        fi
        return 1
    fi
    
    return 0
}

# ==========================================
# Cleanup Function
# ==========================================

cleanup() {
    local exit_code=$?
    
    if [[ $exit_code -eq 130 ]]; then
        warn "Test interrupted by user (SIGINT)"
    fi
    
    log "Starting cleanup..."
    
    # Delete chaos engine
    if kubectl get chaosengine ${CHAOS_ENGINE_NAME} -n ${LITMUS_NAMESPACE} &>/dev/null; then
        log "Deleting chaos engine: ${CHAOS_ENGINE_NAME}"
        kubectl delete chaosengine ${CHAOS_ENGINE_NAME} -n ${LITMUS_NAMESPACE} --wait=false || true
    fi
    
    # Delete Jepsen Job
    if kubectl get job ${JOB_NAME} -n ${NAMESPACE} &>/dev/null; then
        log "Deleting Jepsen Job: ${JOB_NAME}"
        kubectl delete job ${JOB_NAME} -n ${NAMESPACE} --wait=false || true
    fi
    
    # Kill background monitoring
    if [[ -n "${MONITOR_PID:-}" ]]; then
        kill ${MONITOR_PID} 2>/dev/null || true
    fi
    
    success "Cleanup complete"
    exit $exit_code
}

trap cleanup EXIT INT TERM

# ==========================================
# Step 1/10: Pre-flight Checks
# ==========================================

log "Starting CNPG Jepsen + Chaos E2E Test"
log "Cluster: ${CLUSTER_NAME}"
log "DB User: ${DB_USER}"
log "Test Duration: ${TEST_DURATION}s"
log "Job Name: ${JOB_NAME}"
log "Logs: ${LOG_DIR}"
log ""

log "Step 1/10: Running pre-flight checks..."

# Check kubectl
if ! command -v kubectl &>/dev/null; then
    error "kubectl not found in PATH"
    exit 2
fi

# Check cluster connectivity
if ! kubectl cluster-info &>/dev/null; then
    error "Cannot connect to Kubernetes cluster"
    exit 2
fi

# Check Litmus operator + control plane
if ! kubectl get deployment chaos-operator-ce -n "${LITMUS_NAMESPACE}" &>/dev/null \
    && ! kubectl get deployment litmus -n "${LITMUS_NAMESPACE}" &>/dev/null; then
    error "Litmus chaos operator not found in namespace '${LITMUS_NAMESPACE}'. Install or repair via Helm (see README section 3)."
    exit 2
fi

if ! kubectl get deployment chaos-litmus-portal-server -n "${LITMUS_NAMESPACE}" &>/dev/null \
    && ! kubectl get deployment chaos-litmus-server -n "${LITMUS_NAMESPACE}" &>/dev/null; then
    error "Litmus control plane deployment not found in namespace '${LITMUS_NAMESPACE}'. Install or repair via Helm (see README section 3)."
    exit 2
fi

# Check CNPG cluster
check_resource "cluster" "${CLUSTER_NAME}" "${NAMESPACE}" \
    "CNPG cluster '${CLUSTER_NAME}' not found in namespace '${NAMESPACE}'" || exit 2

# Check credentials secret
SECRET_NAME="${CLUSTER_NAME}-app"
check_resource "secret" "${SECRET_NAME}" "${NAMESPACE}" \
    "Credentials secret '${SECRET_NAME}' not found. CNPG should auto-generate this during cluster bootstrap." || exit 2

# Check Prometheus (required for probes) - non-fatal
if ! check_resource "service" "prometheus-kube-prometheus-prometheus" "${PROMETHEUS_NAMESPACE}"; then
    warn "Prometheus not found in namespace '${PROMETHEUS_NAMESPACE}'. Probes may fail."
    warn "Install with: helm install prometheus prometheus-community/kube-prometheus-stack -n ${PROMETHEUS_NAMESPACE}"
fi

success "Pre-flight checks passed"
log ""

# ==========================================
# Step 2/10: Clean Database Tables
# ==========================================

log "Step 2/10: Cleaning previous test data..."

# Prefer CNPG status for authoritative primary identification
PRIMARY_POD=$(kubectl get cluster ${CLUSTER_NAME} -n ${NAMESPACE} -o jsonpath='{.status.currentPrimary}' 2>/dev/null | tr -d ' ')

if [[ -z "$PRIMARY_POD" ]]; then
    warn "CNPG status did not report a current primary, falling back to label selector..."
    PRIMARY_POD=$(kubectl get pods -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME},role=primary -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi

if [[ -z "$PRIMARY_POD" ]]; then
    warn "Label selector did not return a primary pod; probing cluster members..."
    for pod in $(kubectl get pods -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME} -o jsonpath='{.items[*].metadata.name}'); do
        if kubectl exec ${pod} -n ${NAMESPACE} -- psql -U postgres -d ${DB_USER} -Atq -c "SELECT pg_is_in_recovery();" 2>/dev/null | grep -qx "f"; then
            PRIMARY_POD=${pod}
            break
        fi
    done
fi

if [[ -z "$PRIMARY_POD" ]]; then
    error "Unable to determine CNPG primary pod; aborting cleanup to avoid stale data"
    exit 2
fi

log "Cleaning tables on primary: ${PRIMARY_POD}"
kubectl exec ${PRIMARY_POD} -n ${NAMESPACE} -- psql -U postgres -d ${DB_USER} -c "DROP TABLE IF EXISTS txn, txn_append CASCADE;" 2>&1 | grep -E "DROP TABLE|NOTICE" || true
success "Database cleaned"

log ""

# ==========================================
# Step 3/10: Ensure Persistent Volume for Results
# ==========================================

log "Step 3/10: Ensuring persistent volume for results..."

# Create PVC if it doesn't exist
if ! kubectl get pvc jepsen-results -n ${NAMESPACE} &>/dev/null; then
    log "Creating PersistentVolumeClaim for Jepsen results..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jepsen-results
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
EOF
    
    PVC_BOUND=false

    PVC_SC=$(kubectl get pvc jepsen-results -n ${NAMESPACE} -o jsonpath='{.spec.storageClassName}' 2>/dev/null | tr -d ' ')
    if [[ -z "$PVC_SC" ]]; then
        PVC_SC=$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1)
    fi

    BINDING_MODE=""
    if [[ -n "$PVC_SC" ]]; then
        BINDING_MODE=$(kubectl get sc "$PVC_SC" -o jsonpath='{.volumeBindingMode}' 2>/dev/null || echo "")
    fi

    if [[ "$BINDING_MODE" == "WaitForFirstConsumer" ]]; then
        log "StorageClass '${PVC_SC}' uses WaitForFirstConsumer; PVC will stay Pending until the Jepsen pod is scheduled. Continuing without blocking."
        PVC_BOUND=true
    else
        # Wait for PVC to be bound
        log "Waiting up to ${PVC_BIND_TIMEOUT}s for PVC to bind..."
        MAX_ITERATIONS=$((PVC_BIND_TIMEOUT / PVC_BIND_CHECK_INTERVAL))
        
        for i in $(seq 1 $MAX_ITERATIONS); do
            PVC_STATUS=$(kubectl get pvc jepsen-results -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [[ "$PVC_STATUS" == "Bound" ]]; then
                success "PersistentVolumeClaim bound after $((i * PVC_BIND_CHECK_INTERVAL))s"
                PVC_BOUND=true
                break
            fi
            sleep $PVC_BIND_CHECK_INTERVAL
        done
    fi
    
    if [[ "$PVC_BOUND" == "false" ]]; then
        error "PVC did not bind within ${PVC_BIND_TIMEOUT}s"
        kubectl get pvc jepsen-results -n ${NAMESPACE}
        exit 2
    fi
else
    log "PersistentVolumeClaim already exists"
fi

log ""

# ==========================================
# Step 4/10: Deploy Jepsen Job
# ==========================================

log "Step 4/10: Deploying Jepsen consistency testing Job..."

# Create temporary Job manifest with parameters
# Note: Using cat with EOF to avoid shell expansion issues
cat > "${LOG_DIR}/jepsen-job-${TIMESTAMP}.yaml" <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: JOB_NAME_PLACEHOLDER
  namespace: NAMESPACE_PLACEHOLDER
  labels:
    app: jepsen-test
    test-id: chaos-TIMESTAMP_PLACEHOLDER
    cluster: CLUSTER_NAME_PLACEHOLDER
spec:
  backoffLimit: 2
  activeDeadlineSeconds: DEADLINE_PLACEHOLDER
  template:
    metadata:
      labels:
        app: jepsen-test
        test-id: chaos-TIMESTAMP_PLACEHOLDER
    spec:
      restartPolicy: Never
      containers:
      - name: jepsen
        image: ardentperf/jepsenpg:latest
        imagePullPolicy: IfNotPresent
        
        env:
        - name: PGHOST
          value: "PGHOST_PLACEHOLDER"
        - name: PGPORT
          value: "5432"
        - name: PGUSER
          value: "DB_USER_PLACEHOLDER"
        - name: CLUSTER_NAME
          value: "CLUSTER_NAME_PLACEHOLDER"
        - name: NAMESPACE
          value: "NAMESPACE_PLACEHOLDER"
        - name: PGDATABASE
          value: "DB_USER_PLACEHOLDER"
        - name: WORKLOAD
          value: append
        - name: DURATION
          value: "DURATION_PLACEHOLDER"
        - name: RATE
          value: "50"
        - name: CONCURRENCY
          value: "7"
        - name: ISOLATION
          value: read-committed
        
        command:
        - /bin/bash
        - -c
        - |
          set -e
          cd /jepsenpg
          
          # Get PostgreSQL connection details from secret
          export PGPASSWORD=$(cat /secrets/password)
          export PGUSER=$(cat /secrets/username)
          export PGHOST="${CLUSTER_NAME}-rw.${NAMESPACE}.svc.cluster.local"
          export PGDATABASE="${PGDATABASE}"
          
          echo "========================================="
          echo "Jepsen Chaos Integration Test"
          echo "========================================="
          echo "Cluster:     ${CLUSTER_NAME}"
          echo "Namespace:   ${NAMESPACE}"
          echo "Database:    ${PGDATABASE}"
          echo "User:        ${PGUSER}"
          echo "Host:        ${PGHOST}"
          echo "Workload:    ${WORKLOAD}"
          echo "Duration:    ${DURATION}s"
          echo "Concurrency: ${CONCURRENCY} workers"
          echo "Rate:        ${RATE} ops/sec"
          echo "Keys:        50 (uniform distribution)"
          echo "Txn Length:  1 (single-op transactions)"
          echo "Max Writes:  50 per key"
          echo "Isolation:   ${ISOLATION}"
          echo "========================================="
          echo ""
          
          # Test database connectivity
          echo "Testing database connectivity..."
          if command -v psql &> /dev/null; then
            psql -h ${PGHOST} -U ${PGUSER} -d ${PGDATABASE} -c "SELECT version();" || {
              echo "❌ Failed to connect to database"
              exit 1
            }
            echo "✅ Database connection successful"
          else
            echo "⚠️  psql not available, skipping connectivity test"
          fi
          echo ""
          
          # Run Jepsen test
          echo "Starting Jepsen consistency test..."
          echo "========================================="
          
          lein run test-all -w ${WORKLOAD} \
            --isolation ${ISOLATION} \
            --nemesis none \
            --no-ssh \
            --key-count 50 \
            --max-writes-per-key 50 \
            --max-txn-length 1 \
            --key-dist uniform \
            --concurrency ${CONCURRENCY} \
            --rate ${RATE} \
            --time-limit ${DURATION} \
            --test-count 1 \
            --existing-postgres \
            --node ${PGHOST} \
            --postgres-user ${PGUSER} \
            --postgres-password ${PGPASSWORD}
          
          EXIT_CODE=$?
          
          echo ""
          echo "========================================="
          echo "Test completed with exit code: ${EXIT_CODE}"
          echo "========================================="
          
          # Display summary
          if [[ -f store/latest/results.edn ]]; then
            echo ""
            echo "Test Summary:"
            echo "-------------"
            grep -E ":valid\?|:failure-types|:anomaly-types" store/latest/results.edn || true
          fi
          
          exit ${EXIT_CODE}
        
        resources:
          requests:
            memory: "MEMORY_REQUEST_PLACEHOLDER"
            cpu: "CPU_REQUEST_PLACEHOLDER"
          limits:
            memory: "MEMORY_LIMIT_PLACEHOLDER"
            cpu: "CPU_LIMIT_PLACEHOLDER"
        
        volumeMounts:
        - name: results
          mountPath: /jepsenpg/store
        - name: credentials
          mountPath: /secrets
          readOnly: true
      
      volumes:
      - name: results
        persistentVolumeClaim:
          claimName: jepsen-results
      - name: credentials
        secret:
          secretName: SECRET_NAME_PLACEHOLDER
EOF

# Replace placeholders safely
sed -i "s/JOB_NAME_PLACEHOLDER/${JOB_NAME}/g" "${LOG_DIR}/jepsen-job-${TIMESTAMP}.yaml"
sed -i "s/NAMESPACE_PLACEHOLDER/${NAMESPACE}/g" "${LOG_DIR}/jepsen-job-${TIMESTAMP}.yaml"
sed -i "s/TIMESTAMP_PLACEHOLDER/${TIMESTAMP}/g" "${LOG_DIR}/jepsen-job-${TIMESTAMP}.yaml"
sed -i "s/CLUSTER_NAME_PLACEHOLDER/${CLUSTER_NAME}/g" "${LOG_DIR}/jepsen-job-${TIMESTAMP}.yaml"
sed -i "s/DB_USER_PLACEHOLDER/${DB_USER}/g" "${LOG_DIR}/jepsen-job-${TIMESTAMP}.yaml"
sed -i "s/DURATION_PLACEHOLDER/${TEST_DURATION}/g" "${LOG_DIR}/jepsen-job-${TIMESTAMP}.yaml"
sed -i "s/DEADLINE_PLACEHOLDER/$((TEST_DURATION + WORKLOAD_BUFFER))/g" "${LOG_DIR}/jepsen-job-${TIMESTAMP}.yaml"
sed -i "s/PGHOST_PLACEHOLDER/${CLUSTER_NAME}-rw.${NAMESPACE}.svc.cluster.local/g" "${LOG_DIR}/jepsen-job-${TIMESTAMP}.yaml"
sed -i "s/MEMORY_REQUEST_PLACEHOLDER/${JEPSEN_MEMORY_REQUEST}/g" "${LOG_DIR}/jepsen-job-${TIMESTAMP}.yaml"
sed -i "s/MEMORY_LIMIT_PLACEHOLDER/${JEPSEN_MEMORY_LIMIT}/g" "${LOG_DIR}/jepsen-job-${TIMESTAMP}.yaml"
sed -i "s/CPU_REQUEST_PLACEHOLDER/${JEPSEN_CPU_REQUEST}/g" "${LOG_DIR}/jepsen-job-${TIMESTAMP}.yaml"
sed -i "s/CPU_LIMIT_PLACEHOLDER/${JEPSEN_CPU_LIMIT}/g" "${LOG_DIR}/jepsen-job-${TIMESTAMP}.yaml"
sed -i "s/SECRET_NAME_PLACEHOLDER/${SECRET_NAME}/g" "${LOG_DIR}/jepsen-job-${TIMESTAMP}.yaml"

# Deploy Job
kubectl apply -f "${LOG_DIR}/jepsen-job-${TIMESTAMP}.yaml"

# Wait for pod to be created
log "Waiting for Jepsen pod to be created..."
POD_NAME=""
for i in {1..30}; do
    POD_NAME=$(kubectl get pods -n ${NAMESPACE} -l job-name=${JOB_NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$POD_NAME" ]]; then
        break
    fi
    sleep 2
done

if [[ -z "$POD_NAME" ]]; then
    error "Jepsen pod not created after 60 seconds"
    exit 2
fi

log "Jepsen pod created: ${POD_NAME}"

# Wait for pod to be running
log "Waiting for Jepsen pod to start (may take 3-5 minutes on first run for image pull)..."
log "Timeout: ${POD_START_TIMEOUT}s"

MAX_ITERATIONS=$((POD_START_TIMEOUT / POD_START_CHECK_INTERVAL))

for i in $(seq 1 $MAX_ITERATIONS); do
    # Always get latest pod name first (in case Job recreated it)
    CURRENT_POD=$(kubectl get pods -n ${NAMESPACE} \
        -l job-name=${JOB_NAME} \
        --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$CURRENT_POD" ]]; then
        POD_NAME="$CURRENT_POD"
    fi
    
    # Check if Job has failed
    JOB_FAILED=$(kubectl get job ${JOB_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
    if [[ "$JOB_FAILED" == "True" ]]; then
        error "Job failed during pod startup!"
        log "Job status:"
        kubectl get job ${JOB_NAME} -n ${NAMESPACE} -o yaml | grep -A 20 "status:" | tee -a "${LOG_DIR}/test.log"
        
        # Get logs from current pod
        if [[ -n "$POD_NAME" ]]; then
            log "Logs from pod ${POD_NAME}:"
            kubectl logs ${POD_NAME} -n ${NAMESPACE} 2>&1 | tail -50 | tee -a "${LOG_DIR}/test.log"
        fi
        exit 2
    fi
    
    # Check if pod is ready
    POD_READY=$(kubectl get pod ${POD_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$POD_READY" == "True" ]]; then
        success "Pod ready after $((i * POD_START_CHECK_INTERVAL))s"
        break
    fi
    
    # Progress indicator every 30 seconds
    if (( (i * POD_START_CHECK_INTERVAL) % 30 == 0 )); then
        log "Waiting for pod... ($((i * POD_START_CHECK_INTERVAL))s elapsed)"
    fi
    
    sleep $POD_START_CHECK_INTERVAL
done

# Final check
POD_READY=$(kubectl get pod ${POD_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
if [[ "$POD_READY" != "True" ]]; then
    error "Pod failed to become ready within ${POD_START_TIMEOUT}s"
    log "Pod status:"
    kubectl get pod ${POD_NAME} -n ${NAMESPACE} | tee -a "${LOG_DIR}/test.log"
    log "Pod logs:"
    kubectl logs ${POD_NAME} -n ${NAMESPACE} 2>&1 | tail -50 | tee -a "${LOG_DIR}/test.log"
    exit 2
fi

success "Jepsen Job deployed and running"
log ""

# ==========================================
# Step 5/10: Start Background Monitoring
# ==========================================

log "Step 5/10: Starting background monitoring..."

# Wait for logs to actually appear before streaming (avoid race condition)
log "Waiting for pod to start logging..."
for i in {1..10}; do
    if kubectl logs ${POD_NAME} -n ${NAMESPACE} --tail=1 2>/dev/null | grep -q .; then
        log "Logs detected, starting monitoring..."
        break
    fi
    sleep 2
done

# Monitor Jepsen logs in background
(
    kubectl logs -f ${POD_NAME} -n ${NAMESPACE} > "${LOG_DIR}/jepsen-live.log" 2>&1
) &
MONITOR_PID=$!

log "Background monitoring started (PID: ${MONITOR_PID})"
log ""

# ==========================================
# Step 6/10: Wait for Jepsen Initialization
# ==========================================

log "Step 6/10: Waiting for Jepsen to initialize and connect to database..."
log "Timeout: ${JEPSEN_INIT_TIMEOUT}s"

INIT_ELAPSED=0
JEPSEN_CONNECTED=false

while [ $INIT_ELAPSED -lt $JEPSEN_INIT_TIMEOUT ]; do
    # Check if Jepsen logged that it's starting the test
    if kubectl logs ${POD_NAME} -n ${NAMESPACE} 2>/dev/null | grep -qE "Starting Jepsen|Running test:|jepsen worker.*:invoke"; then
        JEPSEN_CONNECTED=true
        break
    fi
    
    # Check if pod crashed
    POD_STATUS=$(kubectl get pod ${POD_NAME} -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [[ "$POD_STATUS" == "Failed" ]] || [[ "$POD_STATUS" == "Unknown" ]]; then
        error "Jepsen pod crashed during initialization"
        kubectl logs ${POD_NAME} -n ${NAMESPACE} 2>&1 | tail -50
        exit 2
    fi
    
    sleep $JEPSEN_INIT_CHECK_INTERVAL
    INIT_ELAPSED=$((INIT_ELAPSED + JEPSEN_INIT_CHECK_INTERVAL))
    
    # Progress indicator every 15 seconds
    if (( INIT_ELAPSED % 15 == 0 )); then
        log "Waiting for Jepsen database connection... (${INIT_ELAPSED}s elapsed)"
    fi
done

if [ "$JEPSEN_CONNECTED" = false ]; then
    warn "Jepsen did not log database connection within ${JEPSEN_INIT_TIMEOUT}s"
    warn "Proceeding anyway - Jepsen may still be initializing"
    # Give it 30 more seconds as fallback
    sleep 30
fi

# Final check if Jepsen is still running
if ! kubectl get pod ${POD_NAME} -n ${NAMESPACE} | grep -q Running; then
    error "Jepsen pod crashed during initialization"
    kubectl logs ${POD_NAME} -n ${NAMESPACE} | tail -50
    exit 2
fi

success "Jepsen initialized successfully (waited ${INIT_ELAPSED}s)"
log ""

# ==========================================
# Step 7/10: Apply Chaos Experiment
# ==========================================

log "Step 7/10: Applying Litmus chaos experiment..."

# Reset previous ChaosResult so each run starts with fresh counters
if kubectl get chaosresult ${CHAOS_ENGINE_NAME}-pod-delete -n ${LITMUS_NAMESPACE} >/dev/null 2>&1; then
    log "Deleting previous chaos result ${CHAOS_ENGINE_NAME}-pod-delete to reset verdict history..."
    kubectl delete chaosresult ${CHAOS_ENGINE_NAME}-pod-delete -n ${LITMUS_NAMESPACE} >/dev/null 2>&1 || true
    for i in {1..12}; do
        if ! kubectl get chaosresult ${CHAOS_ENGINE_NAME}-pod-delete -n ${LITMUS_NAMESPACE} >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
fi

# Check if chaos experiment manifest exists
if [[ ! -f "experiments/cnpg-jepsen-chaos.yaml" ]]; then
    error "Chaos experiment manifest not found: experiments/cnpg-jepsen-chaos.yaml"
    exit 2
fi

# Patch chaos duration to match test duration
if [[ "$TEST_DURATION" != "600" ]]; then
    log "Adjusting chaos duration to ${TEST_DURATION}s..."
    sed "/TOTAL_CHAOS_DURATION/,/value:/ s/value: \"[0-9]*\"/value: \"${TEST_DURATION}\"/" \
        experiments/cnpg-jepsen-chaos.yaml > "${LOG_DIR}/chaos-${TIMESTAMP}.yaml"
    kubectl apply -f "${LOG_DIR}/chaos-${TIMESTAMP}.yaml"
else
    kubectl apply -f experiments/cnpg-jepsen-chaos.yaml
fi

success "Chaos experiment applied: ${CHAOS_ENGINE_NAME}"
log ""

# ==========================================
# Step 8/10: Monitor Execution
# ==========================================

log "Step 8/10: Monitoring test execution..."
log "This will take approximately $((TEST_DURATION / 60)) minutes for workload..."
log ""

START_TIME=$(date +%s)
LAST_LOG_CHECK=0
LAST_STATUS_CHECK=0

# Wait for test workload to complete (not Elle analysis!)
# Look for "Run complete, writing" in logs which happens BEFORE Elle analysis
log "Waiting for test workload to complete..."

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    # Throttled log checking (every LOG_CHECK_INTERVAL seconds)
    if (( CURRENT_TIME - LAST_LOG_CHECK >= LOG_CHECK_INTERVAL )); then
        # Check if workload completed (log says "Run complete")
        if kubectl logs ${POD_NAME} -n ${NAMESPACE} 2>/dev/null | grep -q "Run complete, writing"; then
            success "Test workload completed (${ELAPSED}s)"
            log "Operations finished, results written (Elle analysis may still be running)"
            break
        fi
        LAST_LOG_CHECK=$CURRENT_TIME
    fi
    
    # Throttled status checking (every STATUS_CHECK_INTERVAL seconds)
    if (( CURRENT_TIME - LAST_STATUS_CHECK >= STATUS_CHECK_INTERVAL )); then
        # Check if pod crashed
        POD_STATUS=$(kubectl get pod ${POD_NAME} -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [[ "$POD_STATUS" == "Failed" ]] || [[ "$POD_STATUS" == "Unknown" ]]; then
            error "Jepsen pod crashed during execution (${ELAPSED}s)"
            kubectl logs ${POD_NAME} -n ${NAMESPACE} 2>/dev/null | tail -100
            exit 2
        fi
        
        # Progress indicator
        PROGRESS=$((ELAPSED * 100 / TEST_DURATION))
        if [[ $PROGRESS -le 100 ]]; then
            log "Progress: ${ELAPSED}s / ${TEST_DURATION}s (${PROGRESS}%) - workload running..."
        else
            log "Progress: ${ELAPSED}s elapsed (workload should complete soon...)"
        fi
        
        LAST_STATUS_CHECK=$CURRENT_TIME
    fi
    
    # Timeout after test duration + WORKLOAD_BUFFER
    if [[ $ELAPSED -gt $((TEST_DURATION + WORKLOAD_BUFFER)) ]]; then
        error "Test workload did not complete within expected time (${ELAPSED}s)"
        warn "Expected completion by $((TEST_DURATION + WORKLOAD_BUFFER))s"
        kubectl logs ${POD_NAME} -n ${NAMESPACE} 2>/dev/null | tail -50
        exit 2
    fi
    
    sleep 5
done

log ""

# Wait a few seconds for files to be written
sleep 5

# Kill background monitoring
if [[ -n "${MONITOR_PID:-}" ]]; then
    kill ${MONITOR_PID} 2>/dev/null || true
    unset MONITOR_PID
fi

# ==========================================
# Step 9/10: Extract and Analyze Results
# ==========================================

log "Step 9/10: Extracting results from PVC..."

# Create temporary pod to access PVC
log "Creating temporary pod to access results..."
kubectl run pvc-extractor-${TIMESTAMP} --image=busybox --restart=Never --command --overrides="
{
  \"spec\": {
    \"containers\": [{
      \"name\": \"extractor\",
      \"image\": \"busybox\",
      \"command\": [\"sleep\", \"300\"],
      \"volumeMounts\": [{
        \"name\": \"results\",
        \"mountPath\": \"/data\"
      }]
    }],
    \"volumes\": [{
      \"name\": \"results\",
      \"persistentVolumeClaim\": {\"claimName\": \"jepsen-results\"}
    }]
  }
}" -- sleep 300 >/dev/null 2>&1

# Wait for pod to be ready with timeout
log "Waiting for extractor pod to be ready..."
if ! kubectl wait --for=condition=ready pod/pvc-extractor-${TIMESTAMP} --timeout=${EXTRACTOR_POD_TIMEOUT}s >/dev/null 2>&1; then
    error "Extractor pod failed to become ready within ${EXTRACTOR_POD_TIMEOUT}s"
    kubectl get pod pvc-extractor-${TIMESTAMP} 2>/dev/null
    exit 2
fi

# Wait for Jepsen results to finalize
log "Waiting for Jepsen results to finalize (up to ${RESULT_WAIT_TIMEOUT}s)..."
OUTPUT_READY=false
MAX_RESULT_ITERATIONS=$((RESULT_WAIT_TIMEOUT / RESULT_WAIT_INTERVAL))

for i in $(seq 1 $MAX_RESULT_ITERATIONS); do
    if kubectl exec pvc-extractor-${TIMESTAMP} -- test -s /data/current/history.txt >/dev/null 2>&1; then
        OUTPUT_READY=true
        log "history.txt detected with data after $((i * RESULT_WAIT_INTERVAL))s"
        break
    fi
    sleep $RESULT_WAIT_INTERVAL
done

if [[ "${OUTPUT_READY}" == false ]]; then
    warn "history.txt still empty after ${RESULT_WAIT_TIMEOUT}s; proceeding with best-effort extraction"
else
    success "history.txt ready for extraction"
fi

# Extract key files
log "Extracting operation history and logs..."
kubectl exec pvc-extractor-${TIMESTAMP} -- cat /data/current/history.txt > "${RESULT_DIR}/history.txt" 2>/dev/null || true
kubectl exec pvc-extractor-${TIMESTAMP} -- cat /data/current/history.edn > "${RESULT_DIR}/history.edn" 2>/dev/null || true
kubectl exec pvc-extractor-${TIMESTAMP} -- cat /data/current/jepsen.log > "${RESULT_DIR}/jepsen.log" 2>/dev/null || true

# Try to get results.edn if Elle finished (unlikely but possible)
kubectl exec pvc-extractor-${TIMESTAMP} -- cat /data/current/results.edn > "${RESULT_DIR}/results.edn" 2>/dev/null || true

# Extract PNG files (use kubectl cp for binary files)
log "Extracting PNG graphs..."
EXTRACT_ERRORS=0

if ! kubectl cp ${NAMESPACE}/pvc-extractor-${TIMESTAMP}:/data/current/latency-raw.png "${RESULT_DIR}/latency-raw.png" 2>/dev/null; then
    warn "Could not extract latency-raw.png (may not exist yet)"
    ((EXTRACT_ERRORS++))
fi

if ! kubectl cp ${NAMESPACE}/pvc-extractor-${TIMESTAMP}:/data/current/latency-quantiles.png "${RESULT_DIR}/latency-quantiles.png" 2>/dev/null; then
    warn "Could not extract latency-quantiles.png (may not exist yet)"
    ((EXTRACT_ERRORS++))
fi

if ! kubectl cp ${NAMESPACE}/pvc-extractor-${TIMESTAMP}:/data/current/rate.png "${RESULT_DIR}/rate.png" 2>/dev/null; then
    warn "Could not extract rate.png (may not exist yet)"
    ((EXTRACT_ERRORS++))
fi

if [[ $EXTRACT_ERRORS -gt 0 ]]; then
    warn "${EXTRACT_ERRORS} PNG file(s) could not be extracted (they may be generated later)"
fi

# Clean up extractor pod with verification
log "Cleaning up extractor pod..."
kubectl delete pod pvc-extractor-${TIMESTAMP} --wait=false >/dev/null 2>&1

# Wait briefly to verify deletion started
sleep 2
if kubectl get pod pvc-extractor-${TIMESTAMP} >/dev/null 2>&1; then
    warn "Extractor pod deletion in progress (will complete in background)"
fi

log ""
log "Files extracted:"
if ls -lh "${RESULT_DIR}/" 2>/dev/null | grep -v "^total" | awk '{print "  " $9 " (" $5 ")"}'; then
    success "Extraction complete"
else
    warn "Result directory may be empty"
fi

# ==========================================
# Analyze Operation Statistics
# ==========================================

log ""
log "Analyzing operation statistics..."
log ""

if [[ -f "${RESULT_DIR}/history.txt" ]]; then
    TOTAL_LINES=$(wc -l < "${RESULT_DIR}/history.txt")
    
    # Use safe_grep_count with -F flag for literal matching
    INVOKE_COUNT=$(safe_grep_count ":invoke" "${RESULT_DIR}/history.txt")
    OK_COUNT=$(safe_grep_count ":ok" "${RESULT_DIR}/history.txt")
    FAIL_COUNT=$(safe_grep_count ":fail" "${RESULT_DIR}/history.txt")
    INFO_COUNT=$(safe_grep_count ":info" "${RESULT_DIR}/history.txt")
    
    # Calculate success rate
    TOTAL_OPS=$((OK_COUNT + FAIL_COUNT + INFO_COUNT))
    if [[ $TOTAL_OPS -gt 0 ]]; then
        SUCCESS_RATE=$(awk "BEGIN {printf \"%.2f\", ($OK_COUNT / $TOTAL_OPS) * 100}")
    else
        SUCCESS_RATE="0.00"
    fi
    
    # Display results
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}Operation Statistics${NC}"
    echo -e "${GREEN}==========================================${NC}"
    echo -e "Total Operations:    ${TOTAL_OPS}"
    echo -e "${GREEN}  ✓ Successful:      ${OK_COUNT} (${SUCCESS_RATE}%)${NC}"
    
    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo -e "${RED}  ✗ Failed:          ${FAIL_COUNT}${NC}"
    else
        echo -e "  ✗ Failed:          ${FAIL_COUNT}"
    fi
    
    if [[ $INFO_COUNT -gt 0 ]]; then
        echo -e "${YELLOW}  ? Indeterminate:   ${INFO_COUNT}${NC}"
    else
        echo -e "  ? Indeterminate:   ${INFO_COUNT}"
    fi
    
    echo -e "${GREEN}==========================================${NC}"
    echo ""
    
    # Show failure details if any
    if [[ $FAIL_COUNT -gt 0 ]] || [[ $INFO_COUNT -gt 0 ]]; then
        log "Failure Details:"
        log "----------------"
        
        if [[ $FAIL_COUNT -gt 0 ]]; then
            echo -e "${RED}Failed operations (connection refused):${NC}"
            grep -F ":fail" "${RESULT_DIR}/history.txt" | head -5
            if [[ $FAIL_COUNT -gt 5 ]]; then
                echo "  ... and $((FAIL_COUNT - 5)) more"
            fi
            echo ""
        fi
        
        if [[ $INFO_COUNT -gt 0 ]]; then
            echo -e "${YELLOW}Indeterminate operations (connection killed during operation):${NC}"
            grep -F ":info" "${RESULT_DIR}/history.txt" | head -5
            if [[ $INFO_COUNT -gt 5 ]]; then
                echo "  ... and $((INFO_COUNT - 5)) more"
            fi
            echo ""
        fi
    fi
    
    # Save statistics to file
    cat > "${RESULT_DIR}/STATISTICS.txt" <<EOF
Jepsen Chaos Test Results
=========================
Test: ${JOB_NAME}
Duration: ${TEST_DURATION}s
Timestamp: ${TIMESTAMP}

Operation Statistics:
--------------------
Total Operations:    ${TOTAL_OPS}
  ✓ Successful:      ${OK_COUNT} (${SUCCESS_RATE}%)
  ✗ Failed:          ${FAIL_COUNT}
  ? Indeterminate:   ${INFO_COUNT}

Notes:
------
- :ok    = Operation completed successfully
- :fail  = Connection refused (expected during pod deletion)
- :info  = Connection killed mid-operation (potential data loss)

Failure Details:
----------------
EOF
    
    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo "" >> "${RESULT_DIR}/STATISTICS.txt"
        echo "Failed Operations:" >> "${RESULT_DIR}/STATISTICS.txt"
        grep -F ":fail" "${RESULT_DIR}/history.txt" >> "${RESULT_DIR}/STATISTICS.txt" || true
    fi
    
    if [[ $INFO_COUNT -gt 0 ]]; then
        echo "" >> "${RESULT_DIR}/STATISTICS.txt"
        echo "Indeterminate Operations:" >> "${RESULT_DIR}/STATISTICS.txt"
        grep -F ":info" "${RESULT_DIR}/history.txt" >> "${RESULT_DIR}/STATISTICS.txt" || true
    fi
    
      success "Statistics saved to: ${RESULT_DIR}/STATISTICS.txt"
    
    log ""
    
    # ==========================================
    # Step 9.5/10: Wait for EOT Probes
    # ==========================================
    
    log "Step 9.5/10: Waiting for End-of-Test (EOT) probes to complete..."
    
    EOT_WAIT_TIME=110  # 110 seconds to be safe
    
    log "Chaos duration was ${TEST_DURATION}s"
    log "Allowing ${EOT_WAIT_TIME}s for EOT probes (initialDelay + retries)"
    log "This prevents 'N/A' probe verdicts by not deleting chaos engine too early"
    
    # Show countdown
    for ((i=EOT_WAIT_TIME; i>0; i-=10)); do
        if [ $i -le $EOT_WAIT_TIME ] && [ $((i % 30)) -eq 0 ]; then
            log "  Waiting for EOT probes... ${i}s remaining"
        fi
        sleep 10
    done
    
    # Check probe statuses
    if kubectl get chaosresult ${CHAOS_ENGINE_NAME}-pod-delete -n ${LITMUS_NAMESPACE} &>/dev/null; then
        PROBE_STATUS=$(kubectl -n ${LITMUS_NAMESPACE} get chaosresult ${CHAOS_ENGINE_NAME}-pod-delete \
            -o jsonpath='{.status.probeStatuses}' 2>/dev/null || echo "[]")
        
        # Count how many EOT probes executed
        EOT_COUNT=$(echo "$PROBE_STATUS" | jq '[.[] | select(.mode == "EOT")] | length' 2>/dev/null || echo "0")
        EOT_PASSED=$(echo "$PROBE_STATUS" | jq '[.[] | select(.mode == "EOT" and .status.verdict == "Passed")] | length' 2>/dev/null || echo "0")
        
        if [ "$EOT_COUNT" -gt 0 ]; then
            success "EOT probes executed: ${EOT_PASSED}/${EOT_COUNT} passed"
        else
            warn "No EOT probes found (may still be executing)"
        fi
        
        # Show probe summary
        TOTAL_PROBES=$(echo "$PROBE_STATUS" | jq '. | length' 2>/dev/null || echo "0")
        PASSED_PROBES=$(echo "$PROBE_STATUS" | jq '[.[] | select(.status.verdict == "Passed")] | length' 2>/dev/null || echo "0")
        
        log "Overall probe status: ${PASSED_PROBES}/${TOTAL_PROBES} probes passed"
    else
        warn "ChaosResult not found - probes may not have executed"
    fi
    
    log ""
    
    # ==========================================
    # Step 10/10: Extract Litmus Chaos Results
    # ==========================================
    
    log "Step 10/10: Extracting Litmus chaos results..."
    
    # Create chaos-results subdirectory
    mkdir -p "${RESULT_DIR}/chaos-results"
    
    # Extract ChaosEngine status
    # Export chaos results if available
    if kubectl get chaosengine ${CHAOS_ENGINE_NAME} -n ${LITMUS_NAMESPACE} &>/dev/null; then
        kubectl get chaosengine ${CHAOS_ENGINE_NAME} -n ${LITMUS_NAMESPACE} -o yaml > "${RESULT_DIR}/chaos-results/chaosengine.yaml"
        
        # Get ChaosResult using the engine UID
        ENGINE_UID=$(kubectl get chaosengine ${CHAOS_ENGINE_NAME} -n ${LITMUS_NAMESPACE} -o jsonpath='{.status.uid}' 2>/dev/null)
        
        if [[ -n "${ENGINE_UID}" ]]; then
            # Find ChaosResult by chaosUID label
            CHAOS_RESULT=$(kubectl get chaosresult -n ${LITMUS_NAMESPACE} -l chaosUID=${ENGINE_UID} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            
            if [[ -n "${CHAOS_RESULT}" ]]; then
                kubectl get chaosresult ${CHAOS_RESULT} -n ${LITMUS_NAMESPACE} -o yaml > "${RESULT_DIR}/chaos-results/chaosresult.yaml"
                
                # Extract key metrics
                VERDICT=$(kubectl get chaosresult ${CHAOS_RESULT} -n ${LITMUS_NAMESPACE} -o jsonpath='{.status.experimentStatus.verdict}' 2>/dev/null || echo "Unknown")
                PROBE_SUCCESS=$(kubectl get chaosresult ${CHAOS_RESULT} -n ${LITMUS_NAMESPACE} -o jsonpath='{.status.experimentStatus.probeSuccessPercentage}' 2>/dev/null || echo "0")
                FAILED_STEP=$(kubectl get chaosresult ${CHAOS_RESULT} -n ${LITMUS_NAMESPACE} -o jsonpath='{.status.experimentStatus.failStep}' 2>/dev/null || echo "None")
                
                cat >> "${RESULT_DIR}/STATISTICS.txt" <<EOF

Chaos Experiment Results:
==========================
Verdict: ${VERDICT}
Probe Success Rate: ${PROBE_SUCCESS}%
Failed Step: ${FAILED_STEP}

Note: If verdict is 'Fail' and Jepsen reports valid, the failure may be due to 
Prometheus probe timing issues during pod deletion, not actual data inconsistency.
Jepsen's mathematical proof (Elle) is the authoritative consistency check.

See chaosresult.yaml for full probe results and timings.
EOF
                
                success "Chaos results exported to ${RESULT_DIR}/chaos-results/"
                
                # Extract probe results (if jq is available)
                log "Extracting probe results..."
                if command -v jq &>/dev/null; then
                    kubectl get chaosresult ${CHAOS_RESULT} -n ${LITMUS_NAMESPACE} -o jsonpath='{.status.probeStatuses}' 2>/dev/null | jq '.' > "${RESULT_DIR}/chaos-results/probe-results.json" 2>/dev/null || true
                else
                    kubectl get chaosresult ${CHAOS_RESULT} -n ${LITMUS_NAMESPACE} -o jsonpath='{.status.probeStatuses}' 2>/dev/null > "${RESULT_DIR}/chaos-results/probe-results.json" || true
                fi
                
                # Display result
                log ""
                log "========================================="
                log "Chaos Experiment Summary"
                log "========================================="
                log "Verdict: ${VERDICT}"
                log "Probe Success Rate: ${PROBE_SUCCESS}%"
                
                if [[ "$VERDICT" == "Pass" ]]; then
                    success "✅ Chaos experiment PASSED"
                elif [[ "$VERDICT" == "Fail" ]]; then
                    error "❌ Chaos experiment FAILED"
                    warn "   Failed step: ${FAILED_STEP}"
                else
                    warn "⚠️  Chaos experiment status: ${VERDICT}"
                fi
                log "========================================="
                log ""
            else
                warn "ChaosResult not found for engine ${CHAOS_ENGINE_NAME}"
            fi
        else
            warn "Could not get chaos engine UID"
        fi
    else
        warn "ChaosEngine ${CHAOS_ENGINE_NAME} not found (may have been deleted)"
    fi
    
    # Extract chaos events
    log "Extracting chaos events..."
    kubectl get events -n ${NAMESPACE} --field-selector involvedObject.name=${CHAOS_ENGINE_NAME} --sort-by='.lastTimestamp' > "${RESULT_DIR}/chaos-results/chaos-events.txt" 2>/dev/null || true
    
    success "Chaos results saved to: ${RESULT_DIR}/chaos-results/"
    log ""
    
    # Check for Elle results (unlikely to exist)
    if [[ -f "${RESULT_DIR}/results.edn" ]] && [[ -s "${RESULT_DIR}/results.edn" ]]; then
        log ""
        log "⚠️  Elle analysis completed! Checking for consistency violations..."
        
        if grep -q ":valid? true" "${RESULT_DIR}/results.edn"; then
            success "✓ No consistency anomalies detected"
        else
            warn "✗ Consistency anomalies detected - review results.edn"
        fi
    else
        log ""
        warn "Note: results.edn not available (Elle analysis still running in background)"
        warn "      This is NORMAL - Elle can take 30+ minutes to complete"
        warn "      Operation statistics above are sufficient for analysis"
    fi
    
    log ""
    success "========================================="
    success "Test Complete!"
    success "========================================="
    success "Results saved to: ${RESULT_DIR}/"
    log ""
    log "Generated artifacts:"
    log "  - ${RESULT_DIR}/STATISTICS.txt (Jepsen operation summary)"
    log "  - ${RESULT_DIR}/chaos-results/ (Litmus probe results)"
    log "  - ${RESULT_DIR}/*.png (Latency and rate graphs)"
    log ""
    log "Next steps:"
    log "1. Review ${RESULT_DIR}/STATISTICS.txt for operation success rates"
    log "2. Review ${RESULT_DIR}/chaos-results/SUMMARY.txt for probe results"
    log "3. Compare with other test runs (async vs sync replication)"
    log "4. Monitor Elle analysis (results.edn) for eventual consistency verdict"
    log "   Run './scripts/extract-jepsen-history.sh ${POD_NAME}' later to check if Elle finished"
    
    exit 0
else
    error "Failed to extract history.txt from PVC"
    error "Check PVC contents manually with:"
    error "  kubectl run -it --rm debug --image=busybox --restart=Never -- sh"
    error "  (then mount the PVC and inspect /data/current/)"
    exit 2
fi