#!/bin/bash
# Complete Chaos Testing Setup and Execution Guide
# This script will guide you through running a chaos experiment from start to finish

set -e

echo "================================================================"
echo "    CNPG Chaos Testing - Complete Setup & Execution"
echo "================================================================"
echo ""

# Configuration
CLUSTER_NAME="pg-eu"
DATABASE="app"
NAMESPACE="default"
SCALE_FACTOR=50  # Adjust based on your needs (50 = ~5M rows)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Step 1: Environment Check
echo ""
echo "================================================================"
echo "STEP 1: Environment Check"
echo "================================================================"
log_info "Checking prerequisites..."

# Check CNPG cluster
log_info "Checking CNPG cluster..."
if kubectl get cluster $CLUSTER_NAME -n $NAMESPACE &>/dev/null; then
    STATUS=$(kubectl get cluster $CLUSTER_NAME -n $NAMESPACE -o jsonpath='{.status.phase}')
    PRIMARY=$(kubectl get cluster $CLUSTER_NAME -n $NAMESPACE -o jsonpath='{.status.currentPrimary}')
    INSTANCES=$(kubectl get cluster $CLUSTER_NAME -n $NAMESPACE -o jsonpath='{.status.instances}')
    log_success "Cluster '$CLUSTER_NAME' found"
    echo "  Status: $STATUS"
    echo "  Primary: $PRIMARY"
    echo "  Instances: $INSTANCES"
else
    log_error "Cluster '$CLUSTER_NAME' not found!"
    exit 1
fi

# Check pods
log_info "Checking CNPG pods..."
READY_PODS=$(kubectl get pods -l cnpg.io/cluster=$CLUSTER_NAME -n $NAMESPACE --no-headers | grep "1/1" | wc -l)
TOTAL_PODS=$(kubectl get pods -l cnpg.io/cluster=$CLUSTER_NAME -n $NAMESPACE --no-headers | wc -l)
if [ "$READY_PODS" -eq "$TOTAL_PODS" ] && [ "$READY_PODS" -gt 0 ]; then
    log_success "All $READY_PODS pods are ready"
    kubectl get pods -l cnpg.io/cluster=$CLUSTER_NAME -n $NAMESPACE
else
    log_warning "$READY_PODS/$TOTAL_PODS pods are ready"
    kubectl get pods -l cnpg.io/cluster=$CLUSTER_NAME -n $NAMESPACE
fi

# Check secret
log_info "Checking database credentials..."
if kubectl get secret ${CLUSTER_NAME}-credentials -n $NAMESPACE &>/dev/null; then
    log_success "Secret '${CLUSTER_NAME}-credentials' found"
else
    log_error "Secret '${CLUSTER_NAME}-credentials' not found!"
    exit 1
fi

# Check Litmus
log_info "Checking Litmus Chaos..."
if kubectl get crd chaosengines.litmuschaos.io &>/dev/null; then
    log_success "Litmus CRDs installed"
else
    log_error "Litmus CRDs not found! Please install Litmus first."
    exit 1
fi

if kubectl get sa litmus-admin -n $NAMESPACE &>/dev/null; then
    log_success "Litmus service account found"
else
    log_warning "Litmus service account 'litmus-admin' not found in $NAMESPACE"
    log_info "You may need to create it or adjust the experiment YAML"
fi

# Check Prometheus
log_info "Checking Prometheus..."
if kubectl get prometheus -A &>/dev/null; then
    PROM_NS=$(kubectl get prometheus -A -o jsonpath='{.items[0].metadata.namespace}')
    PROM_NAME=$(kubectl get prometheus -A -o jsonpath='{.items[0].metadata.name}')
    log_success "Prometheus found in namespace '$PROM_NS'"
    echo "  Name: $PROM_NAME"
else
    log_warning "Prometheus not found - promProbes will not work"
fi

echo ""
read -p "Environment check complete. Continue with test data initialization? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Stopped by user"
    exit 0
fi

# Step 2: Check/Initialize Test Data
echo ""
echo "================================================================"
echo "STEP 2: Test Data Initialization"
echo "================================================================"

log_info "Checking if test data already exists..."
PRIMARY_POD=$(kubectl get pods -l cnpg.io/cluster=$CLUSTER_NAME,cnpg.io/instanceRole=primary \
    -n $NAMESPACE -o jsonpath='{.items[0].metadata.name}')

if [ -z "$PRIMARY_POD" ]; then
    log_error "Could not find primary pod!"
    exit 1
fi

log_info "Using primary pod: $PRIMARY_POD"

