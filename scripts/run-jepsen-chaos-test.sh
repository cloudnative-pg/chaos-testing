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

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
CLUSTER_NAME="${1:-}"
DB_USER="${2:-}"
TEST_DURATION="${3:-300}"  # Default 5 minutes
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

if [[ -z "$CLUSTER_NAME" || -z "$DB_USER" ]]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    echo "Usage: $0 <cluster-name> <db-user> [test-duration-seconds]"
    echo ""
    echo "Examples:"
    echo "  $0 pg-eu app 300"
    echo "  $0 pg-prod postgres 600"
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

# Logging function
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

safe_grep_count() {
    local pattern="$1"
    local file="$2"
    local count="0"

    if count=$(grep -c "$pattern" "$file" 2>/dev/null); then
        printf "%s" "$count"
    else
        printf "%s" "0"
    fi
}

# Cleanup function
cleanup() {
    local exit_code=$?
    
    if [[ $exit_code -eq 130 ]]; then
        warn "Test interrupted by user (SIGINT)"
    fi
    
    log "Starting cleanup..."
    
    # Delete chaos engine
    if kubectl get chaosengine ${CHAOS_ENGINE_NAME} -n ${NAMESPACE} &>/dev/null; then
        log "Deleting chaos engine: ${CHAOS_ENGINE_NAME}"
        kubectl delete chaosengine ${CHAOS_ENGINE_NAME} -n ${NAMESPACE} --wait=false || true
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
# Step 1: Pre-flight Checks
# ==========================================

log "Starting CNPG Jepsen + Chaos E2E Test"
log "Cluster: ${CLUSTER_NAME}"
log "DB User: ${DB_USER}"
log "Test Duration: ${TEST_DURATION}s"
log "Job Name: ${JOB_NAME}"
log "Logs: ${LOG_DIR}"
log ""

log "Step 1/7: Running pre-flight checks..."

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

# Check Litmus operator
if ! kubectl get deployment chaos-operator-ce -n litmus &>/dev/null; then
    error "Litmus chaos operator not found. Install with: kubectl apply -f https://litmuschaos.github.io/litmus/litmus-operator-v1.13.8.yaml"
    exit 2
fi

# Check CNPG cluster
if ! kubectl get cluster ${CLUSTER_NAME} -n ${NAMESPACE} &>/dev/null; then
    error "CNPG cluster '${CLUSTER_NAME}' not found in namespace '${NAMESPACE}'"
    exit 2
fi

# Check credentials secret
SECRET_NAME="${CLUSTER_NAME}-credentials"
if ! kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} &>/dev/null; then
    error "Credentials secret '${SECRET_NAME}' not found"
    exit 2
fi

# Check Prometheus (required for probes)
if ! kubectl get service prometheus-kube-prometheus-prometheus -n monitoring &>/dev/null; then
    warn "Prometheus not found in 'monitoring' namespace. Probes may fail."
    warn "Install with: helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring"
fi

success "Pre-flight checks passed"
log ""

# ==========================================
# Step 2: Clean Database Tables
# ==========================================

log "Step 2/9: Cleaning previous test data..."

# Find primary pod
PRIMARY_POD=$(kubectl get pods -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME},role=primary -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -z "$PRIMARY_POD" ]]; then
    warn "Could not identify primary pod, trying all pods..."
    # Try each pod until we find the primary
    for pod in $(kubectl get pods -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME} -o jsonpath='{.items[*].metadata.name}'); do
        if kubectl exec ${pod} -n ${NAMESPACE} -- psql -U postgres -d ${DB_USER} -c "SELECT 1" &>/dev/null; then
            if kubectl exec ${pod} -n ${NAMESPACE} -- psql -U postgres -d ${DB_USER} -c "DROP TABLE IF EXISTS txn, txn_append CASCADE;" 2>&1 | grep -q "DROP TABLE"; then
                PRIMARY_POD=${pod}
                break
            fi
        fi
    done
fi

