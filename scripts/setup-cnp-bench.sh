#!/bin/bash
# Setup cnp-bench for advanced CNPG benchmarking
# cnp-bench is EDB's official tool for benchmarking CloudNativePG
# 
# Features:
# - Storage performance testing (fio)
# - Database performance testing (pgbench)
# - Grafana dashboards for visualization
# - Integration with Prometheus
#
# Documentation: https://github.com/cloudnative-pg/cnp-bench

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
NAMESPACE=${2:-default}
BENCH_NAMESPACE="cnpg-bench"
HELM_RELEASE="cnp-bench"

echo "=========================================="
echo "  cnp-bench Setup for CNPG"
echo "=========================================="
echo ""
echo "Target Cluster: $CLUSTER_NAME"
echo "Namespace:      $NAMESPACE"
echo "Bench Namespace: $BENCH_NAMESPACE"
echo ""

# ============================================================
# Step 1: Check prerequisites
# ============================================================
echo -e "${BLUE}Step 1: Checking prerequisites...${NC}"
echo ""

# Check Helm
if ! command -v helm &> /dev/null; then
  echo -e "${RED}❌ Error: Helm not found${NC}"
  echo ""
  echo "Please install Helm first:"
  echo "  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  echo ""
  echo "Or visit: https://helm.sh/docs/intro/install/"
  exit 1
fi

HELM_VERSION=$(helm version --short)
echo -e "${GREEN}✓${NC} Helm found: $HELM_VERSION"

# Check kubectl
if ! command -v kubectl &> /dev/null; then
  echo -e "${RED}❌ Error: kubectl not found${NC}"
  exit 1
fi
echo -e "${GREEN}✓${NC} kubectl found"

# Check if cluster exists
if ! kubectl get cluster $CLUSTER_NAME -n $NAMESPACE &>/dev/null; then
  echo -e "${RED}❌ Error: Cluster '$CLUSTER_NAME' not found in namespace '$NAMESPACE'${NC}"
  exit 1
fi
echo -e "${GREEN}✓${NC} Target cluster found: $CLUSTER_NAME"

# Check kubectl-cnpg plugin
if ! kubectl cnpg status $CLUSTER_NAME -n $NAMESPACE &>/dev/null; then
  echo -e "${YELLOW}⚠️  Warning: kubectl-cnpg plugin not found or not working${NC}"
  echo "   Install with: curl -sSfL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh | sh -s -- -b /usr/local/bin"
else
  echo -e "${GREEN}✓${NC} kubectl-cnpg plugin found"
fi

echo ""

# ============================================================
# Step 2: Add Helm repository
# ============================================================
echo -e "${BLUE}Step 2: Adding cnp-bench Helm repository...${NC}"
echo ""

# Note: As of now, cnp-bench may not have an official Helm repo yet
# Check https://github.com/cloudnative-pg/cnp-bench for latest installation method

echo -e "${YELLOW}ℹ️  Note: cnp-bench is currently evolving${NC}"
echo "   Check latest installation instructions at:"
echo "   https://github.com/cloudnative-pg/cnp-bench"
echo ""

# For now, we'll provide instructions for manual setup
echo -e "${CYAN}Current installation options:${NC}"
echo ""

# ============================================================
# Option 1: Using kubectl cnpg pgbench (Built-in)
# ============================================================
echo "=========================================="
echo "Option 1: Built-in pgbench (Recommended)"
echo "=========================================="
echo ""
echo "The CloudNativePG kubectl plugin includes built-in pgbench support."
echo "This is the simplest way to run benchmarks."
echo ""
echo "Installation:"
echo "  curl -sSfL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh | sh -s -- -b /usr/local/bin"
echo ""
echo "Usage Examples:"
echo ""
echo "  # Initialize pgbench tables"
echo "  kubectl cnpg pgbench \\\\
echo "    $CLUSTER_NAME \\\\
echo "    --namespace $NAMESPACE \\\\
echo "    --db-name app \\\\
echo "    --job-name pgbench-init \\\\
echo "    -- --initialize --scale 50"
echo ""
echo "  # Run benchmark (300 seconds, 10 clients, 2 jobs)"
echo "  kubectl cnpg pgbench \\\\
echo "    $CLUSTER_NAME \\\\
echo "    --namespace $NAMESPACE \\\\
echo "    --db-name app \\\\
echo "    --job-name pgbench-run \\\\
echo "    -- --time 300 --client 10 --jobs 2"
echo ""
echo "  # Run with custom script"
echo "  kubectl cnpg pgbench \\\\
echo "    $CLUSTER_NAME \\\\
echo "    --namespace $NAMESPACE \\\\
echo "    --db-name app \\\\
echo "    --job-name pgbench-custom \\\\
echo "    -- -f custom.sql --time 600"
echo ""

# ============================================================
# Option 2: Manual cnp-bench deployment
# ============================================================
echo "=========================================="
echo "Option 2: cnp-bench Helm Chart (Advanced)"
echo "=========================================="
echo ""
echo "For advanced features including fio storage benchmarks and Grafana dashboards."
echo ""
echo "Installation steps:"
echo ""
echo "1. Clone the repository:"
echo "   git clone https://github.com/cloudnative-pg/cnp-bench.git"
echo "   cd cnp-bench"
echo ""
echo "2. Install using Helm:"
echo "   helm install $HELM_RELEASE ./charts/cnp-bench \\\\
echo "     --namespace $BENCH_NAMESPACE \\\\
echo "     --create-namespace \\\\
echo "     --set targetCluster.name=$CLUSTER_NAME \\\\
echo "     --set targetCluster.namespace=$NAMESPACE"
echo ""
echo "3. Run storage benchmark:"
echo "   kubectl cnpg fio $CLUSTER_NAME \\\\
echo "     --namespace $NAMESPACE \\\\
echo "     --storageClass standard"
echo ""
echo "4. Access Grafana dashboards:"
echo "   kubectl port-forward -n $BENCH_NAMESPACE svc/grafana 3000:80"
echo "   # Open http://localhost:3000"
echo ""