# Check if pgbench tables exist
TABLE_COUNT=$(timeout 10 kubectl exec -n $NAMESPACE $PRIMARY_POD -- \
    psql -U postgres -d $DATABASE -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_name LIKE 'pgbench_%';" 2>&1 | \
    grep -E '^[0-9]+$' | head -1 || echo "0")

if [ "$TABLE_COUNT" -ge 4 ]; then
    ACCOUNT_COUNT=$(timeout 10 kubectl exec -n $NAMESPACE $PRIMARY_POD -- \
        psql -U postgres -d $DATABASE -tAc \
        "SELECT count(*) FROM pgbench_accounts;" 2>&1 | \
        grep -E '^[0-9]+$' | head -1 || echo "0")
    
    log_success "Test data already exists!"
    echo "  Tables found: $TABLE_COUNT"
    echo "  Rows in pgbench_accounts: $ACCOUNT_COUNT"
    echo ""
    read -p "Skip initialization and use existing data? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        log_info "Using existing test data"
    else
        log_warning "Re-initializing will DROP existing data!"
        read -p "Are you sure? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            ./scripts/init-pgbench-testdata.sh $CLUSTER_NAME $DATABASE $SCALE_FACTOR
        else
            log_info "Keeping existing data"
        fi
    fi
else
    log_info "No test data found. Initializing pgbench tables..."
    ./scripts/init-pgbench-testdata.sh $CLUSTER_NAME $DATABASE $SCALE_FACTOR
fi

# Verify test data
echo ""
log_info "Verifying test data..."
FINAL_COUNT=$(timeout 10 kubectl exec -n $NAMESPACE $PRIMARY_POD -- \
    psql -U postgres -d $DATABASE -tAc \
    "SELECT count(*) FROM pgbench_accounts;" 2>&1 | \
    grep -E '^[0-9]+$' | head -1 || echo "0")

if [ "$FINAL_COUNT" -gt 1000 ]; then
    log_success "Test data verified: $FINAL_COUNT rows in pgbench_accounts"
else
    log_error "Test data verification failed!"
    exit 1
fi

# Step 3: Choose Experiment
echo ""
echo "================================================================"
echo "STEP 3: Select Chaos Experiment"
echo "================================================================"
echo ""
echo "Available experiments:"
echo "  1) cnpg-primary-pod-delete.yaml      - Delete primary pod (tests failover)"
echo "  2) cnpg-replica-pod-delete.yaml      - Delete replica pod (tests resilience)"
echo "  3) cnpg-random-pod-delete.yaml       - Delete random pod"
echo "  4) cnpg-primary-with-workload.yaml   - Primary delete with active workload (FULL E2E)"
echo ""
read -p "Select experiment [1-4]: " EXPERIMENT_CHOICE

case $EXPERIMENT_CHOICE in
    1)
        EXPERIMENT_FILE="experiments/cnpg-primary-pod-delete.yaml"
        EXPERIMENT_NAME="cnpg-primary-pod-delete"
        log_info "Selected: Primary Pod Delete"
        ;;
    2)
        EXPERIMENT_FILE="experiments/cnpg-replica-pod-delete.yaml"
        EXPERIMENT_NAME="cnpg-replica-pod-delete-v2"
        log_info "Selected: Replica Pod Delete"
        ;;
    3)
        EXPERIMENT_FILE="experiments/cnpg-random-pod-delete.yaml"
        EXPERIMENT_NAME="cnpg-random-pod-delete"
        log_info "Selected: Random Pod Delete"
        ;;
    4)
        EXPERIMENT_FILE="experiments/cnpg-primary-with-workload.yaml"
        EXPERIMENT_NAME="cnpg-primary-workload-test"
        log_info "Selected: Primary Delete with Workload (Full E2E)"
        ;;
    *)
        log_error "Invalid selection"
        exit 1
        ;;
esac

if [ ! -f "$EXPERIMENT_FILE" ]; then
    log_error "Experiment file not found: $EXPERIMENT_FILE"
    exit 1
fi

# Step 4: Clean up old experiments
echo ""
echo "================================================================"
echo "STEP 4: Clean Up Old Experiments"
echo "================================================================"

log_info "Checking for existing chaos engines..."
EXISTING_ENGINES=$(kubectl get chaosengine -n $NAMESPACE --no-headers 2>/dev/null | wc -l)

if [ "$EXISTING_ENGINES" -gt 0 ]; then
    log_warning "Found $EXISTING_ENGINES existing chaos engine(s)"
    kubectl get chaosengine -n $NAMESPACE
    echo ""
    read -p "Delete all existing chaos engines? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Deleting existing chaos engines..."
        kubectl delete chaosengine --all -n $NAMESPACE
        sleep 5
        log_success "Cleanup complete"
    fi