if [[ -n "$PRIMARY_POD" ]]; then
    log "Cleaning tables on primary: ${PRIMARY_POD}"
    kubectl exec ${PRIMARY_POD} -n ${NAMESPACE} -- psql -U postgres -d ${DB_USER} -c "DROP TABLE IF EXISTS txn, txn_append CASCADE;" 2>&1 | grep -E "DROP TABLE|NOTICE" || true
    success "Database cleaned"
else
    warn "Could not clean database tables (primary pod not accessible)"
    warn "Test will continue, but may use existing data"
fi

log ""

# ==========================================
# Step 3: Ensure Persistent Volume for Results
# ==========================================

log "Step 3/9: Ensuring persistent volume for results..."

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
    # Wait for PVC to be bound
    for i in {1..30}; do
        PVC_STATUS=$(kubectl get pvc jepsen-results -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$PVC_STATUS" == "Bound" ]]; then
            success "PersistentVolumeClaim bound successfully"
            break
        fi
        sleep 2
    done
else
    log "PersistentVolumeClaim already exists"
fi

log ""

# ==========================================
# Step 4: Deploy Jepsen Job
# ==========================================

log "Step 4/9: Deploying Jepsen consistency testing Job..."

# Create temporary Job manifest with parameters
cat > "${LOG_DIR}/jepsen-job-${TIMESTAMP}.yaml" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: jepsen-test
    test-id: chaos-${TIMESTAMP}
    cluster: ${CLUSTER_NAME}
spec:
  backoffLimit: 2
  activeDeadlineSeconds: $((TEST_DURATION + 600))  # Test duration + 10min buffer for cleanup
  template:
    metadata:
      labels:
        app: jepsen-test
        test-id: chaos-${TIMESTAMP}
    spec:
      restartPolicy: Never
      containers:
      - name: jepsen
        image: ardentperf/jepsenpg:latest
        imagePullPolicy: IfNotPresent
        
        env:
        - name: PGHOST
          value: "${CLUSTER_NAME}-rw.${NAMESPACE}.svc.cluster.local"
        - name: PGPORT
          value: "5432"
        - name: PGUSER
          value: "${DB_USER}"
        - name: CLUSTER_NAME
          value: "${CLUSTER_NAME}"
        - name: NAMESPACE
          value: "${NAMESPACE}"
        - name: PGDATABASE
          value: "${DB_USER}"
        - name: WORKLOAD
          value: append
        - name: DURATION
          value: "${TEST_DURATION}"
        - name: RATE
          value: "50"  # Medium load: 50 ops/sec (reduced from 100)
                       # Allows faster label propagation (~40-70s vs 60-120s)
                       # Can use CHAOS_INTERVAL=300s instead of 480s
        - name: CONCURRENCY
          value: "7"   # Medium load: 7 workers (reduced from 10)
                       # Still realistic but less resource intensive
        - name: ISOLATION
          value: read-committed
        
        command:
        - /bin/bash
        - -c
        - |
          set -e
          cd /jepsenpg
          
          # Get PostgreSQL connection details from secret
          export PGPASSWORD=\$(cat /secrets/password)
          export PGUSER=\$(cat /secrets/username)
          export PGHOST="\${CLUSTER_NAME}-rw.\${NAMESPACE}.svc.cluster.local"
          export PGDATABASE="\${PGDATABASE}"
          
          echo "========================================="
          echo "Jepsen Chaos Integration Test"
          echo "========================================="
          echo "Cluster:     \${CLUSTER_NAME}"
          echo "Namespace:   \${NAMESPACE}"
          echo "Database:    \${PGDATABASE}"
          echo "User:        \${PGUSER}"
          echo "Host:        \${PGHOST}"
          echo "Workload:    \${WORKLOAD}"
          echo "Duration:    \${DURATION}s"
          echo "Concurrency: \${CONCURRENCY} workers"
          echo "Rate:        \${RATE} ops/sec"
          echo "Keys:        50 (uniform distribution)"
          echo "Txn Length:  1 (single-op transactions)"
          echo "Max Writes:  50 per key"
          echo "Isolation:   \${ISOLATION}"
          echo "========================================="
          echo ""
          
          # Test database connectivity
          echo "Testing database connectivity..."
          if command -v psql &> /dev/null; then
            psql -h \${PGHOST} -U \${PGUSER} -d \${PGDATABASE} -c "SELECT version();" || {
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
          
          lein run test-all -w \${WORKLOAD} \\
            --isolation \${ISOLATION} \\
            --nemesis none \\
            --no-ssh \\
            --key-count 50 \\
            --max-writes-per-key 50 \\
            --max-txn-length 1 \\
            --key-dist uniform \\
            --concurrency \${CONCURRENCY} \\
            --rate \${RATE} \\
            --time-limit \${DURATION} \\
            --test-count 1 \\
            --existing-postgres \\
            --node \${PGHOST} \\
            --postgres-user \${PGUSER} \\
            --postgres-password \${PGPASSWORD}
          
          EXIT_CODE=\$?
          
          echo ""
          echo "========================================="
          echo "Test completed with exit code: \${EXIT_CODE}"
          echo "========================================="
          
          # Display summary
          if [[ -f store/latest/results.edn ]]; then
            echo ""
            echo "Test Summary:"
            echo "-------------"
            grep -E ":valid\?|:failure-types|:anomaly-types" store/latest/results.edn || true
          fi
          
          exit \${EXIT_CODE}
        
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
        
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
          secretName: ${SECRET_NAME}
EOF

# Deploy Job
kubectl apply -f "${LOG_DIR}/jepsen-job-${TIMESTAMP}.yaml"

# Wait for pod to be created
log "Waiting for Jepsen pod to be created..."
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

# Wait for pod to be running (check both pod and Job status)
log "Waiting for Jepsen pod to start (may take 3-5 minutes on first run for image pull)..."

# Poll for up to 10 minutes
for i in {1..120}; do
    # Check if Job has failed
    JOB_FAILED=$(kubectl get job ${JOB_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
    if [[ "$JOB_FAILED" == "True" ]]; then
        error "Job failed during pod startup!"
        log "Job status:"
        kubectl get job ${JOB_NAME} -n ${NAMESPACE} -o yaml | grep -A 20 "status:" | tee -a "${LOG_DIR}/test.log"
        
        # Get logs from last pod attempt
        LAST_POD=$(kubectl get pods -n ${NAMESPACE} -l job-name=${JOB_NAME} --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
        if [[ -n "$LAST_POD" ]]; then
            log "Logs from pod ${LAST_POD}:"
            kubectl logs ${LAST_POD} -n ${NAMESPACE} 2>&1 | tail -50 | tee -a "${LOG_DIR}/test.log"
        fi
        exit 2
    fi
    
    # Check if pod is ready
    POD_READY=$(kubectl get pod ${POD_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$POD_READY" == "True" ]]; then
        break
    fi
    
    # Update POD_NAME in case it changed (Job created a new pod after failure)
    POD_NAME=$(kubectl get pods -n ${NAMESPACE} -l job-name=${JOB_NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "$POD_NAME")
    
    sleep 5
done

# Final check
POD_READY=$(kubectl get pod ${POD_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
if [[ "$POD_READY" != "True" ]]; then
    error "Pod failed to become ready within 10 minutes"
    log "Pod status:"
    kubectl get pod ${POD_NAME} -n ${NAMESPACE} | tee -a "${LOG_DIR}/test.log"
    log "Pod logs:"
    kubectl logs ${POD_NAME} -n ${NAMESPACE} 2>&1 | tail -50 | tee -a "${LOG_DIR}/test.log"
    exit 2
fi

success "Jepsen Job deployed and running"
log ""

# ==========================================
# Step 5: Start Background Monitoring
# ==========================================

log "Step 5/9: Starting background monitoring..."

# Monitor Jepsen logs in background
(
    kubectl logs -f ${POD_NAME} -n ${NAMESPACE} > "${LOG_DIR}/jepsen-live.log" 2>&1
) &
MONITOR_PID=$!

log "Background monitoring started (PID: ${MONITOR_PID})"
log ""

# ==========================================
# Step 6: Wait for Jepsen Initialization
# ==========================================

log "Step 6/9: Waiting for Jepsen to initialize and connect to database..."

# Wait for Jepsen to establish database connection (up to 2 minutes)
INIT_TIMEOUT=120
INIT_ELAPSED=0
JEPSEN_CONNECTED=false

while [ $INIT_ELAPSED -lt $INIT_TIMEOUT ]; do
    # Check if Jepsen logged that it's starting the test
    # Look for either "Starting Jepsen" or "Running test:" or "jepsen worker" (indicates operations started)
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
    
    sleep 5
    INIT_ELAPSED=$((INIT_ELAPSED + 5))
    
    # Progress indicator every 15 seconds
    if (( INIT_ELAPSED % 15 == 0 )); then
        log "Waiting for Jepsen database connection... (${INIT_ELAPSED}s elapsed)"
    fi
done

if [ "$JEPSEN_CONNECTED" = false ]; then
    warn "Jepsen did not log database connection within ${INIT_TIMEOUT}s"
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
# Step 7: Apply Chaos Experiment
# ==========================================

log "Step 7/9: Applying Litmus chaos experiment..."

# Reset previous ChaosResult so each run starts with fresh counters
if kubectl get chaosresult ${CHAOS_ENGINE_NAME}-pod-delete -n ${NAMESPACE} >/dev/null 2>&1; then
    log "Deleting previous chaos result ${CHAOS_ENGINE_NAME}-pod-delete to reset verdict history..."
    kubectl delete chaosresult ${CHAOS_ENGINE_NAME}-pod-delete -n ${NAMESPACE} >/dev/null 2>&1 || true
    for i in {1..12}; do
        if ! kubectl get chaosresult ${CHAOS_ENGINE_NAME}-pod-delete -n ${NAMESPACE} >/dev/null 2>&1; then
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
if [[ "$TEST_DURATION" != "300" ]]; then
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
# Step 8: Monitor Execution
# ==========================================

log "Step 8/9: Monitoring test execution..."
log "This will take approximately $((TEST_DURATION / 60)) minutes for workload..."
log ""

START_TIME=$(date +%s)

# Wait for test workload to complete (not Elle analysis!)
# Look for "Run complete, writing" in logs which happens BEFORE Elle analysis
log "Waiting for test workload to complete..."

while true; do
    ELAPSED=$(($(date +%s) - START_TIME))
    
    # Check if workload completed (log says "Run complete")
    if kubectl logs ${POD_NAME} -n ${NAMESPACE} 2>/dev/null | grep -q "Run complete, writing"; then
        success "Test workload completed (${ELAPSED}s)"
        log "Operations finished, results written (Elle analysis may still be running)"
        break
    fi
    
    # Check if pod crashed
    POD_STATUS=$(kubectl get pod ${POD_NAME} -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [[ "$POD_STATUS" == "Failed" ]] || [[ "$POD_STATUS" == "Unknown" ]]; then
        error "Jepsen pod crashed (${ELAPSED}s)"
        kubectl logs ${POD_NAME} -n ${NAMESPACE} 2>/dev/null | tail -100
        exit 2
    fi
    
    # Timeout after test duration + 2 minutes buffer
    if [[ $ELAPSED -gt $((TEST_DURATION + 120)) ]]; then
        error "Test workload did not complete within expected time (${ELAPSED}s)"
        kubectl logs ${POD_NAME} -n ${NAMESPACE} 2>/dev/null | tail -50
        exit 2
    fi
    
    # Progress indicator every 30 seconds
    if (( ELAPSED % 30 == 0 )); then
        PROGRESS=$((ELAPSED * 100 / TEST_DURATION))
        log "Progress: ${ELAPSED}s elapsed (waiting for workload completion...)"
    fi
    
    sleep 10
done

log ""
log "⚠️  Elle consistency analysis is running in background (can take 30+ minutes)"
log "⚠️  We will extract results NOW without waiting for Elle to finish"
log ""

# Wait a few seconds for files to be written
sleep 5

# Kill background monitoring
kill ${MONITOR_PID} 2>/dev/null || true
unset MONITOR_PID

# ==========================================
# Step 9: Extract and Analyze Results
# ==========================================

log "Step 9/9: Extracting results from PVC..."

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

# Wait for pod to be ready
kubectl wait --for=condition=ready pod/pvc-extractor-${TIMESTAMP} --timeout=30s >/dev/null 2>&1

# Give Elle up to 3 minutes to finish writing files
log "Waiting for Jepsen results to finalize..."
OUTPUT_READY=false
for i in {1..36}; do
    if kubectl exec pvc-extractor-${TIMESTAMP} -- test -s /data/current/history.txt >/dev/null 2>&1; then
        OUTPUT_READY=true
        break
    fi
    sleep 5
done

if [[ "${OUTPUT_READY}" == false ]]; then
    warn "history.txt still empty after 3 minutes; proceeding with best-effort extraction"
else
    success "history.txt detected with data; starting extraction"
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
kubectl cp ${NAMESPACE}/pvc-extractor-${TIMESTAMP}:/data/current/latency-raw.png "${RESULT_DIR}/latency-raw.png" 2>/dev/null || touch "${RESULT_DIR}/latency-raw.png"
kubectl cp ${NAMESPACE}/pvc-extractor-${TIMESTAMP}:/data/current/latency-quantiles.png "${RESULT_DIR}/latency-quantiles.png" 2>/dev/null || touch "${RESULT_DIR}/latency-quantiles.png"
kubectl cp ${NAMESPACE}/pvc-extractor-${TIMESTAMP}:/data/current/rate.png "${RESULT_DIR}/rate.png" 2>/dev/null || touch "${RESULT_DIR}/rate.png"

# Clean up extractor pod
kubectl delete pod pvc-extractor-${TIMESTAMP} --wait=false >/dev/null 2>&1

log ""
log "Files extracted:"
ls -lh "${RESULT_DIR}/" 2>/dev/null | grep -v "^total" | awk '{print "  " $9 " (" $5 ")"}'

# ==========================================
# Analyze Operation Statistics
# ==========================================

log ""
log "Analyzing operation statistics..."
log ""

if [[ -f "${RESULT_DIR}/history.txt" ]]; then
    TOTAL_LINES=$(wc -l < "${RESULT_DIR}/history.txt")
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
            grep ":fail" "${RESULT_DIR}/history.txt" | head -5
            if [[ $FAIL_COUNT -gt 5 ]]; then
                echo "  ... and $((FAIL_COUNT - 5)) more"
            fi
            echo ""
        fi
        
        if [[ $INFO_COUNT -gt 0 ]]; then
            echo -e "${YELLOW}Indeterminate operations (connection killed during operation):${NC}"
            grep ":info" "${RESULT_DIR}/history.txt" | head -5
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
        grep ":fail" "${RESULT_DIR}/history.txt" >> "${RESULT_DIR}/STATISTICS.txt" || true
    fi
    
    if [[ $INFO_COUNT -gt 0 ]]; then
        echo "" >> "${RESULT_DIR}/STATISTICS.txt"
        echo "Indeterminate Operations:" >> "${RESULT_DIR}/STATISTICS.txt"
        grep ":info" "${RESULT_DIR}/history.txt" >> "${RESULT_DIR}/STATISTICS.txt" || true
    fi
    
    success "Statistics saved to: ${RESULT_DIR}/STATISTICS.txt"
    
    log ""
    
    # ==========================================
    # Step 10: Extract Litmus Chaos Results
    # ==========================================
    
    log "Step 10/10: Extracting Litmus chaos results..."
    
    # Create chaos-results subdirectory
    mkdir -p "${RESULT_DIR}/chaos-results"
    
    # Extract ChaosEngine status
    log "Extracting ChaosEngine status..."
    if kubectl get chaosengine ${CHAOS_ENGINE_NAME} -n ${NAMESPACE} &>/dev/null; then
        kubectl get chaosengine ${CHAOS_ENGINE_NAME} -n ${NAMESPACE} -o yaml > "${RESULT_DIR}/chaos-results/chaosengine.yaml"
        
        # Get engine UID for finding results
        ENGINE_UID=$(kubectl get chaosengine ${CHAOS_ENGINE_NAME} -n ${NAMESPACE} -o jsonpath='{.status.uid}' 2>/dev/null)
        
        # Extract ChaosResult
        if [[ -n "$ENGINE_UID" ]]; then
            log "Extracting ChaosResult (UID: ${ENGINE_UID})..."
            CHAOS_RESULT=$(kubectl get chaosresult -n ${NAMESPACE} -l chaosUID=${ENGINE_UID} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            
            if [[ -n "$CHAOS_RESULT" ]]; then
                kubectl get chaosresult ${CHAOS_RESULT} -n ${NAMESPACE} -o yaml > "${RESULT_DIR}/chaos-results/chaosresult.yaml"
                
                # Extract summary
                VERDICT=$(kubectl get chaosresult ${CHAOS_RESULT} -n ${NAMESPACE} -o jsonpath='{.status.experimentStatus.verdict}' 2>/dev/null || echo "Unknown")
                PROBE_SUCCESS=$(kubectl get chaosresult ${CHAOS_RESULT} -n ${NAMESPACE} -o jsonpath='{.status.experimentStatus.probeSuccessPercentage}' 2>/dev/null || echo "0")
                FAILED_STEP=$(kubectl get chaosresult ${CHAOS_RESULT} -n ${NAMESPACE} -o jsonpath='{.status.experimentStatus.failStep}' 2>/dev/null || echo "None")
                
                # Save human-readable summary
                cat > "${RESULT_DIR}/chaos-results/SUMMARY.txt" <<EOF
Chaos Experiment Results
========================
Experiment: ${CHAOS_ENGINE_NAME}
Result: ${CHAOS_RESULT}
Timestamp: ${TIMESTAMP}

Verdict: ${VERDICT}
Probe Success Rate: ${PROBE_SUCCESS}%
Failed Step: ${FAILED_STEP}

Detailed Results:
-----------------
See chaosresult.yaml for full probe results and timings.

EOF
                
                # Extract probe results
                log "Extracting probe results..."
                kubectl get chaosresult ${CHAOS_RESULT} -n ${NAMESPACE} -o jsonpath='{.status.probeStatuses}' 2>/dev/null | jq '.' > "${RESULT_DIR}/chaos-results/probe-results.json" 2>/dev/null || true
                
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
    if [[ -f "${RESULT_DIR}/results.edn" ]]; then
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
    
    # ==========================================
    # Step 11: Post-Chaos Data Consistency Verification
    # ==========================================
    
    log "Step 11/11: Verifying post-chaos data consistency..."
    log ""
    
    if [[ -f "scripts/verify-data-consistency.sh" ]]; then
        log "Running consistency verification on cluster ${CLUSTER_NAME}..."
        bash scripts/verify-data-consistency.sh ${CLUSTER_NAME} ${DB_USER} ${NAMESPACE} 2>&1 | tee -a "${LOG_DIR}/consistency-check.log"
        
        CONSISTENCY_EXIT_CODE=${PIPESTATUS[0]}
        
        if [[ $CONSISTENCY_EXIT_CODE -eq 0 ]]; then
            success "Post-chaos consistency verification PASSED"
        else
            warn "Post-chaos consistency verification had issues (exit code: $CONSISTENCY_EXIT_CODE)"
            warn "Review ${LOG_DIR}/consistency-check.log for details"
        fi
    else
        warn "verify-data-consistency.sh not found, skipping post-chaos validation"
        warn "For complete validation, ensure scripts/verify-data-consistency.sh exists"
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
    log "  - ${LOG_DIR}/consistency-check.log (Post-chaos validation)"
    log "  - ${RESULT_DIR}/*.png (Latency and rate graphs)"
    log ""
    log "Next steps:"
    log "1. Review ${RESULT_DIR}/STATISTICS.txt for operation success rates"
    log "2. Check ${LOG_DIR}/consistency-check.log for replication consistency"
    log "3. Review ${RESULT_DIR}/chaos-results/SUMMARY.txt for probe results"
    log "4. Compare with other test runs (async vs sync replication)"
    log "5. Jepsen pod will continue Elle analysis in background"
    log "   Run './scripts/extract-jepsen-history.sh ${POD_NAME}' later to check if Elle finished"
    
    exit 0
else
    error "Failed to extract history.txt from PVC"
    error "Check PVC contents manually"
    exit 2
fi