# ============================================================
# Option 3: Custom Job (What we already created)
# ============================================================
echo "=========================================="
echo "Option 3: Custom Workload Jobs (Current)"
echo "=========================================="
echo ""
echo "We've already created custom workload manifests in this repo:"
echo ""
echo "Files:"
echo "  - workloads/pgbench-continuous-job.yaml"
echo "  - scripts/init-pgbench-testdata.sh"
echo "  - scripts/run-e2e-chaos-test.sh"
echo ""
echo "Usage:"
echo "  # Initialize data"
echo "  ./scripts/init-pgbench-testdata.sh $CLUSTER_NAME app 50"
echo ""
echo "  # Run workload"
echo "  kubectl apply -f workloads/pgbench-continuous-job.yaml"
echo ""
echo "  # Full E2E test"
echo "  ./scripts/run-e2e-chaos-test.sh $CLUSTER_NAME app cnpg-primary-with-workload 600"
echo ""

# ============================================================
# Recommendation based on use case
# ============================================================
echo "=========================================="
echo "Recommendations"
echo "=========================================="
echo ""
echo "Choose based on your needs:"
echo ""
echo "  ✅ For Chaos Testing:"
echo "     Use Option 3 (Custom Jobs) - Already configured in this repo"
echo "     Best integration with Litmus chaos experiments"
echo ""
echo "  ✅ For Quick Benchmarks:"
echo "     Use Option 1 (kubectl cnpg pgbench)"
echo "     Simple, no extra installations needed"
echo ""
echo "  ✅ For Production Evaluation:"
echo "     Use Option 2 (cnp-bench)"
echo "     Comprehensive testing with storage benchmarks"
echo "     Includes visualization dashboards"
echo ""

# ============================================================
# Quick start example
# ============================================================
echo "=========================================="
echo "Quick Start Example"
echo "=========================================="
echo ""
echo "Try this now to verify your setup works:"
echo ""

cat << 'EOF'
# 1. Initialize test data (if not done already)
./scripts/init-pgbench-testdata.sh pg-eu app 10

# 2. Run a quick 60-second benchmark
kubectl cnpg pgbench pg-eu \
  --namespace default \
  --db-name app \
  --job-name quick-bench \
  -- --time 60 --client 5 --jobs 2 --progress 10

# 3. Check results
kubectl logs -n default job/quick-bench

# 4. Or run using our custom workload
kubectl apply -f workloads/pgbench-continuous-job.yaml

# 5. Monitor progress
kubectl logs -f job/pgbench-workload --all-containers

# 6. Clean up
kubectl delete job quick-bench pgbench-workload
EOF

echo ""
echo "=========================================="
echo -e "${GREEN}✅ Setup Information Complete${NC}"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Choose an option above based on your needs"
echo "  2. Run the quick start example to verify"
echo "  3. Review the full guide: docs/CNPG_E2E_TESTING_GUIDE.md"
echo ""
echo "For questions or issues:"
echo "  - CNPG Docs: https://cloudnative-pg.io/documentation/"
echo "  - cnp-bench: https://github.com/cloudnative-pg/cnp-bench"
echo "  - Slack: #cloudnativepg on Kubernetes Slack"
echo ""

# ============================================================
# Optional: Interactive setup
# ============================================================
echo ""
read -p "Would you like to run a quick benchmark now? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo ""
  echo "Running quick benchmark..."
  echo ""
  
  # Check if test data exists
  PASSWORD=$(kubectl get secret ${CLUSTER_NAME}-credentials -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d 2>/dev/null)
  
  if [ -z "$PASSWORD" ]; then
    echo -e "${RED}❌ Cannot retrieve database password${NC}"
    exit 1
  fi
  
  TABLES=$(kubectl run temp-check-$$ --rm -i --restart=Never \
    --image=postgres:16 \
    --namespace=$NAMESPACE \
    --env="PGPASSWORD=$PASSWORD" \
    --command -- \
    psql -h ${CLUSTER_NAME}-rw -U app -d app -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_name LIKE 'pgbench_%';" 2>/dev/null || echo "0")
  
  if [ "$TABLES" -lt 4 ]; then
    echo "Test data not found. Initializing..."
    bash "$(dirname "$0")/init-pgbench-testdata.sh" $CLUSTER_NAME app 10 $NAMESPACE
  fi
  
  echo ""
  echo "Starting 60-second benchmark..."
  echo ""
  
  # Create a quick benchmark job
  kubectl run pgbench-quick-$$ --rm -i --restart=Never \
    --image=postgres:16 \
    --namespace=$NAMESPACE \
    --env="PGPASSWORD=$PASSWORD" \
    --command -- \
    pgbench -h ${CLUSTER_NAME}-rw -U app -d app -c 5 -j 2 -T 60 -P 10
  
  echo ""
  echo -e "${GREEN}✅ Benchmark completed!${NC}"
else
  echo "Skipping benchmark. You can run it later using the examples above."
fi

echo ""
echo "Done! 🎉"