fi

# Step 5: Review Experiment Configuration
echo ""
echo "================================================================"
echo "STEP 5: Review Experiment Configuration"
echo "================================================================"

log_info "Experiment file: $EXPERIMENT_FILE"
echo ""
echo "Key settings:"
kubectl get -f $EXPERIMENT_FILE -o yaml 2>/dev/null | grep -A 3 "TOTAL_CHAOS_DURATION\|CHAOS_INTERVAL\|FORCE" || \
    (log_warning "Could not extract settings from YAML" && cat $EXPERIMENT_FILE | grep -A 1 "TOTAL_CHAOS_DURATION\|CHAOS_INTERVAL\|FORCE")

echo ""
read -p "Proceed with chaos experiment? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Stopped by user"
    exit 0
fi

# Step 6: Run Chaos Experiment
echo ""
echo "================================================================"
echo "STEP 6: Execute Chaos Experiment"
echo "================================================================"

log_info "Applying chaos experiment..."
kubectl apply -f $EXPERIMENT_FILE

log_success "Chaos engine created!"
echo ""

# Monitor the experiment
log_info "Monitoring chaos experiment (press Ctrl+C to stop watching)..."
echo ""
sleep 3

# Watch chaos engine status
echo "Waiting for experiment to start..."
sleep 5

log_info "Current status:"
kubectl get chaosengine $EXPERIMENT_NAME -n $NAMESPACE -o wide

echo ""
echo "Watch experiment progress with:"
echo "  kubectl get chaosengine $EXPERIMENT_NAME -n $NAMESPACE -w"
echo ""
echo "Or use our monitoring script:"
echo "  watch -n 5 kubectl get chaosengine,chaosresult -n $NAMESPACE"
echo ""

# Step 7: Wait for completion (optional)
read -p "Wait for experiment to complete? [Y/n] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    log_info "Waiting for chaos experiment to complete..."
    echo "This may take several minutes..."
    
    # Wait up to 10 minutes
    TIMEOUT=600
    ELAPSED=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
        STATUS=$(kubectl get chaosengine $EXPERIMENT_NAME -n $NAMESPACE -o jsonpath='{.status.engineStatus}' 2>/dev/null || echo "unknown")
        
        if [ "$STATUS" == "completed" ]; then
            log_success "Chaos experiment completed!"
            break
        elif [ "$STATUS" == "stopped" ]; then
            log_warning "Chaos experiment stopped"
            break
        fi
        
        echo -n "."
        sleep 10
        ELAPSED=$((ELAPSED + 10))
    done
    echo ""
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
        log_warning "Timeout waiting for experiment to complete"
        log_info "Experiment is still running in the background"
    fi
fi

# Step 8: View Results
echo ""
echo "================================================================"
echo "STEP 8: View Results"
echo "================================================================"

log_info "Fetching chaos results..."
sleep 2

kubectl get chaosresult -n $NAMESPACE

echo ""
log_info "To see detailed results, run:"
echo "  ./scripts/get-chaos-results.sh"
echo ""

# Step 9: Verify Data Consistency
echo ""
echo "================================================================"
echo "STEP 9: Verify Data Consistency"
echo "================================================================"

read -p "Run data consistency checks? [Y/n] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    log_info "Running data consistency verification..."
    ./scripts/verify-data-consistency.sh $CLUSTER_NAME $DATABASE $NAMESPACE
else
    log_info "Skipping data consistency checks"
    log_info "Run manually with: ./scripts/verify-data-consistency.sh $CLUSTER_NAME $DATABASE $NAMESPACE"
fi

# Final Summary
echo ""
echo "================================================================"
echo "    Chaos Testing Complete!"
echo "================================================================"
echo ""
log_success "Experiment execution finished"
echo ""
echo "Next steps:"
echo "  1. Review chaos results:"
echo "     kubectl describe chaosresult -n $NAMESPACE"
echo ""
echo "  2. Check Prometheus metrics:"
echo "     kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090"
echo ""
echo "  3. View pod status:"
echo "     kubectl get pods -l cnpg.io/cluster=$CLUSTER_NAME -n $NAMESPACE"
echo ""
echo "  4. Check cluster health:"
echo "     kubectl get cluster $CLUSTER_NAME -n $NAMESPACE"
echo ""
echo "  5. Clean up (when done):"
echo "     kubectl delete chaosengine $EXPERIMENT_NAME -n $NAMESPACE"
echo ""
echo "For detailed analysis, see: docs/CNPG_CHAOS_TESTING_COMPLETE_GUIDE.md"
echo ""
